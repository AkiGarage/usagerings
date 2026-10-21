# Changelog

## Unreleased — initial public source release

- Introduce UsageRings, the multi-provider macOS floating usage dashboard for Codex, Claude Code, Antigravity, GLM Coding Plan, and Grok.
- Provide compact rings, reset-time details, account-separated usage, and appearance/layout controls.
- Make remote Claude B monitoring opt-in, with a configurable SSH host in Settings.
- Default local app builds to ad-hoc signing; support `USAGERINGS_SIGN_IDENTITY` for a custom identity.
- Include public contribution guidance and a macOS build/test workflow.

The source target retains its historical `CodexUsageWidget` name. The packaged app uses `com.akigarage.usagerings` and can copy existing settings once from the legacy multi-provider app. Remote SSH monitoring requires the new explicit opt-in and a configured host.
