# Builds the Microsoft Store package (.msix) of the Windows app from a built RookieLedgerSync.exe.
#
#   pwsh companion/store/package.ps1 -Tag v0.7.0 -Exe companion/dist/RookieLedgerSync.exe -Out RookieLedgerSync.msix
#
# The package is not signed: the Store signs what it publishes, and Windows installs no unsigned package, so the
# file is only good for uploading to Partner Center. It needs MakeAppx.exe, which comes with the Windows SDK.
param(
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Out
)
$ErrorActionPreference = 'Stop'

# The Store refuses a version whose first number is 0 and keeps the fourth for itself: v0.7.0 is 1.7.0.0 there,
# v1.0.0 will be 2.0.0.0. A suffix (-beta1) is dropped.
if ($Tag -notmatch '^v(\d+)\.(\d+)\.(\d+)') { throw "'$Tag' is not a version tag such as v0.7.0" }
$version = '{0}.{1}.{2}.0' -f ([int]$Matches[1] + 1), [int]$Matches[2], [int]$Matches[3]

$stage = Join-Path ([IO.Path]::GetTempPath()) ("rookieledger-msix-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    Copy-Item $Exe (Join-Path $stage 'RookieLedgerSync.exe')
    Copy-Item (Join-Path $PSScriptRoot 'Assets') $stage -Recurse
    $manifest = Get-Content (Join-Path $PSScriptRoot 'AppxManifest.xml') -Raw
    if (-not $manifest.Contains('Version="0.0.0.0"')) { throw 'AppxManifest.xml has no Version="0.0.0.0" to replace' }
    $manifest = $manifest.Replace('Version="0.0.0.0"', "Version=`"$version`"")
    [IO.File]::WriteAllText((Join-Path $stage 'AppxManifest.xml'), $manifest, [Text.UTF8Encoding]::new($false))

    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $makeappx = Get-ChildItem (Join-Path $kits '*\x64\makeappx.exe') -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } | Select-Object -Last 1
    if (-not $makeappx) { throw "MakeAppx.exe not found under $kits: install the Windows SDK" }
    # /l: the manifest names two languages and the package holds no resources per language.
    & $makeappx.FullName pack /o /l /d $stage /p $Out
    if ($LASTEXITCODE -ne 0) { throw "MakeAppx failed with code $LASTEXITCODE" }
    Write-Host "$Out holds version $version"
}
finally {
    Remove-Item $stage -Recurse -Force
}
