#!/usr/bin/env zsh
set -e
cd ${0:A:h}

source ./script.conf
function LOG() { echo "[LOG] $1" }

# Required env vars (R2 + script password)
: "${R2_ENDPOINT:?set R2_ENDPOINT (e.g. https://<ACCOUNT_ID>.r2.cloudflarestorage.com)}"
: "${R2_SCRIPT_KEY:?set R2_SCRIPT_KEY (object key, e.g. secret/script.7z)}"
: "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID}"
: "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY}"
: "${PASSWORD:?set PASSWORD (7z encryption password)}"

# Optional env var
: "${R2_REGION:=auto}"

command -v 7z >/dev/null 2>&1 || { echo "7z not found"; exit 1; }
command -v rclone >/dev/null 2>&1 || { echo "rclone not found"; exit 1; }

rm -f /tmp/script.7z
LOG "Packing script directory to /tmp/script.7z"
7z a /tmp/script.7z -mhe=on -p"$PASSWORD" ./ -xr!${0:A:h}/disabled

# ---- rclone S3 backend via env vars (no creds in argv) ----
# These env vars are supported by rclone's S3 backend config.
export RCLONE_CONFIG_R2_TYPE="s3"
export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
export RCLONE_CONFIG_R2_REGION="$R2_REGION"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENV_AUTH="false"
export RCLONE_CONFIG_R2_FORCE_PATH_STYLE="true"

LOG "Checking R2 connectivity..."
rclone lsf "R2:"

LOG "Uploading /tmp/script.7z to R2: s3://$R2_SCRIPT_KEY"
rclone copyto /tmp/script.7z "R2:${R2_SCRIPT_KEY}"

LOG "Done"
read
rm -f /tmp/script.7z
