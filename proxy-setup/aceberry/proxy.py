#!/usr/bin/env python3
"""
aceberry
Web UI + URL resolver. Streaming handled by httpaceproxy.
GET /ace/url?id=<id>       → JSON with httpaceproxy stream URL
GET /ace/getstream?id=<id> → 302 redirect to httpaceproxy (:8888)
GET /logo.png              → logo image
GET /favicon.ico           → logo image (favicon)
"""

import http.client
import http.server
import json
import urllib.request
import urllib.parse
import socketserver
import threading
import time
import os

ENGINE_HOST = os.environ.get('ENGINE_HOST', 'aceserve')
ENGINE_PORT = int(os.environ.get('ENGINE_PORT', 6878))
PROXY_PORT = int(os.environ.get('PROXY_PORT', 8080))
HTTPACEPROXY_PORT = int(os.environ.get('HTTPACEPROXY_PORT', 8888))
ENABLED_PLUGINS = os.environ.get('ENABLED_PLUGINS', 'all')
SHOW_STREAM_LISTS = os.environ.get('SHOW_STREAM_LISTS', 'false').lower() == 'true'

ENGINE_URL = f"http://{ENGINE_HOST}:{ENGINE_PORT}"


def engine_request(path, timeout=10):
    try:
        req = urllib.request.Request(f"{ENGINE_URL}{path}")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


class Handler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[{time.strftime('%H:%M:%S')}] {self.client_address[0]} {fmt % args}")

    def get_client_host(self):
        h = self.headers.get('Host', '')
        return h.split(':')[0] if h else '127.0.0.1'

    def do_GET(self):
        p = urllib.parse.urlparse(self.path)
        path = p.path.rstrip('/')

        if path in ('', '/'):
            self.serve_ui()
        elif path in ('/ace/getstream', '/ace/manifest.m3u8'):
            self.handle_stream(p)
        elif path == '/ace/url':
            self.handle_url(p)
        elif path == '/status':
            self.handle_status()
        elif path == '/aceproxy/stat':
            self.handle_aceproxy_stat()
        elif path.startswith('/aceproxy/'):
            self.handle_aceproxy(p)
        elif path == '/health':
            self.send_json({'status': 'ok'})
        elif path in ('/logo.png', '/favicon.ico'):
            self.serve_logo()
        else:
            self.send_error(404)

    def handle_stream(self, parsed):
        params = urllib.parse.parse_qs(parsed.query)
        sid = params.get('id', [None])[0]
        if not sid:
            self.send_error(400, "Missing 'id' parameter")
            return
        sid = sid.strip().removeprefix('acestream://')
        host = self.get_client_host()
        target = f"http://{host}:{HTTPACEPROXY_PORT}/content_id/{sid}/stream.ts"
        self.send_response(302)
        self.send_header('Location', target)
        self.end_headers()

    def handle_url(self, parsed):
        params = urllib.parse.parse_qs(parsed.query)
        sid = params.get('id', [None])[0]
        if not sid:
            self.send_error(400, "Missing 'id' parameter")
            return
        sid = sid.strip().removeprefix('acestream://')
        host = self.get_client_host()
        url = f"http://{host}:{HTTPACEPROXY_PORT}/content_id/{sid}/stream.ts"
        self.send_json({'id': sid, 'url': url})

    def handle_status(self):
        ver = engine_request('/webui/api/service?method=get_version')
        self.send_json({
            'engine': {
                'url': ENGINE_URL,
                'online': ver is not None,
                'version': ver.get('result', {}).get('version') if ver else None,
            },
            'timestamp': time.strftime('%Y-%m-%d %H:%M:%S'),
        })

    def handle_aceproxy_stat(self):
        try:
            req = urllib.request.Request(
                f"http://httpaceproxy:8888/stat/?action=get_status"
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = resp.read()
                ct = resp.headers.get('Content-Type', 'application/json')
        except Exception as e:
            self.send_error(502, str(e))
            return
        self.send_response(200)
        self.send_header('Content-Type', ct)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def handle_aceproxy(self, parsed):
        subpath = parsed.path[len('/aceproxy'):]
        qs = ('?' + parsed.query) if parsed.query else ''
        try:
            conn = http.client.HTTPConnection('httpaceproxy', HTTPACEPROXY_PORT, timeout=60)
            conn.request('GET', subpath + qs)
            resp = conn.getresponse()
        except Exception as e:
            self.send_error(502, str(e))
            return
        ct = resp.getheader('Content-Type', 'application/octet-stream')
        if 'text' in ct or 'm3u' in ct or 'xml' in ct or 'json' in ct:
            # Text/list: buffer, rewrite internal URLs, send
            try:
                body = resp.read()
            except Exception as e:
                resp.close(); conn.close()
                self.send_error(502, str(e))
                return
            host = self.get_client_host()
            body = body.replace(
                b'http://httpaceproxy:8888',
                f'http://{host}:{HTTPACEPROXY_PORT}'.encode()
            )
            self.send_response(200)
            self.send_header('Content-Type', ct)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(body)
        else:
            # Binary/video stream: disable socket timeout, forward continuously
            try:
                conn.sock.settimeout(None)
            except Exception:
                pass
            self.send_response(resp.status)
            self.send_header('Content-Type', ct)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            try:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            except Exception:
                pass
        resp.close()
        conn.close()

    def serve_ui(self):
        ch = self.get_client_host()
        with open(os.path.join(os.path.dirname(__file__), 'index.html'), encoding='utf-8') as f:
            page = f.read()
        page = page.replace('{{HOST}}', ch)
        page = page.replace('{{ENGINE_PORT}}', str(ENGINE_PORT))
        page = page.replace('{{PROXY_PORT}}', str(PROXY_PORT))
        page = page.replace('{{HTTPACEPROXY_PORT}}', str(HTTPACEPROXY_PORT))
        page = page.replace('{{ENABLED_PLUGINS}}', ENABLED_PLUGINS)
        page = page.replace('{{SHOW_STREAM_LISTS}}', 'true' if SHOW_STREAM_LISTS else 'false')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(page.encode())

    def serve_logo(self):
        logo_path = os.path.join(os.path.dirname(__file__), 'logo.png')
        try:
            with open(logo_path, 'rb') as f:
                data = f.read()
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Cache-Control', 'public, max-age=86400')
            self.end_headers()
            self.wfile.write(data)
        except FileNotFoundError:
            self.send_error(404)

    def send_json(self, data):
        body = json.dumps(data, indent=2, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == '__main__':
    print(f"Aceberry :{PROXY_PORT} -> engine {ENGINE_URL}")
    server = ThreadedServer(('0.0.0.0', PROXY_PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()
