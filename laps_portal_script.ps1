#Requires -Modules Az.Accounts, Az.Resources, Az.OperationalInsights, Az.Websites, Az.Functions, Microsoft.Graph.Authentication, Microsoft.Graph.Applications

<#
.SYNOPSIS
    Full installation script for the LAPS Portal
.DESCRIPTION
    This script automates all steps from the LAPS Portal blog post:
    - App Registration (backend)
    - Resource Group
    - Log Analytics Workspace
    - Azure Function App
    - Azure Web App
    - App Registration (frontend)
    - Deployment of GitHub files
    - App Service Authentication
    - Access restriction via Entra ID group
    - Conditional Access policy (MFA + Session Timeout)
.NOTES
    Requirements:
    - Azure subscription with Owner permissions
    - PowerShell 7.x or Azure Cloud Shell
    - Az module + Microsoft.Graph module installed
#>

# ============================================================
# HELPER FUNCTIONS
# ============================================================
function Write-Step { param($n, $msg) Write-Host "`n========== STEP ${n}: $msg ==========" -ForegroundColor Cyan }
function Write-OK   { param($msg)     Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Info { param($msg)     Write-Host "  [INFO] $msg" -ForegroundColor Yellow }

# ============================================================
# CONFIGURATION
# ============================================================
# In Azure Cloud Shell you are already logged in — just retrieve the context
$context        = Get-AzContext
$SubscriptionId = $context.Subscription.Id
$TenantId       = $context.Tenant.Id
Write-OK "Subscription ID : $SubscriptionId"
Write-OK "Tenant ID       : $TenantId"
$Region                 = "westeurope"
$ResourceGroupName      = "rg-laps-data-portal"
$LawName                = "law-laps-data-portal"
$randomSuffix           = -join ((97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
$FunctionAppName        = "laps-graph-$randomSuffix"   # must be globally unique
$WebAppName             = "laps-portal-$randomSuffix"  # must be globally unique
$AppServicePlanName     = "ASP-lapsportal-$randomSuffix"
$BackendAppRegName      = "View Laps data"
$FrontendAppRegName     = "LAPS-Portal-frontend"
$SecretDescription      = "LAPS-data-secret"
$SecretExpireDays       = 180
$AccessGroupName        = "LAPS-Portal-Admins"         # Entra ID group name

# GitHub raw file URLs
$GithubBase             = "https://raw.githubusercontent.com/iamsysadmin/LAPS-portal/main"
$IndexHtmlUrl           = "$GithubBase/index.html"
$ProxyPhpUrl            = "$GithubBase/proxy.php"
$FunctionScriptUrl      = "$GithubBase/run.ps1"

# ============================================================
# HELPER FUNCTIONS
# ============================================================
function Write-Step { param($n, $msg) Write-Host "`n========== STEP ${n}: $msg ==========" -ForegroundColor Cyan }
function Write-OK   { param($msg)     Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Info { param($msg)     Write-Host "  [INFO] $msg" -ForegroundColor Yellow }

# ============================================================
# LOGIN
# ============================================================
Write-Host "`nLAPS Portal - Full Installation Script" -ForegroundColor Magenta
Write-Host "=======================================" -ForegroundColor Magenta

# NOTE: Before running this script, manually run the following command in Cloud Shell and complete the device login:
# Connect-MgGraph -Scopes "Application.ReadWrite.All","Directory.ReadWrite.All","AppRoleAssignment.ReadWrite.All","Policy.ReadWrite.ConditionalAccess","Policy.Read.All","RoleManagement.ReadWrite.Directory" -UseDeviceAuthentication
Write-Info "Using existing Microsoft Graph session..."
if (-not (Get-MgContext)) {
    Write-Host "  [ERROR] Not connected to Microsoft Graph. Please run Connect-MgGraph first!" -ForegroundColor Red
    exit
}

Write-OK "Signed in successfully."

# ============================================================
# STEP 1: Create Resource Group (Managed Identity — no backend App Registration needed)
# ============================================================
Write-Step 1 "Creating Resource Group"

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Region | Out-Null
    Write-OK "Resource group '$ResourceGroupName' created."
} else {
    Write-Info "Resource group '$ResourceGroupName' already exists, skipping."
}

# ============================================================
# STEP 3: Create Log Analytics Workspace
# ============================================================
Write-Step 2 "Creating Log Analytics Workspace"

$law = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $LawName -ErrorAction SilentlyContinue
if (-not $law) {
    $law = New-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName `
        -Name $LawName -Location $Region -Sku PerGB2018
    Write-OK "Log Analytics Workspace '$LawName' created."
} else {
    Write-Info "Log Analytics Workspace '$LawName' already exists, skipping."
}

# Retrieve Workspace ID and Primary Key for use in Function App environment variables
$lawWorkspaceId = $law.CustomerId
$lawPrimaryKey  = (Get-AzOperationalInsightsWorkspaceSharedKey `
    -ResourceGroupName $ResourceGroupName -Name $LawName).PrimarySharedKey
Write-OK "Workspace ID: $lawWorkspaceId"

# ============================================================
# STEP 4: Create Azure Function App
# ============================================================
Write-Step 3 "Creating Azure Function App"

# Create a storage account (required by New-AzFunctionApp, created silently in the background)
$storageAccountName = ("lapsstor" + -join ((97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ }))
New-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $storageAccountName `
    -Location $Region -SkuName Standard_LRS -Kind StorageV2 | Out-Null

# Create the Function App with retry logic (Azure sometimes times out on first attempt)
$funcApp = $null
$attempts = 0
while (-not $funcApp -and $attempts -lt 3) {
    $attempts++
    try {
        $funcApp = New-AzFunctionApp -ResourceGroupName $ResourceGroupName `
            -Name $FunctionAppName -Location $Region `
            -StorageAccountName $storageAccountName `
            -Runtime PowerShell -RuntimeVersion 7.4 `
            -FunctionsVersion 4 -OSType Windows
    } catch {
        Write-Info "Attempt $attempts failed, retrying in 30 seconds..."
        Start-Sleep -Seconds 30
    }
}
if (-not $funcApp) {
    # Check if it was created despite the timeout
    $funcApp = Get-AzFunctionApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction SilentlyContinue
}
if (-not $funcApp) { Write-Host "  [ERROR] Function App could not be created." -ForegroundColor Red; exit }
Write-OK "Function App '$FunctionAppName' created."

# Enable System-assigned Managed Identity on the Function App
$miUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName?api-version=2022-03-01"
$miBody = @{ identity = @{ type = "SystemAssigned" } } | ConvertTo-Json
$miResult = Invoke-RestMethod -Uri $miUrl -Method Patch `
    -Headers @{ Authorization = "Bearer $(Get-FreshToken)"; "Content-Type" = "application/json" } `
    -Body $miBody
$managedIdentityObjectId = $miResult.identity.principalId
Write-OK "Managed Identity enabled. Object ID: $managedIdentityObjectId"

# Grant Graph API permissions to the Managed Identity
$graphSp    = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$deviceRead = ($graphSp.AppRoles | Where-Object { $_.Value -eq "Device.Read.All" }).Id
$lapsRead   = ($graphSp.AppRoles | Where-Object { $_.Value -eq "DeviceLocalCredential.Read.All" }).Id

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentityObjectId `
    -PrincipalId $managedIdentityObjectId -ResourceId $graphSp.Id -AppRoleId $deviceRead | Out-Null
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentityObjectId `
    -PrincipalId $managedIdentityObjectId -ResourceId $graphSp.Id -AppRoleId $lapsRead | Out-Null
Write-OK "Graph API permissions granted to Managed Identity."

# Set environment variables — no client secret needed with Managed Identity
$funcSettings = @{
    LAPS_TENANT_ID   = $TenantId
    LAW_WORKSPACE_ID = $lawWorkspaceId
    LAW_PRIMARY_KEY  = $lawPrimaryKey
}
Update-AzFunctionAppSetting -ResourceGroupName $ResourceGroupName `
    -Name $FunctionAppName -AppSetting $funcSettings | Out-Null
Write-OK "Function App environment variables configured."

# Download the PowerShell function script from GitHub and deploy it
Write-Info "Downloading and deploying function script from GitHub..."
$runPs1 = Invoke-RestMethod -Uri $FunctionScriptUrl
$funcContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($runPs1))

$deployBody = @{
    properties = @{
        files = @{
            "run.ps1" = $runPs1
        }
        config = @{
            bindings = @(
                @{
                    authLevel = "function"
                    type      = "httpTrigger"
                    direction = "in"
                    name      = "Request"
                    methods   = @("get", "post")
                }
                @{
                    type      = "http"
                    direction = "out"
                    name      = "Response"
                }
            )
        }
    }
} | ConvertTo-Json -Depth 10

# Helper function to always get a fresh token before each REST call
function Get-FreshToken {
    $t = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
    if ($t.Token -is [System.Security.SecureString]) {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($t.Token)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    }
    return $t.Token
}
$funcApiUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/functions/GetLapsPassword?api-version=2022-03-01"
Invoke-RestMethod -Uri $funcApiUrl -Method Put `
    -Headers @{ Authorization = "Bearer $(Get-FreshToken)"; "Content-Type" = "application/json" } `
    -Body $deployBody | Out-Null
Write-OK "Function 'GetLapsPassword' deployed."

# Retrieve the function URL including the function key (used as FUNCTION_URL in the Web App)
$funcKeyUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/functions/GetLapsPassword/listKeys?api-version=2022-03-01"
$funcKey    = (Invoke-RestMethod -Uri $funcKeyUrl -Method Post `
    -Headers @{ Authorization = "Bearer $(Get-FreshToken)"; "Content-Type" = "application/json" }).default
$functionUrl = "https://$FunctionAppName.azurewebsites.net/api/GetLapsPassword?code=$funcKey"
Write-OK "Function URL retrieved."

# ============================================================
# STEP 5: Create Web App
# ============================================================
Write-Step 4 "Creating Web App"

# Create the App Service Plan only if it does not exist yet (check across entire subscription)
$asp = Get-AzAppServicePlan -Name $AppServicePlanName -ErrorAction SilentlyContinue
if (-not $asp) {
    $asp = New-AzAppServicePlan -ResourceGroupName $ResourceGroupName `
        -Name $AppServicePlanName -Location $Region `
        -Tier Free -Linux
    Write-OK "App Service Plan '$AppServicePlanName' created."
} else {
    Write-Info "App Service Plan '$AppServicePlanName' already exists, skipping."
}

# Create the Web App running PHP 8.5 on Linux
$webApp = New-AzWebApp -ResourceGroupName $ResourceGroupName `
    -Name $WebAppName -AppServicePlan $AppServicePlanName `
    -Location $Region

# Set PHP 8.5 as the runtime stack (required to match blog configuration and get correct Azure URL)
$webAppConfig = @{
    properties = @{
        linuxFxVersion = "PHP|8.4"
    }
} | ConvertTo-Json

Invoke-RestMethod -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$WebAppName/config/web?api-version=2022-03-01" `
    -Method Patch `
    -Headers @{ Authorization = "Bearer $(Get-FreshToken)"; "Content-Type" = "application/json" } `
    -Body $webAppConfig | Out-Null
Write-OK "Web App '$WebAppName' created with PHP 8.5."

# Re-fetch the Web App to get the correct DefaultHostName including Azure's unique suffix
$webApp    = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $WebAppName
$webAppUrl = "https://" + $webApp.DefaultHostName
Write-OK "Web App URL: $webAppUrl"

# ============================================================
# STEP 6: Create Frontend App Registration
# ============================================================
Write-Step 5 "Creating Frontend App Registration"

# The redirect URI must match the Web App URL for the authentication callback to work
$redirectUri = "$webAppUrl/.auth/login/aad/callback"

$frontendApp = Get-MgApplication -Filter "displayName eq '$FrontendAppRegName'" -ErrorAction SilentlyContinue
if (-not $frontendApp) {
    $frontendApp = New-MgApplication -DisplayName $FrontendAppRegName `
        -SignInAudience "AzureADMyOrg"
    Write-OK "Frontend app registration '$FrontendAppRegName' created."
} else {
    Write-Info "Frontend app registration already exists, skipping."
}

$frontendClientId = $frontendApp.AppId
$frontendObjectId = $frontendApp.Id
Write-OK "Frontend Client ID: $frontendClientId"

# Create service principal for the frontend app registration
$frontendSp = Get-MgServicePrincipal -Filter "appId eq '$frontendClientId'" -ErrorAction SilentlyContinue
if (-not $frontendSp) {
    $frontendSp = New-MgServicePrincipal -AppId $frontendClientId
    Write-OK "Service Principal created for frontend app."
}

# Create a client secret for the frontend app (needed for App Service Authentication)
$frontendSecretExpiry = (Get-Date).AddDays($SecretExpireDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
$frontendSecret = Add-MgApplicationPassword -ApplicationId $frontendObjectId -PasswordCredential @{
    DisplayName = "AppServiceAuth"
    EndDateTime = $frontendSecretExpiry
}
$frontendClientSecret = $frontendSecret.SecretText
Write-OK "Frontend client secret created."

# Update the redirect URI now that we have the correct Web App URL
Update-MgApplication -ApplicationId $frontendObjectId `
    -Web @{ RedirectUris = @("$webAppUrl/.auth/login/aad/callback"); ImplicitGrantSettings = @{ EnableIdTokenIssuance = $true } }
Write-OK "Redirect URI updated to: $webAppUrl/.auth/login/aad/callback"

# Grant admin consent for all users in the tenant
$graphSpId2 = (Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'").Id

try {
    $existingGrant = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($frontendSp.Id)' and consentType eq 'AllPrincipals'" -ErrorAction SilentlyContinue
    if ($existingGrant) {
        Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $existingGrant.Id `
            -Scope "openid profile User.Read offline_access" | Out-Null
        Write-OK "Admin consent updated for all users in tenant."
    } else {
        New-MgOauth2PermissionGrant -ClientId $frontendSp.Id `
            -ConsentType "AllPrincipals" `
            -ResourceId $graphSpId2 `
            -Scope "openid profile User.Read offline_access" | Out-Null
        Write-OK "Admin consent granted for all users in tenant."
    }
} catch {
    Write-Host "  [WARNING] Could not grant admin consent: $_" -ForegroundColor Yellow
}

# ============================================================
# STEP 7: Deploy Frontend Files
# ============================================================
Write-Step 6 "Deploying Frontend Files from GitHub"

# Download index.html and proxy.php from GitHub and deploy via ZIP
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$zipPath = Join-Path $tempDir "deploy.zip"

Invoke-WebRequest -Uri $IndexHtmlUrl -OutFile (Join-Path $tempDir "index.html") -UseBasicParsing
Invoke-WebRequest -Uri $ProxyPhpUrl  -OutFile (Join-Path $tempDir "proxy.php")  -UseBasicParsing

Compress-Archive -Path (Join-Path $tempDir "index.html"), (Join-Path $tempDir "proxy.php") `
    -DestinationPath $zipPath -Force

# Deploy files via Kudu ZIP deploy API
$kuduZipUrl = "https://$WebAppName.scm.azurewebsites.net/api/zipdeploy"
$kuduToken  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$(Get-FreshToken):"))
Invoke-RestMethod -Uri $kuduZipUrl -Method Post `
    -Headers @{ Authorization = "Bearer $(Get-FreshToken)" } `
    -ContentType "application/zip" `
    -InFile $zipPath | Out-Null

Write-OK "index.html and proxy.php deployed to Web App."

# Add FUNCTION_URL as an environment variable so proxy.php can call the Function securely
Set-AzWebApp -ResourceGroupName $ResourceGroupName -Name $WebAppName `
    -AppSettings @{ 
        FUNCTION_URL = $functionUrl
        MICROSOFT_PROVIDER_AUTHENTICATION_SECRET = $frontendClientSecret
    } | Out-Null
Write-OK "FUNCTION_URL environment variable set on Web App."

Remove-Item $tempDir -Recurse -Force

# ============================================================
# STEP 8: Enable App Service Authentication
# ============================================================
Write-Step 7 "Enabling App Service Authentication"

# Configure App Service Authentication with Microsoft identity provider
$authSettings = @{
    properties = @{
        platform = @{
            enabled  = $true
            runtimeVersion = "~1"
        }
        globalValidation = @{
            requireAuthentication       = $true
            unauthenticatedClientAction = "RedirectToLoginPage"
        }
        login = @{
            tokenStore = @{ enabled = $true }
        }
        identityProviders = @{
            azureActiveDirectory = @{
                enabled      = $true
                registration = @{
                    clientId                    = $frontendClientId
                    clientSecretSettingName     = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
                    openIdIssuer                = "https://login.microsoftonline.com/$TenantId/v2.0"
                }
                validation = @{
                    allowedAudiences = @("api://$frontendClientId")
                }
            }
        }
    }
} | ConvertTo-Json -Depth 10

$authUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$WebAppName/config/authsettingsV2?api-version=2022-03-01"
Invoke-RestMethod -Uri $authUrl -Method Put `
    -Headers @{ Authorization = "Bearer $(Get-FreshToken)"; "Content-Type" = "application/json" } `
    -Body $authSettings | Out-Null
Write-OK "App Service Authentication enabled."

# ============================================================
# STEP 9: Restrict Access to Specific Users via Entra ID Group
# ============================================================
Write-Step 8 "Restricting Access to Entra ID Group"

# Create the Entra ID security group if it does not exist yet
# Create the Entra ID security group with IsAssignableToRole enabled (required for PIM)
# Note: requires Privileged Role Administrator or Global Administrator role
$accessGroup = Get-MgGroup -Filter "displayName eq '$AccessGroupName'" -ErrorAction SilentlyContinue
if (-not $accessGroup) {
    try {
        $accessGroup = New-MgGroup -DisplayName $AccessGroupName `
            -MailEnabled:$false -SecurityEnabled:$true `
            -MailNickname ($AccessGroupName -replace '\s','') `
            -IsAssignableToRole:$true
        Write-OK "Entra ID group '$AccessGroupName' created (PIM-enabled)."
    } catch {
        Write-Info "Could not create PIM-enabled group (requires Privileged Role Administrator). Creating regular group instead..."
        $accessGroup = New-MgGroup -DisplayName $AccessGroupName `
            -MailEnabled:$false -SecurityEnabled:$true `
            -MailNickname ($AccessGroupName -replace '\s','')
        Write-OK "Entra ID group '$AccessGroupName' created (PIM not enabled — add IsAssignableToRole manually if needed)."
    }
} else {
    Write-Info "Entra ID group '$AccessGroupName' already exists, skipping."
}

# Verify group was created successfully before proceeding
if (-not $accessGroup -or -not $accessGroup.Id) {
    Write-Host "  [ERROR] Could not create or find group '$AccessGroupName'." -ForegroundColor Red
    exit
}

# Require group assignment on the frontend Enterprise Application
Update-MgServicePrincipal -ServicePrincipalId $frontendSp.Id -AppRoleAssignmentRequired:$true
Write-OK "Assignment required enabled on Enterprise Application."

# Assign the access group to the Enterprise Application
$appRoleId = [Guid]::Empty.ToString()
New-MgGroupAppRoleAssignment -GroupId $accessGroup.Id `
    -PrincipalId $accessGroup.Id `
    -ResourceId $frontendSp.Id `
    -AppRoleId $appRoleId | Out-Null
Write-OK "Group '$AccessGroupName' assigned to LAPS Portal."

# ============================================================
# OPTIONAL: Conditional Access Policy — MFA + Session Timeout
# ============================================================
Write-Step "OPT" "Creating Conditional Access Policy (MFA + Session Timeout)"

# Retrieve the built-in MFA authentication strength policy ID
$mfaStrengthId = (Get-MgPolicyAuthenticationStrengthPolicy | Where-Object { $_.DisplayName -eq "Multifactor authentication" }).Id

$caPolicyParams = @{
    DisplayName     = "LAPS Portal - Require MFA and Session"
    State           = "enabled"
    Conditions      = @{
        Users        = @{ IncludeGroups = @($accessGroup.Id) }
        Applications = @{ IncludeApplications = @($frontendClientId) }
    }
    GrantControls   = @{
        Operator              = "OR"
        AuthenticationStrength = @{ Id = $mfaStrengthId }
    }
    SessionControls = @{
        SignInFrequency = @{
            Value                  = 1
            Type                   = "hours"
            AuthenticationType     = "primaryAndSecondaryAuthentication"
            FrequencyInterval      = "timeBased"
            IsEnabled              = $true
        }
    }
}
# Wait for the Service Principal to propagate in Entra ID before creating the CA policy
Write-Info "Waiting 30 seconds for Service Principal to propagate..."
Start-Sleep -Seconds 30

New-MgIdentityConditionalAccessPolicy @caPolicyParams | Out-Null
Write-OK "Conditional Access policy created (MFA required, session timeout: 1 hour)."

# ============================================================
# DONE — Summary
# ============================================================
Write-Host "`n========================================" -ForegroundColor Magenta
Write-Host "  LAPS Portal deployment complete!" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Access Group    : $AccessGroupName"
Write-Host "  Function App    : $FunctionAppName"
Write-Host "  Web App         : $WebAppName"
Write-Host "  Log Analytics   : $LawName"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "  1. Add users to the '$AccessGroupName' group in Entra ID"
Write-Host "  3. Check audit logs in Log Analytics (allow up to 30 min for first entry)"
Write-Host ""

# Fetch the correct Web App URL via PowerShell (most reliable)
$webAppFinal = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $WebAppName
$webAppUrl   = "https://" + $webAppFinal.DefaultHostName

# Display the portal URL prominently so it is easy to find and share
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  YOUR LAPS PORTAL IS READY!" -ForegroundColor Green
Write-Host "  Open the portal at:" -ForegroundColor Green
Write-Host ""
Write-Host "  --> $webAppUrl <--" -ForegroundColor Yellow
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
