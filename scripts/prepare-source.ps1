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
        Repair-CublasHandleApiDrift
        Repair-UnorderedMapInclude
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
