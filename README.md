# Remote Uploading: HPC to Zenodo

Upload large datasets directly from an HPC cluster to Zenodo, bypassing slow local internet.

## Why

- HPC clusters typically have fast network connections (10+ Gbps)
- Avoids downloading to a local machine and re-uploading
- Zenodo's REST API works with `curl` from any login node
- 46 GB uploaded in ~45 minutes from NYU Abu Dhabi Jubail HPC

## Prerequisites

- Shell access to an HPC login node with outbound internet
- A [Zenodo](https://zenodo.org) account
- A Zenodo Personal Access Token (see [Setup](#1-create-a-zenodo-api-token))
- `curl` and `python3` available on the cluster

## Quick Start

```bash
# 1. Store your token
echo 'YOUR_TOKEN' > ~/.zenodo_token && chmod 600 ~/.zenodo_token

# 2. Create a draft deposit
./zenodo_create_draft.sh "My Dataset Title" "Description of the dataset"

# 3. Upload a file
./zenodo_upload.sh DEPOSIT_ID /path/to/data.tar.gz

# 4. Check upload status
cat /tmp/zenodo_upload_*.log

# 5. Review draft at https://zenodo.org/deposit/DEPOSIT_ID
# 6. Publish when ready (web UI or API)
```

## Detailed Walkthrough

### 1. Create a Zenodo API Token

1. Log in to [zenodo.org](https://zenodo.org)
2. Go to **Settings > Applications > Personal access tokens**
3. Click **New token**
4. Name it (e.g., `hpc-uploads`)
5. Enable scopes: `deposit:actions` and `deposit:write`
6. Copy the token immediately (it won't be shown again)

### 2. Store the Token on HPC

```bash
# Store with restricted permissions
echo 'YOUR_TOKEN_HERE' > ~/.zenodo_token
chmod 600 ~/.zenodo_token

# Verify
cat ~/.zenodo_token
```

> **Security**: Delete the token from Zenodo's web UI when you're done uploading.
> Delete the file with `rm ~/.zenodo_token` afterwards.

### 3. Create a Draft Deposit

```bash
TOKEN=$(cat ~/.zenodo_token)

curl -s -X POST "https://zenodo.org/api/deposit/depositions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "metadata": {
      "title": "Your Dataset Title",
      "upload_type": "dataset",
      "description": "What this dataset contains and how it was generated.",
      "creators": [
        {"name": "Last, First", "affiliation": "Your Institution"}
      ],
      "keywords": ["keyword1", "keyword2"],
      "license": "cc-by-4.0"
    }
  }' | python3 -m json.tool
```

From the JSON response, note:
- **`id`** — your deposit ID
- **`links.bucket`** — the upload URL (e.g., `https://zenodo.org/api/files/BUCKET-UUID`)
- **`metadata.prereserve_doi.doi`** — your pre-reserved DOI

### 4. Upload Files

```bash
TOKEN=$(cat ~/.zenodo_token)
BUCKET_URL="https://zenodo.org/api/files/BUCKET-UUID"  # from step 3
FILE="/path/to/your/data.tar.gz"
FILENAME=$(basename "$FILE")

curl -X PUT "$BUCKET_URL/$FILENAME" \
  -H "Authorization: Bearer $TOKEN" \
  --upload-file "$FILE"
```

#### Background upload (recommended for large files)

```bash
TOKEN=$(cat ~/.zenodo_token)
BUCKET_URL="https://zenodo.org/api/files/BUCKET-UUID"
FILE="/path/to/your/data.tar.gz"
FILENAME=$(basename "$FILE")
LOGFILE="/tmp/zenodo_upload_${FILENAME}.log"

nohup bash -c "curl -X PUT '$BUCKET_URL/$FILENAME' \
  -H 'Authorization: Bearer $TOKEN' \
  --upload-file '$FILE' \
  -o '$LOGFILE' \
  -w '\nHTTP_CODE:%{http_code} SPEED:%{speed_upload} TIME:%{time_total}\n' \
  2>&1 && echo DONE >> '$LOGFILE'" \
  > "${LOGFILE}.nohup" 2>&1 &

echo "Upload running in background. Check: cat $LOGFILE"
```

#### Monitor progress

```bash
# Check if curl is still running
ps aux | grep 'curl.*zenodo' | grep -v grep

# Check completion
cat /tmp/zenodo_upload_*.log
```

A successful upload returns JSON with `"checksum": "md5:..."` and the log ends with `DONE`.

### 5. Upload Multiple Files to One Deposit

You can upload multiple files to the same deposit — just use the same bucket URL:

```bash
for FILE in /path/to/files/*.tar.gz; do
  FILENAME=$(basename "$FILE")
  echo "Uploading $FILENAME..."
  curl -X PUT "$BUCKET_URL/$FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    --upload-file "$FILE"
done
```

### 6. Update Metadata (Optional)

```bash
DEPOSIT_ID=12345678
TOKEN=$(cat ~/.zenodo_token)

curl -X PUT "https://zenodo.org/api/deposit/depositions/$DEPOSIT_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "metadata": {
      "title": "Updated Title",
      "upload_type": "dataset",
      "description": "Updated description.",
      "creators": [
        {"name": "Last, First", "affiliation": "Institution"},
        {"name": "Colleague, A.", "affiliation": "Other Institution"}
      ],
      "keywords": ["keyword1", "keyword2"],
      "license": "cc-by-4.0",
      "related_identifiers": [
        {
          "identifier": "10.1234/your.paper.doi",
          "relation": "isSupplementTo",
          "scheme": "doi"
        }
      ]
    }
  }' | python3 -m json.tool
```

### 7. Publish

> **Warning**: Publishing is permanent. It mints a DOI and the record cannot be deleted.
> You can still upload new versions afterwards.

**Option A — Web UI (recommended)**:
Visit `https://zenodo.org/deposit/DEPOSIT_ID` and click **Publish**.

**Option B — API**:
```bash
curl -X POST "https://zenodo.org/api/deposit/depositions/$DEPOSIT_ID/actions/publish" \
  -H "Authorization: Bearer $TOKEN"
```

### 8. Clean Up

```bash
# Remove token from HPC
rm ~/.zenodo_token

# Revoke token on Zenodo web UI:
# Settings > Applications > Personal access tokens > Delete
```

## Limits and Tips

| Constraint | Value |
|---|---|
| Max file size | 50 GB per file |
| Max total per deposit | 50 GB |
| Supported formats | Any (tar.gz, zip, fasta, etc.) |

- **Compress first**: `tar czf data.tar.gz data/` on a compute node before uploading
- **Run from login node**: Compute nodes may not have outbound internet
- **Use `nohup`**: SSH disconnects won't kill the upload
- **Use `tmux`/`screen`**: Even safer for very long uploads
- **Verify checksums**: The API response includes an MD5 — compare with `md5sum yourfile`
- **Draft deposits persist**: No rush to publish; edit metadata via web UI at any time

## Helper Scripts

See [`zenodo_create_draft.sh`](zenodo_create_draft.sh) and [`zenodo_upload.sh`](zenodo_upload.sh) for ready-to-use wrappers.

## License

MIT
