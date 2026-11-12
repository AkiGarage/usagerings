// The four Zstandard decode entry points UsageRings calls, copied from lib/zstd.h
// of the pinned release (see ../README.md). zstddeclib.c carries zstd.h inline,
// so declaring only these keeps the vendored file byte-identical.

#ifndef USAGERINGS_ZSTD_H
#define USAGERINGS_ZSTD_H

#include <stddef.h>

size_t ZSTD_decompress(void *dst, size_t dstCapacity,
                       const void *src, size_t compressedSize);
size_t ZSTD_findFrameCompressedSize(const void *src, size_t srcSize);
unsigned ZSTD_isError(size_t result);
unsigned long long ZSTD_getFrameContentSize(const void *src, size_t srcSize);

#define ZSTD_CONTENTSIZE_UNKNOWN (0ULL - 1)
#define ZSTD_CONTENTSIZE_ERROR   (0ULL - 2)

#endif
