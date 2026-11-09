# Wholesale POS - web/PWA deploy to Cloudflare Pages.
#
# WHY THIS EXISTS
#   We left Vercel. Cloudflare Pages re-points the stable production domain
#   (https://<project>.pages.dev) at the newest deploy of the `main` branch on
#   every upload, so there is none of the alias-drift-to-404 failure the
#   hand-pinned *.vercel.app alias kept hitting. This script is the LOCAL,
#   on-demand path ("deploy when I order it"); the automatic path is the
#   Deploy Web workflow (.github/workflows/deploy-web.yml) that fires on every
#   push to main. Both build with tools/build_release.ps1 and upload build/web.
#
#   Needs wrangler installed and logged in locally (wrangler whoami): the upload
#   authenticates with your stored OAuth session. CI uses an API token instead.
#
# Usage:
#   powershell -File tools\deploy_web.ps1                       # build web + deploy (production)
#   powershell -File tools\deploy_web.ps1 -SkipBuild            # redeploy current build/web
#   powershell -File tools\deploy_web.ps1 -ProjectName aymen-pos -Branch main

param(
    [switch]$SkipBuild,

    # The Cloudflare Pages project to publish (its stable domain is
    # https://<ProjectName>.pages.dev).
    [string]$ProjectName = 'aymen-pos',

    # 'main' => production deploy; any other value lands as an immutable preview.
    [string]$Branch = 'main'
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

# 2. Defensive sweep: a previous Vercel run could have left a live credential
#    (.env.local, its OIDC token) or Vercel-only files in the output folder.
#    Pages would serve any of those PUBLICLY, so strip them before uploading.
foreach ($junk in @('.vercel', '.env.local', 'vercel.json', '.gitignore', '.last_build_id')) {
    $p = Join-Path $WebDir $junk
    if (Test-Path $p) {
        Write-Host "Removing non-deployable artifact from upload: $junk"
        Remove-Item $p -Recurse -Force
    }
}

Set-Location $WebDir

# 3. Upload to Cloudflare Pages. wrangler prints progress to stderr; relax
#    ErrorActionPreference around the native call so PowerShell does not turn a
#    benign stderr banner into a terminating NativeCommandError.
#
#    Retried (up to 5x): a Pages direct upload batches the files into a few
#    large POSTs and a single socket/header timeout aborts the whole deploy with
#    an opaque "Failed to upload files. Error: {}". The asset store is content-
#    addressed, so each retry re-sends ONLY the still-missing files and the run
#    converges; without the loop a flaky link leaves an empty (404) branch.
Write-Host "Deploying to Cloudflare Pages ($ProjectName / branch $Branch)..."
$ErrorActionPreference = 'Continue'
$ok = $false
for ($attempt = 1; $attempt -le 5 -and -not $ok; $attempt++) {
    if ($attempt -gt 1) { Write-Host "Retry $attempt - re-sending only the files still missing..." }
    npx --yes wrangler@4 pages deploy . --project-name=$ProjectName --branch=$Branch --commit-dirty=true 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -eq 0) { $ok = $true } else { Write-Warning "Attempt $attempt failed (large-upload timeout is the usual cause); retrying." }
}
$ErrorActionPreference = 'Stop'
if (-not $ok) {
    throw "wrangler pages deploy failed after 5 attempts."
}

# 4. Verify the public link actually serves the fresh build. Pages updates the
#    branch domain almost immediately, but compare the served bundle against the
#    one just built so a silent mis-point to an older deploy fails loudly.
#
#    Compare SHA-256, not Content-Length: Cloudflare may serve main.dart.js
#    compressed (gzip/brotli), so the HTTP Content-Length is the COMPRESSED size
#    and never equals the local file size even when the bytes are identical.
#    -OutFile writes the decoded body, and hashing that matches what the browser
#    actually evaluates.
$Domain = "$ProjectName.pages.dev"
$localBundle = Join-Path $WebDir 'main.dart.js'
$localHash = (Get-FileHash $localBundle -Algorithm SHA256).Hash
Write-Host "Verifying https://$Domain serves the new bundle (sha256 $localHash)..."
$max = 12
for ($i = 1; $i -le $max; $i++) {
    $tmp = Join-Path $env:TEMP ("pos_served_main_$PID.dart.js")
    try {
        # Probe the root, not /index.html: Pages answers /index.html with a 308
        # redirect to "/", and PowerShell 5.1's Invoke-WebRequest does not follow
        # 308, which made this check fail even on a perfectly live deploy.
        $probe = Invoke-WebRequest -Uri "https://$Domain/" -UseBasicParsing -TimeoutSec 30
        if ($probe.StatusCode -eq 200) {
            Invoke-WebRequest -Uri "https://$Domain/main.dart.js" -UseBasicParsing -TimeoutSec 180 -OutFile $tmp
            $servedHash = (Get-FileHash $tmp -Algorithm SHA256).Hash
            if ($servedHash -eq $localHash) {
                Write-Host "OK: https://$Domain is live (HTTP $($probe.StatusCode), bundle sha256 $localHash)." -ForegroundColor Green
                return
            }
        }
    } catch {
        # Transient 5xx / propagation; retry below.
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 5
}
throw "Verification failed for https://$Domain - served main.dart.js did not match the built bundle (sha256 $localHash) after $max attempts."
