param(
    [string]$Destination = "source",
    [string]$Repository = "https://github.com/TheTom/llama-cpp-turboquant.git",
    [string]$PullRequestRef = "refs/pull/357/head",
    [string]$MainlineRepository = "https://github.com/ggml-org/llama.cpp.git",
    [string]$MainlineRef = "master",
    [switch]$SkipMainlineMerge
)

$ErrorActionPreference = "Stop"

function Invoke-Git {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$GitArgs
    )

    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Get-UnmergedPaths {
    $paths = @(& git diff --name-only --diff-filter=U)
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --diff-filter=U failed with exit code $LASTEXITCODE"
    }
    return $paths
}

function Assert-CleanIntegration {
    $unmerged = @(Get-UnmergedPaths)
    if ($unmerged.Count -gt 0) {
        throw "Integration still contains unmerged paths:`n$($unmerged -join "`n")"
    }

    $markers = @(& git grep -n -E '^(<<<<<<<|>>>>>>>)' -- . 2>$null)
    $grepExit = $LASTEXITCODE
    if ($grepExit -eq 0 -and $markers.Count -gt 0) {
        throw "Integration contains conflict markers:`n$($markers -join "`n")"
    }
    if ($grepExit -ne 0 -and $grepExit -ne 1) {
        throw "git grep conflict-marker scan failed with exit code $grepExit"
    }
}

