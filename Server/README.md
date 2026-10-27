# Funky Friday relay

A tiny message relay for the Funky Friday scripts
([`Games/FunkyFriday.lua`](../Games/FunkyFriday.lua) and
[`Games/FunkyFridayBeta.lua`](../Games/FunkyFridayBeta.lua)), small enough to
run on your phone in Termux. By default the scripts use the free public
`ntfy.sh`; this lets you run your own instead, on a link that stays the same
every session, with signed requests so nobody can read your room or send fake
commands.

`funky_friday_relay.py` uses **only Python's standard library — there is nothing
to `pip install`.** You just need Python itself and a tunnel to give the phone a
public link.

## What you download

In Termux:

```sh
pkg update && pkg install python git
# optionally, to get the file onto the phone:
git clone https://github.com/iamdookie1/Rblx2
cd Rblx2/Server
```

That is all Python needs. For the public link, pick one tunnel below and install
that too.

## 1. Run the relay

```sh
python funky_friday_relay.py
```

It listens on port `8080` and prints a **key** and a **secret** on the first
run. They are saved in `relay_auth.json` next to the script and are the same
every run after, so your link setup doesn't change between sessions. See them
again any time with:

```sh
python funky_friday_relay.py --show
```

- **key** — public-ish; it just names which relay this is.
- **secret** — keep it off-screen/recordings. It's the one that signs requests,
  and it is never sent over the network.

Use a different port with `PORT=9000 python funky_friday_relay.py`.

## 2. Give it a public link that stays the same

The phone is behind your carrier/router, so you need a tunnel. Both options give
a **stable** URL and the clients connect to the tunnel provider, not to your
phone — your home/phone IP is never handed out to the Roblox clients.

### Option A — ngrok (easiest; one free static domain)

1. Make a free account at ngrok.com, then in Termux:
   `pkg install ngrok` (or download the ARM build).
2. `ngrok config add-authtoken <your token>` (from the ngrok dashboard).
3. On the dashboard, **Domains → create a free static domain**, e.g.
   `funky-yourname.ngrok-free.app`. A free account gets one, and it stays yours.
4. Run it against the relay:
   `ngrok http --url=funky-yourname.ngrok-free.app 8080`
5. Your relay URL is `https://funky-yourname.ngrok-free.app`.

### Option B — Cloudflare Tunnel (needs a domain, no provider sees your IP either)

1. `pkg install cloudflared`.
2. If you own a domain on Cloudflare (or get a cheap/free one and add it),
   `cloudflared tunnel login`, then create a named tunnel and route a
   hostname (e.g. `relay.yourdomain.com`) to `http://localhost:8080`. Cloudflare
   has a short walkthrough for "locally-managed tunnels".
3. Your relay URL is `https://relay.yourdomain.com`.

A quick `cloudflared tunnel --url http://localhost:8080` also works but its URL
changes every run, so it's only good for a one-off test — use a named tunnel for
a link that stays put.

> The tunnel provider (ngrok/Cloudflare) does carry your traffic and can see
> your phone's connection to them. You can't hide from the provider itself; what
> this setup does is keep your IP off the public URL the Roblox clients use.

Check it's reachable: open `https://your-url/health` in a browser — it should
say `ok`.

## 3. Point the scripts at your relay

Put these three lines **before** the `loadstring(...)` that loads the script, on
every client (both the dev script and anyone on the beta script — they must all
use the same relay, key and secret or they won't see each other):

```lua
getgenv().FunkyFridayRelay = "https://your-url"        -- no trailing slash
getgenv().FunkyFridayRelayKey = "<key from the server>"
getgenv().FunkyFridayRelaySecret = "<secret from the server>"
loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/Games/FunkyFridayBeta.lua'))()
```

With a secret set, the scripts stamp, add a one-time nonce to, and sign every
request (HMAC-SHA256), and they poll the relay (this relay has no WebSocket). The
Dev tab's Link box will read `on, checking every 6s (your relay, signed)`.

To test it all on one device, run **both** the dev and beta scripts in the same
game with the same three lines — they find each other through your relay and you
appear on your own beta list.

## The four auth checks

A request is only accepted when all four pass (see the top of the `.py` for
detail): the **key** matches, the **timestamp** is within a minute of the
server's clock, the **nonce** hasn't been used before, and the **signature**
(HMAC-SHA256 over key + topic + time + nonce + body, using the secret) is
correct. The topic is one of the signed fields, so a request signed for your
room can't be replayed into another. Anyone without the secret can't produce a
valid signature, so forged commands are dropped.
