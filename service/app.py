#!/usr/bin/env python3
"""Tiny CAS protocol client for the local POC; uses only Python's stdlib."""

from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import ssl
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import urlopen
import xml.etree.ElementTree as ET


CAS_PUBLIC_URL = os.environ.get("CAS_PUBLIC_URL", "https://localhost:8443/cas").rstrip("/")
CAS_INTERNAL_URL = os.environ.get("CAS_INTERNAL_URL", "https://cas:8443/cas").rstrip("/")
SERVICE_URL = os.environ.get("SERVICE_URL", "https://localhost:8081/callback")
CAS_CA_CERT = os.environ.get("CAS_CA_CERT", "/certs/localhost.crt")
SERVICE_CERT = os.environ.get("SERVICE_CERT", "/certs/localhost.crt")
SERVICE_KEY = os.environ.get("SERVICE_KEY", "/certs/localhost.key")
CAS_NS = "http://www.yale.edu/tp/cas"


def page(title: str, body: str) -> bytes:
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        f"<title>{escape(title)}</title></head><body><h1>{escape(title)}</h1>"
        f"{body}</body></html>"
    ).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    def send_body(self, status: int, content: bytes, content_type: str = "text/html; charset=utf-8") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.send_body(200, b"ok\n", "text/plain; charset=utf-8")
            return

        if parsed.path == "/":
            login_url = f"{CAS_PUBLIC_URL}/login?{urlencode({'service': SERVICE_URL})}"
            self.send_response(302)
            self.send_header("Location", login_url)
            self.end_headers()
            return

        if parsed.path != "/callback":
            self.send_body(404, page("Not found", "<p>Use <a href='/'>/</a>.</p>"))
            return

        ticket = parse_qs(parsed.query).get("ticket", [""])[0]
        if not ticket:
            self.send_body(400, page("Missing ticket", "<p>CAS did not return a service ticket.</p>"))
            return

        validation_url = f"{CAS_INTERNAL_URL}/serviceValidate?{urlencode({'service': SERVICE_URL, 'ticket': ticket})}"
        context = ssl.create_default_context(cafile=CAS_CA_CERT)
        try:
            with urlopen(validation_url, context=context, timeout=15) as response:
                validation = response.read()
            root = ET.fromstring(validation)
            user = root.findtext(f".//{{{CAS_NS}}}authenticationSuccess/{{{CAS_NS}}}user")
            if not user:
                failure = root.find(f".//{{{CAS_NS}}}authenticationFailure")
                detail = failure.text.strip() if failure is not None and failure.text else "unknown validation failure"
                self.send_body(401, page("Ticket rejected", f"<pre>{escape(detail)}</pre>"))
                return
            self.send_body(
                200,
                page(
                    "CAS login succeeded",
                    f"<p id='authenticated-user'>Authenticated user: <strong>{escape(user)}</strong></p>"
                    f"<p>Service ticket <code>{escape(ticket)}</code> was validated exactly once.</p>",
                ),
            )
        except (HTTPError, URLError, ssl.SSLError, ET.ParseError) as exc:
            self.send_body(502, page("Validation error", f"<pre>{escape(str(exc))}</pre>"))

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"test-service: {self.address_string()} - {fmt % args}", flush=True)


if __name__ == "__main__":
    print(f"Test service listening on {SERVICE_URL}", flush=True)
    server = ThreadingHTTPServer(("0.0.0.0", 8081), Handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(certfile=SERVICE_CERT, keyfile=SERVICE_KEY)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    server.serve_forever()
