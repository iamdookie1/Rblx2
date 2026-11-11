# ParrySim

Offline simulator for `Games/BladeBallRewrite.lua`'s auto parry. It runs the script's real core
(everything up to the `BBStop == 1` line) in LuaJIT against fake Roblox services, a simulated
Blade Ball server and a lossy network, so timing changes can be measured before testing in game.

```
apt-get install -y luajit          # once
luajit Tools/ParrySim/run.lua <suite> <script.lua> [variant] [trials] [seed]
python3 Tools/ParrySim/compare.py a.csv b.csv ...   # same seeds, per-trial comparison
```

Suites
- `pass`: one ball sent at you by a bot (random speed 40-1300, distance 12-120, curve type).
- `rally`: 1v1 against a perfect bot that curves randomly; speed grows every hit.
- `ffa`: you and 5 bots for 45s, random targets; deaths per minute.
- `session`: a long 1v1 at random speeds, so the in-game timing correction has time to learn.
- `smoke`: three quick pass trials with the flight log.

Variants: `ap` (auto parry, Remote), `apkey` (auto parry, Keypress), `tb` / `tbkey` (triggerbot).

Every trial randomises ping (20-500ms, by trial index), jitter, lag spikes, frame rate (60/144/240),
the render smoothing delay, the server's homing law (proportional / constant rate / tightening, with
or without speed scaling), the deflect range, whether Roblox signals are deferred, and whether you
are strafing.

Environment switches
- `SIM_CSV=path` per-trial CSV (for compare.py), `SIM_VERBOSE=1` one line per trial,
  `SIM_ONLY=n` run only trial n, `SIM_LOG=1` the script's flight log, `SIM_DBG=1` debug events and
  holds, `SIM_EVAL=1` every auto parry evaluation, `SIM_WLOG=1` server events.
- `SIM_S=key=value,...` override settings (`timing=100`, `hp_preparry=true`, ...).
- `SIM_PINGBIAS=0.5` Data Ping reports half the real round trip; `SIM_BUF=0.22` a long render
  smoothing delay; `SIM_NOCAL=1` turns off the residual timing correction.

The server model is a guess (the real ball physics run on Blade Ball's server and are not in the
client dumps), so the numbers compare versions under the same assumptions; they are not a promise
of in-game hit rates. `compare.py` scores the "reachable" passes separately: a pass shorter than
your round trip can only be hit by pre-parrying.
