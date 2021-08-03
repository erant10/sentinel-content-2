function AttemptAzLogin($psCredential, $tenantId, $cloudEnv) {
    $maxLoginRetries = 3
    $delayInSeconds = 30
    $retryCount = 1
    $stopTrying = $false
    do {
        try {
            Connect-AzAccount -ServicePrincipal -Tenant $tenantId -Credential $psCredential -Environment $cloudEnv | out-null;
            Write-Host "Login Successful"
            $stopTrying = $true
        }
        catch {
            if ($retryCount -ge $maxLoginRetries) {
                Write-Host "Login failed after $maxLoginRetries attempts."
                $stopTrying = $true
            }
            else {
                Write-Host "Login attempt failed, retrying in $delayInSeconds seconds."
                Start-Sleep -Seconds $delayInSeconds
                $retryCount++
            }
        }
    }
    while (-not $stopTrying)
}

function ConnectAzCloud {
    $RawCreds = $Env:creds | ConvertFrom-Json

    Clear-AzContext -Scope Process;
    Clear-AzContext -Scope CurrentUser -Force -ErrorAction SilentlyContinue;
    
    Add-AzEnvironment `
        -Name $Env:cloudEnv `
        -ActiveDirectoryEndpoint $RawCreds.activeDirectoryEndpointUrl `
        -ResourceManagerEndpoint $RawCreds.resourceManagerEndpointUrl `
        -ActiveDirectoryServiceEndpointResourceId $RawCreds.activeDirectoryServiceEndpointResourceId `
        -GraphEndpoint $RawCreds.graphEndpointUrl | out-null;

    $servicePrincipalKey = ConvertTo-SecureString $RawCreds.clientSecret.replace("'", "''") -AsPlainText -Force
    $psCredential = New-Object System.Management.Automation.PSCredential($RawCreds.clientId, $servicePrincipalKey)

    AttemptAzLogin $psCredential $RawCreds.tenantId $Env:cloudEnv
    Set-AzContext -Tenant $RawCreds.tenantId | out-null;
}

function IsValidTemplate($path) {
    Try {
        Test-AzResourceGroupDeployment -ResourceGroupName $Env:resourceGroupName -TemplateFile $path -workspace $Env:workspaceName
        return $true
    }
    Catch {
        Write-Host "[Warning] The file $path is not valid: $_"
        return $false
    }
}

function IsTransient($statusMessage) {
    $transientErrors = "AllocationFailed","AnotherOperationInProgress","Conflict","DeploymentActiveAndUneditable","DeploymentFailed"
    return $transientErrors -contains $statusMessage
}

function AttemptDeployment($path, $deploymentName) {
    $isValid = IsValidTemplate $path
    if (-not $isValid) {
        return $false
    }
    $isSuccess = $false
    $MaxRetries = 3
    $currentAttempt = 1
    While (($currentAttempt -le $MaxRetries) -and (-not $isSuccess)) {
        $currentAttempt ++
        Try {
            New-AzResourceGroupDeployment -ResourceGroupName $Env:resourceGroupName -TemplateFile $path -workspace $Env:workspaceName
            $isSuccess = $true
        }
        Catch {
            $deploymentResult = Get-AzResourceGroupDeploymentOperation -DeploymentName $deploymentName -ResourceGroupName $Env:resourceGroupName
            if (-not IsTransient $deploymentResult.Properties.statusMessage) {
                Write-Output "[Warning] Failed to deploy $path with error: $_"
                break
            }
            Write-Output "[Warning] Failed to deploy $path with error: $_. Retrying..."
        }
    }
    return $isSuccess
}

function main() {
    if ($Env:cloudEnv -ne 'AzureCloud') {
        Write-Output "Attempting Sign In to Azure Cloud"
        ConnectAzCloud
    }

    Write-Output "Starting Deployment for Files in path: $Env:directory"

    if (Test-Path -Path $Env:directory) {
        $totalFiles = 0;
        $totalFailed = 0;
        Get-ChildItem -Path $Env:directory -Recurse -Filter *.json |
        ForEach-Object {
            $totalFiles ++
            $isSuccess = AttemptDeployment $_.FullName $_.Name
            if (-not $isSuccess) {
                $totalFailed++
            }
        }
        if ($totalFiles -gt 0 -and $totalFailed -gt 0) {
            $error = "$totalFailed of $totalFiles deployments failed."
            Throw $error
        }
    }
    else {
        Write-Output "[Warning] $Env:directory not found. nothing to deploy"
    }
}

main