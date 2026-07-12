#!/usr/bin/env bash
# Create a metadata-complete Zenodo draft without exposing the access token in
# process arguments. The script never publishes a deposition.

set -euo pipefail
umask 077

usage() {
    cat <<'EOF'
Usage:
  zenodo_create_draft.sh --title TITLE --description DESCRIPTION \
    --creator "Last, First" --license LICENSE_ID [options]

Required:
  --title TITLE              Dataset title
  --description DESCRIPTION  Dataset description
  --creator NAME             Creator in "Last, First" form
  --license LICENSE_ID       Zenodo license identifier (for example, cc-by-4.0)

Options:
  --affiliation TEXT         Creator affiliation
  --upload-type TYPE         Zenodo upload type (default: dataset)
  --sandbox                  Use sandbox.zenodo.org and ~/.zenodo_sandbox_token
  --dry-run                  Print endpoint and validated JSON; make no request
  -h, --help                 Show this help

Set ZENODO_TOKEN_FILE to use a different token file. The file must not be
accessible by group or other users.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

TITLE=''
DESCRIPTION=''
CREATOR_NAME=''
CREATOR_AFFILIATION=''
LICENSE_ID=''
UPLOAD_TYPE='dataset'
SANDBOX=false
DRY_RUN=false

while (($#)); do
    case "$1" in
        --title)
            (($# >= 2)) || die '--title requires a value'
            TITLE=$2
            shift 2
            ;;
        --description)
            (($# >= 2)) || die '--description requires a value'
            DESCRIPTION=$2
            shift 2
            ;;
        --creator)
            (($# >= 2)) || die '--creator requires a value'
            CREATOR_NAME=$2
            shift 2
            ;;
        --affiliation)
            (($# >= 2)) || die '--affiliation requires a value'
            CREATOR_AFFILIATION=$2
            shift 2
            ;;
        --license)
            (($# >= 2)) || die '--license requires a value'
            LICENSE_ID=$2
            shift 2
            ;;
        --upload-type)
            (($# >= 2)) || die '--upload-type requires a value'
            UPLOAD_TYPE=$2
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
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

missing=()
[[ -n "$TITLE" ]] || missing+=(--title)
[[ -n "$DESCRIPTION" ]] || missing+=(--description)
[[ -n "$CREATOR_NAME" ]] || missing+=(--creator)
[[ -n "$LICENSE_ID" ]] || missing+=(--license)
if ((${#missing[@]})); then
    die "missing required arguments: ${missing[*]}"
fi

[[ "$LICENSE_ID" =~ ^[A-Za-z0-9.+-]+$ ]] || die 'invalid --license identifier'
[[ "$UPLOAD_TYPE" =~ ^[A-Za-z0-9_-]+$ ]] || die 'invalid --upload-type value'

if $SANDBOX; then
    BASE_URL='https://sandbox.zenodo.org'
    DEFAULT_TOKEN_FILE="${HOME}/.zenodo_sandbox_token"
else
    BASE_URL='https://zenodo.org'
    DEFAULT_TOKEN_FILE="${HOME}/.zenodo_token"
fi
API_URL="${BASE_URL}/api/deposit/depositions"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agent_${USER:-user}_XXXXXX")
trap 'rm -rf -- "$TEMP_DIR"' EXIT
REQUEST_FILE="${TEMP_DIR}/request.json"
RESPONSE_FILE="${TEMP_DIR}/response.json"

python3 - "$TITLE" "$DESCRIPTION" "$CREATOR_NAME" \
    "$CREATOR_AFFILIATION" "$LICENSE_ID" "$UPLOAD_TYPE" > "$REQUEST_FILE" <<'PY'
import json
import sys

title, description, creator_name, affiliation, license_id, upload_type = sys.argv[1:]
creator = {"name": creator_name}
if affiliation:
    creator["affiliation"] = affiliation
payload = {
    "metadata": {
        "title": title,
        "upload_type": upload_type,
        "description": description,
        "creators": [creator],
        "license": license_id,
        "prereserve_doi": True,
    }
}
json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY

if $DRY_RUN; then
    printf 'DRY RUN — no network request was made.\n'
    printf 'Endpoint: %s\n' "$API_URL"
    printf 'Request JSON:\n'
    cat "$REQUEST_FILE"
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

if ! HTTP_CODE=$(
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
        curl --config - \
            --silent \
            --show-error \
            --retry 3 \
            --retry-all-errors \
            --connect-timeout 30 \
            --request POST \
            --header 'Content-Type: application/json' \
            --data-binary "@${REQUEST_FILE}" \
            --output "$RESPONSE_FILE" \
            --write-out '%{http_code}' \
            "$API_URL"
); then
    printf 'ERROR: Zenodo request failed before a valid HTTP response was received.\n' >&2
    [[ ! -s "$RESPONSE_FILE" ]] || cat "$RESPONSE_FILE" >&2
    exit 1
fi

if [[ "$HTTP_CODE" != '201' ]]; then
    printf 'ERROR: Zenodo returned HTTP %s.\n' "$HTTP_CODE" >&2
    cat "$RESPONSE_FILE" >&2
    exit 1
fi

if ! SUMMARY=$(python3 - "$RESPONSE_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
required = {
    "id": data["id"],
    "bucket": data["links"]["bucket"],
    "doi": data["metadata"]["prereserve_doi"]["doi"],
    "html": data["links"]["html"],
}
print("\t".join(str(required[key]) for key in ("id", "bucket", "doi", "html")))
PY
); then
    printf 'ERROR: Zenodo returned an incomplete or invalid JSON response.\n' >&2
    cat "$RESPONSE_FILE" >&2
    exit 1
fi

IFS=$'\t' read -r DEPOSIT_ID BUCKET_URL DOI DRAFT_URL <<< "$SUMMARY"

printf 'Zenodo draft created (not published).\n'
printf 'Deposit ID:  %s\n' "$DEPOSIT_ID"
printf 'Bucket URL:  %s\n' "$BUCKET_URL"
printf 'Reserved DOI: %s\n' "$DOI"
printf 'Draft URL:   %s\n' "$DRAFT_URL"
printf '\nUpload a file with:\n'
printf '  ./zenodo_upload.sh --deposit-id %q --file /path/to/file\n' "$DEPOSIT_ID"
