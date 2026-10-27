#!/usr/bin/env python3
"""
Funky Friday relay -- a tiny message relay for the Funky Friday scripts
(Games/FunkyFriday.lua and Games/FunkyFridayBeta.lua), made to run on an Android
phone in Termux with nothing but Python's standard library. No pip installs.

The relay is deliberately dumb: it just holds the last couple of minutes of
messages per topic and hands them to whoever polls. It is NOT trusted and needs
no password. Security lives in the messages themselves -- the dev script signs
every command with an RSA private key and the beta script checks the signature
with the matching public key, so a forged or replayed command is rejected by
the beta client no matter what the relay (or anyone else) sends. That's why
there's nothing to copy between this server and the scripts any more.

It speaks the bit of the ntfy protocol the scripts use: a copy POSTs a JSON
message to  /<topic>  and reads new ones from  /<topic>/json?poll=1&since=..

It also opens the tunnel for you: on start it runs the Serveo SSH tunnel
(the same `ssh -R funkyff:80:localhost:8080 serveo.net` you'd type by hand),
points it at its own port, prints your https URL and reconnects if Serveo drops.
That needs `ssh` (pkg install openssh) and an SSH key Serveo has registered so it
gives you the reserved name; the relay makes the key on first run. Without ssh
the relay still serves locally and tells you. Change the name with
FF_SUBDOMAIN=yourname, or skip the tunnel with --no-tunnel.

Run:
  python funky_friday_relay.py              # relay + tunnel on 0.0.0.0:8080
  PORT=9000 python funky_friday_relay.py    # a different local port
  python funky_friday_relay.py --no-tunnel  # relay only
"""

import os
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PORT", "8080"))
SUBDOMAIN = os.environ.get("FF_SUBDOMAIN", "funkyff")  # the name you reserved on Serveo
TUNNEL_DOMAIN = os.environ.get("FF_TUNNEL_DOMAIN", "serveousercontent.com")
MESSAGE_TTL = 120         # seconds a message is kept and handed to late pollers
MAX_PER_TOPIC = 400       # most messages kept per topic
MAX_BODY = 8 * 1024       # biggest message body accepted


class Store:
    """Per-topic message logs, pruned by time. All access holds the lock, since
    requests come in on threads."""

    def __init__(self):
        self.lock = threading.Lock()
        self.topics = {}            # topic -> list of {id, time, event, message}
        self.next_id = 1

    def _prune(self, now):
        for topic, msgs in list(self.topics.items()):
            kept = [m for m in msgs if m["time"] >= now - MESSAGE_TTL][-MAX_PER_TOPIC:]
            if kept:
                self.topics[topic] = kept
            else:
                del self.topics[topic]

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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # quiet

    def _send(self, code, body="", content_type="application/json"):
        import json as _json
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        import json
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        if parts == ["health"]:
            return self._send(200, "ok\n", "text/plain")
        if len(parts) == 2 and parts[1] == "json":
            since = (parse_qs(url.query).get("since") or [""])[0]
            msgs = STORE.since(parts[0], since, time.time())
            lines = "".join(json.dumps(m, separators=(",", ":")) + "\n" for m in msgs)
            return self._send(200, lines, "application/x-ndjson")
        return self._send(404, "not found\n", "text/plain")

    def do_POST(self):
        import json
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if len(parts) != 1:
            return self._send(404, "not found\n", "text/plain")
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > MAX_BODY:
            return self._send(413, "too big\n", "text/plain")
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        msg = STORE.add(parts[0], body, time.time())
        return self._send(200, json.dumps({"id": msg["id"]}))


STOP = threading.Event()        # set on shutdown so the tunnel thread can quit
TUNNEL = {"proc": None}         # the running ssh process, so we can stop it
KEY_FILE = os.path.expanduser("~/.ssh/id_ed25519")


