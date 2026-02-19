#!/usr/bin/env zsh

function LOG() {
  echo "[LOG] $1"
}

function TRAPZERR() {
  local ret=$?
  LOG "Non zero exit code($ret) detected. Exiting..."
  exit $ret
}

cd ${0:A:h}

source ${0:A:h}/script.conf

function init_system() {
  LOG 'Initing pacman'
  cat >> /etc/pacman.conf <<EOF

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
  print $MAKEPKG_CONF >> /etc/makepkg.conf

  LOG "Initing user"
  useradd --create-home aur-build
  printf "123\n123" | passwd aur-build
  print "aur-build ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
  mkdir -p /home/aur-build/.cache/go-build
  chown -R aur-build:aur-build ~aur-build

  LOG "Initing GPG"
  rm -fr /etc/pacman.d/gnupg
  pacman-key --init
  pacman-key --populate archlinux
  pacman-key --add ${0:A:h}/data/private.key
  pacman-key --lsign-key $GPGKEY

  LOG "Importing GPG (no passphrase key)"
  install -Dm600 -o aur-build -g aur-build \
  "${0:A:h}/data/private.key" \
  "/home/aur-build/private.key"
  sudo -u aur-build gpg --import --batch --yes /home/aur-build/private.key
  shred --remove /home/aur-build/private.key
  shred --remove ${0:A:h}/data/private.key

  # NOTE:
  # The original script presets passphrase via gpg-preset-passphrase.
  # Since your private key has NO passphrase, we skip all preset-passphrase logic.

  LOG "Initing repo"
  mkdir -p ~aur-build/.cache/{pikaur/{build,pkg},aur}
  chown -R aur-build:aur-build ~aur-build/.cache/{pikaur/{build,pkg},aur}
  if [[ ! -f ~aur-build/.cache/pikaur/pkg/$REPO_NAME.db.tar.gz ]]; then
    sudo -u aur-build repo-add -n -p -s -k $GPGKEY \
         ~aur-build/.cache/pikaur/pkg/$REPO_NAME.db.tar.gz
  fi

  LOG 'Installing packages'
  # rclone is required for uploading to Cloudflare R2
  pacman -Syu git pacman-contrib rclone --noconfirm --needed --noprogressbar
  sudo -u aur-build -H bash -lc '
    set -e
    cd "$HOME"
    rm -rf pikaur
    git clone https://aur.archlinux.org/pikaur.git
    cd pikaur
    makepkg -fsri --noconfirm
  '
}

function current_package_list() {
  LOG "Current package list"
  for i in ~aur-build/.cache/pikaur/pkg/*.pkg.tar.*~*.sig; do
    LOG "=> $i"
  done
}

function build_repo() {
  setopt local_options null_glob extended_glob
  current_package_list
  paccache -rvk1 -c ~aur-build/.cache/pikaur/pkg
  local -a new_packages=(~aur-build/.cache/pikaur/pkg/*.pkg.tar.*~*.sig)
  local -a new_packages=(${new_packages:|packages})
  if (( $#new_packages )); then
    LOG "There are $#new_packages new packages"
    sudo -u aur-build repo-add -n -p -s -k $GPGKEY \
         ~aur-build/.cache/pikaur/pkg/$REPO_NAME.db.tar.gz \
         $new_packages
  else
    LOG "No new package"
  fi
}

function deploy() {
  LOG "Uploading repo to Cloudflare R2 (rclone)"

  : "${R2_ENDPOINT:?R2_ENDPOINT is required in script.conf}"
  : "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required in script.conf}"
  : "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required in script.conf}"
  : "${R2_REPO_PREFIX:?R2_REPO_PREFIX is required in script.conf}"
  : "${R2_REGION:=auto}"

  # Create an rclone remote via env (no creds in argv)
  export RCLONE_CONFIG_R2_TYPE="s3"
  export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
  export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"      # bucket-level endpoint is OK here
  export RCLONE_CONFIG_R2_REGION="$R2_REGION"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_ENV_AUTH="false"
  export RCLONE_CONFIG_R2_FORCE_PATH_STYLE="true"

  # Sync local repo dir to the prefix on the bucket
  # Trailing slash matters: keep it on source, and ensure prefix ends with /
  rclone sync ~aur-build/.cache/pikaur/pkg/ "R2:${R2_REPO_PREFIX}" --config /dev/null --delete-during -L
}

function remove_package() {
  LOG "Revoming package $1"
  setopt local_options null_glob
  [[ -d ~aur-build/.cache/aur/$1 ]] && rm -rdf ~aur-build/.cache/aur/$1
  sudo -u aur-build repo-remove -s -k $GPGKEY ~aur-build/.cache/pikaur/pkg/$REPO_NAME.db.tar.gz $1 \
    || LOG "Cannot found $1 in database"
  for file in ~aur-build/.cache/pikaur/pkg/$1-*.pkg.tar.*; do
    rm -f $file
  done
}

function prebuild_hook() {
  setopt local_options null_glob extended_glob
  typeset -g -a packages=(~aur-build/.cache/pikaur/pkg/*.pkg.tar.*~*.sig)
  # remove_package libgccjit
  # remove_package emacs-native-comp-git
}

typeset -g -a packages=()

# init
init_system

prebuild_hook

# build packages
sudo -u aur-build zsh update_all.zsh

build_repo

deploy
