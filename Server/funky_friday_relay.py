#!/usr/bin/env python3
"""
Funky Friday relay -- a tiny message relay for the Funky Friday scripts
(Games/FunkyFriday.lua and Games/FunkyFridayBeta.lua), made to run on your
phone in Termux with nothing but Python's standard library. No pip installs.

It speaks the little bit of the ntfy protocol the scripts use: a copy POSTs a
JSON message to  /<topic>  and reads new ones from  /<topic>/json?poll=1&since=..
The scripts fall back to this polling path on their own when there's no
WebSocket, which there isn't here, so the Lua side needs no protocol change --
only the relay URL and the shared key/secret below.

Every request is checked four ways before a message is stored or handed out, so
someone who doesn't have your key and secret can't read your room or send fake
commands:
  1. key      X-FF-Key must equal the public key (names which relay this is)
  2. time     X-FF-Time must be within AUTH_WINDOW seconds of now (no stale req)
  3. nonce    X-FF-Nonce must be one this server hasn't seen (no replaying a req)
  4. sign     X-FF-Sign must be HMAC-SHA256(secret, key\ntopic\ntime\nnonce\nbody)
              -- the secret is never sent, so this proves the sender has it and
              that nobody changed the topic, time, nonce or body on the way
The topic (room) is one of the signed fields, so a request signed for your room
can't be replayed into anyone else's, and rooms are made on demand (a game
server's topic just starts working the first time a signed request names it).

The key and secret are made once, on first run, and saved next to this file in
relay_auth.json, so they stay the same every session. Print them with
  python funky_friday_relay.py --show
and put them in the scripts (see Server/README.md).

Run:
  python funky_friday_relay.py              # listens on 0.0.0.0:8080
  PORT=9000 python funky_friday_relay.py    # a different port
"""

import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
AUTH_FILE = os.path.join(HERE, "relay_auth.json")

PORT = int(os.environ.get("PORT", "8080"))
AUTH_WINDOW = 60          # seconds a request's timestamp may be off by
MESSAGE_TTL = 120         # seconds a message is kept and handed to late pollers
MAX_PER_TOPIC = 400       # most messages kept per topic
MAX_BODY = 8 * 1024       # biggest message body accepted


def load_auth():
    """The key/secret pair, made once and reused every run after."""
    try:
        with open(AUTH_FILE) as f:
            data = json.load(f)
            if data.get("key") and data.get("secret"):
                return data["key"], data["secret"]
    except (OSError, ValueError):
        pass
    auth = {"key": secrets.token_hex(8), "secret": secrets.token_hex(32)}
    with open(AUTH_FILE, "w") as f:
        json.dump(auth, f, indent=2)
    try:
        os.chmod(AUTH_FILE, 0o600)
    except OSError:
        pass
    return auth["key"], auth["secret"]


KEY, SECRET = load_auth()


class Store:
    """Per-topic message logs and the set of nonces already used, both pruned
    by time. All access holds the lock, since requests come in on threads."""

    def __init__(self):
        self.lock = threading.Lock()
        self.topics = {}            # topic -> list of {id, time, event, message}
        self.nonces = {}            # nonce -> expiry time
        self.next_id = 1

    def _prune(self, now):
        for topic, msgs in list(self.topics.items()):
            kept = [m for m in msgs if m["time"] >= now - MESSAGE_TTL][-MAX_PER_TOPIC:]
            if kept:
                self.topics[topic] = kept
            else:
                del self.topics[topic]
        for nonce, expiry in list(self.nonces.items()):
            if expiry < now:
                del self.nonces[nonce]

    def use_nonce(self, nonce, now):
        """True the first time a nonce is seen, False if it's a replay."""
        with self.lock:
            if nonce in self.nonces:
                return False
            self.nonces[nonce] = now + AUTH_WINDOW * 2
            return True

    def add(self, topic, body, now):
        with self.lock:
            self._prune(now)
            msg = {"id": "m%d" % self.next_id, "time": int(now),
                   "event": "message", "topic": topic, "message": body}
            self.next_id += 1
            self.topics.setdefault(topic, []).append(msg)
            return msg

    def since(self, topic, since, now):
        """Messages after the given id, or from the last MESSAGE_TTL seconds
        when `since` isn't a known id (a duration like '10s' or a timestamp)."""
        with self.lock:
            self._prune(now)
            msgs = self.topics.get(topic, [])
            if since and since.startswith("m"):
                for i, m in enumerate(msgs):
                    if m["id"] == since:
                        return list(msgs[i + 1:])
                return list(msgs)
            return [m for m in msgs if m["time"] >= now - MESSAGE_TTL]


STORE = Store()


def verify(handler, topic, body):
    """Run the five checks. Returns None when all pass, or an (code, why)."""
    now = time.time()

    key = handler.headers.get("X-FF-Key", "")
    if not hmac.compare_digest(key, KEY):
        return 401, "bad key"

    stamp = handler.headers.get("X-FF-Time", "")
    try:
        if abs(now - int(stamp)) > AUTH_WINDOW:
            return 401, "stale or future timestamp"
    except ValueError:
        return 401, "bad timestamp"

    nonce = handler.headers.get("X-FF-Nonce", "")
    if not nonce or len(nonce) > 64:
        return 401, "missing nonce"

    sign = handler.headers.get("X-FF-Sign", "")
    mac = hmac.new(
        SECRET.encode(),
        ("%s\n%s\n%s\n%s\n%s" % (KEY, topic, stamp, nonce, body)).encode(),
        hashlib.sha256,
    ).hexdigest()
    if not hmac.compare_digest(sign, mac):
        return 401, "bad signature"

    # the nonce is spent last, so a request that fails an earlier check can be
    # corrected and sent again with the same nonce
    if not STORE.use_nonce(nonce, now):
        return 401, "nonce already used"

    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # quiet; flip to super().log_message(*args) to see every request

    def _send(self, code, body="", content_type="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        if parts == ["health"]:
            return self._send(200, "ok\n", "text/plain")
        if len(parts) == 2 and parts[1] == "json":
            topic = parts[0]
            err = verify(self, topic, "")
            if err:
                return self._send(err[0], err[1] + "\n", "text/plain")
            since = (parse_qs(url.query).get("since") or [""])[0]
            msgs = STORE.since(topic, since, time.time())
            lines = "".join(json.dumps(m, separators=(",", ":")) + "\n" for m in msgs)
            return self._send(200, lines, "application/x-ndjson")
        return self._send(404, "not found\n", "text/plain")

    def do_POST(self):
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if len(parts) != 1:
            return self._send(404, "not found\n", "text/plain")
        topic = parts[0]
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > MAX_BODY:
            return self._send(413, "too big\n", "text/plain")
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        err = verify(self, topic, body)
        if err:
            return self._send(err[0], err[1] + "\n", "text/plain")
        msg = STORE.add(topic, body, time.time())
        return self._send(200, json.dumps({"id": msg["id"]}))


def main():
    import sys
    if "--show" in sys.argv:
        print("relay key:    %s" % KEY)
        print("relay secret: %s" % SECRET)
        print("\nkept in %s -- same every run" % AUTH_FILE)
        return
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("Funky Friday relay on port %d" % PORT)
    print("  key:    %s" % KEY)
    print("  secret: %s  (keep this one off-screen)" % SECRET)
    print("  health: http://127.0.0.1:%d/health" % PORT)
    print("Expose this port with a tunnel (see Server/README.md), then put the")
    print("public URL, key and secret in the scripts. Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
