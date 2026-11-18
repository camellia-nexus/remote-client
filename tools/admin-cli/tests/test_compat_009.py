import io
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace
from unittest.mock import patch

from camellia_remote_admin import users

UNSUPPORTED_COMMANDS = (
    "invite",
    "enable-2fa-enforce",
    "disable-2fa-enforce",
    "disable-email-verification",
    "reset-2fa",
)


class Compat009Tests(unittest.TestCase):
    def test_help_exposes_only_management_routes_that_exist(self):
        output = io.StringIO()
        argv = ["users.py", "--help"]

        with (
            patch.object(sys, "argv", argv),
            redirect_stdout(output),
            self.assertRaises(SystemExit) as raised,
        ):
            users.main()

        self.assertEqual(raised.exception.code, 0)
        help_text = output.getvalue()
        self.assertIn("view", help_text)
        self.assertIn("force-logout", help_text)
        for command in UNSUPPORTED_COMMANDS:
            self.assertNotIn(command, help_text)
        self.assertFalse(hasattr(users, "invite_user"))
        self.assertFalse(hasattr(users, "enable_2fa_enforce"))
        self.assertFalse(hasattr(users, "disable_2fa_enforce"))
        self.assertFalse(hasattr(users, "disable_email_verification"))
        self.assertFalse(hasattr(users, "reset_2fa"))

    def test_removed_commands_fail_during_argument_parsing_without_http(self):
        def unexpected_http(*_args, **_kwargs):
            self.fail("unsupported command must not issue an HTTP request")

        users.requests = SimpleNamespace(get=unexpected_http, post=unexpected_http)
        for command in UNSUPPORTED_COMMANDS:
            with self.subTest(command=command):
                argv = [
                    "users.py",
                    command,
                    "--url",
                    "https://management.example.test",
                    "--token",
                    "token",
                ]
                errors = io.StringIO()
                with (
                    patch.object(sys, "argv", argv),
                    redirect_stderr(errors),
                    self.assertRaises(SystemExit) as raised,
                ):
                    users.main()
                self.assertEqual(raised.exception.code, 2)
                self.assertIn("invalid choice", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
