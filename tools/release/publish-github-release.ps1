param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Runtime = "win-x64",
    [string]$Configuration = "Release",
    [string]$RepoUrl = "https://github.com/iamniketas/contora",
    [string]$PackId = "Contora",
    [string]$MainExe = "Contora.exe",
    [string]$PackTitle = "Contora",
    [string]$PackAuthors = "iamniketas",
    [string]$ReleaseNotesPath = "",
    [string]$Tag = "",
    [string]$ReleaseName = "",
    [string]$Channel = "win",
    [string]$OutputRoot = "artifacts",
    [switch]$NoDownloadExisting,
    [switch]$NoUpload,
    [switch]$PreRelease,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-VpkInvoker {
    param([string]$VelopackVersion)

    $globalVpk = Get-Command vpk -ErrorAction SilentlyContinue
    if ($globalVpk) {
        return @{ Prefix = @("vpk") }
    }

    $dnx = Get-Command dnx -ErrorAction SilentlyContinue
    if ($dnx) {
        return @{ Prefix = @("dnx", "vpk", "--version", $VelopackVersion) }
    }

    throw "Could not find 'vpk' or 'dnx'. Install vpk: dotnet tool install -g vpk --version $VelopackVersion"
}

function Resolve-GitHubToken {
    if (-not [string]::IsNullOrWhiteSpace($env:VPK_TOKEN)) {
        return $env:VPK_TOKEN
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        return $env:GITHUB_TOKEN
    }

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        try {
            $token = (& gh auth token 2>$null).Trim()
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                return $token
            }
        }
        catch {
            # ignore
        }
    }

    return ""
}

function Resolve-IsccPath {
    $iscc = Get-Command iscc -ErrorAction SilentlyContinue
    if ($iscc) {
        return $iscc.Source
    }

    $candidates = @(
        "C:\Users\$env:USERNAME\AppData\Local\Programs\Inno Setup 6\ISCC.exe",
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "ISCC.exe not found. Install Inno Setup 6."
}

function Invoke-External {
    param(
        [string[]]$Command,
        [switch]$Dry
    )

    $display = ($Command | ForEach-Object {
        if ($_ -match "\s") { '"' + $_ + '"' } else { $_ }
    }) -join " "

    Write-Host "`n> $display" -ForegroundColor Cyan

    if ($Dry) {
        return
    }

    & $Command[0] $Command[1..($Command.Length - 1)]
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $display"
    }
}

