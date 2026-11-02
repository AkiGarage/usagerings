---
name: usagerings-formal-verification
description: Use when changing how UsageRings reads provider usage (MultiUsageService source arguments, disabled providers, Claude pending section, CLI retry). Keeps docs/formal/UsageRead.tla in step with the code and runs TLC.
---
1. Update docs/formal/UsageRead.tla so each action matches the code path in MultiUsageService.fetchAll / fetchProvider.
2. Keep every rule as an INVARIANT in UsageRead.cfg; never weaken one to pass.
3. Run `TLA2TOOLS_JAR=/path/tla2tools.jar docs/formal/check.sh`; it must print "No error has been found".
4. Mirror each invariant in Tests/CodexUsageWidgetTests/SourcePolicyTests.swift and run `swift test` and `script/lint.sh`.
5. Update docs/formal/chart.mmd when states or steps change.