function Resolve-KnownMergeConflicts {
    $unmerged = @(Get-UnmergedPaths)
    if ($unmerged.Count -eq 0) {
        throw "git merge failed, but Git reports no unmerged paths"
    }

    $allowed = @(
        ".github/workflows/build-wasm.yml",
        ".github/workflows/build-self-hosted.yml",
        "ggml/src/ggml-metal/ggml-metal.metal"
    )

    $unknown = @($unmerged | Where-Object { $_ -notin $allowed })
    if ($unknown.Count -gt 0) {
        throw "Unknown upstream merge conflicts require review:`n$($unknown -join "`n")"
    }

    foreach ($path in $unmerged) {
        switch ($path) {
            ".github/workflows/build-wasm.yml" {
                Invoke-Git rm -f -- $path
                Write-Host "Resolved known conflict (feature deletion): $path"
            }
            ".github/workflows/build-self-hosted.yml" {
                Invoke-Git rm -f -- $path
                Write-Host "Resolved known conflict (upstream deletion): $path"
            }
            "ggml/src/ggml-metal/ggml-metal.metal" {
                Invoke-Git add -- $path
                Write-Host "Resolved known conflict (feature copy): $path"
            }
        }
    }

    Assert-CleanIntegration
    Invoke-Git commit --no-edit
}

function Repair-UnorderedMapInclude {
    $backendCpp = "ggml/src/ggml-backend.cpp"
    if (-not (Test-Path $backendCpp)) {
        return
    }

    $backendText = Get-Content $backendCpp -Raw
    if (($backendText -match 'std::unordered_map') -and ($backendText -notmatch '#include\s*<unordered_map>')) {
        $needle = "#include <mutex>"
        if (-not $backendText.Contains($needle)) {
            throw "ggml-backend.cpp uses std::unordered_map but no stable include insertion point was found"
        }

        $backendText = $backendText.Replace($needle, "$needle`r`n#include <unordered_map>")
        Set-Content -Path $backendCpp -Value $backendText -Encoding UTF8
        Invoke-Git add $backendCpp
        Invoke-Git commit -m "integration: restore unordered_map include after merge"
        Write-Host "Applied semantic repair: restored <unordered_map> include required by merged ggml-backend.cpp."
    }
}




function Remove-LaterDuplicateLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    if (-not (Test-Path $Path)) { return $false }
    $lines = @(Get-Content $Path)
    $remove = @()
    foreach ($pattern in $Patterns) {
        $hits = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) { $hits += $i }
        }
        if ($hits.Count -gt 1) { $remove += $hits[1..($hits.Count - 1)] }
    }
    $remove = @($remove | Sort-Object -Unique)
    if ($remove.Count -eq 0) { return $false }
    $out = for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -notin $remove) { $lines[$i] }
    }
    Set-Content -Path $Path -Value $out -Encoding UTF8
    Write-Host "Removed $($remove.Count) later duplicate line(s) from $Path."
    return $true
}

function Repair-ModelHeaderMergeDrift {
    $changed = @()
    $archH = "src/llama-arch.h"
    if (Remove-LaterDuplicateLines -Path $archH -Patterns @(
        '^\s*LLM_KV_DFLASH_BLOCK_SIZE,\s*$',
        '^\s*LLM_KV_DFLASH_CONV_KERNEL_SIZE,\s*$',
        '^\s*LLM_KV_DFLASH_CONV_GROUP_SIZE,\s*$',
        '^\s*LLM_KV_DFLASH_SELECTOR_RANK,\s*$',
        '^\s*LLM_KV_DFLASH_SELECTOR_TOP_K,\s*$'
    )) { $changed += $archH }

    $hparamsH = "src/llama-hparams.h"
    if (Remove-LaterDuplicateLines -Path $hparamsH -Patterns @(
        '^\s*uint32_t\s+dflash_block_size\b.*;\s*$',
        '^\s*uint32_t\s+dflash_conv_kernel_size\b.*;\s*$',
        '^\s*uint32_t\s+dflash_conv_group_size\b.*;\s*$',
        '^\s*uint32_t\s+dflash_selector_rank\b.*;\s*$',
        '^\s*uint32_t\s+dflash_selector_top_k\b.*;\s*$'
    )) { $changed += $hparamsH }

    $modelH = "src/llama-model.h"
    if (Remove-LaterDuplicateLines -Path $modelH -Patterns @(
        '^\s*struct\s+ggml_tensor\s+\*\s*output_res_score\s*=\s*nullptr;\s*(?://.*)?$'
    )) { $changed += $modelH }

    $archCpp = "src/llama-arch.cpp"
    if (Remove-LaterDuplicateLines -Path $archCpp -Patterns @(
        '^\s*\{\s*LLM_KV_DFLASH_BLOCK_SIZE\s*,.*\},\s*$',
        '^\s*\{\s*LLM_KV_DFLASH_CONV_KERNEL_SIZE\s*,.*\},\s*$',
        '^\s*\{\s*LLM_KV_DFLASH_CONV_GROUP_SIZE\s*,.*\},\s*$',
        '^\s*\{\s*LLM_KV_DFLASH_SELECTOR_RANK\s*,.*\},\s*$',
        '^\s*\{\s*LLM_KV_DFLASH_SELECTOR_TOP_K\s*,.*\},\s*$'
    )) { $changed += $archCpp }

    # Current mainline's HY-V4 loader consumes the hyper-connection magnitude
    # GGUF key.  The feature-first merge retained the older key registry and
    # hparams structure, leaving that otherwise complete model source unable to
    # compile.  Backport the complete enum/registry/storage trio together.
    $hyV4 = "src/models/hy-v4.cpp"
    $needsHcMagnitude = (Test-Path $hyV4) -and ((Get-Content $hyV4 -Raw) -match '\bLLM_KV_HYPER_CONNECTION_MAGNITUDE\b')
    if ($needsHcMagnitude) {
        $archText = Get-Content $archH -Raw
        if ($archText -notmatch '\bLLM_KV_HYPER_CONNECTION_MAGNITUDE\b') {
            $old = 'LLM_KV_HYPER_CONNECTION_EPSILON,'
            if (-not $archText.Contains($old)) { throw 'Cannot restore HY-V4 magnitude key: enum anchor is missing' }
            Set-Content -Path $archH -Value $archText.Replace($old, "$old`r`n    LLM_KV_HYPER_CONNECTION_MAGNITUDE,") -Encoding UTF8
            $changed += $archH
        }

        $hparamsText = Get-Content $hparamsH -Raw
        if ($hparamsText -notmatch '\bhc_magnitude\b') {
            $old = 'uint32_t hc_low_rank = 0;'
            if (-not $hparamsText.Contains($old)) { throw 'Cannot restore HY-V4 magnitude hparam: storage anchor is missing' }
            $new = "$old`r`n`r`n    // scale of the hyper-connection post gate (DeepSeek-V4 hardcodes 2.0)`r`n    float    hc_magnitude = 0.0f;"
            Set-Content -Path $hparamsH -Value $hparamsText.Replace($old, $new) -Encoding UTF8
            $changed += $hparamsH
        }

        $archCppText = Get-Content $archCpp -Raw
        if ($archCppText -notmatch '\bLLM_KV_HYPER_CONNECTION_MAGNITUDE\b') {
            $old = '{ LLM_KV_HYPER_CONNECTION_EPSILON,               "%s.hyper_connection.epsilon"               },'
            if (-not $archCppText.Contains($old)) { throw 'Cannot restore HY-V4 magnitude key: registry anchor is missing' }
            $new = "$old`r`n    { LLM_KV_HYPER_CONNECTION_MAGNITUDE,             `"%s.hyper_connection.magnitude`"             },"
            Set-Content -Path $archCpp -Value $archCppText.Replace($old, $new) -Encoding UTF8
            $changed += $archCpp
        }
        Write-Host 'Restored the HY-V4 hyper-connection magnitude key, registry entry, and hparam storage.'
    }

    $modelsH = "src/models/models.h"
    if (Test-Path $modelsH) {
        $modelsText = Get-Content $modelsH -Raw
        if ($modelsText -notmatch '(?m)^\s*struct\s+llama_model_spark2_5\s*:') {
            $sparkLines = @(
                'struct llama_model_spark2_5 : public llama_model_base {',
                '    llama_model_spark2_5(const struct llama_model_params & params) : llama_model_base(params) {}',
                '    void load_arch_hparams(llama_model_loader & ml) override;',
                '    void load_arch_tensors(llama_model_loader & ml) override;',
                '',
                '    struct graph : public llm_graph_context {',
                '        graph(const llama_model & model, const llm_graph_params & params);',
                '    };',
                '',
                '    std::unique_ptr<llm_graph_context> build_arch_graph(const llm_graph_params & params) const override;',
                '};',
                ''
            )
            $sparkDecl = $sparkLines -join [Environment]::NewLine
            $markerIndex = $modelsText.IndexOf('struct llm_build_eagle3_encode')
            if ($markerIndex -ge 0) {
                $modelsText = $modelsText.Insert($markerIndex, $sparkDecl)
            } else {
                $modelsText = $modelsText.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $sparkDecl
            }
            Set-Content -Path $modelsH -Value $modelsText -Encoding UTF8
            $changed += $modelsH
            Write-Host 'Restored llama_model_spark2_5 declaration lost by the feature-first merge.'
        }
    }

    $changed = @($changed | Select-Object -Unique)
    if ($changed.Count -eq 0) { return }
    foreach ($path in $changed) { Invoke-Git add -- $path }
    Invoke-Git commit -m "integration: repair model header merge drift"
    Write-Host 'Applied semantic repair for duplicate DFlash/K3 declarations and missing Spark2.5 model declaration.'
}

