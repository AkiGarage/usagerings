# Contributing to UsageRings

Open a GitHub issue for bugs or focused feature proposals. For vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of posting details publicly.

## Development

Use macOS 14 or later and Swift 5.9 or later. Running the XCTest suite requires
the full Xcode installation; standalone Command Line Tools can build the app but
may fail tests with `no such module 'XCTest'`.

If `xcode-select -p` points to `/Library/Developer/CommandLineTools`, select your
installed Xcode for this shell before running the checks (adjust the path if
Xcode is installed elsewhere). This does not change the system-wide selection:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --find xctest
```

Setting `SDKROOT` here also replaces any inherited Command Line Tools SDK path,
so the compiler and SDK come from the same Xcode installation.

```sh
swift build
swift test
./script/build_and_run.sh usagerings package
./script/build_and_run.sh usagerings package-verify
```

The package command builds without launching the app. For UI checks, use sample data and review both compact rings and the detail panel. `Tests/CodexBarReleaseDetectionTests/Fixtures` contains data used by compatibility tests, not an active release or merge policy.

## Pull requests

Keep changes focused. Describe the problem, resulting behavior, and checks performed. Add a regression test when changing behavior that can fail silently. Include sanitized screenshots for UI changes.

Never commit credentials, personal logs, account details, local paths, generated app bundles, or build output. Use reserved example domains and clearly synthetic credentials in tests. Changes to authentication, SSH, signing, workflows, or release behavior need particular attention to permissions and recovery.

CI uses a hosted macOS runner with read-only repository permissions. Contributions do not trigger publishing or automatic merging. Maintainers review pull requests before merging.
