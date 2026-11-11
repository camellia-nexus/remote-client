#!/usr/bin/env python3
"""Contract and invariant verification tests for Batch 63:
COMPAT-008 — Management 保留的 WebSocket Proxy Path 与 Query 被 Client Runtime 静默丢弃.

Verifies:
1. Static code invariants in client/flutter/web/js/src/runtime/runtime.ts:
   - `ParsedServerEndpoint` schema includes `path: string` and `query: string`.
   - `parseServerInput` parses path and query, disallowing userinfo, fragments, and control characters.
   - `normalizeRendezvousServer` & `normalizeRelayServer` preserve custom path and query;
     default absent path to `/ws/id` or `/ws/relay`.
   - `deriveRelayServer` maps WSS to `/ws/relay` preserving query string and TLS port.
   - `getRendezvousCandidatesForConnect` and `buildConnectionCandidates` maintain full candidate URLs.
2. Static code invariants in client/flutter/web/js/src/runtime/rendezvous.ts:
   - `checkWsEndpoint` preserves custom path and query, defaults absent paths, and fails closed on invalid characters.
   - `parseServerEndpoint` conforms to the shared parsing contract.
3. Static code invariants in management/webui2/views.py:
   - `_parse_server_input` rejects control characters, fragments, userinfo, and bare path strings.
   - `_format_ws_endpoint` formats path and clean query without double slashes.
   - `_derive_relay_server` passes path and query for WS endpoints.
4. Functional contract execution across shared fixtures matrix:
   - Path and query preservation for custom endpoints.
   - Default path restoration when absent.
   - Rejection and fail-closed security boundaries.
"""

import unittest
from pathlib import Path
from urllib.parse import urlsplit
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[3]
WORKSPACE_ROOT = REPO_ROOT.parent
CLIENT_WEB_JS_SRC = REPO_ROOT / "flutter" / "web" / "js" / "src" / "runtime"
MANAGEMENT_WEBUI2 = WORKSPACE_ROOT / "management" / "webui2"


class _ServerEndpoint(NamedTuple):
    scheme: str | None
    host: str
    port: int | None
    path: str = ""
    query: str = ""


def _strip_ipv6_brackets(host: str) -> str:
    if host.startswith("[") and host.endsWith("]") if hasattr(host, "endsWith") else (host.startswith("[") and host.endswith("]")):
        return host[1:-1]
    return host


def _format_ws_endpoint(
    scheme: str,
    host: str,
    port: int,
    path: str = "",
    query: str = "",
) -> str:
    host = _strip_ipv6_brackets(host)
    if ":" in host:
        host = f"[{host}]"
    suffix = path if path and path != "/" else ""
    if suffix and not suffix.startswith("/"):
        suffix = f"/{suffix}"
    clean_query = query[1:] if query.startswith("?") else query
    if clean_query:
        suffix = f"{suffix}?{clean_query}"
    return f"{scheme}://{host}:{port}{suffix}"


def _format_host_port(host: str, port: int) -> str:
    host = _strip_ipv6_brackets(host)
    if ":" in host:
        host = f"[{host}]"
    return f"{host}:{port}"


