import time
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n=int(self.headers.get("content-length",0)); self.rfile.read(n)
        time.sleep(10)
        self.send_response(200); self.send_header("content-length","0"); self.end_headers()
    def log_message(self,*a): pass
HTTPServer(("127.0.0.1",8099),H).serve_forever()