function Repair-MissingMainlineModelDeclarations {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MainlineSha
    )

    $modelsH = "src/models/models.h"
    if (-not (Test-Path $modelsH)) { return }

    # A feature-first merge can accept a new model .cpp without touching the
    # heavily edited models.h.  Derive the required classes from the integrated
    # sources, then copy only their exact declarations from the same mainline
    # revision used for the merge.  This keeps model declarations and sources in
    # lockstep without replacing feature-owned declarations.
    $mainlineHeaderLines = @(& git show "${MainlineSha}:src/models/models.h")
    if ($LASTEXITCODE -ne 0) { throw "Cannot read mainline models.h at $MainlineSha" }
    $mainlineHeader = $mainlineHeaderLines -join [Environment]::NewLine
    $modelsText = Get-Content $modelsH -Raw

    $sourceNames = @(
        Get-ChildItem -Path "src/models" -Filter "*.cpp" | ForEach-Object {
            [regex]::Matches((Get-Content $_.FullName -Raw), '\b(llama_model_[A-Za-z0-9_]+)::') |
                ForEach-Object { $_.Groups[1].Value }
        } | Sort-Object -Unique
    )

    $added = @()
    foreach ($name in $sourceNames) {
        $declPattern = "(?m)^\s*struct\s+$([regex]::Escape($name))\s*:"
        if ($modelsText -match $declPattern) { continue }

        $start = $mainlineHeader.IndexOf("struct $name")
        if ($start -lt 0) {
            throw "Integrated source defines $name but mainline models.h has no declaration"
        }
        $open = $mainlineHeader.IndexOf('{', $start)
        if ($open -lt 0) { throw "Cannot parse mainline declaration for ${name}: opening brace is missing" }

        $depth = 0
        $close = -1
        for ($i = $open; $i -lt $mainlineHeader.Length; $i++) {
            if ($mainlineHeader[$i] -eq '{') { $depth++ }
            elseif ($mainlineHeader[$i] -eq '}') {
                $depth--
                if ($depth -eq 0) { $close = $i; break }
            }
        }
        if ($close -lt 0) { throw "Cannot parse mainline declaration for ${name}: closing brace is missing" }
        $end = $mainlineHeader.IndexOf(';', $close)
        if ($end -lt 0) { throw "Cannot parse mainline declaration for ${name}: terminator is missing" }

        $declaration = $mainlineHeader.Substring($start, $end - $start + 1)
        $modelsText = $modelsText.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $declaration + [Environment]::NewLine
        $added += $name
    }

    if ($added.Count -gt 0) {
        Set-Content -Path $modelsH -Value $modelsText -Encoding UTF8
        Invoke-Git add -- $modelsH
        Invoke-Git commit -m "integration: restore missing mainline model declarations"
        Write-Host "Restored model declarations from mainline: $($added -join ', ')."
    }

    $finalHeader = Get-Content $modelsH -Raw
    $missing = @($sourceNames | Where-Object { $finalHeader -notmatch "(?m)^\s*struct\s+$([regex]::Escape($_))\s*:" })
    if ($missing.Count -gt 0) {
        throw "Integrated model source(s) still lack declarations: $($missing -join ', ')"
    }
}

function Repair-MmvqMergeDrift {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FeatureSha
    )

    $mmvqCu = "ggml/src/ggml-cuda/mmvq.cu"
    if (-not (Test-Path $mmvqCu)) {
        return
    }

    $mmvqText = Get-Content $mmvqCu -Raw

    # TurboQuant's feature translation unit carries the convrot/q8 reuse path.
    # Current mainline carries a different MMVQ tuning rewrite (should_halve_iters).
    # A textual three-way merge can retain both without conflict while destroying
    # the surrounding function/switch structure. Treat that mixed state as semantic
    # merge drift and keep the feature translation unit coherent.
    $hasFeatureOwnedPath = $mmvqText -match '\bconvrot\b'
    $hasMainlineRewrite  = $mmvqText -match '\bshould_halve_iters\b'

    if (-not ($hasFeatureOwnedPath -and $hasMainlineRewrite)) {
        return
    }

    Write-Host "Detected semantic merge drift in mmvq.cu (feature convrot path mixed with mainline MMVQ rewrite); restoring the feature-owned translation unit."
    Invoke-Git checkout $FeatureSha -- $mmvqCu

    & git diff --quiet $FeatureSha -- $mmvqCu
    $featureDiffExit = $LASTEXITCODE
    if ($featureDiffExit -eq 1) {
        throw "Feature mmvq.cu invariant failed after restore: translation unit differs from feature source"
    }
    if ($featureDiffExit -ne 0) {
        throw "git diff --quiet for restored mmvq.cu failed with exit code $featureDiffExit"
    }

    Invoke-Git add $mmvqCu
    Invoke-Git commit -m "integration: keep feature mmvq translation unit coherent"
    Write-Host "Applied semantic repair: kept TurboQuant mmvq.cu coherent instead of mixing incompatible mainline MMVQ rewrites."
}

