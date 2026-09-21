#!/usr/bin/env python3
"""combine-verdicts.py <stage> <indir> <outfile>

Merges every per-combo verdict file under <indir> (written by emit-verdict.py
or emit-static-verdicts.py, each {"series","target","verdict"}) into one
{"stage": ..., "results": {"series/target": "pass"|"fail"}} file -- the shape
release-gate.py expects.
"""
import json, sys, pathlib

stage, indir, outfile = sys.argv[1], sys.argv[2], sys.argv[3]
results = {}
for f in sorted(pathlib.Path(indir).glob("*.json")):
    d = json.loads(f.read_text())
    results[f"{d['series']}/{d['target']}"] = d["verdict"]
json.dump({"stage": stage, "results": results}, open(outfile, "w"))
print(f"{stage}: {len(results)} combo(s) -> {outfile}")