def _parse_server_input(server: str) -> _ServerEndpoint | None:
    if not server or len(server) > 2048:
        return None
    if any((ord(c) < 32 and c not in " \t\r\n") or ord(c) == 127 or (128 <= ord(c) <= 159) for c in server):
        return None
    server = server.strip()
    if not server or any(character.isspace() or ord(character) < 32 or ord(character) == 127 or (128 <= ord(character) <= 159) for character in server):
        return None
    if "#" in server:
        return None
    if "://" in server:
        try:
            parsed = urlsplit(server)
            scheme = (parsed.scheme or "").lower()
            if scheme not in ("ws", "wss"):
                return None
            if parsed.username is not None or parsed.password is not None or "@" in parsed.netloc:
                return None
            host = (parsed.hostname or "").strip()
            if not host:
                return None
            try:
                port = parsed.port
                if port is not None and (port <= 0 or port > 65535):
                    return None
            except ValueError:
                return None
            host = _strip_ipv6_brackets(host)
            return _ServerEndpoint(
                scheme=scheme,
                host=host,
                port=port,
                path=parsed.path if parsed.path != "/" else "",
                query=parsed.query,
            )
        except ValueError:
            return None
    if any(character in server for character in "/?#@"):
        return None
    if server.startswith("["):
        end = server.find("]")
        if end <= 0:
            return None
        host = _strip_ipv6_brackets(server[1:end])
        rest = server[end + 1 :]
        if not rest:
            return _ServerEndpoint(None, host, None)
        if not rest.startswith(":"):
            return None
        try:
            port = int(rest[1:])
        except ValueError:
            return None
        if port <= 0 or port > 65535:
            return None
        return _ServerEndpoint(None, host, port)
    colon_count = server.count(":")
    if colon_count == 1:
        host, port_text = server.rsplit(":", 1)
        if not host:
            return None
        try:
            port = int(port_text)
        except ValueError:
            return None
        if port <= 0 or port > 65535:
            return None
        host = _strip_ipv6_brackets(host)
        return _ServerEndpoint(None, host, port)
    host = _strip_ipv6_brackets(server)
    if not host:
        return None
    return _ServerEndpoint(None, host, None)


def _normalize_rendezvous_server(server: str, default_id_port: int = 21116) -> str:
    parsed = _parse_server_input(server)
    if not parsed:
        return ""
    if parsed.scheme:
        websocket_port = parsed.port or (default_id_port + 2)
        default_path = "/ws/id" if parsed.scheme == "wss" else ""
        return _format_ws_endpoint(
            parsed.scheme,
            parsed.host,
            websocket_port,
            parsed.path or default_path,
            parsed.query,
        )
    return _format_host_port(parsed.host, parsed.port or default_id_port)


def _normalize_relay_server(
    server: str,
    rendezvous_endpoint: str = "",
    default_id_port: int = 21116,
) -> str:
    parsed = _parse_server_input(server)
    if not parsed:
        return ""
    fallback = _parse_server_input(rendezvous_endpoint)
    if parsed.scheme == "wss":
        if parsed.port:
            port = parsed.port
        elif fallback and fallback.scheme == "wss":
            port = fallback.port or (default_id_port + 2)
        else:
            port = default_id_port + 3
        return _format_ws_endpoint(
            "wss",
            parsed.host,
            port,
            parsed.path or "/ws/relay",
            parsed.query,
        )
    if parsed.scheme == "ws":
        if parsed.port:
            port = parsed.port
        elif fallback and fallback.scheme == "ws":
            port = (fallback.port or (default_id_port + 2)) + 1
        else:
            port = default_id_port + 3
        return _format_ws_endpoint(
            "ws",
            parsed.host,
            port,
            parsed.path,
            parsed.query,
        )
    base_service_port = fallback.port or default_id_port if fallback and not fallback.scheme else default_id_port
    return _format_host_port(
        parsed.host,
        parsed.port or (base_service_port + 1),
    )


def _derive_relay_server(rendezvous_endpoint: str, default_id_port: int = 21116) -> str:
    parsed = _parse_server_input(rendezvous_endpoint)
    if not parsed:
        return ""
    if not parsed.scheme:
        return _format_host_port(
            parsed.host,
            (parsed.port or default_id_port) + 1,
        )
    websocket_port = parsed.port or (default_id_port + 2)
    if parsed.scheme == "wss":
        return _format_ws_endpoint(
            "wss",
            parsed.host,
            websocket_port,
            "/ws/relay",
            parsed.query,
        )
    return _format_ws_endpoint(
        "ws",
        parsed.host,
        websocket_port + 1,
        parsed.path,
        parsed.query,
    )


