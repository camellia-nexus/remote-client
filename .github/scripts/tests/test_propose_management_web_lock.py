#!/usr/bin/env python3
"""Pure policy tests for the Management Web lock proposal."""

from __future__ import annotations

import base64
import importlib.util
import json
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SCRIPT = Path(__file__).parents[1] / "propose-management-web-lock.py"
SPEC = importlib.util.spec_from_file_location("propose_web_lock", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load lock proposal")
proposal = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proposal)


class ProposeManagementWebLockTests(unittest.TestCase):
    def test_accepts_complete_logical_map(self) -> None:
        value = proposal.repository_map(
            json.dumps(
                {
                    "remote-client": "desktop",
                    "remote-management": "service",
                    "remote-protocol": "protocol",
                    "remote-server": "relay",
                }
            ),
            "example/desktop",
        )
        self.assertEqual(value["remote-management"], "service")

    def test_rejects_current_repository_mismatch(self) -> None:
        with self.assertRaisesRegex(ValueError, "current repository"):
            proposal.repository_map(
                json.dumps(
                    {
                        "remote-client": "other",
                        "remote-management": "service",
                        "remote-protocol": "protocol",
                        "remote-server": "relay",
                    }
                ),
                "example/desktop",
            )

    def test_rejects_incomplete_map(self) -> None:
        with self.assertRaisesRegex(ValueError, "complete reviewed"):
            proposal.repository_map(
                '{"remote-client":"desktop","remote-management":"service"}',
                "example/desktop",
            )

    def test_rejects_noncanonical_repository_owner(self) -> None:
        with self.assertRaisesRegex(ValueError, "canonical owner/name"):
            proposal.repository_map(
                json.dumps(
                    {
                        "remote-client": "desktop",
                        "remote-management": "service",
                        "remote-protocol": "protocol",
                        "remote-server": "relay",
                    }
                ),
                "../desktop",
            )

    def test_rest_client_rejects_an_external_endpoint(self) -> None:
        with (
            patch.dict(proposal.os.environ, {"GH_TOKEN": "test"}, clear=True),
            self.assertRaisesRegex(ValueError, "reviewed REST surface"),
        ):
            proposal.gh_json("https://example.test/repos/owner/repository")

    def test_recovers_branch_created_before_lock_commit(self) -> None:
        old_commit = "a" * 40
        new_commit = "b" * 40
        base_commit = "c" * 40
        lock_blob = "d" * 40
        branch = "automation/remote-client-web-v1.2.3"
        branch_updated = False

        def content(value: str) -> dict[str, str]:
            return {
                "encoding": "base64",
                "content": base64.b64encode(f"{value}\n".encode()).decode(),
                "sha": lock_blob,
            }

        def api(
            endpoint: str,
            *,
            method: str = "GET",
            payload=None,
        ):
            nonlocal branch_updated
            if endpoint == "repos/example/desktop/releases/tags/v1.2.3":
                return {
                    "tag_name": "v1.2.3",
                    "target_commitish": new_commit,
                    "draft": False,
                    "prerelease": False,
                    "immutable": True,
                    "author": {"login": "release-app[bot]"},
                    "body": f"<!-- release-complete:{new_commit} -->\n",
                    "assets": [{"name": "release-evidence.json"}],
                }
            if endpoint == "repos/example/service":
                return {"default_branch": "main"}
            if endpoint == "repos/example/service/contents/web-client.lock?ref=main":
                return content(old_commit)
            if endpoint.startswith("repos/example/service/pulls?"):
                return []
            if endpoint == "repos/example/service/git/ref/heads/main":
                return {
                    "ref": "refs/heads/main",
                    "object": {"type": "commit", "sha": base_commit},
                }
            if endpoint == (
                "repos/example/service/git/ref/heads/"
                "automation%2Fremote-client-web-v1.2.3"
            ):
                return {
                    "ref": f"refs/heads/{branch}",
                    "object": {"type": "commit", "sha": base_commit},
                }
            if endpoint == (
                "repos/example/service/contents/web-client.lock"
                "?ref=automation%2Fremote-client-web-v1.2.3"
            ):
                return content(new_commit if branch_updated else old_commit)
            if (
                endpoint == "repos/example/service/contents/web-client.lock"
                and method == "PUT"
            ):
                self.assertEqual(payload["branch"], branch)
                self.assertEqual(payload["sha"], lock_blob)
                branch_updated = True
                return {"commit": {"sha": "e" * 40}}
            if endpoint == "repos/example/service/pulls" and method == "POST":
                return {
                    "number": 7,
                    "state": "open",
                    "draft": False,
                    "user": {"login": "release-app[bot]"},
                    "head": {
                        "ref": branch,
                        "repo": {"full_name": "example/service"},
                    },
                    "base": {"ref": "main"},
                }
            if endpoint == "repos/example/service/pulls/7/files?per_page=100":
                return [{"filename": "web-client.lock", "status": "modified"}]
            raise AssertionError(f"unexpected GitHub API call: {method} {endpoint}")

        args = SimpleNamespace(
            repository_map=json.dumps(
                {
                    "remote-client": "desktop",
                    "remote-management": "service",
                    "remote-protocol": "protocol",
                    "remote-server": "relay",
                }
            ),
            current_repository="example/desktop",
            release_app_login="release-app[bot]",
            version="1.2.3",
            tag="v1.2.3",
            commit=new_commit,
        )
        with patch.object(proposal, "gh_json", side_effect=api):
            self.assertEqual(proposal.ensure_lock_pr(args), "7")
        self.assertTrue(branch_updated)


if __name__ == "__main__":
    unittest.main()