function Repair-Eagle3MergeDrift {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FeatureSha
    )

    $eagle3 = "src/models/eagle3.cpp"
    if (-not (Test-Path $eagle3)) { return }

    $text = Get-Content $eagle3 -Raw
    $entryPoint = '\bllama_model_eagle3::build_arch_graph\s*\('
    $count = [regex]::Matches($text, $entryPoint).Count
    if ($count -le 1) { return }
    if ($count -ne 2) { throw "Unexpected eagle3 build_arch_graph definition count: $count" }

    # The feature header declares llm_build_eagle3_encode/decode.  A clean merge
    # can retain that implementation and append mainline's newer graph-template
    # implementation, producing two entry points.  Keep the coherent feature
    # translation unit instead of mixing the incompatible graph APIs.
    Invoke-Git checkout $FeatureSha -- $eagle3
    $repaired = Get-Content $eagle3 -Raw
    if ([regex]::Matches($repaired, $entryPoint).Count -ne 1) {
        throw 'Feature eagle3 translation unit invariant failed after restore'
    }
    Invoke-Git add -- $eagle3
    Invoke-Git commit -m "integration: keep feature eagle3 translation unit coherent"
    Write-Host 'Restored the coherent feature-owned eagle3 implementation after duplicate mainline entry-point merge drift.'
}

function Assert-NoDuplicateModelEntryPoints {
    $duplicates = @()
    Get-ChildItem -Path "src/models" -Filter "*.cpp" | ForEach-Object {
        $matches = @([regex]::Matches((Get-Content $_.FullName -Raw), '\b(llama_model_[A-Za-z0-9_]+)::build_arch_graph\s*\('))
        $matches | Group-Object { $_.Groups[1].Value } | Where-Object { $_.Count -gt 1 } | ForEach-Object {
            $duplicates += "$($_.Name) in $($_.PSParentPath) ($($_.Count) definitions)"
        }
    }
    if ($duplicates.Count -gt 0) {
        throw "Integrated model entry-point definitions are duplicated: $($duplicates -join '; ')"
    }
}

function Repair-DsaIswaMergeDrift {
    param([Parameter(Mandatory = $true)][string]$MainlineSha)

    # The feature branch carried a placeholder header while the merged graph and
    # model paths use the complete upstream DSA+ISWA memory context.  Restore
    # the matched header and ensure its implementation is linked.
    $header = "src/llama-kv-cache-dsa-iswa.h"
    $cmake = "src/CMakeLists.txt"
    if ((Test-Path $header) -and ((Get-Content $header -Raw) -match 'minimal placeholder')) {
        Invoke-Git checkout $MainlineSha -- $header
        Invoke-Git add -- $header
        Invoke-Git commit -m "integration: restore DSA ISWA memory context header"
    }
    $text = Get-Content $cmake -Raw
    if ($text -notmatch '(?m)^\s*llama-kv-cache-dsa-iswa\.cpp\s*$') {
        $needle = "            llama-kv-cache-dsa.cpp"
        if (-not $text.Contains($needle)) { throw "DSA ISWA source insertion point missing" }
        Set-Content -Path $cmake -Value $text.Replace($needle, "$needle`r`n            llama-kv-cache-dsa-iswa.cpp") -Encoding UTF8
        Invoke-Git add -- $cmake
        Invoke-Git commit -m "integration: link DSA ISWA memory implementation"
    }
}

function Repair-ValidatedMainlineMergeDrift {
    # This patch is deliberately narrow: it records the source/header pairs
    # that compiled and linked together in the CPU preflight.  Its guard makes
    # an upstream layout change fail loudly instead of applying a fuzzy repair.
    $patch = Join-Path $PSScriptRoot "patches/validated-mainline-merge-drift.patch"
    if (-not (Test-Path $patch)) { throw "Validated merge-drift patch is missing: $patch" }

    $context = Get-Content "src/llama-context.cpp" -Raw
    if ($context -match 'gf_res_prev->reset\(\)') {
        Invoke-Git apply --check $patch
        Invoke-Git apply $patch
        Invoke-Git add -- src/CMakeLists.txt src/llama-context.cpp src/llama-graph.cpp src/llama-model-loader.cpp src/llama-model-loader.h src/llama-model-saver.cpp src/llama-model.cpp src/llama-quant.cpp
        Invoke-Git commit -m "integration: repair validated mainline API merge drift"
        Write-Host "Applied CPU-validated context, graph, loader, model and quantization merge repair."
        return
    }

    & git apply --reverse --check $patch
    if ($LASTEXITCODE -ne 0) {
        throw "Integrated source matches neither the validated merge-drift patch preimage nor postimage"
    }
}

