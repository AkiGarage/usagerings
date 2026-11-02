#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
jar="${TLA2TOOLS_JAR:?set TLA2TOOLS_JAR to tla2tools.jar}"
java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers 1 UsageRead.tla -config UsageRead.cfg
java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers 1 CodexBarGate.tla -config CodexBarGate.cfg
