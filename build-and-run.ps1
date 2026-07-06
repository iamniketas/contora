# Build and run Contora
# Usage:
#   .\build-and-run.ps1          # Debug build
#   .\build-and-run.ps1 Release  # Release build

param(
    [string]$Configuration = "Debug"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot

Write-Host "Building Contora ($Configuration)..." -ForegroundColor Cyan

# Build the solution (x64 — Whisper.net/sherpa-onnx native runtimes only ship x64 binaries)
dotnet build "$ProjectRoot\Contora.sln" --configuration $Configuration -p:Platform=x64

if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed!" -ForegroundColor Red
    exit 1
}

Write-Host "Build successful! Starting application..." -ForegroundColor Green

# Determine exe path based on configuration
$ExePath = "$ProjectRoot\src\AudioRecorder.App\bin\x64\$Configuration\net8.0-windows10.0.19041.0\win-x64\Contora.exe"

if (-not (Test-Path $ExePath)) {
    Write-Host "Executable not found at: $ExePath" -ForegroundColor Red
    exit 1
}

# Start the application
Start-Process $ExePath