function Build-ClassicInstaller {
    param(
        [string]$ProjectRoot,
        [string]$PublishDir,
        [string]$ReleaseDir,
        [string]$Version
    )

    $isccPath = Resolve-IsccPath
    $issPath = Join-Path $ReleaseDir "contora-installer.iss"
    $issPathEsc = $issPath.Replace('\', '\\')
    $publishEsc = $PublishDir.Replace('\', '\\')
    $releaseEsc = $ReleaseDir.Replace('\', '\\')

    $iss = @"
[Setup]
AppId={{7BC8DB04-8A03-4E8F-AF4E-1D3E4FC2B8A1}
AppName=Contora
AppVersion=$Version
AppPublisher=iamniketas
DefaultDirName={autopf}\Contora
DefaultGroupName=Contora
DisableDirPage=no
DisableProgramGroupPage=yes
OutputDir=$releaseEsc
OutputBaseFilename=Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\Contora.exe

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "$publishEsc\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Contora"; Filename: "{app}\Contora.exe"
Name: "{autodesktop}\Contora"; Filename: "{app}\Contora.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Contora.exe"; Description: "Launch Contora"; Flags: nowait postinstall skipifsilent
"@

    Set-Content -Path $issPath -Value $iss -Encoding utf8
    Invoke-External -Command @($isccPath, "/Qp", $issPath)
}

function Sync-ClassicInstallerAsset {
    param(
        [string]$Tag,
        [string]$ReleaseDir,
        [string]$RepoUrl
    )

    $setupPath = Join-Path $ReleaseDir "Setup.exe"
    if (-not (Test-Path $setupPath)) {
        throw "Classic installer was not created: $setupPath"
    }

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Warning "gh CLI is not installed; skipping Setup.exe release asset sync."
        return
    }

    $repo = $RepoUrl
    if ($repo -match '^https://github\.com/') {
        $repo = $repo -replace '^https://github\.com/', ''
        $repo = $repo.TrimEnd('/')
    }

    try {
        & gh release upload $Tag $setupPath --repo $repo --clobber | Out-Null
    }
    catch {
        throw "Failed to upload Setup.exe via gh CLI: $($_.Exception.Message)"
    }

    try {
        & gh release delete-asset $Tag "Contora-win-Setup.exe" --repo $repo --yes | Out-Null
    }
    catch {
        Write-Warning "Could not delete Contora-win-Setup.exe from release $Tag. Please remove it manually."
    }
}

function Get-VelopackVersion {
    param([string]$CsprojPath)

    [xml]$proj = Get-Content $CsprojPath
    $node = $proj.SelectSingleNode("//PackageReference[@Include='Velopack']")

    if (-not $node) {
        throw "PackageReference Include=`"Velopack`" was not found in $CsprojPath"
    }

    $versionAttr = $node.Attributes["Version"]
    $version = if ($versionAttr) { $versionAttr.Value } else { "" }
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "PackageReference Velopack is missing Version in $CsprojPath"
    }

    return $version
}

if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "Version must be semver, for example 0.2.3"
}

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$appCsproj = Join-Path $projectRoot "src\AudioRecorder.App\AudioRecorder.csproj"
if (-not (Test-Path $appCsproj)) {
    throw "App project not found: $appCsproj"
}

$resolvedOutputRoot = Join-Path $projectRoot $OutputRoot
$publishDir = Join-Path $resolvedOutputRoot "publish\$Version\$Runtime"
$releaseDir = Join-Path $resolvedOutputRoot "releases\$Version"

$releaseTag = if ([string]::IsNullOrWhiteSpace($Tag)) { "v$Version" } else { $Tag }
$releaseTitle = if ([string]::IsNullOrWhiteSpace($ReleaseName)) { "Contora $Version" } else { $ReleaseName }

$velopackVersion = Get-VelopackVersion -CsprojPath $appCsproj
$vpk = Resolve-VpkInvoker -VelopackVersion $velopackVersion

Write-Host "Project root: $projectRoot"
Write-Host "Publish dir:  $publishDir"
Write-Host "Release dir:  $releaseDir"
Write-Host "vpk source:   $($vpk.Prefix -join ' ')"

if (-not (Test-Path $publishDir)) {
    New-Item -ItemType Directory -Force -Path $publishDir | Out-Null
}
if (-not (Test-Path $releaseDir)) {
    New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
}

Invoke-External -Command @(
    "dotnet", "publish", $appCsproj,
    "-c", $Configuration,
    "-r", $Runtime,
    "-p:WindowsPackageType=None",
    "-p:WindowsAppSDKSelfContained=true",
    "-p:PublishTrimmed=false",
    "-o", $publishDir
) -Dry:$DryRun

if (-not $NoDownloadExisting) {
    $downloadArgs = @(
        "download", "github",
        "--repoUrl", $RepoUrl,
        "--channel", $Channel,
        "--outputDir", $releaseDir
    )

    $token = Resolve-GitHubToken
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $downloadArgs += @("--token", $token)
    }

    Invoke-External -Command ($vpk.Prefix + $downloadArgs) -Dry:$DryRun
}

$packArgs = @(
    "pack",
    "--packId", $PackId,
    "--packVersion", $Version,
    "--packDir", $publishDir,
    "--mainExe", $MainExe,
    "--channel", $Channel,
    "--outputDir", $releaseDir,
    "--packTitle", $PackTitle,
    "--packAuthors", $PackAuthors
)

if (-not [string]::IsNullOrWhiteSpace($ReleaseNotesPath)) {
    $resolvedNotes = Join-Path $projectRoot $ReleaseNotesPath
    if (-not (Test-Path $resolvedNotes)) {
        throw "Release notes file not found: $resolvedNotes"
    }

    $packArgs += @("--releaseNotes", $resolvedNotes)
}

Invoke-External -Command ($vpk.Prefix + $packArgs) -Dry:$DryRun

if (-not $DryRun) {
    Build-ClassicInstaller -ProjectRoot $projectRoot -PublishDir $publishDir -ReleaseDir $releaseDir -Version $Version
}

if (-not $NoUpload) {
    $token = Resolve-GitHubToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Upload requires a token. Set VPK_TOKEN or GITHUB_TOKEN."
    }

    $uploadArgs = @(
        "upload", "github",
        "--repoUrl", $RepoUrl,
        "--channel", $Channel,
        "--outputDir", $releaseDir,
        "--token", $token,
        "--publish",
        "--tag", $releaseTag,
        "--releaseName", $releaseTitle,
        "--merge"
    )

    if ($PreRelease) {
        $uploadArgs += "--pre"
    }

    Invoke-External -Command ($vpk.Prefix + $uploadArgs) -Dry:$DryRun

    if (-not $DryRun) {
        Sync-ClassicInstallerAsset -Tag $releaseTag -ReleaseDir $releaseDir -RepoUrl $RepoUrl
    }
}

Write-Host "`nDone. Artifacts: $releaseDir" -ForegroundColor Green
