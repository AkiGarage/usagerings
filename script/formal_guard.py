#!/usr/bin/env python3
"""Check model invariants and exact verified content, including uncommitted work."""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def definitions(text):
    text = re.sub(r"\(\*.*?\*\)", " ", text, flags=re.S)
    text = re.sub(r"\\\*[^\n]*", " ", text)
    marks = list(re.finditer(r"^([A-Za-z_][A-Za-z0-9_]*)(\([^)]*\))?\s*==", text, re.M))
    return {m[1]: " ".join(text[m.end():marks[i + 1].start() if i + 1 < len(marks) else len(text)]
                                   .split("====")[0].split()) for i, m in enumerate(marks)}


def invariants(text):
    return {name for line in text.splitlines() if line.startswith(("INVARIANT ", "INVARIANTS ", "PROPERTY ", "PROPERTIES "))
            for name in line.split()[1:]}


def constants(text):
    result = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] in ("=", "<-"):
            result[parts[0]] = " ".join(parts[2:])
    return result


def baseline(root, path):
    result = subprocess.run(["git", "-C", str(root), "show", f"HEAD:{path}"],
                            capture_output=True, text=True, env={**os.environ, "GIT_NO_LAZY_FETCH": "1"})
    if result.returncode:
        raise ValueError(f"Cannot read HEAD:{path}: {result.stderr.strip()}")
    return result.stdout


def check(root):
    config = json.loads((root / ".formal/guard.json").read_text())
    previous = json.loads(baseline(root, ".formal/guard.json"))
    specs = {s["tla"]: s for s in config["specs"]}
    problems = []
    for old in previous["specs"]:
        spec = specs.get(old["tla"])
        if spec is None:
            problems.append(f"REMOVED spec {old['tla']}")
            continue
        for field in ("sources", "cfgs"):
            for path in set(old[field]) - set(spec[field]):
                problems.append(f"REMOVED {field} {path}")
        # New actions/variables may describe intended behavior; old rules must stay.
        old_defs = definitions(baseline(root, old["tla"]))
        new_defs = definitions((root / spec["tla"]).read_text())
        for cfg in old["cfgs"]:
            old_rules = invariants(baseline(root, cfg))
            new_rules = invariants((root / cfg).read_text())
            old_constants = constants(baseline(root, cfg))
            new_constants = constants((root / cfg).read_text())
            for name, value in old_constants.items():
                if new_constants.get(name) != value:
                    problems.append(f"CHANGED constant {name} in {cfg}")
            for name in old_rules:
                if name not in new_rules or old_defs.get(name) != new_defs.get(name):
                    problems.append(f"CHANGED invariant {name} in {cfg}")
    for spec in specs.values():
        hashes = spec.get("sync_sha256", {})
        required = {spec["tla"], *spec["cfgs"], *spec["sources"], *spec.get("artifacts", [])}
        for path in sorted(required):
            if path not in hashes:
                problems.append(f"UNVERIFIED {path}")
            elif not (root / path).is_file() or digest(root / path) != hashes[path]:
                problems.append(f"STALE {path} for {spec['tla']}")
    return problems


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    for problem in (problems := check(root)):
        print(problem)
    if not problems:
        print("PASS formal sync (invariants and verified content)")
    return bool(problems)


if __name__ == "__main__":
    sys.exit(main())
