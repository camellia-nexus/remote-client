"""Regression contracts for Batch 76: COMPAT-011 and VALID-013.

- COMPAT-011: Admin CLI address book read operations use POST with empty JSON body
  and application/json header, unpacking payload data correctly.
- VALID-013: Audit CLI datetime parsing respects the query date's timezone rules
  without forcing the current month's fixed offset onto historical queries.
"""

import os
import time
import unittest
from unittest.mock import MagicMock, patch

from camellia_remote_admin.address_books import (
    get_personal_ab,
    view_ab_peers,
    view_ab_tags,
    view_shared_abs,
)
from camellia_remote_admin.audits import parse_local_time_to_utc_string


class TestAddressBookReadContracts(unittest.TestCase):
    """COMPAT-011: Align CLI read operations with provider POST contracts."""

    @patch("camellia_remote_admin.transport.post")
    def test_get_personal_ab_uses_post_with_empty_json(self, mock_post):
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            "address_book_snapshot_version": 1,
            "guid": "personal-123",
            "authorization_generation": 1,
            "name": "My Personal Book",
        }
        mock_post.return_value = mock_response

        res = get_personal_ab("http://test-server", "test-token")

        self.assertEqual(res["guid"], "personal-123")
        mock_post.assert_called_once_with(
            "http://test-server/api/ab/personal",
            headers={"Authorization": "Bearer test-token", "Content-Type": "application/json"},
            json={},
        )

    @patch("camellia_remote_admin.transport.post")
    def test_view_shared_abs_uses_post_with_query_params_and_empty_json(self, mock_post):
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            "total": 1,
            "data": [{"guid": "shared-1", "name": "Team Ops"}],
        }
        mock_post.return_value = mock_response

        res = view_shared_abs("http://test-server", "test-token", name="Ops")

        self.assertEqual(len(res), 1)
        self.assertEqual(res[0]["guid"], "shared-1")
        mock_post.assert_called_once_with(
            "http://test-server/api/ab/shared/profiles",
            headers={"Authorization": "Bearer test-token", "Content-Type": "application/json"},
            params={"name": "Ops", "pageSize": 30, "current": 1},
            json={},
        )

    @patch("camellia_remote_admin.transport.post")
    def test_view_ab_peers_uses_post_with_query_params_and_empty_json(self, mock_post):
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            "total": 1,
            "data": [{"id": "peer-100", "alias": "DevBox"}],
        }
        mock_post.return_value = mock_response

        res = view_ab_peers("http://test-server", "test-token", "book-guid-1")

        self.assertEqual(len(res), 1)
        self.assertEqual(res[0]["id"], "peer-100")
        mock_post.assert_called_once_with(
            "http://test-server/api/ab/peers",
            headers={"Authorization": "Bearer test-token", "Content-Type": "application/json"},
            params={"ab": "book-guid-1", "pageSize": 30, "current": 1},
            json={},
        )

    @patch("camellia_remote_admin.transport.post")
    def test_view_ab_tags_uses_post_and_parses_data_envelope(self, mock_post):
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            "address_book_snapshot_version": 1,
            "guid": "book-guid-1",
            "authorization_generation": 5,
            "total": 2,
            "data": [
                {"name": "Production", "color": 0xFF0000},
                {"name": "Staging", "color": 0x00FF00},
            ],
        }
        mock_post.return_value = mock_response

        res = view_ab_tags("http://test-server", "test-token", "book-guid-1")

        self.assertEqual(len(res), 2)
        self.assertEqual(res[0]["name"], "Production")
        self.assertEqual(res[0]["color"], "0x00FF0000")
        self.assertEqual(res[1]["name"], "Staging")
        self.assertEqual(res[1]["color"], "0x0000FF00")
        mock_post.assert_called_once_with(
            "http://test-server/api/ab/tags/book-guid-1",
            headers={"Authorization": "Bearer test-token", "Content-Type": "application/json"},
            json={},
        )


class TestAuditTimeParsingContracts(unittest.TestCase):
    """VALID-013: Local and explicit offset time parsing without DST shift."""

    def test_dst_independent_conversion(self):
        old_tz = os.environ.get("TZ")
        try:
            os.environ["TZ"] = "America/New_York"
            time.tzset()

            # Winter date (EST, UTC-5): 12:00 -> 17:00 UTC
            est_res = parse_local_time_to_utc_string("2026-01-15 12:00:00")
            self.assertEqual(est_res, "2026-01-15 17:00:00.000")

            # Summer date (EDT, UTC-4): 12:00 -> 16:00 UTC
            edt_res = parse_local_time_to_utc_string("2026-07-15 12:00:00")
            self.assertEqual(edt_res, "2026-07-15 16:00:00.000")
        finally:
            if old_tz is not None:
                os.environ["TZ"] = old_tz
            else:
                os.environ.pop("TZ", None)
            time.tzset()

    def test_explicit_utc_and_offset_strings(self):
        # Explicit UTC with Z
        z_res = parse_local_time_to_utc_string("2026-06-01T10:00:00Z")
        self.assertEqual(z_res, "2026-06-01 10:00:00.000")

        # Explicit positive offset (+08:00)
        cst_res = parse_local_time_to_utc_string("2026-06-01 18:00:00+08:00")
        self.assertEqual(cst_res, "2026-06-01 10:00:00.000")

        # Microseconds
        micro_res = parse_local_time_to_utc_string("2026-06-01T10:00:00.123456Z")
        self.assertEqual(micro_res, "2026-06-01 10:00:00.000")

    def test_invalid_input_returns_none(self):
        self.assertIsNone(parse_local_time_to_utc_string(""))
        self.assertIsNone(parse_local_time_to_utc_string("   "))
        self.assertIsNone(parse_local_time_to_utc_string("not-a-timestamp"))
        self.assertIsNone(parse_local_time_to_utc_string(None))


if __name__ == "__main__":
    unittest.main()
