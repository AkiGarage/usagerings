# Security Policy

Report vulnerabilities through this repository's **Security → Advisories → Report a vulnerability** private reporting flow, when enabled. Do not include vulnerability details, credentials, account data, or exploit instructions in public issues.

If private reporting is unavailable, open a GitHub issue requesting a private reporting channel without including sensitive details. Maintainers can arrange a private GitHub security advisory.

UsageRings stores settings and display data locally, but usage retrieval contacts configured services. The CLIProxyAPI management connection is loopback-only. Remote Claude SSH monitoring is off by default and requires an explicit host and a trusted host key. See the [README](README.md#privacy) for local files and network behavior.

Build CI runs on GitHub-hosted macOS with read-only repository permissions and no publishing steps. Never add credentials to issue attachments, test fixtures, logs, or screenshots. Synthetic test credentials are not production credentials.
