## Globals ##
$CloudEnv = $Env:cloudEnv
$ResourceGroupName = $Env:resourceGroupName
$WorkspaceName = $Env:workspaceName
$Directory = $Env:directory
$Creds = $Env:creds
$contentTypes = $Env:contentTypes
$contentTypeMapping = @{
    "AnalyticsRule"=@("Microsoft.OperationalInsights/workspaces/providers/alertRules", "Microsoft.OperationalInsights/workspaces/providers/alertRules/actions");
    "AutomationRule"=@("Microsoft.OperationalInsights/workspaces/providers/automationRules");
    "HuntingQuery"=@("Microsoft.OperationalInsights/workspaces/savedSearches");
    "Parser"=@("Microsoft.OperationalInsights/workspaces/savedSearches");
    "Playbook"=@("Microsoft.Web/connections", "Microsoft.Logic/workflows", "Microsoft.Web/customApis");
    "Workbook"=@("Microsoft.Insights/workbooks");
}
$sourceControlId = $Env:sourceControlId 

$guidPattern = '(\b[0-9a-f]{8}\b-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-\b[0-9a-f]{12}\b)'
$namePattern = '([-\w\._\(\)]+)'
$sentinelResourcePatterns = @{
    "AnalyticsRule" = "/subscriptions/$guidPattern/resourceGroups/$namePattern/providers/Microsoft.OperationalInsights/workspaces/$namePattern/providers/Microsoft.SecurityInsights/alertRules/$namePattern"
    "AutomationRule" = "/subscriptions/$guidPattern/resourceGroups/$namePattern/providers/Microsoft.OperationalInsights/workspaces/$namePattern/providers/Microsoft.SecurityInsights/automationRules/$namePattern"
    "HuntingQuery" = "/subscriptions/$guidPattern/resourceGroups/$namePattern/providers/Microsoft.OperationalInsights/workspaces/$namePattern/savedSearches/$namePattern"
    "Parser" = "/subscriptions/$guidPattern/resourceGroups/$namePattern/providers/Microsoft.OperationalInsights/workspaces/$namePattern/savedSearches/$namePattern"
    "Playbook" = "/subscriptions/$guidPattern/resourceGroups/$namePattern/providers/Microsoft.Logic/workflows/$namePattern"
    "Workbook" = "/subscriptions/$guidPattern/resourceGroups/$namePattern/providers/Microsoft.Insights/workbooks/$namePattern"
}

if ([string]::IsNullOrEmpty($contentTypes)) {
    $contentTypes = "AnalyticsRule"
}

$metadataFilePath = ".github\workflows\.sentinel\metadata.json"
@"
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "parentResourceId": {
            "type": "string"
        },
        "kind": {
            "type": "string"
        },
        "sourceControlId": {
            "type": "string"
        },
        "workspace": {
            "type": "string"
        }
    },
    "variables": {
        "metadataName": "[guid(parameters('parentResourceId'))]"
    },
    "resources": [
        {
            "type": "Microsoft.OperationalInsights/workspaces/providers/metadata",
            "apiVersion": "2021-03-01-preview",
            "name": "[concat(parameters('workspace'),'/Microsoft.SecurityInsights/',variables('metadataName'))]",
            "properties": {
                "parentId": "[parameters('parentResourceId')]",
                "kind": "[parameters('kind')]",
                "source": {
                    "kind": "SourceRepository",
                    "sourceId": "[parameters('sourceControlId')]"
                }
            }
        }
    ]
}
"@ | Out-File -FilePath $metadataFilePath 

$resourceTypes = $contentTypes.Split(",") | ForEach-Object { $contentTypeMapping[$_] } | ForEach-Object { $_.ToLower() }
$MaxRetries = 3
$secondsBetweenAttempts = 5

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
    $RawCreds = $Creds | ConvertFrom-Json

    Clear-AzContext -Scope Process;
    Clear-AzContext -Scope CurrentUser -Force -ErrorAction SilentlyContinue;
    
    Add-AzEnvironment `
        -Name $CloudEnv `
        -ActiveDirectoryEndpoint $RawCreds.activeDirectoryEndpointUrl `
        -ResourceManagerEndpoint $RawCreds.resourceManagerEndpointUrl `
        -ActiveDirectoryServiceEndpointResourceId $RawCreds.activeDirectoryServiceEndpointResourceId `
        -GraphEndpoint $RawCreds.graphEndpointUrl | out-null;

    $servicePrincipalKey = ConvertTo-SecureString $RawCreds.clientSecret.replace("'", "''") -AsPlainText -Force
    $psCredential = New-Object System.Management.Automation.PSCredential($RawCreds.clientId, $servicePrincipalKey)

    AttemptAzLogin $psCredential $RawCreds.tenantId $CloudEnv
    Set-AzContext -Tenant $RawCreds.tenantId | out-null;
}

function AttemptDeployMetadata($deploymentName, $resourceGroupName, $templateObject) {
    $deploymentInfo = $null
    try {
        $deploymentInfo = Get-AzResourceGroupDeploymentOperation -DeploymentName $deploymentName -ResourceGroupName $ResourceGroupName -ErrorAction Ignore
    }
    catch {
        Write-Host "[Warning] Unable to fetch deployment info for $deploymentName, no metadata was created for the resources in the file. Error: $_"
        return
    }
    Write-Host "[Debug] $deploymentInfo"
    $deploymentInfo | ForEach-Object {
        $resource = $_.TargetResource
        Write-Host "[Debug] getting content kinds for $resource"
        $sentinelContentKinds = GetContentKinds $resource
        Write-Host "[Debug] sentinelContentKinds $sentinelContentKinds"
        $contentKind = ToContentKind $sentinelContentKinds $templateObject
        Write-Host "[Debug] contentKind $contentKind"
        if ($null -ne $contentKind) {
            # sentinel resources detected, deploy a new metadata item for each one
            try {
                New-AzResourceGroupDeployment -Name "md-$deploymentName" -ResourceGroupName $ResourceGroupName -TemplateFile $metadataFilePath `
                    -parentResourceId $resource `
                    -kind $contentKind `
                    -sourceControlId $sourceControlId `
                    -workspace $workspaceName `
                    -ErrorAction Stop | Out-Host
                Write-Host "[Info] Created metadata metadata for $contentKind with oparent resource id $resource"
            }
            catch {
                Write-Host "[Warning] Failed to deploy metadata for $contentKind with parent resource id $resource with error $_"
            }
        }
    }
}

