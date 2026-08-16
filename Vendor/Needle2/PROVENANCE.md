# Needle2 binary provenance

Hourglass embeds the official Cactus Needle engine from the public
`Cactus-Compute/needle2` Hugging Face model repository.

- Package: `cactus-needle` 2.0.2
- Hub artifact: `python/cactus_needle-2.0.2-py3-none-macosx_11_0_arm64.whl`
- Hub revision: `17a803d95928ba33d3e9a0160e024d9565b5c3f2`
- Wheel SHA-256: `5ef0caf9b1bbef91e3e6c3eef180440a4d53e4a06dda7b409247efcc4cb55ad8`
- Embedded member: `needle/libneedle.dylib`
- Dylib SHA-256: `f8ff35e0ceea5812f3f90bddbb40ca3a8d03af07c84555e116bf0096fa994afd`
- Architecture: arm64
- Install name: `@rpath/libneedle.dylib`
- Mach-O deployment target: macOS 11.0
- License: Apache-2.0 (`LICENSE` in this directory)

Reproduce the download and extraction with:

```sh
hf download Cactus-Compute/needle2 \
  python/cactus_needle-2.0.2-py3-none-macosx_11_0_arm64.whl \
  --local-dir /private/tmp/hourglass-needle-wheel

unzip /private/tmp/hourglass-needle-wheel/python/\
cactus_needle-2.0.2-py3-none-macosx_11_0_arm64.whl \
  needle/libneedle.dylib -d /private/tmp/hourglass-needle-dylib
```

The public `cactus-compute/needle` repository contains the Python API,
fine-tuning code, and weight exporter, but not the C++ inference-engine source;
its README explicitly describes the engine as a fetched prebuilt with “nothing
else to build.” Hourglass therefore uses the vendor's macOS 11 build instead of
rewriting the deployment metadata on the macOS 26 standalone archive.