def ensure_key():
    """Serveo only gives out a reserved name to an SSH key you've registered with
    it, so make one the first time and use it every run after. Returns its path,
    or None if ssh-keygen isn't there."""
    if os.path.exists(KEY_FILE):
        return KEY_FILE
    if not shutil.which("ssh-keygen"):
        print("  tunnel: ssh-keygen not found (pkg install openssh) -- no key, so")
        print("          Serveo will hand out a random URL instead of your name")
        return None
    os.makedirs(os.path.dirname(KEY_FILE), mode=0o700, exist_ok=True)
    result = subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-N", "", "-q", "-C", "funkyff-relay", "-f", KEY_FILE],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print("  tunnel: couldn't make an ssh key: %s" % (result.stderr.strip() or result.returncode))
        return None
    print("  tunnel: made an ssh key at %s (used every run from now on)" % KEY_FILE)
    print("          Serveo will print a link below to register it -- open it once")
    print("          and log in, then restart this and you get your name for good.")
    return KEY_FILE


def check_forward(line, expected):
    """Shout when Serveo gave a different URL than the one the scripts use."""
    marker = "Forwarding HTTP traffic from "
    if marker not in line:
        return
    url = line.split(marker, 1)[1].strip().rstrip("/")
    if url == expected:
        print("  tunnel: OK -- %s matches the scripts' LINK_RELAY" % url)
        return
    print("  tunnel: !! Serveo gave %s, NOT %s" % (url, expected))
    print("          the scripts point at %s, so they won't reach this." % expected)
    print("          This happens until your ssh key is registered with Serveo:")
    print("          open the register link Serveo printed above, log in, and")
    print("          restart. Don't use or share the random URL -- it has your")
    print("          IP address written into it.")


def start_serveo(subdomain, port):
    if not shutil.which("ssh"):
        print("  tunnel: ssh not found -- run `pkg install openssh`, then this")
        print("          will bring the tunnel up itself. serving locally for now.")
        return None
    key = ensure_key()
    expected = "https://%s.%s" % (subdomain, TUNNEL_DOMAIN)
    cmd = ["ssh",
           "-o", "StrictHostKeyChecking=accept-new",
           "-o", "ServerAliveInterval=60",
           "-o", "ServerAliveCountMax=3",
           "-o", "ExitOnForwardFailure=yes",
           "-R", "%s:80:localhost:%d" % (subdomain, port),
           "serveo.net"]
    if key:
        cmd[1:1] = ["-i", key, "-o", "IdentitiesOnly=yes"]

    def run():
        backoff = 2
        while not STOP.is_set():
            print("  tunnel: connecting to serveo.net ...")
            try:
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True, bufsize=1)
            except OSError as exc:
                print("  tunnel: couldn't start ssh (%s)" % exc)
                return
            TUNNEL["proc"] = proc
            for line in proc.stdout:
                line = line.rstrip()
                if line:
                    print("  tunnel: " + line)
                    check_forward(line, expected)
            proc.wait()
            TUNNEL["proc"] = None
            if STOP.is_set():
                return
            print("  tunnel: dropped, reconnecting in %ds" % backoff)
            STOP.wait(backoff)
            backoff = min(backoff * 2, 30)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread


def stop_serveo():
    STOP.set()
    proc = TUNNEL.get("proc")
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("Funky Friday relay on port %d" % PORT)
    print("  health: http://127.0.0.1:%d/health" % PORT)

    tunnel = None
    if "--no-tunnel" in sys.argv:
        print("Tunnel off (--no-tunnel). Expose port %d yourself; see README." % PORT)
    else:
        print("Opening the Serveo tunnel -- your relay URL will be:")
        print("  https://%s.%s   (this is the scripts' LINK_RELAY)" % (SUBDOMAIN, TUNNEL_DOMAIN))
        print("  change the name with FF_SUBDOMAIN=yourname, or --no-tunnel to skip")
        tunnel = start_serveo(SUBDOMAIN, PORT)
    print("Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        if tunnel is not None:
            stop_serveo()


if __name__ == "__main__":
    main()
