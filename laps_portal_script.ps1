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

    Before running this script, sign in to Microsoft Graph:
    Connect-MgGraph -Scopes "Application.ReadWrite.All","Directory.ReadWrite.All","AppRoleAssignment.ReadWrite.All","Policy.ReadWrite.ConditionalAccess","Policy.Read.All","RoleManagement.ReadWrite.Directory" -UseDeviceAuthentication
#>

# ============================================================
# HELPER FUNCTIONS
# ============================================================
function Write-Step { param($n, $msg) Write-Host "`n========== STEP ${n}: $msg ==========" -ForegroundColor Cyan }
function Write-OK   { param($msg)     Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Info { param($msg)     Write-Host "  [INFO] $msg" -ForegroundColor Yellow }

# Helper function to always get a fresh token before each REST call
function Get-FreshToken {
    $t = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
    if ($t.Token -is [System.Security.SecureString]) {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($t.Token)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    }
    return $t.Token
}

# ============================================================
# CONFIGURATION
# ============================================================
$context        = Get-AzContext
$SubscriptionId = $context.Subscription.Id
$TenantId       = $context.Tenant.Id
Write-OK "Subscription ID : $SubscriptionId"
Write-OK "Tenant ID       : $TenantId"

$Region             = "westeurope"
$ResourceGroupName  = "rg-laps-data-portal"
$LawName            = "law-laps-data-portal"
$randomSuffix       = -join ((97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
$FunctionAppName    = "laps-graph-$randomSuffix"
$WebAppName         = "laps-portal-$randomSuffix"
$AppServicePlanName = "ASP-lapsportal-$randomSuffix"
$BackendAppRegName  = "View Laps data"
$FrontendAppRegName = "LAPS-Portal-frontend"
$SecretDescription  = "LAPS-data-secret"
$SecretExpireDays   = 180
$AccessGroupName    = "LAPS-Portal-Admins"

$GithubBase        = "https://raw.githubusercontent.com/iamsysadmin/LAPS-portal/main"
$IndexHtmlUrl      = "$GithubBase/index.html"
$ProxyPhpUrl       = "$GithubBase/proxy.php"
$FunctionScriptUrl = "$GithubBase/run.ps1"

# ============================================================
# LOGIN
# ============================================================
Write-Host "`nLAPS Portal - Full Installation Script" -ForegroundColor Magenta
Write-Host "=======================================" -ForegroundColor Magenta

Write-Info "Using existing Microsoft Graph session..."
if (-not (Get-MgContext)) {
    Write-Host "  [ERROR] Not connected to Microsoft Graph. Please run Connect-MgGraph first!" -ForegroundColor Red
    exit
}
Write-OK "Signed in successfully."

# ============================================================
# STEP 1: Create Backend App Registration
# ============================================================
Write-Step 1 "Creating Backend App Registration"

$backendApp = Get-MgApplication -Filter "displayName eq '$BackendAppRegName'" -ErrorAction SilentlyContinue
if (-not $backendApp) {
    $backendApp = New-MgApplication -DisplayName $BackendAppRegName -SignInAudience "AzureADMyOrg"
    Write-OK "App registration '$BackendAppRegName' created."
} else {
    Write-Info "App registration '$BackendAppRegName' already exists, skipping."
}

$backendClientId = $backendApp.AppId
$backendObjectId = $backendApp.Id
Write-OK "Backend Client ID: $backendClientId"

$backendSp = Get-MgServicePrincipal -Filter "appId eq '$backendClientId'" -ErrorAction SilentlyContinue
if (-not $backendSp) {
    $backendSp = New-MgServicePrincipal -AppId $backendClientId
    Write-OK "Service Principal created for backend app."
}

$secretExpiry = (Get-Date).AddDays($SecretExpireDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
$secretResult = Add-MgApplicationPassword -ApplicationId $backendObjectId -PasswordCredential @{
    DisplayName = $SecretDescription
    EndDateTime = $secretExpiry
}
$backendClientSecret = $secretResult.SecretText
Write-OK "Client secret created (expires in $SecretExpireDays days)."

$graphSp    = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$graphSpId  = $graphSp.Id
$deviceRead = ($graphSp.AppRoles | Where-Object { $_.Value -eq "Device.Read.All" }).Id
$lapsRead   = ($graphSp.AppRoles | Where-Object { $_.Value -eq "DeviceLocalCredential.Read.All" }).Id

Update-MgApplication -ApplicationId $backendObjectId -RequiredResourceAccess @(
    @{
        ResourceAppId  = "00000003-0000-0000-c000-000000000000"
        ResourceAccess = @(
            @{ Id = $deviceRead; Type = "Role" },
            @{ Id = $lapsRead;   Type = "Role" }
        )
    }
)

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $backendSp.Id `
    -PrincipalId $backendSp.Id -ResourceId $graphSpId -AppRoleId $deviceRead | Out-Null
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $backendSp.Id `
    -PrincipalId $backendSp.Id -ResourceId $graphSpId -AppRoleId $lapsRead | Out-Null
Write-OK "Graph API permissions granted with admin consent."

# ============================================================
# STEP 2: Create Resource Group
# ============================================================
Write-Step 2 "Creating Resource Group"

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
Write-Step 3 "Creating Log Analytics Workspace"

$law = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $LawName -ErrorAction SilentlyContinue
if (-not $law) {
    $law = New-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName `
        -Name $LawName -Location $Region -Sku PerGB2018
    Write-OK "Log Analytics Workspace '$LawName' created."
} else {
    Write-Info "Log Analytics Workspace '$LawName' already exists, skipping."
}

$lawWorkspaceId = $law.CustomerId
$lawPrimaryKey  = (Get-AzOperationalInsightsWorkspaceSharedKey `
    -ResourceGroupName $ResourceGroupName -Name $LawName).PrimarySharedKey
Write-OK "Workspace ID: $lawWorkspaceId"

# ============================================================
# STEP 4: Create Azure Function App
# ============================================================
Write-Step 4 "Creating Azure Function App"

$storageAccountName = ("lapsstor" + -join ((97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ }))
New-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $storageAccountName `
    -Location $Region -SkuName Standard_LRS -Kind StorageV2 | Out-Null

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
    $funcApp = Get-AzFunctionApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction SilentlyContinue
}
if (-not $funcApp) { Write-Host "  [ERROR] Function App could not be created." -ForegroundColor Red; exit }
Write-OK "Function App '$FunctionAppName' created."

$funcSettings = @{
    LAPS_TENANT_ID     = $TenantId
    LAPS_CLIENT_ID     = $backendClientId
    LAPS_CLIENT_SECRET = $backendClientSecret
    LAW_WORKSPACE_ID   = $lawWorkspaceId
    LAW_PRIMARY_KEY    = $lawPrimaryKey
}
Update-AzFunctionAppSetting -ResourceGroupName $ResourceGroupName `
    -Name $FunctionAppName -AppSetting $funcSettings | Out-Null
Write-OK "Function App environment variables configured."

Write-Info "Downloading and deploying function script from GitHub..."
$runPs1 = Invoke-RestMethod -Uri $FunctionScriptUrl

$deployBody = @{
    properties = @{
        files  = @{ "run.ps1" = $runPs1 }
        config = @{
            bindings = @(
                @{ authLevel = "function"; type = "httpTrigger"; direction = "in"; name = "Request"; methods = @("get","post") },
                @{ type = "http"; direction = "out"; name = "Response" }
            )
        }
    }
} | ConvertTo-Json -Depth 10

$funcApiUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/functions/GetLapsPassword?api-version=2022-03-01"
Invoke-RestMethod -Uri $funcApiUrl -Method Put `
    -Headers @{ Authorization = "Bearer $(Get-FreshToken)"; "Content-Type" = "application/json" } `
    -Body $deployBody | Out-Null
Write-OK "Function 'GetLapsPassword' deployed."

$funcKeyUrl  = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/functions/GetLapsPassword/listKeys?api-version=2022-03-01"
$funcKey     = (Invoke-RestMethod -Uri $funcKeyUrl -Method Post `
    -Headers @{ Authorization = "Bearer $(Get-FreshToken)"; "Content-Type" = "application/json" }).default
$functionUrl = "https://$FunctionAppName.azurewebsites.net/api/GetLapsPassword?code=$funcKey"
Write-OK "Function URL retrieved."

# ============================================================
# STEP 5: Create Web App
# ============================================================
Write-Step 5 "Creating Web App"

$asp = Get-AzAppServicePlan -Name $AppServicePlanName -ErrorAction SilentlyContinue
if (-not $asp) {
    $asp = New-AzAppServicePlan -ResourceGroupName $ResourceGroupName `
        -Name $AppServicePlanName -Location $Region -Tier Free -Linux
    Write-OK "App Service Plan '$AppServicePlanName' created."
} else {
    Write-Info "App Service Plan '$AppServicePlanName' already exists, skipping."
}

$webApp = New-AzWebApp -ResourceGroupName $ResourceGroupName `
    -Name $WebAppName -AppServicePlan $AppServicePlanName -Location $Region

$webAppConfig = @{ properties = @{ linuxFxVersion = "PHP|8.5" } } | ConvertTo-Json
Invoke-RestMethod -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$WebAppName/config/web?api-version=2022-03-01" `
    -Method Patch `
    -Headers @{ Authorization = "Bearer $(Get-FreshToken)"; "Content-Type" = "application/json" } `
    -Body $webAppConfig | Out-Null
Write-OK "Web App '$WebAppName' created with PHP 8.5."

$webApp    = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $WebAppName
$webAppUrl = "https://" + $webApp.DefaultHostName
Write-OK "Web App URL: $webAppUrl"

# ============================================================
# STEP 6: Create Frontend App Registration
# ============================================================
Write-Step 6 "Creating Frontend App Registration"

$frontendApp = Get-MgApplication -Filter "displayName eq '$FrontendAppRegName'" -ErrorAction SilentlyContinue
if (-not $frontendApp) {
    $frontendApp = New-MgApplication -DisplayName $FrontendAppRegName -SignInAudience "AzureADMyOrg"
    Write-OK "Frontend app registration '$FrontendAppRegName' created."
} else {
    Write-Info "Frontend app registration already exists, skipping."
}

$frontendClientId = $frontendApp.AppId
$frontendObjectId = $frontendApp.Id
Write-OK "Frontend Client ID: $frontendClientId"

$frontendSp = Get-MgServicePrincipal -Filter "appId eq '$frontendClientId'" -ErrorAction SilentlyContinue
if (-not $frontendSp) {
    $frontendSp = New-MgServicePrincipal -AppId $frontendClientId
    Write-OK "Service Principal created for frontend app."
}

$frontendSecretExpiry = (Get-Date).AddDays($SecretExpireDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
$frontendSecret = Add-MgApplicationPassword -ApplicationId $frontendObjectId -PasswordCredential @{
    DisplayName = "AppServiceAuth"
    EndDateTime = $frontendSecretExpiry
}
$frontendClientSecret = $frontendSecret.SecretText
Write-OK "Frontend client secret created."

Update-MgApplication -ApplicationId $frontendObjectId `
    -Web @{ RedirectUris = @("$webAppUrl/.auth/login/aad/callback"); ImplicitGrantSettings = @{ EnableIdTokenIssuance = $true } }
Write-OK "Redirect URI updated to: $webAppUrl/.auth/login/aad/callback"

$graphSpId2 = (Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'").Id
try {
    $existingGrant = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($frontendSp.Id)' and consentType eq 'AllPrincipals'" -ErrorAction SilentlyContinue
    if ($existingGrant) {
        Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $existingGrant.Id `
            -Scope "openid profile User.Read offline_access" | Out-Null
        Write-OK "Admin consent updated for all users in tenant."
    } else {
        New-MgOauth2PermissionGrant -ClientId $frontendSp.Id `
            -ConsentType "AllPrincipals" -ResourceId $graphSpId2 `
            -Scope "openid profile User.Read offline_access" | Out-Null
        Write-OK "Admin consent granted for all users in tenant."
    }
} catch {
    Write-Host "  [WARNING] Could not grant admin consent: $_" -ForegroundColor Yellow
}

# ============================================================
# STEP 7: Deploy Frontend Files
# ============================================================
Write-Step 7 "Deploying Frontend Files from GitHub"

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$zipPath = Join-Path $tempDir "deploy.zip"

Invoke-WebRequest -Uri $IndexHtmlUrl -OutFile (Join-Path $tempDir "index.html") -UseBasicParsing
Invoke-WebRequest -Uri $ProxyPhpUrl  -OutFile (Join-Path $tempDir "proxy.php")  -UseBasicParsing
Compress-Archive -Path (Join-Path $tempDir "index.html"),(Join-Path $tempDir "proxy.php") `
    -DestinationPath $zipPath -Force

Invoke-RestMethod -Uri "https://$WebAppName.scm.azurewebsites.net/api/zipdeploy" -Method Post `
    -Headers @{ Authorization = "Bearer $(Get-FreshToken)" } `
    -ContentType "application/zip" -InFile $zipPath | Out-Null
Write-OK "index.html and proxy.php deployed to Web App."

Set-AzWebApp -ResourceGroupName $ResourceGroupName -Name $WebAppName `
    -AppSettings @{
        FUNCTION_URL                             = $functionUrl
        MICROSOFT_PROVIDER_AUTHENTICATION_SECRET = $frontendClientSecret
    } | Out-Null
Write-OK "FUNCTION_URL environment variable set on Web App."
Remove-Item $tempDir -Recurse -Force

# ============================================================
# STEP 8: Enable App Service Authentication
# ============================================================
Write-Step 8 "Enabling App Service Authentication"

$authSettings = @{
    properties = @{
        platform         = @{ enabled = $true; runtimeVersion = "~1" }
        globalValidation = @{ requireAuthentication = $true; unauthenticatedClientAction = "RedirectToLoginPage" }
        login            = @{ tokenStore = @{ enabled = $true } }
        identityProviders = @{
            azureActiveDirectory = @{
                enabled      = $true
                registration = @{
                    clientId                = $frontendClientId
                    clientSecretSettingName = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
                    openIdIssuer            = "https://login.microsoftonline.com/$TenantId/v2.0"
                }
                validation = @{ allowedAudiences = @("api://$frontendClientId") }
            }
        }
    }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$WebAppName/config/authsettingsV2?api-version=2022-03-01" `
    -Method Put `
    -Headers @{ Authorization = "Bearer $(Get-FreshToken)"; "Content-Type" = "application/json" } `
    -Body $authSettings | Out-Null
Write-OK "App Service Authentication enabled."

# ============================================================
# STEP 9: Restrict Access to Specific Users via Entra ID Group
# ============================================================
Write-Step 9 "Restricting Access to Entra ID Group"

$accessGroup = Get-MgGroup -Filter "displayName eq '$AccessGroupName'" -ErrorAction SilentlyContinue
if (-not $accessGroup) {
    try {
        $accessGroup = New-MgGroup -DisplayName $AccessGroupName `
            -MailEnabled:$false -SecurityEnabled:$true `
            -MailNickname ($AccessGroupName -replace '\s','') `
            -IsAssignableToRole:$true
        Write-OK "Entra ID group '$AccessGroupName' created (PIM-enabled)."
    } catch {
        Write-Info "Could not create PIM-enabled group, creating regular group instead..."
        $accessGroup = New-MgGroup -DisplayName $AccessGroupName `
            -MailEnabled:$false -SecurityEnabled:$true `
            -MailNickname ($AccessGroupName -replace '\s','')
        Write-OK "Entra ID group '$AccessGroupName' created."
    }
} else {
    Write-Info "Entra ID group '$AccessGroupName' already exists, skipping."
}

if (-not $accessGroup -or -not $accessGroup.Id) {
    Write-Host "  [ERROR] Could not create or find group '$AccessGroupName'." -ForegroundColor Red; exit
}

Update-MgServicePrincipal -ServicePrincipalId $frontendSp.Id -AppRoleAssignmentRequired:$true
Write-OK "Assignment required enabled on Enterprise Application."

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

$mfaStrengthId = (Get-MgPolicyAuthenticationStrengthPolicy | Where-Object { $_.DisplayName -eq "Multifactor authentication" }).Id

$caPolicyParams = @{
    DisplayName   = "LAPS Portal - Require MFA and Session"
    State         = "enabled"
    Conditions    = @{
        Users        = @{ IncludeGroups = @($accessGroup.Id) }
        Applications = @{ IncludeApplications = @($frontendClientId) }
    }
    GrantControls = @{
        Operator               = "OR"
        AuthenticationStrength = @{ Id = $mfaStrengthId }
    }
    SessionControls = @{
        SignInFrequency = @{
            Value              = 1
            Type               = "hours"
            AuthenticationType = "primaryAndSecondaryAuthentication"
            FrequencyInterval  = "timeBased"
            IsEnabled          = $true
        }
    }
}

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
Write-Host "  2. Check audit logs in Log Analytics (allow up to 30 min for first entry)"
Write-Host ""

$webAppFinal = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $WebAppName
$webAppUrl   = "https://" + $webAppFinal.DefaultHostName

Write-Host "======================================================" -ForegroundColor Green
Write-Host "  YOUR LAPS PORTAL IS READY!" -ForegroundColor Green
Write-Host "  Open the portal at:" -ForegroundColor Green
Write-Host ""
Write-Host "  --> $webAppUrl <--" -ForegroundColor Yellow
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
