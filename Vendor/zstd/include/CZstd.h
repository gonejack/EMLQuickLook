#ifndef CZSTD_H
#define CZSTD_H

#include <stddef.h>

/* The small subset of the zstd streaming decoder API used by EML Quick Look.
   Declarations match facebook/zstd v1.5.7's public zstd.h. */

typedef struct ZSTD_DCtx_s ZSTD_DCtx;
typedef ZSTD_DCtx ZSTD_DStream;

typedef struct {
    const void *src;
    size_t size;
    size_t pos;
} ZSTD_inBuffer;

typedef struct {
    void *dst;
    size_t size;
    size_t pos;
} ZSTD_outBuffer;

ZSTD_DStream *ZSTD_createDStream(void);
size_t ZSTD_freeDStream(ZSTD_DStream *zds);
size_t ZSTD_initDStream(ZSTD_DStream *zds);
size_t ZSTD_decompressStream(ZSTD_DStream *zds, ZSTD_outBuffer *output, ZSTD_inBuffer *input);
unsigned ZSTD_isError(size_t code);

#endif
