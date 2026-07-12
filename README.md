<p align="center">
  <img src="assets/banner.png" alt="Remote Uploading: HPC to Zenodo" width="100%">
</p>

# Remote Uploading: HPC to Zenodo

Small Bash helpers for creating a Zenodo dataset draft and uploading a large
file directly from a Linux or HPC system. Draft creation and file upload are
supported; publishing remains an explicit action in the Zenodo web interface.

The helpers are designed to keep the access token out of command-line
arguments, validate API responses, refuse unsafe token-file permissions, and
verify the uploaded file against Zenodo's checksum.

## Requirements

- Bash
- Python 3.9 or newer
- curl 7.71 or newer
- GNU `coreutils` (`md5sum`, `realpath`, `stat`, and `du`)
- A Zenodo access token with `deposit:write`; add `deposit:actions` only if you
  intend to publish separately

Zenodo's sandbox uses a separate account and token from the production service.

## Secure token setup

Create the token in **Zenodo → Settings → Applications → Personal access
tokens**. Store it without putting the value in shell history or printing it to
the terminal:

```bash
umask 077
read -rsp 'Zenodo token: ' ZENODO_TOKEN
printf '\n'
printf '%s' "$ZENODO_TOKEN" > ~/.zenodo_token
unset ZENODO_TOKEN
chmod 600 ~/.zenodo_token
test -s ~/.zenodo_token && stat -c 'token mode: %a' ~/.zenodo_token
```

For sandbox testing, use `~/.zenodo_sandbox_token`. To use another location,
set `ZENODO_TOKEN_FILE` for the command. Never commit a token file.

## Quick start

Validate the metadata and endpoint without accessing a token or making a
network request:

```bash
./zenodo_create_draft.sh \
  --title "Dataset title" \
  --description "What the dataset contains and how it was generated." \
  --creator "Last, First" \
  --affiliation "Institution" \
  --license cc-by-4.0 \
  --dry-run
```

Create the draft only after reviewing that JSON:

```bash
./zenodo_create_draft.sh \
  --title "Dataset title" \
  --description "What the dataset contains and how it was generated." \
  --creator "Last, First" \
  --affiliation "Institution" \
  --license cc-by-4.0
```

The creator and license are required explicitly; the script does not infer
identity or reuse terms. The response prints the deposition ID, reserved DOI,
and draft URL.

Upload one file to that draft:

```bash
./zenodo_upload.sh \
  --deposit-id DEPOSIT_ID \
  --file /path/to/data.tar.gz \
  --dry-run

./zenodo_upload.sh \
  --deposit-id DEPOSIT_ID \
  --file /path/to/data.tar.gz
```

For a long upload, use background mode:

```bash
./zenodo_upload.sh \
  --deposit-id DEPOSIT_ID \
  --file /path/to/data.tar.gz \
  --background
```

Background logs are written under `./logs/` by default. Each filename includes
the deposition ID, input filename, and UTC timestamp, and the script refuses to
overwrite an existing log. Use `--log-dir DIRECTORY` to select another durable
location.

## Sandbox validation

Add `--sandbox` to either helper to use `https://sandbox.zenodo.org`:

```bash
./zenodo_create_draft.sh \
  --title "Integration test" \
  --description "Sandbox validation of the upload workflow." \
  --creator "Last, First" \
  --license cc-by-4.0 \
  --sandbox \
  --dry-run
```

Remove `--dry-run` only when a sandbox token is installed. Sandbox records and
test DOIs are not production deposits.

## What the scripts verify

`zenodo_create_draft.sh`:

- safely JSON-encodes user-provided metadata with Python's standard library;
- requires an explicit creator and license identifier;
- sends authentication to curl over standard input, not in process arguments;
- requires an HTTP `201` response and validates required response fields; and
- creates a draft but never publishes it.

`zenodo_upload.sh`:

- validates the file and deposition ID before accessing the token;
- retrieves the bucket URL from Zenodo and accepts only the expected HTTPS
  Zenodo host and `/api/files/` path;
- retries transient curl failures;
- detects if the input file changes while it is being uploaded; and
- compares a streamed local MD5 checksum with the checksum returned by Zenodo.

The background log records the script path, UTC times, source file, byte count,
deposition ID, target service, and verified checksum so an upload can be traced
to its invocation.

## Publishing

Review the draft URL printed by the helper, verify its metadata and files, and
publish through the Zenodo web interface. Publishing mints the DOI and is not
performed by these scripts.

The API workflow follows the [official Zenodo REST API documentation](https://developers.zenodo.org/).

## Offline tests

The regression tests use a local deterministic curl fixture. They do not read a
real credential or contact Zenodo:

```bash
bash -n zenodo_create_draft.sh zenodo_upload.sh
python3 tests/test_zenodo_scripts_20260712_094209.py -v
```

## License

No license file is currently included. Until the maintainer selects and adds a
license, reuse rights are not granted by this repository.
