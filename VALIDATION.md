# Validation gates

A green CI build proves that the integration compiles. It does **not** prove every backend/hardware path behaves correctly.

## Release-level compile gates

- [ ] CUDA 12.4 / SM70 package builds
- [ ] CUDA 13.1 modern package builds
- [ ] CUDA 13.3 modern package builds
- [ ] Vulkan x64 package builds
- [ ] source provenance exists in every ZIP
- [ ] tag build attaches all four ZIPs to one GitHub Release

## Tesla V100 / SM70 hardware gate

Run on a real V100 before calling the V100 artifact validated:

- [ ] `llama-cli --version` starts
- [ ] `llama-server --version` starts
- [ ] CUDA device is detected as SM70
- [ ] ordinary GGUF inference works with full/partial GPU offload
- [ ] Turbo4 K/V cache can initialize
- [ ] Turbo4 K/V output is coherent on a short deterministic prompt
- [ ] adaptive KV streaming initializes with `--kv-stream-arena-mib`
- [ ] long-context run shows host RAM growth and bounded VRAM as intended
- [ ] compare streaming on/off output using PPL/KLD where practical
- [ ] measure prompt/decode throughput and PCIe transfer overhead
- [ ] verify MTP interaction separately if the chosen model contains MTP layers

Record driver version, CUDA runtime reported by the binary, model GGUF, KV types, context, arena size, VRAM/RAM, and command line.

## Modern NVIDIA smoke gate

At minimum on one post-Volta GPU:

- [ ] CUDA 13.1 package starts and runs
- [ ] CUDA 13.3 package starts and runs
- [ ] Turbo4 K/V works
- [ ] streamed Turbo4 path runs with `GGML_CUDA_FA_ALL_QUANTS` build

## Vulkan gate

- [ ] Vulkan package starts on a representative NVIDIA/AMD/Intel Vulkan driver
- [ ] ordinary model inference works
- [ ] TurboQuant features supported by the upstream Vulkan backend behave correctly
- [ ] documentation continues to avoid claiming CUDA phase-arena KV streaming on Vulkan

## Regression gate when upstream changes KV/cache/attention code

Pay extra attention to changes touching:

- `llama-kv-cache*`
- `llama-memory*`
- scheduler / graph phase transitions
- Flash Attention dispatch
- `ggml-cuda` buffer allocation / kernels
- Turbo direct-attention kernels
- CMake CUDA architecture handling
- speculative/MTP contexts

For meaningful changes in these areas, compile success alone is not enough; rerun targeted correctness tests before tagging a release.
