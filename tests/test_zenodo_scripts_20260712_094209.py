#!/usr/bin/env python3
"""Offline regression tests for the Zenodo helper scripts.

All network behavior is replaced with a deterministic local curl fixture. No
real token, deposition, or upload is used.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
CREATE_SCRIPT = REPO_ROOT / "zenodo_create_draft.sh"
UPLOAD_SCRIPT = REPO_ROOT / "zenodo_upload.sh"


class ZenodoScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        user = os.environ.get("USER", "user")
        self.temp_dir = Path(
            tempfile.mkdtemp(
                prefix=f"agent_{user}_",
                dir=os.environ.get("TMPDIR", "/tmp"),
            )
        )
        self.addCleanup(shutil.rmtree, self.temp_dir)

    def run_script(
        self,
        script: Path,
        *args: str,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        run_env = os.environ.copy()
        run_env["TMPDIR"] = str(self.temp_dir)
        if env:
            run_env.update(env)
        return subprocess.run(
            ["bash", str(script), *args],
            cwd=REPO_ROOT,
            env=run_env,
            text=True,
            capture_output=True,
            check=False,
        )

    def install_fake_curl(self) -> tuple[Path, dict[str, str]]:
        bin_dir = self.temp_dir / "bin"
        bin_dir.mkdir()
        fake_curl = bin_dir / "curl"
        fake_curl.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail

                printf '%s\\n' '---' "$@" >> "$MOCK_CURL_ARGS_FILE"
                cat >> "$MOCK_CURL_CONFIG_FILE"

                output_file=''
                upload_file=''
                data_file=''
                method='GET'
                while (($#)); do
                    case "$1" in
                        --output)
                            output_file="$2"
                            shift 2
                            ;;
                        --upload-file)
                            upload_file="$2"
                            shift 2
                            ;;
                        --data-binary)
                            data_file="${2#@}"
                            shift 2
                            ;;
                        --request)
                            method="$2"
                            shift 2
                            ;;
                        *)
                            shift
                            ;;
                    esac
                done

                if [[ -n "$data_file" ]]; then
                    cp "$data_file" "$MOCK_CURL_REQUEST_FILE"
                fi

                if [[ -n "$upload_file" ]]; then
                    checksum=$(md5sum "$upload_file" | awk '{print $1}')
                    printf '{"checksum":"md5:%s","links":{"self":"https://zenodo.org/api/files/test/file.txt"}}' \
                        "$checksum" > "$output_file"
                    printf '200'
                else
                    printf '%s' '{"id":42,"links":{"bucket":"https://zenodo.org/api/files/test-bucket","html":"https://zenodo.org/deposit/42"},"metadata":{"prereserve_doi":{"doi":"10.5281/zenodo.test"}}}' > "$output_file"
                    if [[ "$method" == 'POST' ]]; then
                        printf '201'
                    else
                        printf '200'
                    fi
                fi
                """
            ),
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)

        args_file = self.temp_dir / "curl_args.txt"
        config_file = self.temp_dir / "curl_config.txt"
        request_file = self.temp_dir / "request.json"
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "MOCK_CURL_ARGS_FILE": str(args_file),
            "MOCK_CURL_CONFIG_FILE": str(config_file),
            "MOCK_CURL_REQUEST_FILE": str(request_file),
        }
        return request_file, env

    def make_token(self) -> tuple[Path, str]:
        token = "unit-test-token-not-a-real-credential"
        token_file = self.temp_dir / "zenodo_token"
        token_file.write_text(token + "\n", encoding="utf-8")
        token_file.chmod(0o600)
        return token_file, token

    def test_create_dry_run_emits_valid_safely_escaped_json(self) -> None:
        result = self.run_script(
            CREATE_SCRIPT,
            "--title",
            'Quoted "dataset" title',
            "--description",
            "A description with an apostrophe: researcher's data",
            "--creator",
            "Doe, Jane",
            "--affiliation",
            "Example Institute",
            "--license",
            "cc-by-4.0",
            "--sandbox",
            "--dry-run",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("https://sandbox.zenodo.org/api/deposit/depositions", result.stdout)
        payload_text = result.stdout.split("Request JSON:\n", 1)[1]
        payload = json.loads(payload_text)
        metadata = payload["metadata"]
        self.assertEqual(metadata["title"], 'Quoted "dataset" title')
        self.assertEqual(metadata["creators"][0]["name"], "Doe, Jane")
        self.assertEqual(metadata["license"], "cc-by-4.0")

    def test_create_requires_explicit_creator_and_license(self) -> None:
        result = self.run_script(
            CREATE_SCRIPT,
            "--title",
            "Dataset",
            "--description",
            "Description",
            "--dry-run",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--creator", result.stderr)
        self.assertIn("--license", result.stderr)

    def test_create_keeps_token_out_of_process_arguments(self) -> None:
        request_file, env = self.install_fake_curl()
        token_file, token = self.make_token()
        env["ZENODO_TOKEN_FILE"] = str(token_file)

        result = self.run_script(
            CREATE_SCRIPT,
            "--title",
            "Dataset",
            "--description",
            "Description",
            "--creator",
            "Doe, Jane",
            "--license",
            "cc-by-4.0",
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        args_text = Path(env["MOCK_CURL_ARGS_FILE"]).read_text(encoding="utf-8")
        self.assertNotIn(token, args_text)
        request = json.loads(request_file.read_text(encoding="utf-8"))
        self.assertEqual(request["metadata"]["creators"][0]["name"], "Doe, Jane")

    def test_upload_dry_run_needs_no_token_or_network(self) -> None:
        upload_file = self.temp_dir / "input file.txt"
        upload_file.write_bytes(b"real-file-fixture\n")
        result = self.run_script(
            UPLOAD_SCRIPT,
            "--deposit-id",
            "12345",
            "--file",
            str(upload_file),
            "--dry-run",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRY RUN", result.stdout)
        self.assertIn("Deposit:    12345", result.stdout)

    def test_upload_checks_real_file_checksum_and_hides_token(self) -> None:
        _request_file, env = self.install_fake_curl()
        token_file, token = self.make_token()
        env["ZENODO_TOKEN_FILE"] = str(token_file)
        upload_file = self.temp_dir / "input file.txt"
        upload_file.write_bytes(b"real-file-fixture\n")

        result = self.run_script(
            UPLOAD_SCRIPT,
            "--deposit-id",
            "12345",
            "--file",
            str(upload_file),
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checksum verified", result.stdout)
        args_text = Path(env["MOCK_CURL_ARGS_FILE"]).read_text(encoding="utf-8")
        self.assertNotIn(token, args_text)

    def test_scripts_do_not_embed_tokens_in_shell_command_strings(self) -> None:
        for script in (CREATE_SCRIPT, UPLOAD_SCRIPT):
            source = script.read_text(encoding="utf-8")
            self.assertNotIn("bash -c", source)
            self.assertNotIn("Bearer ${TOKEN}", source)
            self.assertNotIn("Bearer $TOKEN\"", source)


if __name__ == "__main__":
    unittest.main()
