# Wholesale POS — release build recipe
#
# Every distributable build (Windows or Android APK) must carry two
# compile-time defines, or licensing silently degrades:
#   * WHOLESALE_POS_LICENSE_PUBLIC_KEY  — verifies signed licenses offline.
#     Without it the app fails closed and nobody can activate.
#   * WHOLESALE_POS_LICENSE_FN_URL      — the licensing Edge Function.
#     Without it the paste-a-code activation screen cannot reach the
#     server and buyers cannot self-activate or manage seats.
#
# Keeping them in ONE script means a release can never ship with a missing
# flag. Run from anywhere; the script cd's into the app folder itself.
#
# Usage:
#   powershell -File tools\build_release.ps1 windows
#   powershell -File tools\build_release.ps1 apk
#   powershell -File tools\build_release.ps1 web
#
# Add the -DevUnlicensed switch ONLY to a throwaway preview build you never
# hand to a customer (bypasses license checks entirely).

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('windows', 'apk', 'web')]
    [string]$Platform,

    [switch]$DevUnlicensed
)

$ErrorActionPreference = 'Stop'

# Shop constants — public values, safe to keep in the repo.
$LicensePublicKey = 'bc56555ab7cdad93ad73b1d3bb18725b4e5f739c283d7690213a75ef7b78be5e'
$LicenseFnUrl     = 'https://trcthxyyuapwavzeisvm.supabase.co/functions/v1/licensing'

# The browser/PWA build talks only to the pos-api Edge Function (no device
# license, no SQLite). It lives on the SAME Supabase host as the licensing
# function, so derive its URL rather than duplicate the project reference.
$PosApiUrl = $LicenseFnUrl -replace '/licensing$', '/pos-api'

# Always build from the app/ folder (where pubspec.yaml lives), regardless
# of the caller's current directory.
$AppDir = Split-Path -Parent $PSScriptRoot
Set-Location $AppDir

$defines = @(
    "--dart-define=WHOLESALE_POS_LICENSE_PUBLIC_KEY=$LicensePublicKey",
    "--dart-define=WHOLESALE_POS_LICENSE_FN_URL=$LicenseFnUrl",
    "--dart-define=WHOLESALE_POS_API_URL=$PosApiUrl"
)
if ($DevUnlicensed) {
    Write-Warning 'DevUnlicensed is ON — this build bypasses license checks. NEVER distribute it.'
    $defines += '--dart-define=WHOLESALE_POS_DEV_UNLICENSED=true'
}

if ($Platform -eq 'windows') {
    flutter build windows --release @defines
    $out = Join-Path $AppDir 'build\windows\x64\runner\Release'
    $lic = Join-Path $AppDir 'license.key'
    if (Test-Path $lic) {
        Copy-Item $lic $out -Force
        Write-Host "Copied license.key into $out (developer's own PC path)."
    }
    Write-Host "Windows release output: $out"
} elseif ($Platform -eq 'apk') {
    flutter build apk --release @defines
    $apk = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-release.apk'
    Write-Host "APK output: $apk"
} else {
    # Web/PWA: separate dart:io-free entry (main_web.dart) wired to CloudBackend.
    flutter build web --release -t lib/main_web.dart @defines
    $out = Join-Path $AppDir 'build\web'
    Write-Host "Web (PWA) output: $out"
}
