# Vendored Zstandard decoder

`zstddeclib.c` is Zstandard's official single-file **decode-only** amalgamation.
Claude Desktop stores cached HTTP bodies with `content-encoding: zstd`, and macOS
ships no zstd decoder a signed app can link (Compression.framework has zlib,
LZFSE, LZ4, LZMA, Brotli and LZBITMAP only). Only
`Sources/CodexUsageWidget/Services/ClaudeDesktopResetCache.swift` uses it, through
the four declarations in `include/UsageRingsZstd.h`. Nothing compresses.

| | |
|---|---|
| Upstream | <https://github.com/facebook/zstd> v1.5.7 |
| Release tarball | `zstd-1.5.7.tar.gz`, sha256 `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3` (downloaded tarball matches) |
| Generator | `build/single_file_libs/combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c` |
| File sha256 | `5eb38abe0a7eea13674b312a006df72002d4192f0f0b4d09e6f03fb927a1f3d0` |
| Licence | BSD-3-Clause, `LICENSE` beside this file (upstream dual-licenses BSD-3-Clause or GPLv2; BSD-3-Clause is taken) |
| Local edits | none |

The file was taken from Codenotch's vendored copy
(<https://github.com/vinzdg/codenotch>, `Sources/Vendor/zstd/zstddeclib.c` at
`835550a342871779135b6484d6899161c5222f7c`, MIT, see `THIRD_PARTY_NOTICES.md`)
and is byte-identical to that copy. `LICENSE` is byte-identical to the
release tarball's. A line-by-line comparison of `zstddeclib.c` against a fresh
`combine.py` run on the tarball has **not** been completed; do that before
treating this file as independently re-derived from upstream.
