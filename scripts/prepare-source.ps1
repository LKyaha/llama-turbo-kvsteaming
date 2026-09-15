param(
    [string]$Destination = "source",
    [string]$Repository = "https://github.com/TheTom/llama-cpp-turboquant.git",
    [string]$PullRequestRef = "refs/pull/357/head"
)

$ErrorActionPreference = "Stop"

if (Test-Path $Destination) {
    Remove-Item -Recurse -Force $Destination
}

git clone --filter=blob:none --no-checkout $Repository $Destination
Push-Location $Destination
try {
    git fetch --depth 1 origin "+${PullRequestRef}:refs/remotes/origin/integration-kv-stream"
    git checkout --detach refs/remotes/origin/integration-kv-stream
    git submodule update --init --recursive --depth 1

    $sha = (git rev-parse HEAD).Trim()
    $describe = (git log -1 --format="%H%n%ci%n%s") -join "`n"

    Write-Host "Resolved integration source: $sha"
    Write-Host $describe

    "SOURCE_SHA=$sha" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8 -ErrorAction SilentlyContinue
}
finally {
    Pop-Location
}
