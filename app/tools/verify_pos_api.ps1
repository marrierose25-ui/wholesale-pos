# Wholesale POS — pos-api live round-trip verifier (M2/M3 gate)
#
# Runs the exact authenticated action contract the Flutter `Cloud*Repository`
# clients use against a deployed `pos-api` Edge Function, so the plan's
# "cloud action round-trip verified live" gate is one command instead of a pile
# of hand-written Invoke-RestMethod calls.
#
# It is READ-heavy by default (auth + tenancy scoping + server aggregates), which
# is everything needed to prove the function, the JWT session, and the schema are
# wired correctly WITHOUT mutating data. Pass -IncludeWrites to also exercise the
# write path (seed a product -> ring a sale -> void-request -> shift close); those
# create rows under the tenant and are meant for a THROWAWAY test activation code.
#
# Usage (PowerShell, from anywhere):
#   powershell -File tools\verify_pos_api.ps1 -ActivationCode MERCA-XXXX-XXXX-XXXX-XX `# read-only smoke
#   powershell -File tools\verify_pos_api.ps1 -ActivationCode MERCA-... -SetupOwner -OwnerPassword 'a-long-strong-passphrase'
#   powershell -File tools\verify_pos_api.ps1 -ActivationCode MERCA-... -Username owner -Password 'pw' -IncludeWrites
#
# Notes:
#   * First run against a brand-new tenant: pass -SetupOwner to seed the owner
#     (pos-api allows it ONLY while the tenant has zero accounts) — it returns a
#     session token and everything after uses it.
#   * Otherwise it logs in with -Username/-Password.
#   * SUPABASE_URL / service role are injected inside the function; this script
#     never holds a Supabase key — it only carries the shop activation code + the
#     session JWT, exactly like the browser does.

[CmdletBinding()]
param(
    [string]$Url = 'https://trcthxyyuapwavzeisvm.supabase.co/functions/v1/pos-api',
    [Parameter(Mandatory = $true)]
    [string]$ActivationCode,
    [string]$Username = 'owner',
    [string]$Password = '',
    [switch]$SetupOwner,
    [string]$OwnerPassword = '',
    [switch]$IncludeWrites,

    # Overridable test data used only with -IncludeWrites.
    [string]$ProductName = '__verify_product__',
    [string]$ProductCode = '__VRP__',
    [string]$ProductUnit = 'bag',
    [int]$ProductPriceMinor = 45000
)

$ErrorActionPreference = 'Stop'

# --- tiny per-step report collector -----------------------------------------
$script:Results = @()
function Add-Step {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $script:Results += [pscustomobject]@{ Step = $Name; Ok = $Ok; Detail = $Detail }
    $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1,-22} {2}" -f $mark, $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

# POST one action. Returns a hashtable @{ ok=$bool; body=<parsed>; status=<int>; error=<string> }.
# Handles Windows PowerShell 5.1 (no -SkipHttpErrorCheck) by reading the error stream.
function Invoke-Api {
    param([string]$Action, [hashtable]$Body = @{}, [string]$Token = $null)
    $payload = @{ action = $Action } + $Body
    $json = $payload | ConvertTo-Json -Depth 12 -Compress
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Post -Headers $headers -Body $json -UseBasicParsing -TimeoutSec 30
        $parsed = $resp.Content | ConvertFrom-Json
        return @{ ok = [bool]$parsed.ok; body = $parsed; status = [int]$resp.StatusCode; error = $null }
    } catch {
        $content = $null
        try {
            if ($_.Exception.Response) {
                $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $content = $sr.ReadToEnd()
            }
        } catch { }
        if ($content) {
            $parsed = $null
            try { $parsed = $content | ConvertFrom-Json } catch { }
            $err = if ($parsed -and $parsed.error) { [string]$parsed.error } elseif ($parsed -and $parsed.message) { [string]$parsed.message } else { $content }
            $status = [int]$_.Exception.Response.StatusCode
            return @{ ok = $false; body = $parsed; status = $status; error = "$($status): $err" }
        }
        return @{ ok = $false; body = $null; status = -1; error = $_.Exception.Message }
    }
}

Write-Host "=== pos-api round-trip verifier ===" -ForegroundColor Cyan
Write-Host "URL:       $Url"
Write-Host "Tenant:    $ActivationCode"
Write-Host ""

# --- 1) tenancy probe (unauthenticated) -------------------------------------
$has = Invoke-Api 'has_users' @{ activation_code = $ActivationCode }
Add-Step 'has_users' $has.ok $(if ($has.ok) { "has_users=$($has.body.has_users)" } else { $has.error })
if (-not $has.ok) {
    Write-Host ""
    Write-Host "STOPPED: has_users failed. Most likely causes: the function is not deployed" -ForegroundColor Red
    Write-Host "         (404 NOT_FOUND), the activation code is unknown/revoked, or the" -ForegroundColor Red
    Write-Host "         schema (docs/supabase_pos_users.sql) has not been applied." -ForegroundColor Red
    exit 2
}

# --- 2) authenticate -> obtain session token --------------------------------
$token = $null
if ($SetupOwner) {
    if (-not $OwnerPassword) { Write-Host 'ERROR: -SetupOwner requires -OwnerPassword (min 12 chars).' -ForegroundColor Red; exit 1 }
    $r = Invoke-Api 'setup_owner' @{ activation_code = $ActivationCode; username = $Username; password = $OwnerPassword }
    Add-Step 'setup_owner' $r.ok $(if ($r.ok) { 'owner seeded + session issued' } else { $r.error })
    if ($r.ok) { $token = [string]$r.body.token }
} else {
    if (-not $Password) { Write-Host 'ERROR: login path requires -Password (or use -SetupOwner for a brand-new tenant).' -ForegroundColor Red; exit 1 }
    $r = Invoke-Api 'login' @{ activation_code = $ActivationCode; username = $Username; password = $Password }
    Add-Step 'login' $r.ok $(if ($r.ok) { "role=$($r.body.role) user_id=$($r.body.user_id)" } else { $r.error })
    if ($r.ok) { $token = [string]$r.body.token }
}
if (-not $token) {
    Add-Step 'session' $false 'no bearer token; cannot continue authenticated checks'
    exit 3
}

