# Upstream sources and integration policy

## Current source graph

The build workflow materializes the integration tree from:

1. **TurboQuant base**
   - Repository: `https://github.com/TheTom/llama-cpp-turboquant.git`
   - Base branch: `feature/turboquant-kv-cache`

2. **Adaptive KV streaming integration**
   - Pull request: `TheTom/llama-cpp-turboquant#357`
   - Git fetch ref: `refs/pull/357/head`
   - Purpose: ports/generalizes Raymond Huang's phase-arena streaming design and connects it to Turbo2/3/4 direct attention.

3. **Original phase-arena work**
   - Repository: `https://github.com/RaymondHuang210129/llama.cpp-adaptive-kv-streaming.git`
   - Branch: `feature/kv-stream-phase-arena`

4. **Mainline ancestry**
   - Repository: `https://github.com/ggml-org/llama.cpp.git`
   - Branch: `master`

## Why CI fetches `refs/pull/357/head`

PR #357 is currently the most complete tested composition of TurboQuant/Turbo4 plus phase-arena KV streaming. Fetching the pull-request head avoids manually reconstructing a large conflict-prone patch stack.

The workflow records the resolved commit SHA into each artifact. This gives reproducibility even while PR #357 is still moving.

## Update policy

Upstream changes are **not** blindly merged into releases.

For a new integration baseline:

1. run the `Upstream status` workflow;
2. resolve and record the candidate source SHA;
3. run the full Windows build matrix;
4. inspect any API/ABI, KV-cache, CUDA, attention, scheduler, or CMake changes;
5. only tag a release after all intended build legs are green;
6. run hardware validation separately for behavior that CI cannot prove (especially V100/SM70 and long-context streaming).

## Backend support claims

### CUDA

Adaptive KV phase-arena streaming is a CUDA-oriented implementation in the current integration. CUDA artifacts enable:

```text
GGML_CUDA_FA_ALL_QUANTS=ON
```

This is important for streamed Turbo KV attention performance.

### Vulkan

The Vulkan package is produced from the same source tree so users get the TurboQuant-capable Vulkan backend where supported by upstream. It must **not** be described as supporting the CUDA phase-arena KV streaming path unless a Vulkan implementation is added and validated later.

### V100 / Volta

The dedicated V100 build uses CUDA 12.4 and explicitly targets SM70:

```text
CMAKE_CUDA_ARCHITECTURES=70
```

CUDA 13.x artifacts are modern-GPU builds and are not the V100 path.

## Validation debt

Compilation is necessary but not sufficient. The following remain real-hardware gates:

- Tesla V100 / SM70 startup and inference with the CUDA 12 build
- Turbo4 KV cache correctness/performance on V100
- phase-arena KV streaming behavior on V100
- long-context memory transfer behavior across PCIe on V100 systems
- Vulkan functional smoke tests across representative drivers
- any future Vulkan implementation of adaptive KV streaming
