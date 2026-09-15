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

# Use a normal clone here instead of a promisor/partial clone. The integration
# deliberately merges histories from two related-but-independent repositories;
# partial-clone promisor lookups can otherwise emit scary "not our ref" errors
# when one side references objects the other remote cannot serve.
git clone --no-checkout $Repository $Destination
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

        # Ephemeral merge: textual conflicts are hard failures. We never silently
        # discard either the Turbo/KV feature branch or current llama.cpp mainline.
        git merge --no-ff --no-edit FETCH_HEAD

        # Semantic repair #1: current mainline deleted tools/parser, while the
        # Turbo/KV branch can leave a stale add_subdirectory(parser) behind.
        $toolsCmake = "tools/CMakeLists.txt"
        if ((Test-Path $toolsCmake) -and -not (Test-Path "tools/parser")) {
            $toolsText = Get-Content $toolsCmake -Raw
            $repaired = $toolsText -replace '(?m)^\s*add_subdirectory\(parser\)\s*\r?\n', ''
            if ($repaired -ne $toolsText) {
                Set-Content -Path $toolsCmake -Value $repaired -Encoding UTF8
                git add $toolsCmake
                git commit -m "integration: drop stale tools/parser reference after mainline merge"
                Write-Host "Applied semantic repair: removed stale tools/parser reference."
            }
        }

        # Semantic repair #2: PR #357 does not touch the UI at all, while current
        # mainline replaced the old llama-ui-embed host executable with a native
        # CMake asset generator. A clean Git merge can combine old/new halves and
        # leave missing files. Since UI is outside the feature delta, take the whole
        # UI build chain from the exact mainline SHA, not only CMakeLists.txt.
        $prChanges = @(
            "tools/ui",
            "scripts/ui-assets.cmake"
        )
        git checkout $mainlineSha -- $prChanges
        if (-not (git diff --cached --quiet)) {
            git commit -m "integration: align UI asset pipeline with mainline"
            Write-Host "Applied semantic repair: aligned the complete UI asset pipeline with mainline."
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
