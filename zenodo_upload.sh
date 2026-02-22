#!/usr/bin/env bash
# zenodo_upload.sh — Upload a file to an existing Zenodo draft deposit
#
# Usage:
#   ./zenodo_upload.sh DEPOSIT_ID /path/to/file.tar.gz
#   ./zenodo_upload.sh DEPOSIT_ID /path/to/file.tar.gz --background
#
# Requires: ~/.zenodo_token (chmod 600)

set -euo pipefail

DEPOSIT_ID="${1:?Usage: $0 DEPOSIT_ID /path/to/file [--background]}"
FILE="${2:?Usage: $0 DEPOSIT_ID /path/to/file [--background]}"
BACKGROUND="${3:-}"

if [[ ! -f "$FILE" ]]; then
    echo "ERROR: File not found: $FILE"
    exit 1
fi

TOKEN_FILE="${HOME}/.zenodo_token"
if [[ ! -f "$TOKEN_FILE" ]]; then
    echo "ERROR: Token file not found at $TOKEN_FILE"
    exit 1
fi
TOKEN=$(cat "$TOKEN_FILE")

FILENAME=$(basename "$FILE")
FILESIZE=$(du -h "$FILE" | cut -f1)

# Get the bucket URL from the deposit
BUCKET_URL=$(curl -s "https://zenodo.org/api/deposit/depositions/$DEPOSIT_ID" \
    -H "Authorization: Bearer $TOKEN" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['links']['bucket'])")

if [[ -z "$BUCKET_URL" || "$BUCKET_URL" == "None" ]]; then
    echo "ERROR: Could not retrieve bucket URL for deposit $DEPOSIT_ID"
    exit 1
fi

echo "Uploading: $FILENAME ($FILESIZE)"
echo "Target:    Deposit $DEPOSIT_ID"
echo "Bucket:    $BUCKET_URL"
echo ""

if [[ "$BACKGROUND" == "--background" ]]; then
    LOGFILE="/tmp/zenodo_upload_${DEPOSIT_ID}_${FILENAME}.log"
    echo "Running in background. Log: $LOGFILE"
    echo ""

    nohup bash -c "curl -X PUT '${BUCKET_URL}/${FILENAME}' \
        -H 'Authorization: Bearer ${TOKEN}' \
        --upload-file '${FILE}' \
        -o '${LOGFILE}' \
        -w '\nHTTP_CODE:%{http_code} SPEED_AVG:%{speed_upload} TIME:%{time_total}\n' \
        2>&1 && echo DONE >> '${LOGFILE}'" \
        > "${LOGFILE}.nohup" 2>&1 &

    echo "Monitor with:"
    echo "  ps aux | grep 'curl.*zenodo' | grep -v grep"
    echo "  cat $LOGFILE"
else
    curl -X PUT "${BUCKET_URL}/${FILENAME}" \
        -H "Authorization: Bearer ${TOKEN}" \
        --upload-file "${FILE}" \
        --progress-bar \
        | python3 -m json.tool

    echo ""
    echo "Upload complete. Review draft: https://zenodo.org/deposit/$DEPOSIT_ID"
fi
