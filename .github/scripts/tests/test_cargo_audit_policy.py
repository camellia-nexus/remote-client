from __future__ import annotations

import contextlib
from datetime import date
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import unittest.mock


SCRIPT_PATH = Path(__file__).parents[1] / "audit_cargo_dependencies.py"
SPEC = importlib.util.spec_from_file_location("audit_cargo_dependencies", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
AUDITOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDITOR)


def warning(
    *,
    category: str = "unsound",
    advisory_id: str | None = "RUSTSEC-2099-0001",
    package: str = "example",
    version: str = "1.0.0",
) -> dict[str, object]:
    return {
        "kind": category,
        "package": {"name": package, "version": version},
        "advisory": None if advisory_id is None else {"id": advisory_id},
    }


def policy_warning() -> dict[str, object]:
    return {
        "category": "unsound",
        "advisory_id": "RUSTSEC-2099-0001",
        "package": "example",
        "version": "1.0.0",
    }


def policy(*, expires_on: str = "2099-12-31") -> dict[str, object]:
    return {
        "schema_version": 1,
        "reviewed_on": "2026-07-29",
        "exception_groups": [
            {
                "id": "reviewed-example",
                "owner": "remote-security-maintainers",
                "expires_on": expires_on,
                "reason": "Test-only reviewed warning.",
                "exit_condition": "Remove the dependency.",
                "warnings": [policy_warning()],
            }
        ],
    }


def report(
    *,
    warnings: list[dict[str, object]] | None = None,
    vulnerabilities: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "warnings": {"unsound": warnings or []},
        "vulnerabilities": {"list": vulnerabilities or []},
    }


class CargoAuditPolicyTests(unittest.TestCase):
    def test_empty_budget_is_strict_for_every_warning(self) -> None:
        strict_policy = policy()
        strict_policy["exception_groups"] = []
        errors, active, inactive = AUDITOR.evaluate_report(
            report(), strict_policy, today=date(2026, 7, 29)
        )
        self.assertEqual((errors, active, inactive), ([], set(), set()))
        errors, _, _ = AUDITOR.evaluate_report(
            report(warnings=[warning()]), strict_policy, today=date(2026, 7, 29)
        )
        self.assertRegex(errors[0], "Unapproved cargo-audit warning")

    def test_current_authorization_can_renew_the_frozen_scope(self) -> None:
        source = policy(expires_on="2026-07-28")
        source["reviewed_on"] = "2026-07-01"
        AUDITOR.validate_publication_policy(
            source, policy(), today=date(2026, 7, 29),
            source_packages={("example", "1.0.0")},
        )

    def test_current_authorization_must_cover_every_frozen_warning(self) -> None:
        authorization = policy()
        authorization["exception_groups"][0]["warnings"][0]["version"] = "2.0.0"
        with self.assertRaisesRegex(AUDITOR.PolicyError, "does not authorize"):
            AUDITOR.validate_publication_policy(
                policy(), authorization, today=date(2026, 7, 29),
                source_packages={("example", "1.0.0")},
            )

    def test_expired_current_authorization_cannot_publish(self) -> None:
        with self.assertRaisesRegex(AUDITOR.PolicyError, "expired"):
            AUDITOR.validate_publication_policy(
                policy(), policy(expires_on="2026-07-28"), today=date(2026, 7, 29),
                source_packages={("example", "1.0.0")},
            )

    def test_inactive_source_warning_does_not_need_reauthorization(self) -> None:
        source = policy()
        inactive = policy_warning()
        inactive["package"] = "absent"
        source["exception_groups"][0]["warnings"].append(inactive)
        AUDITOR.validate_publication_policy(
            source, policy(), today=date(2026, 7, 29),
            source_packages={("example", "1.0.0")},
        )

    def test_publication_lockfile_is_required_and_well_formed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "Cargo.lock"
            for text in ["version = 4\n", "[[package]]\nname = 7\nversion = '1.0.0'\n"]:
                source.write_text(text, encoding="utf-8")
                with self.assertRaises(AUDITOR.PolicyError):
                    AUDITOR.lockfile_packages(source)
            source.write_text("[[package]]\nname = 'example'\nversion = '1.0.0'\n", encoding="utf-8")
            self.assertEqual(AUDITOR.lockfile_packages(source), {("example", "1.0.0")})

    def test_policy_only_validates_deadlines_without_executing_cargo(self) -> None:
        for expiry, expected in [("2099-12-31", 0), ("2026-07-28", 2)]:
            with self.subTest(expiry=expiry), tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "policy.json"
                source.write_text(json.dumps(policy(expires_on=expiry)), encoding="utf-8")
                with (
                    unittest.mock.patch(
                        "sys.argv",
                        [str(SCRIPT_PATH), "--policy", str(source), "--policy-only"],
                    ),
                    unittest.mock.patch.object(AUDITOR, "date", wraps=date) as clock,
                    unittest.mock.patch.object(AUDITOR.subprocess, "run") as cargo,
                    contextlib.redirect_stdout(io.StringIO()),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    clock.today.return_value = date(2026, 7, 29)
                    self.assertEqual(AUDITOR.main(), expected)
                    cargo.assert_not_called()

    def test_policy_only_rejects_missing_policy_without_executing_cargo(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "missing.json"
            with (
                unittest.mock.patch(
                    "sys.argv",
                    [str(SCRIPT_PATH), "--policy", str(source), "--policy-only"],
                ),
                unittest.mock.patch.object(AUDITOR.subprocess, "run") as cargo,
                contextlib.redirect_stderr(io.StringIO()),
            ):
                self.assertEqual(AUDITOR.main(), 2)
                cargo.assert_not_called()

    def test_reviewed_warning_passes(self) -> None:
        errors, active, inactive = AUDITOR.evaluate_report(
            report(warnings=[warning()]),
            policy(),
            today=date(2026, 7, 29),
        )
        self.assertEqual(errors, [])
        self.assertEqual(len(active), 1)
        self.assertEqual(inactive, set())

    def test_unapproved_warning_fails(self) -> None:
        errors, _, _ = AUDITOR.evaluate_report(
            report(
                warnings=[
                    warning(
                        advisory_id="RUSTSEC-2099-0002",
                        package="new-warning",
                    )
                ]
            ),
            policy(),
            today=date(2026, 7, 29),
        )
        self.assertRegex(errors[0], "Unapproved cargo-audit warning")

    def test_vulnerability_always_fails(self) -> None:
        errors, _, _ = AUDITOR.evaluate_report(
            report(
                vulnerabilities=[
                    {
                        "advisory": {"id": "RUSTSEC-2099-9999"},
                        "package": {"name": "vulnerable", "version": "1.0.0"},
                    }
                ]
            ),
            policy(),
            today=date(2026, 7, 29),
        )
        self.assertRegex(errors[0], "Rust vulnerability")

    def test_expired_exception_fails_policy_validation(self) -> None:
        with self.assertRaisesRegex(AUDITOR.PolicyError, "expired"):
            AUDITOR.evaluate_report(
                report(warnings=[warning()]),
                policy(expires_on="2026-07-27"),
                today=date(2026, 7, 29),
            )

    def test_duplicate_warning_exception_is_rejected(self) -> None:
        duplicate_policy = policy()
        duplicate_policy["exception_groups"][0]["warnings"].append(policy_warning())
        with self.assertRaisesRegex(AUDITOR.PolicyError, "duplicate warning"):
            AUDITOR.evaluate_report(
                report(warnings=[warning()]),
                duplicate_policy,
                today=date(2026, 7, 29),
            )


if __name__ == "__main__":
    unittest.main()
