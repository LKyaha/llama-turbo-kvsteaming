# llama-turbo-kvsteaming

A reproducible integration/build repository for a Windows-focused llama.cpp stack combining:

- latest `ggml-org/llama.cpp` mainline
- TurboQuant / Turbo2 / Turbo3 / Turbo4 KV-cache support
- Raymond Huang's adaptive KV streaming phase-arena design, as integrated and generalized by the TurboQuant KV-streaming work
- reproducible Windows CUDA and Vulkan binary builds

This repository is intentionally an **integration control plane**, not a manually copied snapshot of hundreds of thousands of upstream source lines. CI materializes the TurboQuant + KV-streaming feature head, temporarily merges the latest llama.cpp `master`, builds the result, packages the binaries, and records all resolved source SHAs in every artifact. A merge conflict is a hard failure rather than silently dropping either side.

## Windows build targets

| Artifact | Backend | Intended hardware | Adaptive KV streaming |
|---|---|---|---|
| `llama-win-cuda12-v100-sm70` | CUDA 12.4 | Tesla V100 / Volta SM70 | compiled in; **real V100 validation still required** |
| `llama-win-cuda13.1-modern` | CUDA 13.1 | modern NVIDIA GPUs | yes |
| `llama-win-cuda13.3-modern` | CUDA 13.3 | modern NVIDIA GPUs | yes |
| `llama-win-vulkan-x64` | Vulkan | Vulkan-capable GPUs | backend build only; **do not assume CUDA phase-arena streaming is available** |

CUDA builds explicitly enable `GGML_CUDA_FA_ALL_QUANTS=ON`, because streamed Turbo KV attention otherwise may fall back to the much slower F16 dequantization path.

## Source composition

The feature side is `TheTom/llama-cpp-turboquant` PR #357, fetched through GitHub's pull-request ref. That PR ports/generalizes Raymond Huang's `feature/kv-stream-phase-arena` work and wires Turbo2/3/4 into the streaming attention path.

The materializer then fetches the latest `ggml-org/llama.cpp` `master` and creates an **ephemeral merge**. This means CI answers the question we actually care about: does *current mainline + TurboQuant/Turbo4 + adaptive KV streaming* still merge and compile today?

See [`UPSTREAMS.md`](UPSTREAMS.md) for source-of-truth refs and maintenance policy, and [`VALIDATION.md`](VALIDATION.md) for hardware gates.

## Build locally

PowerShell:

```powershell
./scripts/prepare-source.ps1
```

This creates `source/` containing the same three-way integration tree used by CI. Build it with ordinary llama.cpp CMake options; the GitHub Actions workflow is the canonical reference for the exact Windows configurations.

To inspect only the feature branch without merging latest mainline:

```powershell
./scripts/prepare-source.ps1 -SkipMainlineMerge
```

## Releases

- Pushes / pull requests: build artifacts are uploaded to the workflow run.
- A weekly scheduled build rechecks the moving upstreams.
- Manual `workflow_dispatch`: builds the full matrix.
- Tags matching `v*`: the same artifacts are attached to a GitHub Release.

Every package contains `SOURCE-PROVENANCE.txt` with the Turbo/KV-stream feature SHA, llama.cpp mainline SHA, final integration SHA, backend, toolkit, and architecture list.

## Maintenance rules

1. Do not blindly merge upstream changes into a permanent release branch.
2. Let the ephemeral merge expose conflicts first.
3. Require all intended Windows build legs to compile before tagging a release.
4. Treat V100 support as provisional until exercised on real SM70 hardware.
5. Do not claim Vulkan KV phase-arena streaming until the Vulkan backend actually implements and validates it.

## Credits and licenses

This repository orchestrates builds of upstream projects and does not replace their licenses or attribution. Preserve the license files and notices shipped by the materialized source tree.

Primary upstream work:

- `ggml-org/llama.cpp`
- `TheTom/llama-cpp-turboquant`
- `RaymondHuang210129/llama.cpp-adaptive-kv-streaming`
- PR #357 contributors integrating/generalizing phase-arena streaming with TurboQuant