function Repair-DflashMergeDrift {
    $patch = Join-Path $PSScriptRoot "patches/validated-dflash-merge-drift.patch"
    if (-not (Test-Path $patch)) { throw "Validated DFlash merge-drift patch is missing: $patch" }
    $source = Get-Content "src/models/dflash.cpp" -Raw
    if ($source -match 'copy_tensor_async_floats') { return }
    Invoke-Git apply --check --whitespace=nowarn $patch
    Invoke-Git apply --whitespace=nowarn $patch
    Invoke-Git add -- src/models/dflash.cpp
    Invoke-Git commit -m "integration: repair DFlash feature merge drift"
    Write-Host "Applied CPU-validated DFlash feature repair."
}

function Repair-CommonLazyApiDrift {
    $patch = Join-Path $PSScriptRoot "patches/validated-common-lazy-api-drift.patch"
    $path = "common/common.h"
    $text = Get-Content $path -Raw
    if ($text -notmatch '\bLLAMA_LAZY_MODE_AUTO\b') { return }
    Invoke-Git apply --check $patch
    Invoke-Git apply $patch
    Invoke-Git add -- $path
    Invoke-Git commit -m "integration: remove stale common lazy mode API"
    Write-Host "Removed the obsolete common lazy-mode enum after the public lazy API migration."
}

function Repair-CublasHandleApiDrift {
    $mmvqTq = "ggml/src/ggml-cuda/mmvq-tq.cu"
    if (-not (Test-Path $mmvqTq)) {
        return
    }

    $mmvqText = Get-Content $mmvqTq -Raw
    $legacyPattern = 'ctx\.cublas_handle\(id\)'
    $legacyCount = [regex]::Matches($mmvqText, $legacyPattern).Count
    if ($legacyCount -eq 0) {
        return
    }

    $setStreamPattern = 'cublasSetStream\s*\(\s*ctx\.cublas_handle\(id\)\s*,\s*stream\s*\)'
    $gemmPattern = 'cublasGemmEx\s*\(\s*ctx\.cublas_handle\(id\)\s*,'
    $setStreamCount = [regex]::Matches($mmvqText, $setStreamPattern).Count
    $gemmCount = [regex]::Matches($mmvqText, $gemmPattern).Count

    if (($legacyCount -ne 2) -or ($setStreamCount -ne 1) -or ($gemmCount -ne 1)) {
        throw "Unexpected legacy cuBLAS handle shape in mmvq-tq.cu: total=$legacyCount, cublasSetStream=$setStreamCount, cublasGemmEx=$gemmCount"
    }

    $repairedText = $mmvqText.Replace("ctx.cublas_handle(id)", "ctx.cublas_handle()")
    $remainingLegacyCount = [regex]::Matches($repairedText, $legacyPattern).Count
    if ($remainingLegacyCount -ne 0) {
        throw "cuBLAS handle repair invariant failed: $remainingLegacyCount legacy call(s) remain"
    }

    Set-Content -Path $mmvqTq -Value $repairedText -Encoding UTF8
    Invoke-Git add $mmvqTq
    Invoke-Git commit -m "integration: adapt TurboQuant cuBLAS handle calls to mainline"
    Write-Host "Applied semantic repair: updated TurboQuant mmvq-tq.cu to the current zero-argument cublas_handle() API."
}

function Repair-FattnMergeDrift {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FeatureSha
    )

    $fattnCu = "ggml/src/ggml-cuda/fattn.cu"
    if (-not (Test-Path $fattnCu)) {
        return
    }

    $fattnText = Get-Content $fattnCu -Raw
    $sentinelPattern = 'static\s+__global__\s+void\s+flash_attn_mask_to_sparse_indices\s*\('
    $sentinelCount = [regex]::Matches($fattnText, $sentinelPattern).Count
    if ($sentinelCount -le 1) {
        return
    }

    Write-Host "Detected semantic merge drift in fattn.cu ($sentinelCount copies of flash_attn_mask_to_sparse_indices); restoring the feature-owned translation unit."
    Invoke-Git checkout $FeatureSha -- $fattnCu

    $repairedText = Get-Content $fattnCu -Raw
    $repairedCount = [regex]::Matches($repairedText, $sentinelPattern).Count
    if ($repairedCount -ne 1) {
        throw "Feature fattn.cu invariant failed after restore: expected exactly one flash_attn_mask_to_sparse_indices definition, found $repairedCount"
    }

    Invoke-Git add $fattnCu
    Invoke-Git commit -m "integration: keep feature fattn translation unit coherent"
    Write-Host "Applied semantic repair: kept the KV-stream/TurboQuant fattn.cu as one coherent feature-owned translation unit."
}

