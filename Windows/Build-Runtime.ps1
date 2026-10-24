[CmdletBinding()]
param(
    [string]$MsysRoot = (Join-Path $env:LOCALAPPDATA 'MPVKit\msys64'),
    [ValidateRange(1, 64)][int]$Jobs = 12,
    [switch]$InstallDependencies
)
$ErrorActionPreference = 'Stop'
$mpvkitRoot = Split-Path $PSScriptRoot -Parent
$mpvkitLock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'native-lock.json') -Raw | ConvertFrom-Json
$mpvkitBash = Join-Path $MsysRoot 'usr\bin\bash.exe'
if (!(Test-Path -LiteralPath $mpvkitBash)) { throw 'Install an isolated MSYS2 distribution and supply -MsysRoot. See the Windows section in README.md.' }
if ($MsysRoot.Contains(' ')) { throw 'The MSYS2 root must not contain spaces.' }
New-Item -ItemType Directory -Path (Join-Path $mpvkitRoot '.local\upstream') -Force | Out-Null
foreach ($mpvkitLibrary in @('mpv', 'ffmpeg')) {
    $mpvkitPin = $mpvkitLock.$mpvkitLibrary
    $mpvkitSource = Join-Path $mpvkitRoot ".local\upstream\$mpvkitLibrary"
    if (!(Test-Path -LiteralPath (Join-Path $mpvkitSource '.git'))) {
        & git clone --depth 1 --branch $mpvkitPin.tag $mpvkitPin.repository $mpvkitSource
        if ($LASTEXITCODE) { throw "Cannot clone $mpvkitLibrary." }
    }
    $mpvkitHead = & git -C $mpvkitSource rev-parse HEAD
    if ($LASTEXITCODE -or $mpvkitHead -ne $mpvkitPin.commit) { throw "$mpvkitLibrary does not match native-lock.json." }
    $mpvkitChanges = & git -C $mpvkitSource diff --name-only HEAD
    if ($mpvkitChanges) { throw "Preserving modified native source: $mpvkitLibrary." }
}
$mpvkitOldSystem = $env:MSYSTEM
$mpvkitOldInvoking = $env:CHERE_INVOKING
try {
    $env:MSYSTEM = 'UCRT64'
    $env:CHERE_INVOKING = '1'
    if ($InstallDependencies) {
        & $mpvkitBash -lc 'pacman -S --needed --noconfirm make mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-meson mingw-w64-ucrt-x86_64-ninja mingw-w64-ucrt-x86_64-pkgconf mingw-w64-ucrt-x86_64-nasm mingw-w64-ucrt-x86_64-libplacebo mingw-w64-ucrt-x86_64-libass mingw-w64-ucrt-x86_64-shaderc mingw-w64-ucrt-x86_64-spirv-cross mingw-w64-ucrt-x86_64-lcms2 mingw-w64-ucrt-x86_64-uchardet mingw-w64-ucrt-x86_64-libarchive mingw-w64-ucrt-x86_64-libbluray mingw-w64-ucrt-x86_64-vulkan-headers mingw-w64-ucrt-x86_64-luajit mingw-w64-ucrt-x86_64-dav1d mingw-w64-ucrt-x86_64-libxml2 mingw-w64-ucrt-x86_64-zlib'
        if ($LASTEXITCODE) { throw 'MSYS2 dependency installation failed. Update the isolated distribution first.' }
    }
    & $mpvkitBash -l (Join-Path $PSScriptRoot 'build-native.sh') $mpvkitRoot $Jobs $mpvkitLock.ffmpeg.commit
    if ($LASTEXITCODE) { throw 'Native build failed.' }
} finally {
    $env:MSYSTEM = $mpvkitOldSystem
    $env:CHERE_INVOKING = $mpvkitOldInvoking
}
$mpvkitOutput = Join-Path $mpvkitRoot 'dist\windows-x64'
New-Item -ItemType Directory -Path $mpvkitOutput -Force | Out-Null
$mpvkitScanner = Join-Path $MsysRoot 'ucrt64\bin\objdump.exe'
$mpvkitSearch = @((Join-Path $mpvkitRoot '.local\native-build'), (Join-Path $mpvkitRoot '.local\ffmpeg-prefix\bin'), (Join-Path $MsysRoot 'ucrt64\bin'))
$mpvkitPending = [Collections.Generic.Queue[string]]::new()
$mpvkitPending.Enqueue('libmpv-2.dll')
$mpvkitPending.Enqueue('mpvkit-windows.dll')
$mpvkitSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$mpvkitFiles = [Collections.Generic.List[object]]::new()
while ($mpvkitPending.Count) {
    $mpvkitName = $mpvkitPending.Dequeue()
    if (!$mpvkitSeen.Add($mpvkitName)) { continue }
    $mpvkitFile = $null
    foreach ($mpvkitDirectory in $mpvkitSearch) {
        $mpvkitCandidate = Join-Path $mpvkitDirectory $mpvkitName
        if (Test-Path -LiteralPath $mpvkitCandidate) { $mpvkitFile = $mpvkitCandidate; break }
    }
    if (!$mpvkitFile) {
        if ($mpvkitName -match '^(api-ms-|ext-ms-)' -or (Test-Path -LiteralPath (Join-Path "$env:SystemRoot\System32" $mpvkitName))) { continue }
        throw "Missing native dependency: $mpvkitName"
    }
    Copy-Item -LiteralPath $mpvkitFile -Destination (Join-Path $mpvkitOutput $mpvkitName) -Force
    $mpvkitFiles.Add([ordered]@{ name = $mpvkitName; sha256 = (Get-FileHash -LiteralPath $mpvkitFile -Algorithm SHA256).Hash; bytes = (Get-Item -LiteralPath $mpvkitFile).Length })
    $mpvkitImports = & $mpvkitScanner -p $mpvkitFile
    if ($LASTEXITCODE) { throw "Cannot inspect $mpvkitName." }
    foreach ($mpvkitImport in $mpvkitImports) {
        if ($mpvkitImport -match 'DLL Name:\s+(\S+)') { $mpvkitPending.Enqueue($Matches[1]) }
    }
}
foreach ($mpvkitOldFile in (Get-ChildItem -LiteralPath $mpvkitOutput -Filter '*.dll' -File)) {
    if (!$mpvkitFiles.Exists([Predicate[object]]{ param($mpvkitEntry) $mpvkitEntry.name -eq $mpvkitOldFile.Name })) {
        Remove-Item -LiteralPath $mpvkitOldFile.FullName -Force
    }
}
$mpvkitLicenseRoot = Join-Path $mpvkitOutput 'licenses'
if (Test-Path -LiteralPath $mpvkitLicenseRoot) {
    $mpvkitResolvedLicenses = (Resolve-Path -LiteralPath $mpvkitLicenseRoot).Path
    if ((Split-Path $mpvkitResolvedLicenses -Parent) -ne (Resolve-Path -LiteralPath $mpvkitOutput).Path -or (Split-Path $mpvkitResolvedLicenses -Leaf) -ne 'licenses') { throw 'The generated notices directory resolved outside the runtime output.' }
    Remove-Item -LiteralPath $mpvkitResolvedLicenses -Recurse -Force
}
New-Item -ItemType Directory -Path $mpvkitLicenseRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $mpvkitRoot '.local\upstream\mpv\Copyright') -Destination (Join-Path $mpvkitLicenseRoot 'mpv-Copyright.txt') -Force
Copy-Item -LiteralPath (Join-Path $mpvkitRoot '.local\upstream\mpv\LICENSE.LGPL') -Destination (Join-Path $mpvkitLicenseRoot 'mpv-LGPL.txt') -Force
Get-ChildItem -LiteralPath (Join-Path $mpvkitRoot '.local\upstream\ffmpeg') -Filter 'COPYING*' -File | Copy-Item -Destination $mpvkitLicenseRoot -Force
$mpvkitPackageLicenses = Join-Path $MsysRoot 'ucrt64\share\licenses'
if (Test-Path -LiteralPath $mpvkitPackageLicenses) { Copy-Item -LiteralPath $mpvkitPackageLicenses -Destination (Join-Path $mpvkitLicenseRoot 'dependencies') -Recurse -Force }
$mpvkitManifest = [ordered]@{
    schemaVersion = 1
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    platform = 'win-x64'
    runtimeLicense = $mpvkitLock.runtimeLicense
    sources = $mpvkitLock
    packages = @(Get-Content -LiteralPath (Join-Path $mpvkitRoot '.local\native-packages.txt'))
    files = @($mpvkitFiles.ToArray())
}
$mpvkitManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $mpvkitOutput 'runtime-manifest.json') -Encoding utf8
Write-Output "Built $($mpvkitFiles.Count) native DLLs in $mpvkitOutput"
