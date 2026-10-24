[CmdletBinding()]
param(
    [string]$Dotnet = 'dotnet',
    [string]$MsysRoot = (Join-Path $env:LOCALAPPDATA 'MPVKit\msys64'),
    [switch]$SkipNative,
    [switch]$InstallDependencies,
    [switch]$SelfContained
)
$ErrorActionPreference = 'Stop'
$mpvkitRoot = Split-Path $PSScriptRoot -Parent
$mpvkitExclude = & git -C $mpvkitRoot rev-parse --path-format=absolute --git-path info/exclude 2>$null
if ($LASTEXITCODE -eq 0) {
    $mpvkitPatterns = @(Get-Content -LiteralPath $mpvkitExclude -ErrorAction SilentlyContinue)
    foreach ($mpvkitPattern in @('/.local/', '/Windows/**/bin/', '/Windows/**/obj/')) {
        if ($mpvkitPattern -notin $mpvkitPatterns) { Add-Content -LiteralPath $mpvkitExclude -Value $mpvkitPattern }
    }
}
if (!$SkipNative) { & (Join-Path $PSScriptRoot 'Build-Runtime.ps1') -MsysRoot $MsysRoot -InstallDependencies:$InstallDependencies }
$mpvkitDemo = Join-Path $PSScriptRoot 'MPVKit.Demo\MPVKit.Demo.csproj'
$mpvkitRuntime = Join-Path $mpvkitRoot 'dist\windows-x64'
$mpvkitOutput = Join-Path $mpvkitRoot 'dist\windows-demo'
& $Dotnet publish $mpvkitDemo -c Release -r win-x64 --self-contained $SelfContained.IsPresent.ToString().ToLowerInvariant() "-p:MpvKitRuntimeDirectory=$mpvkitRuntime" -o $mpvkitOutput --nologo
if ($LASTEXITCODE) { throw 'Windows demo publish failed.' }
& $Dotnet pack (Join-Path $PSScriptRoot 'MPVKit.Windows\MPVKit.Windows.csproj') -c Release -o (Join-Path $mpvkitRoot 'dist\windows-packages') --nologo
if ($LASTEXITCODE) { throw 'Windows library package failed.' }
Write-Output "Windows demo: $mpvkitOutput"