function Repair-ModelApiMergeDrift {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MainlineSha,
        [Parameter(Mandatory = $true)]
        [string]$FeatureSha
    )

    $changed = @()

    # Mainline moved this shared GDN normalization helper into models.h.  The
    # feature-first merge can keep the old header while accepting the new Qwen
    # model sources that call it; add the complete inline implementation so the
    # callers and semantics stay identical to the mainline implementation.
    $modelsH = "src/models/models.h"
    if (Test-Path $modelsH) {
        $modelsText = Get-Content $modelsH -Raw
        $qwenCalls = [regex]::Matches($modelsText, 'build_gdn_l2_norm').Count
        if ($qwenCalls -eq 0) {
            $qwenCalls = @(& git grep -n 'build_gdn_l2_norm' -- 'src/models/qwen35*.cpp' 'src/models/qwen3next.cpp' 2>$null).Count
        }
        if (($qwenCalls -gt 0) -and ($modelsText -notmatch 'static\s+inline\s+ggml_tensor\s*\*\s*build_gdn_l2_norm\s*\(')) {
            $anchor = 'class llama_memory_hybrid_idx_context;'
            if (-not $modelsText.Contains($anchor)) {
                throw "Cannot restore build_gdn_l2_norm: models.h anchor is missing"
            }
            $helper = @"

// ref: https://github.com/ggml-org/llama.cpp/pull/28068
static inline ggml_tensor * build_gdn_l2_norm(ggml_context * ctx, ggml_tensor * x, float eps) {
    const float n = x->ne[0];

    return ggml_scale(ctx, ggml_rms_norm(ctx, x, eps/n), 1.0f/sqrtf(n));
}
"@
            Set-Content -Path $modelsH -Value $modelsText.Replace($anchor, $anchor + $helper) -Encoding UTF8
            $changed += $modelsH
            Write-Host 'Restored the mainline GDN L2-normalization helper required by merged Qwen sources.'
        }
    }

    # qwen4exp switched from a scalar expert width to a per-layer array in
    # mainline.  Keep the feature translation unit (its graph uses feature-owned
    # HC/QSA APIs), then make only the two hparams API changes it needs.
    $qwen4exp = "src/models/qwen4exp.cpp"
    $hparamsH = "src/llama-hparams.h"
    if ((Test-Path $qwen4exp) -and (Test-Path $hparamsH)) {
        $qwenText = Get-Content $qwen4exp -Raw
        $hparamsText = Get-Content $hparamsH -Raw
        $usesOldExpertWidth = ($qwenText -match 'hparams\.n_ff_exp\b') -and
                              ($qwenText -notmatch 'hparams\.n_ff_exp_arr\b')
        $usesIncompatibleMainlineGraph = ($qwenText -match '\bggml_dsv4_hc_pre_gated\b') -or
                                        ($qwenText -match 'is_ple_impl\.reset\s*\(') -or
                                        ($qwenText -match '\bllm_graph_input_qsa\b')
        if (($hparamsText -match '\bn_ff_exp_arr\b') -and ($usesOldExpertWidth -or $usesIncompatibleMainlineGraph)) {
            Invoke-Git checkout $FeatureSha -- $qwen4exp
            $repairedText = Get-Content $qwen4exp -Raw
            $oldLoad = 'ml.get_key(LLM_KV_EXPERT_FEED_FORWARD_LENGTH,        hparams.n_ff_exp, false);'
            $newLoad = 'ml.get_key_or_arr(LLM_KV_EXPERT_FEED_FORWARD_LENGTH, hparams.n_ff_exp_arr, hparams.n_layer_all, false);'
            $oldWidth = 'hparams.n_ff_exp   ? hparams.n_ff_exp   : n_ff / n_expert_used'
            $newWidth = 'hparams.n_ff_exp(il) ? hparams.n_ff_exp(il) : n_ff / n_expert_used'
            if ((-not $repairedText.Contains($oldLoad)) -or (-not $repairedText.Contains($oldWidth))) {
                throw "Feature qwen4exp API repair anchor is missing"
            }
            $repairedText = $repairedText.Replace($oldLoad, $newLoad).Replace($oldWidth, $newWidth)
            if (($repairedText -notmatch 'hparams\.n_ff_exp_arr\b') -or ($repairedText -match 'hparams\.n_ff_exp\s*(?:,|\?)')) {
                throw "qwen4exp feature API repair invariant failed"
            }
            Set-Content -Path $qwen4exp -Value $repairedText -Encoding UTF8
            $changed += $qwen4exp
            Write-Host 'Adapted the feature qwen4exp implementation to the mainline per-layer expert-width API.'
        }
    }

    $changed = @($changed | Select-Object -Unique)
    if ($changed.Count -gt 0) {
        foreach ($path in $changed) { Invoke-Git add -- $path }
        Invoke-Git commit -m "integration: reconcile Qwen model API drift"
    }
}