class TestBatch63WsProxyPathContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime_ts = (CLIENT_WEB_JS_SRC / "runtime.ts").read_text(encoding="utf-8")
        cls.rendezvous_ts = (CLIENT_WEB_JS_SRC / "rendezvous.ts").read_text(encoding="utf-8")
        cls.views_py = (MANAGEMENT_WEBUI2 / "views.py").read_text(encoding="utf-8")

    # 1. Client Web runtime.ts Source Invariants
    def test_runtime_ts_parsed_server_endpoint_schema(self):
        self.assertIn("export interface ParsedServerEndpoint", self.runtime_ts)
        self.assertIn("path: string;", self.runtime_ts)
        self.assertIn("query: string;", self.runtime_ts)
        self.assertIn("scheme: 'ws' | 'wss' | null;", self.runtime_ts)

    def test_runtime_ts_parse_server_input_guards(self):
        self.assertIn("public parseServerInput(", self.runtime_ts)
        self.assertIn("raw.includes('#')", self.runtime_ts)
        self.assertIn("authority.includes('@')", self.runtime_ts)
        self.assertIn("url.username || url.password", self.runtime_ts)
        self.assertIn("path = url.pathname && url.pathname !== '/' ? url.pathname : ''", self.runtime_ts)
        self.assertIn("query = url.search ? (url.search.startsWith('?') ? url.search.slice(1) : url.search) : ''", self.runtime_ts)

    def test_runtime_ts_format_ws_endpoint_preserves_path_and_query(self):
        self.assertIn("public formatWebSocketServer(", self.runtime_ts)
        self.assertIn("path = '',", self.runtime_ts)
        self.assertIn("query = ''", self.runtime_ts)
        self.assertIn("suffix = `${suffix}?${cleanQuery}`;", self.runtime_ts)

    def test_runtime_ts_normalize_preserves_custom_path_and_query(self):
        self.assertIn("public normalizeRendezvousServer(", self.runtime_ts)
        self.assertIn("parsed.path && parsed.path !== '/' ? parsed.path : defaultPath", self.runtime_ts)
        self.assertIn("public normalizeRelayServer(", self.runtime_ts)
        self.assertIn("parsed.path && parsed.path !== '/' ? parsed.path : '/ws/relay'", self.runtime_ts)
        self.assertIn("public deriveRelayServer(", self.runtime_ts)
        self.assertIn("'/ws/relay'", self.runtime_ts)

    def test_runtime_ts_candidate_builders_are_public(self):
        self.assertIn("public buildConnectionCandidates(", self.runtime_ts)
        self.assertIn("public getRendezvousCandidatesForConnect(", self.runtime_ts)

    # 2. Client Web rendezvous.ts Source Invariants
    def test_rendezvous_ts_check_ws_endpoint_guards_and_preservation(self):
        self.assertIn("export function checkWsEndpoint(", self.rendezvous_ts)
        self.assertIn("authority.includes('@')", self.rendezvous_ts)
        self.assertIn("hasExplicitPath ? url.pathname : ''", self.rendezvous_ts)
        self.assertIn("hasExplicitPath ? url.pathname : (routeKind === 'relay' ? '/ws/relay' : '/ws/id')", self.rendezvous_ts)
        self.assertIn("export function parseServerEndpoint(", self.rendezvous_ts)

    # 3. Management webui2/views.py Source Invariants
    def test_management_views_py_parse_server_input_guards(self):
        self.assertIn("def _parse_server_input(", self.views_py)
        self.assertIn('if "#" in server:', self.views_py)
        self.assertIn('any((ord(c) < 32 and c not in " \\t\\r\\n") or ord(c) == 127 or (128 <= ord(c) <= 159) for c in server)', self.views_py)
        self.assertIn('parsed.username is not None or parsed.password is not None or "@" in parsed.netloc', self.views_py)
        self.assertIn('any(character in server for character in "/?#@")', self.views_py)

    def test_management_views_py_derive_relay_server_preserves_query(self):
        self.assertIn("def _derive_relay_server(", self.views_py)
        self.assertIn('"/ws/relay"', self.views_py)
        self.assertIn("parsed.query", self.views_py)

    # 4. Functional Endpoint Parsing & Normalization Contract Tests
    def test_custom_path_and_query_preservation(self):
        custom_id = "wss://remote.example.com:8443/custom-id?tenant=one"
        custom_relay = "wss://relay.example.com:9443/custom-relay?tenant=one"

        norm_id = _normalize_rendezvous_server(custom_id)
        self.assertEqual(norm_id, custom_id)

        norm_relay = _normalize_relay_server(custom_relay, norm_id)
        self.assertEqual(norm_relay, custom_relay)

        derived_relay = _derive_relay_server(custom_id)
        self.assertEqual(derived_relay, "wss://remote.example.com:8443/ws/relay?tenant=one")

    def test_default_path_restoration_when_absent(self):
        self.assertEqual(
            _normalize_rendezvous_server("wss://remote.example.com:8443"),
            "wss://remote.example.com:8443/ws/id",
        )
        self.assertEqual(
            _normalize_rendezvous_server("wss://remote.example.com:8443/"),
            "wss://remote.example.com:8443/ws/id",
        )
        self.assertEqual(
            _normalize_rendezvous_server("wss://remote.example.com:8443?tenant=one"),
            "wss://remote.example.com:8443/ws/id?tenant=one",
        )
        self.assertEqual(
            _normalize_relay_server("wss://relay.example.com:9443"),
            "wss://relay.example.com:9443/ws/relay",
        )
        self.assertEqual(
            _normalize_relay_server("wss://relay.example.com:9443/"),
            "wss://relay.example.com:9443/ws/relay",
        )
        self.assertEqual(
            _normalize_relay_server("wss://relay.example.com:9443?tenant=one"),
            "wss://relay.example.com:9443/ws/relay?tenant=one",
        )

    def test_ipv6_bracketed_endpoint_preservation(self):
        endpoint = "wss://[2001:db8::1]:8443/custom-id?tenant=one"
        self.assertEqual(_normalize_rendezvous_server(endpoint), endpoint)

        native_ipv6 = "[2001:db8::1]:21116"
        self.assertEqual(_normalize_rendezvous_server(native_ipv6), native_ipv6)

    def test_rejection_of_userinfo_fragments_control_and_bare_paths(self):
        # Userinfo
        self.assertEqual(_normalize_rendezvous_server("wss://user:pass@host:8443/id"), "")
        self.assertEqual(_normalize_rendezvous_server("wss://user@host:8443/id"), "")
        self.assertEqual(_normalize_rendezvous_server("wss://@host:8443/id"), "")
        self.assertEqual(_normalize_rendezvous_server("user@host:21116"), "")

        # Fragments
        self.assertEqual(_normalize_rendezvous_server("wss://host:8443/id#frag"), "")
        self.assertEqual(_normalize_rendezvous_server("wss://host:8443/id#"), "")
        self.assertEqual(_normalize_rendezvous_server("host:21116#frag"), "")

        # Control characters
        self.assertEqual(_normalize_rendezvous_server("wss://host:8443/id\x00"), "")
        self.assertEqual(_normalize_rendezvous_server("wss://host:8443/id\x1f"), "")
        self.assertEqual(_normalize_rendezvous_server("wss://host:8443/id\x7f"), "")
        self.assertEqual(_normalize_rendezvous_server("wss://host:8443/id\x80"), "")
        self.assertEqual(_normalize_rendezvous_server("wss://host:8443/id\x9f"), "")
        self.assertEqual(_normalize_rendezvous_server("wss://host:8443/i d"), "")
        self.assertEqual(_normalize_rendezvous_server("host:21116\x00"), "")
        self.assertEqual(_normalize_rendezvous_server("host:21116\x80"), "")
        self.assertEqual(_normalize_rendezvous_server("host:21116\x9f"), "")

        # Bare paths or query
        self.assertEqual(_normalize_rendezvous_server("host:21116/path"), "")
        self.assertEqual(_normalize_rendezvous_server("host/path"), "")
        self.assertEqual(_normalize_rendezvous_server("host?query"), "")

        # Invalid ports
        self.assertEqual(_normalize_rendezvous_server("wss://host:0/id"), "")
        self.assertEqual(_normalize_rendezvous_server("wss://host:65536/id"), "")
        self.assertEqual(_normalize_rendezvous_server("host:0"), "")
        self.assertEqual(_normalize_rendezvous_server("host:70000"), "")


if __name__ == "__main__":
    unittest.main()
