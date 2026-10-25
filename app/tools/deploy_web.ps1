# Wholesale POS - web/PWA deploy to Vercel.
#
# WHY THIS EXISTS
#   `vercel deploy --prod` publishes a NEW immutable deployment and moves the
#   project's built-in production domain, but it does NOT move a hand-created
#   alias such as web-xi-seven-15.vercel.app. That alias stays pinned to the
#   deployment it was first assigned; once Vercel ages that deployment out the
#   domain starts returning 404 - which is exactly the recurring breakage we
#   kept hitting. This script re-points the stable domain at the freshly built
#   deployment every run, so the public link can never drift to a dead build.
#
# Usage:
#   powershell -File tools\deploy_web.ps1            # build web + deploy + pin alias
#   powershell -File tools\deploy_web.ps1 -SkipBuild # redeploy current build/web
#   powershell -File tools\deploy_web.ps1 -Domain web-marik3.vercel.app

param(
    [switch]$SkipBuild,

    # The stable public domain to keep pointed at the latest build.
    [string]$Domain = 'web-xi-seven-15.vercel.app'
)

$ErrorActionPreference = 'Stop'

$AppDir = Split-Path -Parent $PSScriptRoot
Set-Location $AppDir

# 1. Build (unless reusing an existing build/web).
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build_release.ps1') web
}

$WebDir = Join-Path $AppDir 'build\web'
if (-not (Test-Path (Join-Path $WebDir 'index.html'))) {
    throw "build\web\index.html not found - run without -SkipBuild first."
}
Set-Location $WebDir

# 2. Deploy to production and capture the new deployment URL from the
#    "Production  https://..." line (org-agnostic; the alias line is excluded
#    because it never carries the per-deployment hash form).
Write-Host 'Deploying to Vercel production...'
# The Vercel CLI prints its banner/progress to stderr. Under
# $ErrorActionPreference='Stop' PowerShell turns that stderr into a terminating
# NativeCommandError, so relax it just around the native vercel invocations and
# capture both streams into a string we can parse.
$ErrorActionPreference = 'Continue'
$deployOut = (vercel deploy --prod --yes 2>&1) | Out-String
$prodLine = ($deployOut -split "`r?`n" | Where-Object { $_ -match 'Production' } | Select-Object -First 1)
$DeployUrl = [regex]::Match($prodLine, 'https://\S+\.vercel\.app').Value
if (-not $DeployUrl) {
    $ErrorActionPreference = 'Stop'
    throw "Could not parse the new production deployment URL.`n$deployOut"
}
Write-Host "New deployment: $DeployUrl"

# 3. Pin the stable domain to this deployment (the step --prod skips).
Write-Host "Pinning $Domain -> $DeployUrl"
vercel alias set $DeployUrl $Domain 2>&1 | Out-String | Write-Host
$ErrorActionPreference = 'Stop'

# 4. Verify the public link actually serves the fresh build.
Start-Sleep -Seconds 4
try {
    $probe = Invoke-WebRequest -Uri "https://$Domain/index.html" -UseBasicParsing -TimeoutSec 30
    if ($probe.StatusCode -ne 200) { throw "HTTP $($probe.StatusCode)" }
    Write-Host "OK: https://$Domain is live (HTTP $($probe.StatusCode))." -ForegroundColor Green
} catch {
    throw "Verification failed for https://$Domain - $($_.Exception.Message)"
}
