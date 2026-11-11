#!/usr/bin/env python3
"""Compare per-trial CSVs from run.lua (same seeds).  compare.py a.csv b.csv [c.csv ...]"""
import csv, sys, collections

def load(p):
    return {r['i']: r for r in csv.DictReader(open(p))}

runs = [(p, load(p)) for p in sys.argv[1:]]
ids = set.intersection(*[set(r) for _, r in runs])
ids = [i for i in ids if all(r[i]['out'] != 'timeout' and r[i]['flight'] for _, r in runs)]

def reachable(row):
    return float(row['flight']) >= int(row['rtt']) / 1000 + 0.035

pings = sorted({int(runs[0][1][i]['rtt']) for i in ids})
hdr = "ping   " + "  ".join(f"{p.split('/')[-1][:18]:>18}" for p, _ in runs)
print("success on REACHABLE passes (flight >= ping + 35ms)")
print(hdr)
for pg in pings + ['all']:
    sel = [i for i in ids if (pg == 'all' or int(runs[0][1][i]['rtt']) == pg) and reachable(runs[0][1][i])]
    cells = []
    for _, r in runs:
        ok = sum(1 for i in sel if r[i]['out'] == 'success')
        cells.append(f"{ok / max(len(sel), 1) * 100:6.1f}% ({ok:4d}/{len(sel):4d})")
    print(f"{str(pg):>5}  " + "  ".join(f"{c:>18}" for c in cells))
print("\nsuccess on UNREACHABLE passes (needs pre-parry)")
sel = [i for i in ids if not reachable(runs[0][1][i])]
for p, r in runs:
    ok = sum(1 for i in sel if r[i]['out'] == 'success')
    print(f"  {p.split('/')[-1]:>24}: {ok}/{len(sel)}")
print("\nfailure reasons on reachable passes")
for p, r in runs:
    c = collections.Counter(r[i]['out'] for i in ids if reachable(r[i]) and r[i]['out'] != 'success')
    print(f"  {p.split('/')[-1]:>24}: {dict(c)}")
if len(runs) >= 2:
    a, b = runs[0][1], runs[-1][1]
    worse = [i for i in ids if a[i]['out'] == 'success' and b[i]['out'] != 'success']
    better = [i for i in ids if b[i]['out'] == 'success' and a[i]['out'] != 'success']
    print(f"\nlast vs first: +{len(better)} newly hit, -{len(worse)} newly missed")
    def tab(rows, key):
        c = collections.Counter(key(b[i]) for i in rows)
        return sorted(c.items(), key=lambda x: -x[1])[:10]
    if worse:
        print("  newly missed by curve", tab(worse, lambda x: x['curve']))
        print("  newly missed by out  ", tab(worse, lambda x: x['out']))
        print("  newly missed seeds   ", [b[i]['i'] for i in worse[:15]])
