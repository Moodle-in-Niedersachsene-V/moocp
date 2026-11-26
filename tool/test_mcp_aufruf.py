"""Tests für tool/mcp_aufruf.sh mit einer nachgebauten Brücke.

Die Brücke ist ein Shell-Skript, das wie moocp-bruecke zeilenweises JSON-RPC von
stdin liest und beantwortet, sich das Profil (`--profil`) und jede Zeile merkt."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("mcp_aufruf.sh")

FAKE_BRIDGE = r"""#!/bin/bash
printf '%s\n' "$@" >> "$MOOCP_TEST_BRIDGE_ARGS"
while IFS= read -r zeile; do
  printf '%s\n' "$zeile" >> "$MOOCP_TEST_BRIDGE_IN"
  case "$zeile" in
    *'"id": 1'*|*'"id":1'*) printf '{"jsonrpc":"2.0","id":1,"result":{}}\n' ;;
    *'"id": 2'*|*'"id":2'*)
      if [ -n "${MOOCP_TEST_RESPONSE:-}" ]; then printf '%s\n' "$MOOCP_TEST_RESPONSE"
      else printf '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Fehler"}}\n'; fi ;;
  esac
done
"""


class McpAufrufTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mcp-aufruf-")
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        settings_dir = self.home / "Library" / "Application Support" / "moocp"
        settings_dir.mkdir(parents=True)
        (settings_dir / "einstellungen.json").write_text(
            json.dumps(
                {
                    "profile": [
                        {"name": "Moodle", "mcpName": "moodle", "kennung": "standard"},
                        {"name": "Moodle Test", "mcpName": "moodle-test", "kennung": "k2"},
                    ]
                }
            ),
            encoding="utf-8",
        )
        self.bridge = self.root / "moocp-bruecke"
        self.bridge.write_text(FAKE_BRIDGE, encoding="utf-8")
        self.bridge.chmod(0o755)
        self.args_file = self.root / "bruecke-args.txt"
        self.in_file = self.root / "bruecke-ein.txt"
        self.environment = {
            **os.environ,
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / "Library" / "Application Support"),
            "APPDATA": "",
            "MOOCP_BRUECKE": str(self.bridge),
            "MOOCP_TEST_BRIDGE_ARGS": str(self.args_file),
            "MOOCP_TEST_BRIDGE_IN": str(self.in_file),
        }

    def tearDown(self):
        self.temp.cleanup()

    def call(self, *extra_args, args="{}", environment=None):
        return subprocess.run(
            ["bash", str(SCRIPT), "testwerkzeug", args, *extra_args],
            capture_output=True,
            text=True,
            env=environment or self.environment,
            check=False,
        )

    def bridge_args(self):
        return self.args_file.read_text(encoding="utf-8").split() if self.args_file.exists() else []

    def test_selected_profile_is_the_bridge_argument(self):
        result = self.call("moodle-test")

        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(self.bridge_args(), ["--profil", "moodle-test"])
        self.assertIn("Fehler", result.stdout)

    def test_without_selector_uses_first_profile(self):
        result = self.call()

        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(self.bridge_args(), ["--profil", "moodle"])

    def test_request_goes_through_the_bridge_with_initialize_first(self):
        self.call(args='{"kurs": 43}')

        zeilen = [json.loads(z) for z in self.in_file.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(
            [z.get("method") for z in zeilen],
            ["initialize", "notifications/initialized", "tools/call"],
        )
        self.assertEqual(zeilen[2]["params"], {"name": "testwerkzeug", "arguments": {"kurs": 43}})

    def test_unknown_profile_fails_before_the_bridge_starts(self):
        result = self.call("unknown")

        self.assertEqual(result.returncode, 2)
        self.assertIn("Profil", result.stderr)
        self.assertEqual(self.bridge_args(), [])

    def test_malformed_request_json_fails_before_the_bridge_starts(self):
        result = self.call(args="{bad")

        self.assertEqual(result.returncode, 2)
        self.assertIn("JSON", result.stderr)
        self.assertEqual(self.bridge_args(), [])

    def test_malformed_response_returns_nonzero_and_safe_cause(self):
        env = {**self.environment, "MOOCP_TEST_RESPONSE": '{"jsonrpc":"2.0","id":2,"x'}
        result = self.call(environment=env)

        self.assertNotEqual(result.returncode, 0)

    def test_response_without_result_returns_structure_error(self):
        env = {**self.environment, "MOOCP_TEST_RESPONSE": '{"jsonrpc":"2.0","id":2}'}
        result = self.call(environment=env)

        self.assertEqual(result.returncode, 5)
        self.assertIn("Struktur", result.stderr)

    def test_tool_result_error_returns_nonzero(self):
        response = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "result": {"isError": True, "content": [{"type": "text", "text": "Fehler im Werkzeug"}]},
            }
        )
        env = {**self.environment, "MOOCP_TEST_RESPONSE": response}
        result = self.call(environment=env)

        self.assertEqual(result.returncode, 4)
        self.assertIn("isError: True", result.stdout)
        self.assertIn("Fehler im Werkzeug", result.stdout)

    def test_tool_result_success_prints_the_text(self):
        response = json.dumps(
            {"jsonrpc": "2.0", "id": 2, "result": {"content": [{"type": "text", "text": "Hallo"}]}}
        )
        env = {**self.environment, "MOOCP_TEST_RESPONSE": response}
        result = self.call(environment=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Hallo", result.stdout)

    def test_missing_bridge_returns_transport_error(self):
        env = {**self.environment, "MOOCP_BRUECKE": str(self.root / "gibt-es-nicht")}
        result = self.call(environment=env)

        self.assertEqual(result.returncode, 3)
        self.assertIn("Transportfehler", result.stderr)


if __name__ == "__main__":
    unittest.main()
