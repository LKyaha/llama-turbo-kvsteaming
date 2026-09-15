param(
    [string]$Destination = "source",
    [string]$Repository = "https://github.com/TheTom/llama-cpp-turboquant.git",
    [string]$PullRequestRef = "refs/pull/357/head",
    [string]$MainlineRepository = "https://github.com/ggml-org/llama.cpp.git",
    [string]$MainlineRef = "master",
    [switch]$SkipMainlineMerge
)

$ErrorActionPreference = "Stop"

if (Test-Path $Destination) {
    Remove-Item -Recurse -Force $Destination
}

git clone --filter=blob:none --no-checkout $Repository $Destination
Push-Location $Destination
try {
    git fetch origin "+${PullRequestRef}:refs/remotes/origin/integration-kv-stream"
    git checkout --detach refs/remotes/origin/integration-kv-stream

    $featureSha = (git rev-parse HEAD).Trim()
    $mainlineSha = "not-merged"

    if (-not $SkipMainlineMerge) {
        if (-not (git remote | Select-String -SimpleMatch "mainline")) {
            git remote add mainline $MainlineRepository
        }
        git fetch mainline $MainlineRef
        $mainlineSha = (git rev-parse FETCH_HEAD).Trim()

        git config user.name "llama-turbo-kvsteaming CI"
        git config user.email "actions@users.noreply.github.com"

        # This is deliberately an ephemeral merge. Any textual conflict is a hard failure:
        # we do not publish binaries that silently drop either upstream's changes.
        git merge --no-ff --no-edit FETCH_HEAD

        # Semantic merge repair:
        # The Turbo/KV branch still references tools/parser, while current llama.cpp
        # mainline has removed that tool. Git can merge this cleanly because the directory
        # deletion and the CMake edit touch different paths, leaving a stale
        # add_subdirectory(parser) that breaks every backend during CMake configure.
        # Remove only that stale reference, and only when the directory is actually gone.
        $toolsCmake = "tools/CMakeLists.txt"
        if ((Test-Path $toolsCmake) -and -not (Test-Path "tools/parser")) {
            $toolsText = Get-Content $toolsCmake -Raw
            $repaired = $toolsText -replace '(?m)^\s*add_subdirectory\(parser\)\s*\r?\n', ''
            if ($repaired -ne $toolsText) {
                Set-Content -Path $toolsCmake -Value $repaired -Encoding UTF8
                git add $toolsCmake
                git commit -m "integration: drop stale tools/parser reference after mainline merge"
                Write-Host "Applied semantic merge repair: removed stale tools/parser reference."
            }
        }
    }

    git submodule update --init --recursive --depth 1

    $resolvedSha = (git rev-parse HEAD).Trim()
    $resolvedCommit = (git log -1 --format="%H %ci %s").Trim()

    @"
feature_source=$Repository
feature_ref=$PullRequestRef
feature_sha=$featureSha
mainline_source=$MainlineRepository
mainline_ref=$MainlineRef
mainline_sha=$mainlineSha
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
