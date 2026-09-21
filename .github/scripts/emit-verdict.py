#!/usr/bin/env python3
"""emit-verdict.py <series> <target> <outcome> <outfile>

<outcome> is a GitHub Actions step "outcome" (success/failure/cancelled/
skipped) -- read from `steps.<id>.outcome`, which reflects the step's real
result even under `continue-on-error`. Writes {"series","target","verdict"}
to <outfile>; combine-verdicts.py later merges many of these into one
<stage>-verdicts.json.
"""
import json, sys

series, target, outcome, outfile = sys.argv[1:5]
verdict = "pass" if outcome == "success" else "fail"
json.dump({"series": series, "target": target, "verdict": verdict}, open(outfile, "w"))
