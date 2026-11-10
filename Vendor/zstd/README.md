# Zstandard decoder

`zstddeclib.c` is the single-file Zstandard decompressor from
[facebook/zstd](https://github.com/facebook/zstd) v1.5.7. It was generated from
the release tarball with:

```sh
cd build/single_file_libs
./create_single_file_decoder.sh
```

`CZstd.h` exposes only the streaming decoder API used by the extension and the
`emlrender` tool. Zstandard is licensed under the BSD 3-Clause license; see
[`LICENSE`](LICENSE).
