#!/usr/bin/env bash
# Upload one real file to an existing Zenodo draft. Authentication is supplied
# to curl over stdin so the token is not exposed in process arguments.

set -euo pipefail
umask 077

usage() {
    cat <<'EOF'
Usage:
  zenodo_upload.sh --deposit-id ID --file PATH [options]

Required:
  --deposit-id ID       Existing Zenodo draft deposition ID
  --file PATH           File to upload

Options:
  --background          Run through nohup and write a timestamped log
  --log-dir DIRECTORY   Background log directory (default: ./logs)
  --sandbox             Use sandbox.zenodo.org and ~/.zenodo_sandbox_token
  --dry-run             Validate and print the intended upload; no request
  -h, --help            Show this help

Set ZENODO_TOKEN_FILE to use a different token file. The file must not be
accessible by group or other users.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

DEPOSIT_ID=''
FILE=''
BACKGROUND=false
DRY_RUN=false
SANDBOX=false
LOG_DIR=''
WORKER=false

while (($#)); do
    case "$1" in
        --deposit-id)
            (($# >= 2)) || die '--deposit-id requires a value'
            DEPOSIT_ID=$2
            shift 2
            ;;
        --file)
            (($# >= 2)) || die '--file requires a value'
            FILE=$2
            shift 2
            ;;
        --background)
            BACKGROUND=true
            shift
            ;;
        --log-dir)
            (($# >= 2)) || die '--log-dir requires a value'
            LOG_DIR=$2
            shift 2
            ;;
        --sandbox)
            SANDBOX=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --worker)
            WORKER=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n "$DEPOSIT_ID" ]] || die 'missing required argument: --deposit-id'
[[ "$DEPOSIT_ID" =~ ^[0-9]+$ ]] || die '--deposit-id must contain digits only'
[[ -n "$FILE" ]] || die 'missing required argument: --file'
[[ -f "$FILE" ]] || die "file not found: $FILE"
[[ -r "$FILE" ]] || die "file is not readable: $FILE"

FILE=$(realpath "$FILE")
FILENAME=$(basename "$FILE")
[[ "$FILENAME" != *$'\n'* && "$FILENAME" != *$'\r'* ]] || die 'filename must not contain a newline'
FILE_SIZE_BYTES=$(stat -c '%s' "$FILE")
FILE_SIZE_HUMAN=$(du -h "$FILE" | cut -f1)

if $SANDBOX; then
    BASE_URL='https://sandbox.zenodo.org'
    DEFAULT_TOKEN_FILE="${HOME}/.zenodo_sandbox_token"
    EXPECTED_HOST='sandbox.zenodo.org'
else
    BASE_URL='https://zenodo.org'
    DEFAULT_TOKEN_FILE="${HOME}/.zenodo_token"
    EXPECTED_HOST='zenodo.org'
fi

if $DRY_RUN; then
    printf 'DRY RUN — no network request was made.\n'
    printf 'File:       %s\n' "$FILE"
    printf 'Size:       %s bytes (%s)\n' "$FILE_SIZE_BYTES" "$FILE_SIZE_HUMAN"
    printf 'Deposit:    %s\n' "$DEPOSIT_ID"
    printf 'Service:    %s\n' "$BASE_URL"
    exit 0
fi

if $BACKGROUND && ! $WORKER; then
    SCRIPT_PATH=$(realpath "$0")
    LOG_DIR=${LOG_DIR:-"${PWD}/logs"}
    mkdir -p -- "$LOG_DIR"
    LOG_DIR=$(realpath "$LOG_DIR")
    TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
    SAFE_FILENAME=$(printf '%s' "$FILENAME" | tr -c 'A-Za-z0-9._-' '_')
    LOG_FILE="${LOG_DIR}/zenodo_upload_${DEPOSIT_ID}_${SAFE_FILENAME}_${TIMESTAMP}.log"
    [[ ! -e "$LOG_FILE" ]] || die "refusing to overwrite existing log: $LOG_FILE"

    worker_args=(--deposit-id "$DEPOSIT_ID" --file "$FILE" --worker)
    $SANDBOX && worker_args+=(--sandbox)
    nohup "$SCRIPT_PATH" "${worker_args[@]}" > "$LOG_FILE" 2>&1 < /dev/null &
    WORKER_PID=$!
    printf 'Upload started in background.\n'
    printf 'PID: %s\n' "$WORKER_PID"
    printf 'Log: %s\n' "$LOG_FILE"
    exit 0
fi

TOKEN_FILE=${ZENODO_TOKEN_FILE:-$DEFAULT_TOKEN_FILE}
[[ -f "$TOKEN_FILE" ]] || die "token file not found: $TOKEN_FILE"
[[ -r "$TOKEN_FILE" ]] || die "token file is not readable: $TOKEN_FILE"

TOKEN_MODE=$(stat -c '%a' "$TOKEN_FILE")
TOKEN_MODE_DEC=$((8#$TOKEN_MODE))
(( (TOKEN_MODE_DEC & 077) == 0 )) || die "token file permissions must be 600 or stricter: $TOKEN_FILE"

TOKEN=$(<"$TOKEN_FILE")
[[ -n "$TOKEN" ]] || die "token file is empty: $TOKEN_FILE"
[[ "$TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || \
    die 'token contains characters that cannot be safely passed to curl'

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agent_${USER:-user}_XXXXXX")
trap 'rm -rf -- "$TEMP_DIR"' EXIT
DEPOSIT_RESPONSE="${TEMP_DIR}/deposit.json"
UPLOAD_RESPONSE="${TEMP_DIR}/upload.json"

api_request() {
    local method=$1
    local url=$2
    local output_file=$3
    shift 3
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
        curl --config - \
            --silent \
            --show-error \
            --retry 3 \
            --retry-all-errors \
            --connect-timeout 30 \
            --request "$method" \
            --output "$output_file" \
            --write-out '%{http_code}' \
            "$@" \
            "$url"
}

DEPOSIT_URL="${BASE_URL}/api/deposit/depositions/${DEPOSIT_ID}"
if ! HTTP_CODE=$(api_request GET "$DEPOSIT_URL" "$DEPOSIT_RESPONSE"); then
    printf 'ERROR: failed to retrieve Zenodo deposition %s.\n' "$DEPOSIT_ID" >&2
    [[ ! -s "$DEPOSIT_RESPONSE" ]] || cat "$DEPOSIT_RESPONSE" >&2
    exit 1
fi
if [[ "$HTTP_CODE" != '200' ]]; then
    printf 'ERROR: Zenodo returned HTTP %s while retrieving deposition %s.\n' \
        "$HTTP_CODE" "$DEPOSIT_ID" >&2
    cat "$DEPOSIT_RESPONSE" >&2
    exit 1
fi

if ! BUCKET_URL=$(python3 - "$DEPOSIT_RESPONSE" "$EXPECTED_HOST" <<'PY'
import json
import sys
from urllib.parse import urlparse

with open(sys.argv[1], encoding="utf-8") as handle:
    bucket = json.load(handle)["links"]["bucket"]
parsed = urlparse(bucket)
if parsed.scheme != "https" or parsed.hostname != sys.argv[2] or not parsed.path.startswith("/api/files/"):
    raise SystemExit("unsafe or unexpected bucket URL")
print(bucket.rstrip("/"))
PY
); then
    printf 'ERROR: deposition response contained no trusted bucket URL.\n' >&2
    cat "$DEPOSIT_RESPONSE" >&2
    exit 1
fi

ENCODED_FILENAME=$(python3 - "$FILENAME" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
)
UPLOAD_URL="${BUCKET_URL}/${ENCODED_FILENAME}"

START_SIZE=$(stat -c '%s' "$FILE")
START_MTIME=$(stat -c '%Y' "$FILE")
LOCAL_CHECKSUM=$(md5sum "$FILE" | awk '{print $1}')

printf 'Zenodo upload started.\n'
printf 'Script:     %s\n' "$(realpath "$0")"
printf 'Started:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'File:       %s\n' "$FILE"
printf 'Size:       %s bytes (%s)\n' "$FILE_SIZE_BYTES" "$FILE_SIZE_HUMAN"
printf 'Deposit:    %s\n' "$DEPOSIT_ID"
printf 'Service:    %s\n' "$BASE_URL"

if ! HTTP_CODE=$(api_request PUT "$UPLOAD_URL" "$UPLOAD_RESPONSE" --upload-file "$FILE"); then
    printf 'ERROR: file upload failed before a valid HTTP response was received.\n' >&2
    [[ ! -s "$UPLOAD_RESPONSE" ]] || cat "$UPLOAD_RESPONSE" >&2
    exit 1
fi
if [[ "$HTTP_CODE" != '200' && "$HTTP_CODE" != '201' ]]; then
    printf 'ERROR: Zenodo returned HTTP %s during upload.\n' "$HTTP_CODE" >&2
    cat "$UPLOAD_RESPONSE" >&2
    exit 1
fi

END_SIZE=$(stat -c '%s' "$FILE")
END_MTIME=$(stat -c '%Y' "$FILE")
if [[ "$START_SIZE" != "$END_SIZE" || "$START_MTIME" != "$END_MTIME" ]]; then
    printf 'ERROR: input file changed during upload; checksum validation is invalid.\n' >&2
    exit 1
fi

if ! REMOTE_CHECKSUM=$(python3 - "$UPLOAD_RESPONSE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    checksum = json.load(handle)["checksum"]
print(str(checksum).removeprefix("md5:").lower())
PY
); then
    printf 'ERROR: upload response contained no valid checksum.\n' >&2
    cat "$UPLOAD_RESPONSE" >&2
    exit 1
fi

if [[ "${LOCAL_CHECKSUM,,}" != "$REMOTE_CHECKSUM" ]]; then
    printf 'ERROR: checksum mismatch (local %s, Zenodo %s).\n' \
        "$LOCAL_CHECKSUM" "$REMOTE_CHECKSUM" >&2
    exit 1
fi

printf 'Checksum verified: md5:%s\n' "$LOCAL_CHECKSUM"
printf 'Completed:   %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Review draft: %s/deposit/%s\n' "$BASE_URL" "$DEPOSIT_ID"
