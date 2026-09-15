# llama-turbo-kvsteaming

A reproducible integration/build repository for a Windows-focused llama.cpp stack combining:

- llama.cpp lineage via `TheTom/llama-cpp-turboquant`
- TurboQuant / Turbo2 / Turbo3 / Turbo4 KV-cache support
- Raymond Huang's adaptive KV streaming phase-arena design, as integrated and generalized by the TurboQuant KV-streaming work
- reproducible Windows CUDA and Vulkan binary builds

This repository is intentionally an **integration control plane**, not a manually copied snapshot of hundreds of thousands of upstream source lines. CI materializes the exact upstream source ref described in `UPSTREAMS.md`, builds it, packages the binaries, and records source provenance in every artifact.

## Windows build targets

| Artifact | Backend | Intended hardware | Adaptive KV streaming |
|---|---|---|---|
| `llama-win-cuda12-v100-sm70` | CUDA 12.4 | Tesla V100 / Volta SM70 | compiled in; **real V100 validation still required** |
| `llama-win-cuda13.1-modern` | CUDA 13.1 | modern NVIDIA GPUs | yes |
| `llama-win-cuda13.3-modern` | CUDA 13.3 | modern NVIDIA GPUs | yes |
| `llama-win-vulkan-x64` | Vulkan | Vulkan-capable GPUs | backend build only; **do not assume CUDA phase-arena streaming is available** |

CUDA builds explicitly enable `GGML_CUDA_FA_ALL_QUANTS=ON`, because streamed Turbo KV attention otherwise may fall back to the much slower F16 dequantization path.

## Source baseline

The current integration source is the head of `TheTom/llama-cpp-turboquant` PR #357, fetched through GitHub's pull-request ref. That PR ports/generalizes Raymond Huang's `feature/kv-stream-phase-arena` work and wires Turbo2/3/4 into the streaming attention path.

See [`UPSTREAMS.md`](UPSTREAMS.md) for source-of-truth refs and maintenance policy.

## Build locally

PowerShell:

```powershell
./scripts/prepare-source.ps1
```

This creates `source/` at the integration ref. Build it with ordinary llama.cpp CMake options; the GitHub Actions workflow is the canonical reference for the exact Windows configurations.

## Releases

- Pushes / pull requests: build artifacts are uploaded to the workflow run.
- Manual `workflow_dispatch`: builds the full matrix.
- Tags matching `v*`: the same artifacts are attached to a GitHub Release.

Every package contains `SOURCE-PROVENANCE.txt` with the actual resolved commit SHA.

## Maintenance rules

1. Do not blindly merge upstream changes directly into a release branch.
2. First update/test the integration source ref.
3. Require all Windows build legs to compile before tagging a release.
4. Treat V100 support as provisional until exercised on real SM70 hardware.
5. Do not claim Vulkan KV phase-arena streaming until the Vulkan backend actually implements and validates it.

## Credits and licenses

This repository orchestrates builds of upstream projects and does not replace their licenses or attribution. Preserve the license files and notices shipped by the materialized source tree.

Primary upstream work:

- `ggml-org/llama.cpp`
- `TheTom/llama-cpp-turboquant`
- `RaymondHuang210129/llama.cpp-adaptive-kv-streaming`
- PR #357 contributors integrating/generalizing phase-arena streaming with TurboQuant
