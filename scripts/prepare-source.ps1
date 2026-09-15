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
