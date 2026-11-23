# Wholesale POS — phone-number login verifier (live pos-api round-trip)
#
# Proves the deployed `pos-api` folds phone numbers the same way the Flutter
# client does: an owner can create an account from any accepted spelling, the
# stored identifier is canonical, sign-in accepts every spelling of it, the old
# number stops working after `set_user_phone`, text identifiers are refused for
# new accounts, and the demo account keeps its `demo` login.
#
# It creates ONE throwaway CASHIER account (phone 0911000111) and renames it to
# 0922000222, so point it at a test tenant (or delete the row afterwards).
#
# Usage (PowerShell):
#   powershell -File tools\verify_phone_login.ps1 `
#     -ActivationCode AAXW-XXXX-XXXX-XXXX-XX `
#     -OwnerUsername owner -OwnerPassword '<owner password>'

[CmdletBinding()]
param(
    [string]$Url = 'https://trcthxyyuapwavzeisvm.supabase.co/functions/v1/pos-api',
    [Parameter(Mandatory = $true)]
    [string]$ActivationCode,
    [string]$OwnerUsername = 'owner',
    [Parameter(Mandatory = $true)]
    [string]$OwnerPassword,
    [string]$TestPhone = '0911000111',
    [string]$RenamedPhone = '0922000222',
    [string]$TestPassword = 'phone-test-1234',
    # The demo login has a per-tenant password now, so it is never assumed. Pass
    # the owner-set value to include the demo step; otherwise it is skipped.
    [string]$DemoPassword = $env:POS_DEMO_PASSWORD
)

$ErrorActionPreference = 'Stop'

$script:Results = @()
function Add-Step {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $script:Results += [pscustomobject]@{ Step = $Name; Ok = $Ok; Detail = $Detail }
    $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1,-24} {2}" -f $mark, $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

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
            $err = if ($parsed -and $parsed.error) { [string]$parsed.error } else { $content }
            $status = [int]$_.Exception.Response.StatusCode
            return @{ ok = $false; body = $parsed; status = $status; error = "$($status): $err" }
        }
        return @{ ok = $false; body = $null; status = -1; error = $_.Exception.Message }
    }
}

function Login {
    param([string]$Username, [string]$Password)
    return Invoke-Api 'login' @{
        activation_code = $ActivationCode
        username        = $Username
        password        = $Password
    }
}

Write-Host '=== phone-number login verifier ===' -ForegroundColor Cyan
Write-Host "URL:    $Url"
Write-Host "Tenant: $ActivationCode"
Write-Host ''

# 1) The demo account is the documented exception: any casing/spacing works.
# Its password is per tenant, so the step runs only when one was supplied.
if ($DemoPassword) {
    $demo = Login ' DEMO ' $DemoPassword
    Add-Step 'login demo (padded)' $demo.ok $(if ($demo.ok) { "role=$($demo.body.role)" } else { $demo.error })
} else {
    Write-Host '[SKIP] login demo (padded)   set POS_DEMO_PASSWORD to include it' -ForegroundColor Yellow
}

# 2) Owner sign-in: a legacy text identifier still resolves (trimmed).
$owner = Login "  $OwnerUsername  " $OwnerPassword
Add-Step 'login owner' $owner.ok $(if ($owner.ok) { "role=$($owner.body.role)" } else { $owner.error })
if (-not $owner.ok) { Write-Host 'STOPPED: cannot continue without an owner session.' -ForegroundColor Red; exit 3 }
$token = [string]$owner.body.token

# 3) Creation accepts a messy spelling and stores the canonical number.
$created = Invoke-Api 'create_user' @{
    username    = '+251 911 000 111'
    password    = $TestPassword
    role        = 'CASHIER'
    permissions = @('pos')
} $token
Add-Step 'create_user (messy)' $created.ok $(if ($created.ok) { "id=$($created.body.id)" } else { $created.error })

# 4) The canonical spelling signs in.
$loginCanonical = Login $TestPhone $TestPassword
Add-Step 'login 0911000111' $loginCanonical.ok $(if ($loginCanonical.ok) { "username=$($loginCanonical.body.username)" } else { $loginCanonical.error })

# 5) ...and so does +251 / bare / spaced input for the same account.
foreach ($spelling in @('+251911000111', '911000111', '0911 000 111')) {
    $r = Login $spelling $TestPassword
    Add-Step "login $spelling" $r.ok $(if ($r.ok) { 'ok' } else { $r.error })
}

# 6) A name is no longer accepted for a new account.
$rejected = Invoke-Api 'create_user' @{
    username    = 'someone'
    password    = $TestPassword
    role        = 'CASHIER'
    permissions = @('pos')
} $token
$rejectedByPhone = (-not $rejected.ok) -and ([string]$rejected.error -match 'valid phone number')
Add-Step 'create_user rejects name' $rejectedByPhone ([string]$rejected.error)

# 7) The owner can move the account to a new number.
if ($created.ok) {
    $renamed = Invoke-Api 'set_user_phone' @{
        target_user_id = [string]$created.body.id
        phone          = '0922-000-222'
    } $token
    Add-Step 'set_user_phone' $renamed.ok $(if ($renamed.ok) { 'renamed to 0922000222' } else { $renamed.error })

    $newSpelling = Login '+251922000222' $TestPassword
    Add-Step 'login +251922000222' $newSpelling.ok $(if ($newSpelling.ok) { "username=$($newSpelling.body.username)" } else { $newSpelling.error })

    $oldGone = Login $TestPhone $TestPassword
    Add-Step 'old number retired' (-not $oldGone.ok) $(if ($oldGone.ok) { 'STILL WORKS' } else { 'refused as expected' })
}

# 8) The demo login is pinned.
$users = Invoke-Api 'list_users' @{} $token
$demoId = $null
if ($users.ok -and $users.body.users) {
    $demoRow = @($users.body.users) | Where-Object { $_.is_demo -eq $true } | Select-Object -First 1
    if ($demoRow) { $demoId = [string]$demoRow.id }
}
if ($demoId) {
    $demoRename = Invoke-Api 'set_user_phone' @{ target_user_id = $demoId; phone = '0955000111' } $token
    $demoPinned = (-not $demoRename.ok) -and ([string]$demoRename.error -match 'demo login')
    Add-Step 'demo phone pinned' $demoPinned ([string]$demoRename.error)
} else {
    Add-Step 'demo phone pinned' $false 'demo account not found in list_users'
}

if ($users.ok) {
    $names = (@($users.body.users) | ForEach-Object { $_.username }) -join ', '
    Write-Host ""
    Write-Host "Users now: $names" -ForegroundColor DarkGray
}

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
Write-Host 'Phone-number login verified live: fold, create, rename, retire, demo pin.' -ForegroundColor Green
exit 0
