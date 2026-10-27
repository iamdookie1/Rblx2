# Funky Friday relay

A tiny message relay for the Funky Friday scripts
([`Games/FunkyFriday.lua`](../Games/FunkyFriday.lua) and
[`Games/FunkyFridayBeta.lua`](../Games/FunkyFridayBeta.lua)), small enough to
run on an Android phone in Termux. Nothing but Python's standard library — **no
`pip install`.**

## How the security works

The relay is **dumb and untrusted** — it just carries messages and needs no
password. The security is in the messages:

- The **dev script holds an RSA private key** and signs every command.
- The **beta script carries only the matching public key** — it can *check* a
  signature but can never *make* one.

So a beta copy, even fully deobfuscated, cannot forge a command, and neither can
the relay or anyone watching it: only your dev client can issue commands. Each
command also carries a timestamp and a one-time nonce, so a captured command
can't be replayed. Because the proof is in the signature, **there is nothing to
copy between this server and the scripts.**

## 1. Make your key pair (once)

```sh
pkg update && pkg install python git openssh
git clone https://github.com/iamdookie1/Rblx2
cd Rblx2/Server
python make_key.py
```

It prints two long hex numbers:

- **PUBLIC n** → put it in **both** scripts as `LINK_PUB_N`. Safe to ship/commit.
- **PRIVATE d** → only your **dev** client gets it. Set it on that client with
  `getgenv().FunkyFridayDevKey = "<d>"` before the dev `loadstring`, or paste it
  into `LINK_DEV_PRIVATE` in your own dev copy. **Never share or commit it** —
  whoever holds it can command every beta user.

Generating the key on your own phone means the private key never leaves it.
(The exponent is always 65537, which the scripts already use, so you only copy
`n` and `d`.) Run `make_key.py` again any time to roll a fresh pair — then update
`LINK_PUB_N` everywhere.

## 2. Run the relay

```sh
python funky_friday_relay.py
```

It listens on port `8080` **and opens the tunnel for you** (step 3). `--no-tunnel`
serves locally only; `PORT=9000 ...` changes the local port.

## 3. The public link (the relay opens it for you)

The phone is behind your carrier/router, so you need a tunnel. Clients connect to
the tunnel provider, not to your phone, so your phone/home IP is never in the
public URL. (The provider does carry your traffic — you can't hide from the
provider, only from the clients.)

On Android, tunnels that run their own binary (cloudflared, ngrok) sometimes fail
to start in Termux with an `unexpected e_type: 2` loader error, so the relay uses
the SSH-based **Serveo** tunnel through Termux's own `ssh`. On start it runs

```sh
ssh -R funkyff:80:localhost:8080 serveo.net
```

for you, pointed at its own port, and reconnects if Serveo drops. Your relay URL
is `https://funkyff.serveousercontent.com` (change the name with
`FF_SUBDOMAIN=yourname`).

**One-time: register your SSH key with Serveo.** Serveo only gives you a reserved
name once your SSH key is registered; until then it hands out a random
`...serveousercontent.com` URL that **has your IP address written into it** —
don't use or share that one. The relay makes the key on first run
(`~/.ssh/id_ed25519`); Serveo then prints a link to register it — open it, log
in, and restart the relay. After that you get `https://funkyff.serveousercontent.com`
every time and the relay prints `tunnel: OK -- ... matches the scripts' LINK_RELAY`.

Check it: open `https://funkyff.serveousercontent.com/health` — it should say `ok`.

### Alternatives (run with `--no-tunnel` and bring your own)

- **Pinggy** (SSH-based, reliable; free URL rotates hourly):
  `ssh -p 443 -R0:localhost:8080 qr@a.pinggy.io`
- **Cloudflare Tunnel** (`pkg install tur-repo && pkg install cloudflared`; a
  stable hostname needs your own domain; may hit the `e_type` error).
- **ngrok** (free static domain; same binary caveat).

## 4. Point the scripts at the relay

In **both** scripts, near the top of the link block:

```lua
local LINK_RELAY = "https://funkyff.serveousercontent.com"   -- your relay URL
local LINK_PUB_N = "<the PUBLIC n from make_key.py>"
```

On your **dev** client only, supply the private key (either line):

```lua
getgenv().FunkyFridayDevKey = "<the PRIVATE d from make_key.py>"  -- before loadstring
-- or paste d into LINK_DEV_PRIVATE in your own dev copy
```

The dev script's Link box shows `(signing on)` when it has the key, or
`(no dev key set -- can't send commands)` when it doesn't. Beta needs only the
public key. Signing a command takes a second or two on the dev client (it's done
off the main thread, so the game doesn't freeze); the beta check is instant.
