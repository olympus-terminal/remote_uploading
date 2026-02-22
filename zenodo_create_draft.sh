#!/usr/bin/env bash
# zenodo_create_draft.sh — Create a Zenodo draft deposit from the command line
#
# Usage:
#   ./zenodo_create_draft.sh "Dataset Title" "Description of the dataset"
#   ./zenodo_create_draft.sh "Title" "Description" "Last, First" "Institution"
#
# Requires: ~/.zenodo_token (chmod 600)
# Output:   Deposit ID, bucket URL, and pre-reserved DOI

set -euo pipefail

TITLE="${1:?Usage: $0 \"Title\" \"Description\" [\"Author Name\" \"Affiliation\"]}"
DESCRIPTION="${2:?Usage: $0 \"Title\" \"Description\" [\"Author Name\" \"Affiliation\"]}"
CREATOR_NAME="${3:-}"
CREATOR_AFFIL="${4:-}"

TOKEN_FILE="${HOME}/.zenodo_token"
if [[ ! -f "$TOKEN_FILE" ]]; then
    echo "ERROR: Token file not found at $TOKEN_FILE"
    echo "Create one with: echo 'YOUR_TOKEN' > ~/.zenodo_token && chmod 600 ~/.zenodo_token"
    exit 1
fi
TOKEN=$(cat "$TOKEN_FILE")

# Build creator JSON
if [[ -n "$CREATOR_NAME" ]]; then
    CREATORS="[{\"name\": \"${CREATOR_NAME}\", \"affiliation\": \"${CREATOR_AFFIL}\"}]"
else
    CREATORS="[{\"name\": \"$(whoami)\"}]"
fi

RESPONSE=$(curl -s -X POST "https://zenodo.org/api/deposit/depositions" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"metadata\": {
            \"title\": \"${TITLE}\",
            \"upload_type\": \"dataset\",
            \"description\": \"${DESCRIPTION}\",
            \"creators\": ${CREATORS},
            \"license\": \"cc-by-4.0\"
        }
    }")

# Extract key fields
DEPOSIT_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id'])")
BUCKET_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['links']['bucket'])")
DOI=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['metadata']['prereserve_doi']['doi'])")
DRAFT_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['links']['html'])")

echo "=== Zenodo Draft Created ==="
echo "Deposit ID:  $DEPOSIT_ID"
echo "Bucket URL:  $BUCKET_URL"
echo "DOI:         $DOI"
echo "Draft URL:   $DRAFT_URL"
echo ""
echo "Next step — upload files:"
echo "  ./zenodo_upload.sh $DEPOSIT_ID /path/to/your/file.tar.gz"
