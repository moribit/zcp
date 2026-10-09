#!/usr/bin/env python3
import argparse,csv,statistics,collections
p=argparse.ArgumentParser();p.add_argument("csv",nargs="+");o=p.parse_args()
for path in o.csv:
    groups=collections.defaultdict(list); failures=collections.Counter()
    with open(path) as f:
        for r in csv.DictReader(f):
            key=tuple(r.get(k,"") for k in ("build_mode","phase","backend","buffer_size","buffer_count","connections","integrity"))
            if r.get("status","ok")!="ok":failures[key]+=1;groups[key];continue
            groups[key].append(float(r["MB_s"]))
    print("\n"+path)
    print("| Configuration | n OK | n failed | Median MB/s | Min–max MB/s | vs 25 MB/s |")
    print("|---|---:|---:|---:|---:|---:|")
    for key,values in sorted(groups.items()):
        config=" / ".join(s for s in key if s)
        if values:
            med=statistics.median(values); print(f"| {config} | {len(values)} | {failures[key]} | {med:.2f} | {min(values):.2f}–{max(values):.2f} | {med/25:.2f}x |")
        else:print(f"| {config} | 0 | {failures[key]} | — | — | — |")
