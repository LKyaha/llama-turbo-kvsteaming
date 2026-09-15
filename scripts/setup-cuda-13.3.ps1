param(
    [string]$Release = "13.3.1",
    [string]$ToolkitVersion = "13.3"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$baseUrl = "https://developer.download.nvidia.com/compute/cuda/redist"
$manifestUrl = "$baseUrl/redistrib_$Release.json"
$toolkitRoot = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v$ToolkitVersion"
$tempRoot = Join-Path $env:RUNNER_TEMP "cuda-$Release-redist"

$components = @(
    "cccl",
    "cuda_crt",
    "cuda_cudart",
    "cuda_nvcc",
    "cuda_nvrtc",
    "libcublas",
    "libnvvm",
    "cuda_nvtx",
    "cuda_profiler_api",
    "visual_studio_integration"
)

Write-Host "Downloading NVIDIA CUDA redistributable manifest: $manifestUrl"
$manifest = Invoke-RestMethod -Uri $manifestUrl
if ($manifest.release_label -ne $Release) {
    throw "Unexpected CUDA manifest release_label '$($manifest.release_label)' (expected '$Release')"
}

Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tempRoot | Out-Null
New-Item -ItemType Directory -Force $toolkitRoot | Out-Null

foreach ($component in $components) {
    $componentProperty = $manifest.PSObject.Properties[$component]
    if ($null -eq $componentProperty) {
        throw "Component '$component' is missing from CUDA $Release manifest"
    }

    $entry = $componentProperty.Value
    $platformProperty = $entry.PSObject.Properties["windows-x86_64"]
    if ($null -eq $platformProperty) {
        throw "Component '$component' has no windows-x86_64 payload in CUDA $Release manifest"
    }

    $payload = $platformProperty.Value
    $relativePath = $payload.relative_path
    $expectedSha256 = $payload.sha256.ToLowerInvariant()
    $fileName = Split-Path $relativePath -Leaf
    $archivePath = Join-Path $tempRoot $fileName
    $extractPath = Join-Path $tempRoot ("extract-" + $component)
    $url = "$baseUrl/$relativePath"

    Write-Host "Downloading $component ($($entry.version))"
    & curl.exe -L --fail --retry 3 --retry-delay 2 -o $archivePath $url
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed for $component with exit code $LASTEXITCODE"
    }

    $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        throw "SHA256 mismatch for $component`: expected $expectedSha256, got $actualSha256"
    }

    New-Item -ItemType Directory -Force $extractPath | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force

    $topLevel = @(Get-ChildItem -LiteralPath $extractPath -Force)
    if ($topLevel.Count -eq 1 -and $topLevel[0].PSIsContainer) {
        $payloadRoot = $topLevel[0].FullName
    } else {
        $payloadRoot = $extractPath
    }

    Get-ChildItem -LiteralPath $payloadRoot -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $toolkitRoot -Recurse -Force
    }
}

$nvcc = Join-Path $toolkitRoot "bin\nvcc.exe"
if (-not (Test-Path -LiteralPath $nvcc)) {
    throw "nvcc.exe was not installed at $nvcc"
}

$env:CUDA_PATH = $toolkitRoot
$env:PATH = "$toolkitRoot\bin;$env:PATH"

"CUDA_PATH=$toolkitRoot" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
"CUDA_PATH_V13_3=$toolkitRoot" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
"$toolkitRoot\bin" | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8

Write-Host "Installed CUDA $Release into $toolkitRoot"
& $nvcc --version
if ($LASTEXITCODE -ne 0) {
    throw "nvcc --version failed with exit code $LASTEXITCODE"
}