function GetContentKinds($resource) {
    return $sentinelResourcePatterns.Keys | Where-Object { $resource -match $sentinelResourcePatterns[$_] }
}

function ToContentKind($contentKinds, $resource, $templateObject) {
    if ($contentKinds.Count -eq 1) {
       return $contentKinds 
    }
    if ($null -ne $resource -and $resource.Contains('savedSearches')) {
       if ($templateObject.resources.properties.Category -eq "Hunting Queries") {
           return "HuntingQuery"
       }
       return "Parser"
    }
    return $null
}

function IsValidTemplate($path, $templateObject) {
    Try {
        if (DoesContainWorkspaceParam $templateObject) {
            Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile $path -workspace $WorkspaceName
        }
        else {
            Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile $path
        }

        return $true
    }
    Catch {
        Write-Host "[Warning] The file $path is not valid: $_"
        return $false
    }
}

function IsRetryable($deploymentName) {
    $retryableStatusCodes = "Conflict","TooManyRequests","InternalServerError","DeploymentActive"
    Try {
        $deploymentResult = Get-AzResourceGroupDeploymentOperation -DeploymentName $deploymentName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        return $retryableStatusCodes -contains $deploymentResult.StatusCode
    }
    Catch {
        return $false
    }
}

function IsValidResourceType($template) {
    $isAllowedResources = $true
    $template.resources | ForEach-Object { 
        $isAllowedResources = $resourceTypes.contains($_.type.ToLower()) -and $isAllowedResources
    }
    return $isAllowedResources
}

function DoesContainWorkspaceParam($templateObject) {
    $templateObject.parameters.PSobject.Properties.Name -contains "workspace"
}

function AttemptDeployment($path, $deploymentName, $templateObject) {
    Write-Host "[Info] Deploying $path with deployment name $deploymentName"

    $isValid = IsValidTemplate $path $templateObject
    if (-not $isValid) {
        return $false
    }
    $isSuccess = $false
    $currentAttempt = 0
    While (($currentAttempt -lt $MaxRetries) -and (-not $isSuccess)) 
    {
        $currentAttempt ++
        Try 
        {
            if (DoesContainWorkspaceParam $templateObject) 
            {
                New-AzResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $path -workspace $workspaceName -ErrorAction Stop | Out-Host
            }
            else 
            {
                New-AzResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $path -ErrorAction Stop | Out-Host
            }
            AttemptDeployMetadata $deploymentName $ResourceGroupName $templateObject

            $isSuccess = $true
        }
        Catch [Exception] 
        {
            $err = $_
            if (-not (IsRetryable $deploymentName)) 
            {
                Write-Host "[Warning] Failed to deploy $path with error: $err"
                break
            }
            else 
            {
                if ($currentAttempt -le $MaxRetries) 
                {
                    Write-Host "[Warning] Failed to deploy $path with error: $err. Retrying in $secondsBetweenAttempts seconds..."
                    Start-Sleep -Seconds $secondsBetweenAttempts
                }
                else
                {
                    Write-Host "[Warning] Failed to deploy $path after $currentAttempt attempts with error: $err"
                }
            }
        }
    }
    return $isSuccess
}

function GenerateDeploymentName() {
    $randomId = [guid]::NewGuid()
    return "Sentinel_Deployment_$randomId"
}

function main() {
    if ($CloudEnv -ne 'AzureCloud') 
    {
        Write-Output "Attempting Sign In to Azure Cloud"
        ConnectAzCloud
    }

    Write-Output "Starting Deployment for Files in path: $Directory"

    if (Test-Path -Path $Directory) 
    {
        $totalFiles = 0;
        $totalFailed = 0;
        Get-ChildItem -Path $Directory -Recurse -Filter *.json |
        ForEach-Object {
            $path = $_.FullName
	        try {
	            $totalFiles ++
                $templateObject = Get-Content $path | Out-String | ConvertFrom-Json
                if (-not (IsValidResourceType $templateObject))
                {
                    Write-Output "[Warning] Skipping deployment for $path. The file contains resources for content that was not selected for deployment. Please add content type to connection if you want this file to be deployed."
                    return
                }
                $deploymentName = GenerateDeploymentName
                $isSuccess = AttemptDeployment $_.FullName $deploymentName $templateObject
                if (-not $isSuccess) 
                {
                    $totalFailed++
                }
            }
	        catch {
                $totalFailed++
                Write-Host "[Error] An error occurred while trying to deploy file $path. Exception details: $_"
                Write-Host $_.ScriptStackTrace
            }
	    }
        if ($totalFiles -gt 0 -and $totalFailed -gt 0) 
        {
            $err = "$totalFailed of $totalFiles deployments failed."
            Throw $err
        }
    }
    else 
    {
        Write-Output "[Warning] $Directory not found. nothing to deploy"
    }
}

main