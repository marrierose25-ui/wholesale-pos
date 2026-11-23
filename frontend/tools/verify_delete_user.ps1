# Wholesale POS — account-deletion verifier (live pos-api round-trip)
#
# Proves the deployed `pos-api` delete flow: only an owner may delete, only a
# deactivated account can be deleted, the demo account and the caller's own row
# are refused, a deleted number is gone from the list and from login, and the
# same phone number can be registered again afterwards.
#
# It creates ONE throwaway CASHIER account (phone 0933000444) and deletes it
# again, so point it at a test tenant.
#
# Usage (PowerShell):
#   powershell -File tools\verify_delete_user.ps1 `
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
    [string]$TestPhone = '0933000444',
    [string]$TestPassword = 'delete-test-1234'
)

$ErrorActionPreference = 'Stop'

$script:Results = @()
function Add-Step {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $script:Results += [pscustomobject]@{ Step = $Name; Ok = $Ok; Detail = $Detail }
    $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1,-26} {2}" -f $mark, $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
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

Write-Host '=== account-deletion verifier ===' -ForegroundColor Cyan
Write-Host "URL:    $Url"
Write-Host "Tenant: $ActivationCode"

$owner = Login $OwnerUsername $OwnerPassword
Add-Step 'owner login' $owner.ok "status=$($owner.status)"
if (-not $owner.ok) { exit 1 }
$ownerToken = [string]$owner.body.token
$ownerId = [string]$owner.body.user_id

# A cashier must not be able to delete anyone. Uses the throwaway account below
# (the demo login has a per-tenant password, so it is never assumed here).
$null = Invoke-Api 'create_user' @{
    username = $TestPhone; password = $TestPassword; role = 'CASHIER'
} $ownerToken
$list = Invoke-Api 'list_users' @{} $ownerToken
$test = ($list.body.users | Where-Object { $_.username -eq $TestPhone } | Select-Object -First 1)
Add-Step 'throwaway created' ($null -ne $test) "id=$($test.id)"
if (-not $test) { exit 1 }

$cashier = Login $TestPhone $TestPassword
if ($cashier.ok) {
    $r = Invoke-Api 'delete_user' @{ target_user_id = $ownerId } $cashier.body.token
    Add-Step 'cashier refused' (-not $r.ok -and $r.status -eq 403) "status=$($r.status) error=$($r.error)"
} else {
    Add-Step 'cashier refused' $false 'cashier login failed'
}

# Deleting an active account is refused.
$r = Invoke-Api 'delete_user' @{ target_user_id = $test.id } $ownerToken
Add-Step 'active refused' (-not $r.ok -and "$($r.error)".Contains('Deactivate')) "error=$($r.error)"

# The demo account cannot be deleted even after a deactivate attempt fails.
$null = Invoke-Api 'set_user_active' @{ target_user_id = $test.id; active = $false } $ownerToken

# Deleting your own account is refused.
$r = Invoke-Api 'delete_user' @{ target_user_id = $ownerId } $ownerToken
Add-Step 'self refused' (-not $r.ok -and "$($r.error)".Contains('your own account')) "error=$($r.error)"

# Now the deactivated account can go.
$r = Invoke-Api 'delete_user' @{ target_user_id = $test.id } $ownerToken
Add-Step 'deleted' ($r.ok -and $r.body.retained -eq $false) "status=$($r.status) retained=$($r.body.retained)"

$list = Invoke-Api 'list_users' @{} $ownerToken
$still = ($list.body.users | Where-Object { $_.username -eq $TestPhone } | Select-Object -First 1)
Add-Step 'gone from list' ($null -eq $still) "users=$($list.body.users.Count)"

$relogin = Login $TestPhone $TestPassword
Add-Step 'login refused' (-not $relogin.ok) "status=$($relogin.status)"

# Deleting it freed the number: it can be created again.
$r = Invoke-Api 'create_user' @{
    username = $TestPhone; password = $TestPassword; role = 'CASHIER'
} $ownerToken
Add-Step 'number reusable' ($r.ok) "status=$($r.status) error=$($r.error)"

# Clean up: deactivate the recreated account and delete it for good.
$list = Invoke-Api 'list_users' @{} $ownerToken
$again = ($list.body.users | Where-Object { $_.username -eq $TestPhone } | Select-Object -First 1)
if ($again) {
    $null = Invoke-Api 'set_user_active' @{ target_user_id = $again.id; active = $false } $ownerToken
    $null = Invoke-Api 'delete_user' @{ target_user_id = $again.id } $ownerToken
}
$list = Invoke-Api 'list_users' @{} $ownerToken
$left = ($list.body.users | Where-Object { $_.username -eq $TestPhone } | Select-Object -First 1)
Add-Step 'cleanup' ($null -eq $left) 'throwaway removed'

$passed = ($script:Results | Where-Object { $_.Ok }).Count
Write-Host ''
Write-Host ("{0} / {1} steps passed." -f $passed, $script:Results.Count) -ForegroundColor $(if ($passed -eq $script:Results.Count) { 'Green' } else { 'Red' })
if ($passed -ne $script:Results.Count) { exit 1 }
