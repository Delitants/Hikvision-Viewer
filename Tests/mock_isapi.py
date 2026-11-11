from hashlib import md5
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/ISAPI/ContentMgmt/search":
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if b"<trackID>3301</trackID>" not in body:
            self.send_error(400)
            return
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Digest "):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Digest realm="camera-test", nonce="testnonce", qop="auth"')
            self.end_headers()
            return
        values = {}
        for part in auth[7:].split(","):
            key, _, value = part.strip().partition("=")
            values[key] = value.strip('"')
        ha1 = md5(b"viewer:camera-test:testpass").hexdigest()
        ha2 = md5(f"POST:{values.get('uri','')}".encode()).hexdigest()
        expected = md5(f"{ha1}:testnonce:{values.get('nc','')}:{values.get('cnonce','')}:auth:{ha2}".encode()).hexdigest()
        if values.get("username") != "viewer" or values.get("response") != expected:
            self.send_error(403)
            return
        xml = b'''<CMSearchResult xmlns="http://www.isapi.org/ver20/XMLSchema"><matchList><searchMatchItem><timeSpan><startTime>2026-11-10T10:00:00Z</startTime><endTime>2026-11-10T10:05:00Z</endTime></timeSpan><playbackURI>rtsp://127.0.0.1/Streaming/tracks/3301?starttime=20261110T100000Z&amp;endtime=20261110T100500Z</playbackURI></searchMatchItem></matchList></CMSearchResult>'''
        self.send_response(200)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(xml)))
        self.end_headers()
        self.wfile.write(xml)

    def log_message(self, format, *args):
        pass


server = HTTPServer(("127.0.0.1", 18765), Handler)
print("ready", flush=True)
server.serve_forever()
