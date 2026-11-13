#!/usr/bin/env python3
"""Run the reset model and require each injected fault to break its invariant."""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent
jar = os.environ['TLA2TOOLS']
java = os.environ.get('JAVA', 'java')
for cfg in sorted(root.glob('*.cfg')):
    log = args.output.resolve() / (cfg.stem + '.log')
    with log.open('w') as stream:
        result = subprocess.run([java, '-XX:+UseParallelGC', '-cp', jar, 'tlc2.TLC',
                                 '-workers', '1', '-metadir', str(log.with_suffix('.states')),
                                 str(root / 'ResetRefresh.tla'), '-config', str(cfg)],
                                stdout=stream, stderr=subprocess.STDOUT)
    text = log.read_text()
    fault = cfg.stem.startswith('Fault-')
    invariant = cfg.read_text().split('INVARIANTS\n')[1].strip()
    expected = f'Invariant {invariant} is violated' if fault else 'No error has been found'
    if expected not in text or (not fault and result.returncode != 0):
        raise SystemExit(f'FAIL {cfg.name}: see {log}')
    print(f'PASS {cfg.name}' + (f' caught {invariant}' if fault else ''), flush=True)
