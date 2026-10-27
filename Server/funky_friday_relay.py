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

The simplest way to set it up: pick one seed phrase and give it to both sides.
Run the server with that seed and put the same seed in the script's LINK_SEED;
each side works out the key and secret from it on its own, so there's only one
value to keep in sync.
  FF_SEED="some phrase" python funky_friday_relay.py
  python funky_friday_relay.py --seed "some phrase"
  echo "some phrase" > seed.txt && python funky_friday_relay.py   # picked up too

With no seed, the server instead makes a random key and secret on first run and
saves them next to this file in relay_auth.json, so they stay the same every
session; copy those into the script's LINK_RELAY_KEY / LINK_RELAY_SECRET.

Either way, print what the script needs with
  python funky_friday_relay.py --show      (add --seed "..." to show a seed's)
See Server/README.md.

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
SEED_FILE = os.path.join(HERE, "seed.txt")

PORT = int(os.environ.get("PORT", "8080"))
AUTH_WINDOW = 60          # seconds a request's timestamp may be off by
MESSAGE_TTL = 120         # seconds a message is kept and handed to late pollers
MAX_PER_TOPIC = 400       # most messages kept per topic
MAX_BODY = 8 * 1024       # biggest message body accepted


def derive(seed):
    """key and secret from one seed phrase -- the script does the same, so both
    sides land on the same pair from the same seed."""
    key = hashlib.sha256(("FFKEY:" + seed).encode()).hexdigest()[:16]
    secret = hashlib.sha256(("FFSECRET:" + seed).encode()).hexdigest()
    return key, secret


def find_seed(argv):
    """A seed from --seed, then FF_SEED, then seed.txt; None if none is set."""
    if "--seed" in argv:
        i = argv.index("--seed")
        if i + 1 < len(argv):
            return argv[i + 1].strip() or None
    env = os.environ.get("FF_SEED")
    if env and env.strip():
        return env.strip()
    try:
        with open(SEED_FILE) as f:
            return f.read().strip() or None
    except OSError:
        return None


def load_auth(seed):
    """From a seed when there is one, otherwise a random pair saved once and
    reused every run after. Returns (key, secret, from_seed)."""
    if seed:
        key, secret = derive(seed)
        return key, secret, True
    try:
        with open(AUTH_FILE) as f:
            data = json.load(f)
            if data.get("key") and data.get("secret"):
                return data["key"], data["secret"], False
    except (OSError, ValueError):
        pass
    auth = {"key": secrets.token_hex(8), "secret": secrets.token_hex(32)}
    with open(AUTH_FILE, "w") as f:
        json.dump(auth, f, indent=2)
    try:
        os.chmod(AUTH_FILE, 0o600)
    except OSError:
        pass
    return auth["key"], auth["secret"], False


import sys
SEED = find_seed(sys.argv)
KEY, SECRET, FROM_SEED = load_auth(SEED)


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
    if "--show" in sys.argv:
        if FROM_SEED:
            print("seed:         %s" % SEED)
            print("relay key:    %s   (made from the seed)" % KEY)
            print("relay secret: %s   (made from the seed)" % SECRET)
            print("\nPut the same seed in the script's LINK_SEED -- it works the")
            print("key and secret out itself, so these two are just for reference.")
        else:
            print("relay key:    %s" % KEY)
            print("relay secret: %s" % SECRET)
            print("\nkept in %s -- same every run" % AUTH_FILE)
            print("put these in the script's LINK_RELAY_KEY / LINK_RELAY_SECRET")
        return
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("Funky Friday relay on port %d" % PORT)
    if FROM_SEED:
        print("  seed set -> key %s (put the SAME seed in the script's LINK_SEED)" % KEY)
    else:
        print("  key:    %s" % KEY)
        print("  secret: %s  (keep this one off-screen)" % SECRET)
    print("  health: http://127.0.0.1:%d/health" % PORT)
    print("Expose this port with a tunnel (see Server/README.md), then set the")
    print("public URL and seed (or key/secret) in the scripts. Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