function Repair-ValidatedServerMergeDrift {
    $patch = Join-Path $PSScriptRoot "patches/validated-server-merge-drift.patch"
    if (-not (Test-Path $patch)) { throw "Validated server merge-drift patch is missing: $patch" }

    & git apply --reverse --check $patch
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Validated server merge-drift patch already applied."
        return
    }

    Invoke-Git apply --check --whitespace=nowarn $patch
    Invoke-Git apply --whitespace=nowarn $patch
    Invoke-Git add -- common tools include src ggml/src/ggml-backend.cpp
    Invoke-Git commit -m "integration: repair server and MoE merge drift"
    Write-Host "Applied validated server, speculative, lazy-read, and MoE fit integration repairs."
}

function Repair-GraphInputTensorCounter {
    $contextCpp = "src/llama-context.cpp"
    if (-not (Test-Path $contextCpp)) { return }

    $text = Get-Content $contextCpp -Raw
    if ($text -notmatch 'llama_graph_n_input_tensors\(gf\)') { return }
    if ($text -match 'static int llama_graph_n_input_tensors\(') { return }

    $needle = "void llama_context::sched_reserve() {"
    if (-not $text.Contains($needle)) {
        throw "llama-context graph input counter has no stable insertion point"
    }
    $helper = @'
static int llama_graph_n_input_tensors(ggml_cgraph * gf) {
    std::unordered_map<const ggml_tensor *, std::vector<ggml_tensor *>> users;
    for (int i = 0; i < ggml_graph_n_nodes(gf); ++i) {
        ggml_tensor * node = ggml_graph_node(gf, i);
        if (node->flags & GGML_TENSOR_FLAG_INPUT) {
            users[node].push_back(node);
        }
        for (int j = 0; j < GGML_MAX_SRC; ++j) {
            ggml_tensor * src = node->src[j];
            if (src && (src->flags & GGML_TENSOR_FLAG_INPUT)) {
                users[src].push_back(node);
            }
        }
    }
    return (int) users.size();
}

'@
    Set-Content -Path $contextCpp -Value $text.Replace($needle, $helper + $needle) -Encoding UTF8
    Invoke-Git add -- $contextCpp
    Invoke-Git commit -m "integration: restore graph input counter helper"
    Write-Host "Restored the graph input tensor counter required by the merged context diagnostics."
}

function Repair-CudaFattnSharedMemory {
    $fattnVec = "ggml/src/ggml-cuda/fattn-vec.cuh"
    if (-not (Test-Path $fattnVec)) { return }

    $text = Get-Content $fattnVec -Raw
    $old = 'V_is_turbo ? (nthreads_V_q / 8 < 1 ? 1 : nthreads_V_q / 8) : 128 / cpy_nb'
    if (-not $text.Contains($old)) { return }

    # At D=512 the /8 Turbo-V setting makes ne_combine exceed CUDA's 48 KiB
    # static shared-memory limit.  /4 halves V columns per iteration, preserving
    # the existing indexing/reduction scheme while keeping this instantiation in
    # bounds; retain /8 for the smaller head dimensions it was tuned for.
    $new = 'V_is_turbo ? (D >= 512 ? (nthreads_V_q / 4 < 1 ? 1 : nthreads_V_q / 4) : (nthreads_V_q / 8 < 1 ? 1 : nthreads_V_q / 8)) : 128 / cpy_nb'
    Set-Content -Path $fattnVec -Value $text.Replace($old, $new) -Encoding UTF8
    Invoke-Git add -- $fattnVec
    Invoke-Git commit -m "integration: bound Turbo-V flash attention shared memory"
    Write-Host 'Adjusted D=512 Turbo-V flash-attention thread grouping to fit CUDA static shared memory.'
}

function Repair-VulkanFlashAttentionTypeConstants {
    # flash_attn_cm1.comp includes flash_attn_base.glsl, where current mainline
    # moved the stale host enum references. Repair both sources and verify that
    # no generated shader can retain GGML_TYPE_F16.
    $shaders = @(
        "ggml/src/ggml-vulkan/vulkan-shaders/flash_attn_base.glsl",
        "ggml/src/ggml-vulkan/vulkan-shaders/flash_attn_cm1.comp"
    )
    $changed = @()
    $legacyCount = 0
    foreach ($shader in $shaders) {
        if (-not (Test-Path $shader)) { continue }
        $text = Get-Content $shader -Raw
        $count = [regex]::Matches($text, '\bGGML_TYPE_F16\b').Count
        $legacyCount += $count
        if ($count -gt 0) {
            Set-Content -Path $shader -Value $text.Replace('GGML_TYPE_F16', 'FA_TYPE_F16') -Encoding UTF8
            $changed += $shader
        }
    }
    if ($legacyCount -eq 0) { return }
    if ($legacyCount -gt 7) {
        throw "Unexpected GGML_TYPE_F16 usage count in Vulkan flash-attention sources: $legacyCount"
    }
    foreach ($shader in $shaders) {
        if ((Test-Path $shader) -and ((Get-Content $shader -Raw) -match '\bGGML_TYPE_F16\b')) {
            throw "Vulkan flash-attention type-constant repair invariant failed: $shader"
        }
    }
    foreach ($shader in $changed) { Invoke-Git add -- $shader }
    Invoke-Git commit -m "integration: use Vulkan flash-attention type constants"
    Write-Host "Replaced $legacyCount stale host enum reference(s) with shader-local FA_TYPE_F16 constants."
}

