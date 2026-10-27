# Funky Friday relay

A tiny message relay for the Funky Friday scripts
([`Games/FunkyFriday.lua`](../Games/FunkyFriday.lua) and
[`Games/FunkyFridayBeta.lua`](../Games/FunkyFridayBeta.lua)), small enough to
run on an Android phone in Termux. By default the scripts use the free public
`ntfy.sh`; this lets you run your own instead, on a link that stays the same
every session, with signed requests so nobody can read your room or send fake
commands.

`funky_friday_relay.py` uses **only Python's standard library — there is nothing
to `pip install`.** You just need Python itself and a tunnel to give the phone a
public link.

## What you download

In Termux:

```sh
pkg update && pkg install python git openssh
git clone https://github.com/iamdookie1/Rblx2
cd Rblx2/Server
```

`python` runs the relay, `openssh` is for the SSH-based tunnels below (which
need no extra binary), and `git` just pulls this repo. For a Cloudflare/ngrok
tunnel you'd install that one tool too — see the options further down.

## 1. Pick a seed and run the relay

The easy path is one **seed phrase** that you give to both the relay and the
script. Each side works out the key, the secret and the request signatures from
it, so there's only one value to keep in sync.

```sh
FF_SEED="whatever phrase you like" python funky_friday_relay.py
```

It listens on port `8080` **and opens the tunnel for you** — see step 2. Run it
with `--show` to print what the script needs:

```sh
python funky_friday_relay.py --seed "whatever phrase you like" --show
```

Other ways to give it the seed: `--seed "phrase"` on the command line, or put
the phrase in a file named `seed.txt` next to the script. Use a different port
with `PORT=9000 ...`.

> Keep the seed private. Anyone who has it can send your scripts commands. Since
> you obfuscate the public beta, baking the seed into it (see step 3) keeps it
> out of sight. `seed.txt` and the generated `relay_auth.json` are gitignored so
> they're never committed.

(If you'd rather not use a seed, run it with no seed and it makes a random key
and secret once, saved in `relay_auth.json` and the same every run; `--show`
prints them and you paste them into `LINK_RELAY_KEY` / `LINK_RELAY_SECRET`.)

## 2. The public link (the relay opens it for you)

The phone is behind your carrier/router, so you need a tunnel. The clients
connect to the tunnel provider, not to your phone, so your phone/home IP is
never in the public URL the Roblox clients use. (The provider itself does carry
your traffic — you can't hide from the provider, only from the clients.)

On Android, tunnels that run their own binary (cloudflared, ngrok) sometimes
fail to start in Termux with an `unexpected e_type: 2` loader error. So the
relay uses the **SSH-based** Serveo tunnel, which runs through Termux's own
`ssh` (the `openssh` you installed) and has no binary to trip over.

**You don't run the tunnel separately — the relay does it.** On start it runs

```sh
ssh -R funkyff:80:localhost:8080 serveo.net
```

for you, pointed at its own port, prints the URL, and reconnects if Serveo
drops. Your relay URL is therefore:

```
https://funkyff.serveo.net
```

Change the subdomain with `FF_SUBDOMAIN=yourname python funky_friday_relay.py`
(→ `https://yourname.serveo.net`). Serveo occasionally goes down; if the tunnel
log keeps retrying, try again later or use one of the alternatives below with
`--no-tunnel`.

Check it's reachable: open `https://funkyff.serveo.net/health` in a browser — it
should say `ok`.

### Alternatives (run the relay with `--no-tunnel` and bring your own)

- **Pinggy** — SSH-based like Serveo, very reliable; free URL rotates every 60
  minutes, a cheap plan keeps it fixed:
  `ssh -p 443 -R0:localhost:8080 qr@a.pinggy.io` (prints a `...pinggy.link` URL).

#### Cloudflare Tunnel (robust, but needs the binary to run + a domain for a stable URL)

```sh
pkg install tur-repo && pkg install cloudflared
cloudflared --version        # if this errors with "unexpected e_type", use Option A
```

- A quick tunnel is free and needs no account but the URL changes each run:
  `cloudflared tunnel --url http://localhost:8080` → a random
  `*.trycloudflare.com`. Fine for a one-off test.
- A **stable** hostname needs a domain on Cloudflare: log in with
  `cloudflared tunnel login`, create a named tunnel, and route a hostname
  (e.g. `relay.yourdomain.com`) to `http://localhost:8080`. Cloudflare's
  "locally-managed tunnel" guide covers it.

#### ngrok (free static domain, but also a binary)

Make a free ngrok account, install the Android/arm64 build, add your authtoken,
and create the one free static domain the account includes
(`funky-yourname.ngrok-free.app`), then
`ngrok http --url=funky-yourname.ngrok-free.app 8080`. Same `e_type` caveat as
cloudflared on some phones.

## 3. Point the scripts at your relay

You obfuscate the public beta, so just set the two constants near the top of the
link block — no `getgenv` lines before `loadstring`, and the seed stays hidden
in the obfuscated output:

```lua
local LINK_RELAY = "https://funkyff.serveo.net"   -- your relay URL, no trailing slash
local LINK_SEED  = "whatever phrase you like"      -- the same seed as the server
```

The script derives the key and secret from the seed, then stamps, adds a
one-time nonce to, and signs (HMAC-SHA256) every request, and polls the relay
(this relay has no WebSocket). The dev script's Link box will read
`on, checking every 6s (your relay, signed)`.

If you ever do want to set it at load time instead of baking it in, these still
work and override the constants:

```lua
getgenv().FunkyFridayRelay = "https://your-url"
getgenv().FunkyFridayRelaySeed = "whatever phrase you like"
-- or an exact pair: getgenv().FunkyFridayRelayKey / .FunkyFridayRelaySecret
```

To test it all on one device, run **both** the dev and beta scripts in the same
game with the same relay and seed — they find each other through your relay and
you appear on your own beta list.

## The four auth checks

A request is only accepted when all four pass (see the top of the `.py`): the
**key** matches, the **timestamp** is within a minute of the server's clock, the
**nonce** hasn't been used before, and the **signature** (HMAC-SHA256 over
key + topic + time + nonce + body, using the secret) is correct. The topic is
one of the signed fields, so a request signed for your room can't be replayed
into another. Anyone without the seed (hence without the secret) can't produce a
valid signature, so forged commands are dropped.
