#!/usr/bin/env python3
"""emit-static-verdicts.py <pass|fail> <outfile>

static.yml runs once for the whole repo, not per (series,target) combo --
this marks every known combo the same way, in the combined
{"stage","results"} shape release-gate.py expects (so it composes directly
with combine-verdicts.py's output for the other, per-combo stages).
"""
import json, sys, yaml, pathlib

verdict, outfile = sys.argv[1], sys.argv[2]
root = pathlib.Path(__file__).resolve().parents[2]
doc = yaml.safe_load((root / "series.yaml").read_text())
results = {f"{s}/{t}": verdict for s, cfg in doc["build"].items() for t in cfg["targets"]}
json.dump({"stage": "static", "results": results}, open(outfile, "w"))
