"""Local pages for testing Bosk's page behavior (see docs/manual-checklist.md).

Run:  python3 scripts/test-pages.py   then open http://localhost:8765 in Bosk.
"""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8765

PAGES = {
    "/": """<h1>Bosk test pages</h1><ul>
      <li><a href="/dialogs">Dialogs (alert, confirm, prompt)</a></li>
      <li><a href="/popups">Pop-ups and target=_blank</a></li>
      <li><a href="/download">Download a file</a> (saves bosk-test.txt to ~/Downloads)</li>
      <li><a href="/auth">HTTP sign-in</a> (user: bosk, password: bosk)</li>
      <li><a href="/upload">File upload</a></li>
      <li><a href="/form">Form (unsent text keeps the tab awake)</a></li>
      <li><a href="/media">Camera and microphone</a></li>
      <li><a href="/notifications">Notifications</a></li>
      <li><a href="/controls">Controls for a saved web app (Save as App)</a></li>
      <li><a href="/ads">Ad script (an ad blocker blocks it)</a></li>
      <li><a href="/cookies">Cookie notice (the cookie notice blocker hides it)</a></li>
      <li><a href="http://no-such-host.invalid/">A page that does not exist</a></li></ul>""",
    "/ads": """<h1>Ad script</h1><p>Result: <span id="r">loading…</span></p>
      <script src="https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"
        onload="r.textContent = 'NOT blocked'" onerror="r.textContent = 'blocked'"></script>""",
    "/cookies": """<h1>Cookie notice</h1><p>Result: <span id="r">loading…</span></p>
      <div id="cookiewarner">This site uses cookies. <button>Accept</button></div>
      <script>addEventListener('load', () => r.textContent =
        getComputedStyle(cookiewarner).display == 'none' ? 'hidden' : 'NOT hidden')</script>""",
    "/dialogs": """<h1>Dialogs</h1>
      <button onclick="alert('Hello from the page')">alert</button>
      <button onclick="document.getElementById('r').textContent = confirm('Continue?')">confirm</button>
      <button onclick="document.getElementById('r').textContent = prompt('Your name?', 'Tom')">prompt</button>
      <p>Result: <span id="r"></span></p>""",
    "/popups": """<h1>Pop-ups</h1>
      <p><a href="/dialogs" target="_blank">target=_blank link</a></p>
      <p><button onclick="window.open('/dialogs')">window.open</button></p>
      <p><button onclick="const w = window.open('/closeme'); setTimeout(() => w && w.close(), 1500)">
        window.open, then close it after 1.5 s</button></p>""",
    "/closeme": "<h1>This tab closes itself</h1>",
    "/upload": """<h1>Upload</h1><form method="post" enctype="multipart/form-data" action="/upload">
      <input type="file" name="f" multiple> <button>Send</button></form>""",
    "/form": """<h1>Form</h1><form method="post" action="/form">
      <textarea name="t" rows="6" cols="60" placeholder="Type here, do not send"></textarea><br>
      <button>Send</button></form>""",
    "/media": """<h1>Camera and microphone</h1>
      <button onclick="navigator.mediaDevices.getUserMedia({video: true, audio: true})
        .then(s => { document.querySelector('video').srcObject = s; r.textContent = 'allowed'; })
        .catch(e => r.textContent = e.name)">Start camera</button>
      <p>Result: <span id="r"></span></p><video autoplay muted playsinline width="320"></video>""",
    "/notifications": """<h1>Notifications</h1>
      <p>Permission: <span id="p"></span></p>
      <button onclick="Notification.requestPermission().then(a => p.textContent = a)">Ask</button>
      <button onclick="const n = new Notification('Page notification', {body: 'Click me', tag: 't'});
        n.onshow = () => r.textContent = 'shown'; n.onerror = () => r.textContent = 'error';
        n.onclick = () => r.textContent = 'clicked'">Page notification</button>
      <button onclick="navigator.serviceWorker.register('/notifications-sw.js')
        .then(() => navigator.serviceWorker.ready)
        .then(reg => reg.showNotification('Worker notification', {body: 'From the service worker'}))
        .then(() => r.textContent = 'worker shown', e => r.textContent = 'worker ' + e)">Worker notification</button>
      <p>Result: <span id="r"></span></p>
      <script>p.textContent = Notification.permission;
        navigator.serviceWorker.onmessage = e => r.textContent = e.data;</script>""",
    # Save this page as an app (File > Save as App…) and check each control in the app's window.
    "/controls": """<h1>Controls</h1>
      <p>Text (the cursor is an I-beam here). Right-click it for the page menu.</p>
      <p><select onchange="r.textContent = this.value"><option>one</option><option>two</option><option>three</option></select>
        <a href="/dialogs" target="_blank">target=_blank link (opens in a Bosk window)</a></p>
      <p><input placeholder="Type here"></p>
      <p>Result: <span id="r"></span></p>""",
}

# The service worker of /notifications: it tells its pages when its notification is clicked.
NOTIFICATIONS_WORKER = b"""self.onnotificationclick = e => { e.notification.close();
  e.waitUntil(clients.matchAll().then(all => all.forEach(c => c.postMessage('worker clicked')))); };"""


class Handler(BaseHTTPRequestHandler):
    def send_html(self, body, status=200, headers=()):
        data = f"<!doctype html><meta charset=utf-8><title>{self.path}</title>{body}".encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/download":
            data = b"Bosk download test\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Disposition", "attachment; filename=bosk-test.txt")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif self.path == "/auth":
            expected = "Basic " + base64.b64encode(b"bosk:bosk").decode()
            if self.headers.get("Authorization") == expected:
                self.send_html("<h1>Signed in</h1>")
            else:
                self.send_html("<h1>Sign-in needed</h1>", 401, [("WWW-Authenticate", 'Basic realm="Bosk test"')])
        elif self.path == "/notifications-sw.js":
            self.send_response(200)
            self.send_header("Content-Type", "text/javascript")
            self.send_header("Content-Length", str(len(NOTIFICATIONS_WORKER)))
            self.end_headers()
            self.wfile.write(NOTIFICATIONS_WORKER)
        elif self.path in PAGES:
            self.send_html(PAGES[self.path])
        else:
            self.send_html("<h1>Not found</h1>", 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        self.send_html(f"<h1>Received {length} bytes</h1><p><a href='/'>Back</a></p>")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"Test pages on http://localhost:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
