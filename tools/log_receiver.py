#!/usr/bin/env python3
"""Camera APP Log Receiver — 接收手机APP上传的日志文件。

用法:
  python tools/log_receiver.py

启动后监听 0.0.0.0:8080，手机APP测试完切换到和PC同一网络后，
点击"上传日志"按钮即可将日志传到本机。

日志保存位置: tools/logs_received/
"""

import http.server
import os
import sys
from datetime import datetime

PORT = 8080
SAVE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs_received")


class LogReceiver(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] POST {self.path} Content-Length={self.headers.get('Content-Length', '?')}")
        if self.path == "/upload":
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length == 0:
                self._respond(400, "Empty body")
                return

            body = self.rfile.read(content_length)
            now = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"camera_app_{now}.log"
            os.makedirs(SAVE_DIR, exist_ok=True)
            filepath = os.path.join(SAVE_DIR, filename)

            with open(filepath, "wb") as f:
                f.write(body)

            print(f"[{datetime.now().strftime('%H:%M:%S')}] 收到日志: {filename} ({len(body)} bytes)")
            self._respond(200, f"OK: {filename}")
        else:
            print(f"  Unknown path: {self.path}")
            self._respond(404, f"Not Found: {self.path}")

    def _respond(self, code, msg):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(msg.encode("utf-8"))

    def log_message(self, format, *args):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {args[0]}")


if __name__ == "__main__":
    print(f"日志接收服务已启动: http://0.0.0.0:{PORT}")
    print(f"日志保存目录: {SAVE_DIR}")
    print("等待手机上传... (Ctrl+C 停止)")
    print()

    server = http.server.HTTPServer(("0.0.0.0", PORT), LogReceiver)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n服务已停止")
        server.server_close()