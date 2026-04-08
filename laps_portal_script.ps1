<#
.SYNOPSIS
    Cleanup script for the LAPS Portal
.DESCRIPTION
    This script removes all resources created by the LAPS Portal installation script:
    - Resource Group (including Function App, Web App, App Service Plan, Log Analytics, Storage Account)
    - App Registration (backend)
    - App Registration + Enterprise Application (frontend)
    - Entra ID group
    - Conditional Access policy
.NOTES
    Requirements:
    - Azure subscription with Owner permissions
    - PowerShell 7.x or Azure Cloud Shell
    - Az module + Microsoft.Graph module installed
#>

# ============================================================
# CONFIGURATION — must match the values used during installation
# ============================================================

$ResourceGroupName   = "rg-laps-data-portal"
$BackendAppRegName   = "View Laps data"
$FrontendAppRegName  = "LAPS-Portal-frontend"
$CAPolicyName        = "LAPS Portal - Require MFA and Session"

# NOTE: App Service Plan name is dynamically generated, so we find and delete all in the resource group

# ============================================================
# HELPER FUNCTIONS
# ============================================================
function Write-Step { param($n, $msg) Write-Host "`n========== STEP ${n}: $msg ==========" -ForegroundColor Cyan }
function Write-OK   { param($msg)     Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Info { param($msg)     Write-Host "  [INFO] $msg" -ForegroundColor Yellow }
function Write-Skipped { param($msg)  Write-Host "  [SKIPPED] $msg not found, skipping." -ForegroundColor Gray }

# ============================================================
# LOGIN
# ============================================================
Write-Host "`nLAPS Portal - Cleanup Script" -ForegroundColor Magenta
Write-Host "=============================" -ForegroundColor Magenta

# In Azure Cloud Shell you are already logged in — just retrieve the context
$context        = Get-AzContext
$SubscriptionId = $context.Subscription.Id
$TenantId       = $context.Tenant.Id
Write-OK "Subscription ID : $SubscriptionId"
Write-OK "Tenant ID       : $TenantId"

# NOTE: Before running this script, manually run the following command in Cloud Shell and complete the device login:
# Connect-MgGraph -Scopes "Application.ReadWrite.All","Directory.ReadWrite.All","Policy.ReadWrite.ConditionalAccess" -UseDeviceAuthentication
Write-Info "Using existing Microsoft Graph session..."
if (-not (Get-MgContext)) {
    Write-Host "  [ERROR] Not connected to Microsoft Graph. Please run Connect-MgGraph first!" -ForegroundColor Red
    exit
}

Write-OK "Signed in successfully."

# ============================================================
# CONFIRMATION
# ============================================================
Write-Host ""
Write-Host "  The following resources will be permanently deleted:" -ForegroundColor Red
Write-Host "  - Resource Group  : $ResourceGroupName (+ all resources inside)" -ForegroundColor Red
Write-Host "  - App Registration: $BackendAppRegName" -ForegroundColor Red
Write-Host "  - App Registration: $FrontendAppRegName" -ForegroundColor Red
Write-Host "  - CA Policy       : $CAPolicyName" -ForegroundColor Red
Write-Host ""

$confirm = Read-Host "  Type 'yes' to confirm and continue"
if ($confirm -ne "yes") {
    Write-Host "  Cleanup cancelled." -ForegroundColor Yellow
    exit
}

# ============================================================
# STEP 1: Delete Resource Group (and all resources inside)
# ============================================================
Write-Step 1 "Deleting Resource Group '$ResourceGroupName'"

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($rg) {
    Remove-AzResourceGroup -Name $ResourceGroupName -Force | Out-Null
    Write-OK "Resource group '$ResourceGroupName' and all its resources deleted."
} else {
    Write-Skipped "Resource group '$ResourceGroupName'"
}

# ============================================================
# STEP 2: Delete Backend App Registration
# ============================================================
Write-Step 2 "Deleting Backend App Registration '$BackendAppRegName'"

# Use case-insensitive search for app registrations
$backendApp = Get-MgApplication | Where-Object { $_.DisplayName -eq $BackendAppRegName }
if ($backendApp) {
    Remove-MgApplication -ApplicationId $backendApp.Id
    Write-OK "App registration '$BackendAppRegName' deleted."
} else {
    Write-Skipped "'$BackendAppRegName'"
}

# ============================================================
# STEP 3: Delete Frontend App Registration + Enterprise Application
# ============================================================
Write-Step 3 "Deleting Frontend App Registration '$FrontendAppRegName'"

# Use case-insensitive search for app registrations
$frontendApp = Get-MgApplication | Where-Object { $_.DisplayName -eq $FrontendAppRegName }
if ($frontendApp) {
    # Remove the Enterprise Application (Service Principal) first
    $frontendSp = Get-MgServicePrincipal -Filter "appId eq '$($frontendApp.AppId)'" -ErrorAction SilentlyContinue
    if ($frontendSp) {
        Remove-MgServicePrincipal -ServicePrincipalId $frontendSp.Id
        Write-OK "Enterprise Application '$FrontendAppRegName' deleted."
    }
    Remove-MgApplication -ApplicationId $frontendApp.Id
    Write-OK "App registration '$FrontendAppRegName' deleted."
} else {
    Write-Skipped "'$FrontendAppRegName'"
}

# ============================================================
# STEP 4: Delete Conditional Access Policy
# ============================================================
Write-Step 5 "Deleting Conditional Access Policy '$CAPolicyName'"

$caPolicy = Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.DisplayName -eq $CAPolicyName }
if ($caPolicy) {
    Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $caPolicy.Id
    Write-OK "Conditional Access policy '$CAPolicyName' deleted."
} else {
    Write-Skipped "'$CAPolicyName'"
}

# ============================================================
# DONE
# ============================================================
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  LAPS Portal cleanup complete!" -ForegroundColor Green
Write-Host "  All resources have been successfully removed." -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
