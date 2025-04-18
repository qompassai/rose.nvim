param (
    [string]$Version = "luajit",
    [string]$BuildFromSource = "false"
)

$Build = [System.Convert]::ToBoolean($BuildFromSource)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$BuildDir = "build"

function Build-FromSource($feature) {
    if (-not (Test-Path $BuildDir)) {
        New-Item -ItemType Directory -Path $BuildDir | Out-Null
    }

    cargo build --release --features=$feature

    $targetTokenizerFile = "rose_tokenizers.dll"
    $targetTemplatesFile = "rose_templates.dll"
    Copy-Item (Join-Path "target\release\rose_tokenizers.dll") (Join-Path $BuildDir $targetTokenizerFile)
    Copy-Item (Join-Path "target\release\rose_templates.dll") (Join-Path $BuildDir $targetTemplatesFile)

    Remove-Item -Recurse -Force "target"
}

function Download-Prebuilt($feature) {
    $REPO_OWNER = "qompassai"
    $REPO_NAME = "rose.nvim"

    $SCRIPT_DIR = $PSScriptRoot
    # Set the target directory to clone the artifact
    $TARGET_DIR = Join-Path $SCRIPT_DIR "build"

    # Set the platform to Windows
    $PLATFORM = "windows"
    $ARCH = "x86_64"
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
        $ARCH = "aarch64"
    }

    # Set the Lua version (lua51 or luajit)
    $LUA_VERSION = if ($feature) { $feature } else { "luajit" }

    # Set the artifact name pattern
    $ARTIFACT_NAME_PATTERN = "rose_lib-$PLATFORM-$ARCH-$LUA_VERSION"

    # Get the artifact download URL
    $LATEST_RELEASE = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    $ARTIFACT_URL = $LATEST_RELEASE.assets | Where-Object { $_.name -like "*$ARTIFACT_NAME_PATTERN*" } | Select-Object -ExpandProperty browser_download_url

    # Create target directory if it doesn't exist
    if (-not (Test-Path $TARGET_DIR)) {
        New-Item -ItemType Directory -Path $TARGET_DIR | Out-Null
    }

    # Download and extract the artifact
    $TempFile = Get-Item ([System.IO.Path]::GetTempFilename()) | Rename-Item -NewName { $_.Name + ".zip" } -PassThru
    Invoke-WebRequest -Uri $ARTIFACT_URL -OutFile $TempFile
    Expand-Archive -Path $TempFile -DestinationPath $TARGET_DIR -Force
    Remove-Item $TempFile
}

function Main {
    Set-Location $PSScriptRoot
    if ($Build) {
        Write-Host "Building for $Version..."
        Build-FromSource $Version
    } else {
        Write-Host "Downloading for $Version..."
        Download-Prebuilt $Version
    }
    Write-Host "Completed!"
}

# Run the main function
Main
