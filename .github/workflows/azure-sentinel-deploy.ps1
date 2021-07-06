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

    Connect-AzAccount -ServicePrincipal -Tenant $RawCreds.tenantId -Credential $psCredential -Environment $Env:cloudEnv | out-null;
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

if ($Env:cloudEnv -ne 'AzureCloud') {
    Write-Output "Attempting Sign In to Azure Cloud"
    ConnectAzCloud
}

Write-Output "Starting Deployment for Files in path: $Env:directory"
$MaxRetries = 3;

if (Test-Path -Path $Env:directory) {
    $totalFiles = 0;
    $totalFailed = 0;
    Get-ChildItem -Path $Env:directory -Recurse -Filter *.json |
    ForEach-Object {
        $CurrentFile = $_.FullName
        $totalFiles ++
        $isValid = IsValidTemplate $CurrentFile
        if (-not $isValid) {
            $totalFailed++
            return
        }
        $isSuccess = $false
        $currentAttempt = 1
        While (($currentAttempt -le $MaxRetries) -and (-not $isSuccess)) {
            Write-Output "Deploying $CurrentFile, attempt $currentAttempt of $MaxRetries"
            $currentAttempt ++
            Try {
                New-AzResourceGroupDeployment -ResourceGroupName $Env:resourceGroupName -TemplateFile $CurrentFile -workspace $Env:workspaceName
                $isSuccess = $true
            }
            Catch {        
                Write-Output "[Warning] Failed to deploy $CurrentFile with error: $_"
                $isSuccess = $false
            }
        }
        if (-not $isSuccess) {
            $totalFailed++
            Write-Output "[Warning] Unable to deploy $CurrentFile. Deployment failed after $MaxRetries unsuccessful attempts."
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