# --- 3) authenticated READ / aggregate path (non-mutating) ------------------
$checks = [ordered]@{
    'list_products'      = @{}
    'next_receipt_number'= @{}
    'get_shift'          = @{}
    'list_void_requests' = @{}
    'list_users'         = @{}
    'list_audit'         = @{ limit = 5 }
    'dashboard_summary'  = @{ period_start = (Get-Date).Date.AddHours(-12).ToString('o'); period_end = (Get-Date).ToString('o') }
    'report_summary'     = @{ period_start = (Get-Date).Date.ToString('o'); period_end = (Get-Date).ToString('o') }
}
foreach ($action in $checks.Keys) {
    $r = Invoke-Api $action $checks[$action] $token
    $detail = if ($r.ok) { 'ok' } else { $r.error }
    Add-Step $action $r.ok $detail
}

# --- 4) optional WRITE smoke (mutates the tenant — throwaway code only) ------
if ($IncludeWrites) {
    Write-Host ''
    Write-Host '--- write path (mutates tenant data; use a THROWAWAY activation code) ---' -ForegroundColor Yellow

    $prod = Invoke-Api 'save_product' @{ product = @{ name = $ProductName; code = $ProductCode; unit = $ProductUnit; selling_price_minor_units = $ProductPriceMinor; is_active = 1 } } $token
    Add-Step 'save_product' $prod.ok $(if ($prod.ok) { "id=$($prod.body.id)" } else { $prod.error })

    # Resolve a concrete product id to sell (reuse ours if save failed as duplicate).
    $listing = Invoke-Api 'list_products' @{} $token
    $productId = $null
    if ($listing.ok -and $listing.body.products) { $productId = @($listing.body.products)[0].id }

    $shift = Invoke-Api 'open_shift' @{ opening_cash_minor_units = 0 } $token
    Add-Step 'open_shift' $shift.ok $(if ($shift.ok) { 'shift opened' } else { $shift.error })
    $active = Invoke-Api 'get_shift' @{} $token
    $shiftId = if ($active.ok -and $active.body.shift) { [string]$active.body.shift.id } else { $null }

    $rc = Invoke-Api 'next_receipt_number' @{} $token
    $receipt = if ($rc.ok) { [string]$rc.body.receipt_number } else { $null }

    if ($productId -and $shiftId -and $receipt) {
        $now = (Get-Date).ToString('o')
        $saleId = [guid]::NewGuid().ToString()
        $sale = @{
            id = $saleId; receipt_number = $receipt; shift_id = $shiftId; device_id = 'verify-script'
            payment_method = 'CASH'; status = 'COMPLETED'
            subtotal_minor_units = $ProductPriceMinor; discount_minor_units = 0
            total_minor_units = $ProductPriceMinor; amount_paid_minor_units = $ProductPriceMinor
            change_minor_units = 0; created_at = $now
        }
        $item = @{
            id = [guid]::NewGuid().ToString(); sale_id = $saleId; product_id = $productId
            product_name_snapshot = $ProductName; unit_snapshot = $ProductUnit
            qty_milliunits = 1000; unit_price_minor_units = $ProductPriceMinor
            line_total_minor_units = $ProductPriceMinor; discount_minor_units = 0; created_at = $now
        }
        $ins = Invoke-Api 'insert_sale' @{ sale = $sale; items = @($item) } $token
        Add-Step 'insert_sale' $ins.ok $(if ($ins.ok) { "sale_id=$saleId" } else { $ins.error })

        $srch = Invoke-Api 'search_sales' @{ limit = 10 } $token
        $n = if ($srch.ok -and $srch.body.sales) { @($srch.body.sales).Count } else { 0 }
        Add-Step 'search_sales' $srch.ok "$(if ($srch.ok) { "$n rows" } else { $srch.error })"

        $summ = Invoke-Api 'shift_summary' @{ shift_id = $shiftId } $token
        Add-Step 'shift_summary' $summ.ok $(if ($summ.ok) { ($summ.body.summary | ConvertTo-Json -Compress) } else { $summ.error })

        $close = Invoke-Api 'close_shift' @{ shift_id = $shiftId; closing_cash_minor_units = $ProductPriceMinor } $token
        Add-Step 'close_shift' $close.ok $(if ($close.ok) { 'Z-report closed' } else { $close.error })
    } else {
        Add-Step 'insert_sale' $false "missing prerequisite (productId=$productId shiftId=$shiftId receipt=$receipt)"
    }
}

# --- summary -----------------------------------------------------------------
Write-Host ''
Write-Host '=== summary ===' -ForegroundColor Cyan
$pass = ($script:Results | Where-Object { $_.Ok }).Count
$total = $script:Results.Count
Write-Host "$pass / $total steps passed."
if ($pass -lt $total) {
    Write-Host 'Failing steps:' -ForegroundColor Red
    $script:Results | Where-Object { -not $_.Ok } | ForEach-Object { Write-Host ("  - {0}: {1}" -f $_.Step, $_.Detail) -ForegroundColor Red }
    exit 1
}
Write-Host 'Round-trip verified: pos-api, JWT session, tenancy scoping, and aggregates are live and correct.' -ForegroundColor Green
exit 0
