using namespace System.Net

param($Request, $TriggerMetadata)

# Get device name from query parameter
$deviceName = $Request.Query.deviceName
if (-not $deviceName) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = '{"error":"deviceName parameter is required"}'
        Headers = @{ "Content-Type" = "application/json"; "Access-Control-Allow-Origin" = "*" }
    })
    return
}

# App registration credentials - store client secret as environment variable LAPS_CLIENT_SECRET
$tenantId     = $env:LAPS_TENANT_ID
$clientId     = $env:LAPS_CLIENT_ID
$clientSecret = $env:LAPS_CLIENT_SECRET

# Log Analytics workspace credentials stored as environment variables
$lawWorkspaceId = $env:LAW_WORKSPACE_ID
$lawPrimaryKey  = $env:LAW_PRIMARY_KEY

function Send-LogAnalytics {
    param($workspaceId, $primaryKey, $logType, $body)
    try {
        $bodyJson = $body | ConvertTo-Json
        $date = [DateTime]::UtcNow.ToString("r")
        $contentLength = ([System.Text.Encoding]::UTF8.GetBytes($bodyJson)).Length
        $stringToHash = "POST`n$contentLength`napplication/json`nx-ms-date:$date`n/api/logs"
        $bytesToHash = [System.Text.Encoding]::UTF8.GetBytes($stringToHash)
        $keyBytes = [System.Convert]::FromBase64String($primaryKey)
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = $keyBytes
        $signature = [System.Convert]::ToBase64String($hmac.ComputeHash($bytesToHash))
        $headers = @{
            Authorization          = "SharedKey $workspaceId`:$signature"
            "Log-Type"             = $logType
            "x-ms-date"            = $date
            "time-generated-field" = "TimeGenerated"
        }
        Invoke-RestMethod -Uri "https://$workspaceId.ods.opinsights.azure.com/api/logs?api-version=2016-04-01" `
            -Method Post -ContentType "application/json" -Headers $headers -Body $bodyJson
        Write-Host "Audit log sent OK"
    } catch {
        Write-Host "Audit log failed: $($_.Exception.Message) - $($_.ErrorDetails.Message)"
    }
}

try {
    # Step 1: Obtain access token using client credentials flow
    Write-Host "Step 1: Obtaining access token"
    $tokenBody = @{
        grant_type    = "client_credentials"
        client_id     = $clientId
        client_secret = $clientSecret
        scope         = "https://graph.microsoft.com/.default"
    }
    $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method Post -Body $tokenBody
    $accessToken = $tokenResponse.access_token
    Write-Host "Step 1 OK"

    $headers = @{
        Authorization = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }

    # Step 2: Look up the device by display name in Entra ID
    Write-Host "Step 2: Looking up device: $deviceName"
    $deviceUri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'&`$select=id,displayName,deviceId"
    $deviceResponse = Invoke-RestMethod -Uri $deviceUri -Headers $headers -Method Get
    Write-Host "Step 2 OK: $($deviceResponse.value.Count) device(s) found"

    if (-not $deviceResponse.value -or $deviceResponse.value.Count -eq 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body = '{"error":"Device not found"}'
            Headers = @{ "Content-Type" = "application/json"; "Access-Control-Allow-Origin" = "*" }
        })
        return
    }

    $device = $deviceResponse.value[0]
    $objectId = $device.id
    $azureAdDeviceId = $device.deviceId
    Write-Host "Object ID: $objectId / AzureAD Device ID: $azureAdDeviceId"

    # Step 3: Retrieve LAPS credentials
    # Important: use /v1.0/directory/deviceLocalCredentials - NOT /beta/deviceLocalCredentials
    Write-Host "Step 3: Retrieving LAPS credentials"
    $lapsResponse = $null

    foreach ($id in @($objectId, $azureAdDeviceId)) {
        $lapsUri = "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials/$id`?`$select=id,deviceName,lastBackupDateTime,refreshDateTime,credentials"
        Write-Host "Trying: $lapsUri"
        try {
            $lapsResponse = Invoke-RestMethod -Uri $lapsUri -Headers $headers -Method Get
            Write-Host "Step 3 OK with ID: $id"
            break
        } catch {
            Write-Host "Failed with ID $id`: $($_.ErrorDetails.Message)"
        }
    }

    $callerUpn = $Request.Query.callerUpn
    if (-not $callerUpn) { $callerUpn = $Request.Headers["X-MS-CLIENT-PRINCIPAL-NAME"] }

    if (-not $lapsResponse) {
        Send-LogAnalytics -workspaceId $lawWorkspaceId -primaryKey $lawPrimaryKey -logType "LAPSPortal" -body @{
            TimeGenerated = [DateTime]::UtcNow.ToString("o")
            DeviceName    = $deviceName
            Result        = "No LAPS credentials found"
            CallerUPN     = $callerUpn
            RequestedBy   = $callerUpn
            CallerIP      = $Request.Headers["X-Forwarded-For"]
        }
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body = '{"error":"No LAPS credentials found for this device"}'
            Headers = @{ "Content-Type" = "application/json"; "Access-Control-Allow-Origin" = "*" }
        })
        return
    }

    # Decode base64 encoded password
    $cred = $lapsResponse.credentials[0]
    $password = if ($cred.passwordBase64) {
        [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($cred.passwordBase64))
    } else {
        $cred.password
    }

    $result = @{
        deviceName      = $device.displayName
        accountName     = $cred.accountName
        password        = $password
        backupDateTime  = $lapsResponse.lastBackupDateTime
        refreshDateTime = $lapsResponse.refreshDateTime
    }

    Write-Host "Result: backupDateTime=$($lapsResponse.lastBackupDateTime) refreshDateTime=$($lapsResponse.refreshDateTime)"

    # Write audit log for successful lookup
    Send-LogAnalytics -workspaceId $lawWorkspaceId -primaryKey $lawPrimaryKey -logType "LAPSPortal" -body @{
        TimeGenerated = [DateTime]::UtcNow.ToString("o")
        DeviceName    = $device.displayName
        AccountName   = $cred.accountName
        Result        = "Success"
        CallerUPN     = $callerUpn
        RequestedBy   = $callerUpn
        CallerIP      = $Request.Headers["X-Forwarded-For"]
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = ($result | ConvertTo-Json)
        Headers = @{ "Content-Type" = "application/json"; "Access-Control-Allow-Origin" = "*" }
    })

} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = "{`"error`":`"$($_.Exception.Message)`"}"
        Headers = @{ "Content-Type" = "application/json"; "Access-Control-Allow-Origin" = "*" }
    })
}