if (Test-Path $Destination) {
    Remove-Item -Recurse -Force $Destination
}

Invoke-Git clone --no-checkout $Repository $Destination
Push-Location $Destination
try {
    Invoke-Git fetch origin "+${PullRequestRef}:refs/remotes/origin/integration-kv-stream"
    Invoke-Git checkout --detach refs/remotes/origin/integration-kv-stream

    $featureSha = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git rev-parse HEAD failed" }
    $mainlineSha = "not-merged"

    if (-not $SkipMainlineMerge) {
        $remotes = @(& git remote)
        if ($LASTEXITCODE -ne 0) { throw "git remote failed" }
        if ($remotes -notcontains "mainline") {
            Invoke-Git remote add mainline $MainlineRepository
        }

        Invoke-Git fetch mainline $MainlineRef
        $mainlineSha = (& git rev-parse FETCH_HEAD).Trim()
        if ($LASTEXITCODE -ne 0) { throw "git rev-parse FETCH_HEAD failed" }

        Invoke-Git config user.name "llama-turbo-kvsteaming CI"
        Invoke-Git config user.email "actions@users.noreply.github.com"

        & git merge --no-ff --no-edit -X ours FETCH_HEAD
        $mergeExit = $LASTEXITCODE
        if ($mergeExit -ne 0) {
            Resolve-KnownMergeConflicts
        }
        Assert-CleanIntegration

        $toolsCmake = "tools/CMakeLists.txt"
        if ((Test-Path $toolsCmake) -and -not (Test-Path "tools/parser")) {
            $toolsText = Get-Content $toolsCmake -Raw
            $repaired = $toolsText -replace '(?m)^\s*add_subdirectory\(parser\)\s*\r?\n', ''
            if ($repaired -ne $toolsText) {
                Set-Content -Path $toolsCmake -Value $repaired -Encoding UTF8
                Invoke-Git add $toolsCmake
                Invoke-Git commit -m "integration: drop stale tools/parser reference after mainline merge"
                Write-Host "Applied semantic repair: removed stale tools/parser reference."
            }
        }

        $mainlineUiPaths = @(
            "tools/ui",
            "scripts/ui-assets.cmake"
        )
        foreach ($uiPath in $mainlineUiPaths) {
            Invoke-Git checkout $mainlineSha -- $uiPath
        }
        & git diff --cached --quiet
        $cachedDiffExit = $LASTEXITCODE
        if ($cachedDiffExit -eq 1) {
            Invoke-Git commit -m "integration: align UI asset pipeline with mainline"
            Write-Host "Applied semantic repair: aligned the complete UI asset pipeline with mainline."
        }
        elseif ($cachedDiffExit -ne 0) {
            throw "git diff --cached --quiet failed with exit code $cachedDiffExit"
        }

        Repair-FattnMergeDrift -FeatureSha $featureSha
        Repair-ModelHeaderMergeDrift
        Repair-MissingMainlineModelDeclarations -MainlineSha $mainlineSha
        Repair-ModelApiMergeDrift -MainlineSha $mainlineSha -FeatureSha $featureSha
        Repair-Eagle3MergeDrift -FeatureSha $featureSha
        Repair-ValidatedMainlineMergeDrift
        Repair-DsaIswaMergeDrift -MainlineSha $mainlineSha
        Repair-DflashMergeDrift
        Repair-CommonLazyApiDrift
        Repair-ValidatedServerMergeDrift
        Repair-GraphInputTensorCounter
        Repair-MmvqMergeDrift -FeatureSha $featureSha
        Repair-CublasHandleApiDrift
        Repair-CudaFattnSharedMemory
        Repair-VulkanFlashAttentionTypeConstants
        Repair-UnorderedMapInclude
        Assert-NoDuplicateModelEntryPoints
        Assert-CleanIntegration
    }

    Invoke-Git submodule update --init --recursive --depth 1

    $resolvedSha = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git rev-parse HEAD failed" }
    $resolvedCommit = (& git log -1 --format="%H %ci %s").Trim()
    if ($LASTEXITCODE -ne 0) { throw "git log failed" }

    @"
feature_source=$Repository
feature_ref=$PullRequestRef
feature_sha=$featureSha
mainline_source=$MainlineRepository
mainline_ref=$MainlineRef
mainline_sha=$mainlineSha
merge_strategy=recursive_feature_first_conflicts_with_reviewed_modify_delete_resolutions
resolved_sha=$resolvedSha
resolved_commit=$resolvedCommit
"@ | Set-Content -Path ".integration-provenance" -Encoding UTF8

    Write-Host "Feature source SHA: $featureSha"
    Write-Host "Mainline SHA: $mainlineSha"
    Write-Host "Resolved integration SHA: $resolvedSha"

    if ($env:GITHUB_ENV) {
        "FEATURE_SHA=$featureSha" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
        "MAINLINE_SHA=$mainlineSha" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
        "SOURCE_SHA=$resolvedSha" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    }
}
finally {
    Pop-Location
}
