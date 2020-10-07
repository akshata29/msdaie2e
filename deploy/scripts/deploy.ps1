##################################################################
#                                                                #
#   Setup Script                                                 #
#                                                                #
#   Spins up azure resources for Microsoft Data and AI Platform  #
##################################################################


#----------------------------------------------------------------#
#   Parameters                                                   #
#----------------------------------------------------------------#
Param (
    [Parameter(Mandatory=$true)]
    [string]$uniqueName = "default", 
	[Parameter(Mandatory=$true)]
    [string]$subscriptionId = "default",
	[Parameter(Mandatory=$true)]
    [string]$location = "default",
	[Parameter(Mandatory=$true)]
	[string]$resourceGroupName = "default",
	$executeAdf = $true,
	$executeAdb = $false,
	$executeAml = $false,
	$executeStagingLoad = $false,
	$executeCopyStaging = $false,
	$deployAdf = $false
)

#$executeAdf = $false
#$executeAdb = $true
#$executeAml = $false
#$executeStagingLoad = $false
#$deployAdf = $false

#$location = "eastus"
#$uniqueName = "msdaiete"
if($uniqueName -eq "default")
{
    Write-Error "Please specify a unique name."
    break;
}

if($uniqueName.Length -gt 17)
{
    Write-Error "The unique name is too long. Please specify a name with less than 17 characters."
}

if($uniqueName -Match "-")
{
	Write-Error "The unique name should not contain special characters"
}

if($location -eq "default")
{
	while ($TRUE) {
		try {
			$location = Read-Host -Prompt "Input Location(westus, eastus, centralus, southcentralus): "
			break  
		}
		catch {
				Write-Error "Please specify a resource group name."
		}
	}
}

Function Pause ($Message = "Press any key to continue...") {
   # Check if running in PowerShell ISE
   If ($psISE) {
      # "ReadKey" not supported in PowerShell ISE.
      # Show MessageBox UI
      New-Object -ComObject "WScript.Shell"
      Return
   }
 
   $Ignore =
      16,  # Shift (left or right)
      17,  # Ctrl (left or right)
      18,  # Alt (left or right)
      20,  # Caps lock
      91,  # Windows key (left)
      92,  # Windows key (right)
      93,  # Menu key
      144, # Num lock
      145, # Scroll lock
      166, # Back
      167, # Forward
      168, # Refresh
      169, # Stop
      170, # Search
      171, # Favorites
      172, # Start/Home
      173, # Mute
      174, # Volume Down
      175, # Volume Up
      176, # Next Track
      177, # Previous Track
      178, # Stop Media
      179, # Play
      180, # Mail
      181, # Select Media
      182, # Application 1
      183  # Application 2
 
   Write-Host -NoNewline $Message -ForegroundColor Red
   While ($Null -eq $KeyInfo.VirtualKeyCode  -Or $Ignore -Contains $KeyInfo.VirtualKeyCode) {
      $KeyInfo = $Host.UI.RawUI.ReadKey("NoEcho, IncludeKeyDown")
   }
}

$uniqueName = $uniqueName.ToLower();

# prefixes
$prefix = $uniqueName

if ( $resourceGroupName -eq 'default' ) {
	$resourceGroupName = $prefix
}

if ($ScriptRoot -eq "" -or $null -eq $ScriptRoot ) {
	$ScriptRoot = (Get-Location).path
}

#----------------------------------------------------------------#
#   Setup - Azure Subscription Login							 #
#----------------------------------------------------------------#
$ErrorActionPreference = "Stop"
#Install-Module AzureRM.Sql -Force
#Install-Module -Name azure.databricks.cicd.tools -MinimumVersion 2.1.2915 -Force
#Install-Module -Name SqlServer -Force
#Install-Module -Name Az.Resources -Force
#Install-Module -Name Az -AllowClobber -Force

Import-Module -Name azure.databricks.cicd.tools -MinimumVersion 2.1.2915 -Force
Import-Module -Name SqlServer -Force
Import-Module -Name Az.Resources -Force

# Sign In
Write-Host Logging in... -ForegroundColor Green
try {
	Get-AzContext
}
catch {
	Connect-AzAccount
}

if($subscriptionId -eq "default"){
	# Set Subscription Id
	while ($TRUE) {
		try {
			$subscriptionId = Read-Host -Prompt "Input subscription Id"
			break  
		}
		catch {
			Write-Host Invalid subscription Id. -ForegroundColor Green `n
		}
	}
}

$context = Get-AzSubscription -SubscriptionId $subscriptionId
Set-AzContext @context

$tenantId = $context.TenantId
$subscriptionName = $context.Name

$subscriptionName

Enable-AzContextAutosave -Scope CurrentUser
$index = 0
$numbers = "123456789"
foreach ($char in $subscriptionId.ToCharArray()) {
    if ($numbers.Contains($char)) {
        break;
    }
    $index++
}
$id = $subscriptionId.Substring($index, $index + 5)

Write-Host Unique Id $id... -ForegroundColor Green

#----------------------------------------------------------------#
#   Step 1 - Register Resource Providers and Resource Group		 #
#----------------------------------------------------------------#

$resourceProviders = @(
    "microsoft.documentdb",
    "microsoft.insights",
    "microsoft.sql",
    "microsoft.storage",
    "microsoft.databricks"
)
	
Write-Host Registering resource providers: -ForegroundColor Green`n 
foreach ($resourceProvider in $resourceProviders) {
    Write-Host - Registering $resourceProvider -ForegroundColor Green
	Register-AzResourceProvider `
            -ProviderNamespace $resourceProvider
}

# Create Resource Group 
Write-Host `nCreating Resource Group $resourceGroupName"..." -ForegroundColor Green `n
try {
		Get-AzResourceGroup `
			-Name $resourceGroupName `
			-Location $location `
	}
catch {
		New-AzResourceGroup `
			-Name $resourceGroupName `
			-Location $location `
			-Force
	}

#----------------------------------------------------------------#
#   Step 2 - Storage Account & Containers						 #
#----------------------------------------------------------------#
# Create Storage Account
# storage resources
$storageAccountName = $prefix + "sa";
$storageContainerNycTaxi = "nyctaxi"

Write-Host Creating storage account... -ForegroundColor Green

try {
        $storageAccount = Get-AzStorageAccount `
            -ResourceGroupName $resourceGroupName `
            -AccountName $storageAccountName
    }
    catch {
        $storageAccount = New-AzStorageAccount `
            -AccountName $storageAccountName `
            -ResourceGroupName $resourceGroupName `
            -Location $location `
            -SkuName Standard_LRS `
			-Kind StorageV2 `
			-EnableHierarchicalNamespace $true `
			-EnableHttpsTrafficOnly $true
    }
$storageAccount
$storageContext = $storageAccount.Context
Start-Sleep -s 1

# Create Storage Containers
Write-Host Creating blob containers... -ForegroundColor Green
$storageContainerNames = @($storageContainerNycTaxi)
foreach ($containerName in $storageContainerNames) {
	 $storageAccount = Get-AzStorageAccount `
            -ResourceGroupName $resourceGroupName `
            -Name $storageAccountName
        $storageContext = $storageAccount.Context
        try {
            Get-AzStorageContainer `
                -Name $containerName `
                -Context $storageContext
        }
        catch {
            New-AzStoragecontainer `
                -Name $containerName `
                -Context $storageContext `
                -Permission container
        }
}

# Get Account Key and connection string
$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageAccountName).Value[0]
#$storageAccountConnectionString = 'DefaultEndpointsProtocol=https;AccountName=' + $storageAccountName + ';AccountKey=' + $storageAccountKey + ';EndpointSuffix=core.windows.net' 
$storageAccountV2Url = 'https://' + $storageAccountName + '.dfs.core.windows.net'

$referenceDataFilePath = "$ScriptRoot\..\referencedata\"

$files = Get-ChildItem $referenceDataFilePath
foreach($file in $files){
	$filePath = $referenceDataFilePath + $file.Name
	$blobFileName = 'nyctaxi-staging/reference-data/' + $file.Name
	Write-Host Upload File $filePath to $blobFileName -ForegroundColor Green
	Set-AzStorageBlobContent `
		-File $filePath `
		-Container $storageContainerNycTaxi `
		-Blob  $blobFileName `
		-Context $storageContext `
		-Force
}

#----------------------------------------------------------------#
#   Step 3 - SQL Server and DB									 #
#----------------------------------------------------------------#
Write-Host Create SQL Server and Database ... -ForegroundColor Green

$sqlServerName = $prefix + 'sqlsvr'
$sqlUserName = 'azureadmin'
$sqlPassword = 'p@$$w0rd1!'
$sqlCredential = $(New-Object -TypeName System.Management.Automation.PSCredential `
				-ArgumentList $sqlUserName, $(ConvertTo-SecureString -String $sqlPassword -AsPlainText -Force))

#Parameters for Firewall rules
$fwRuleName = "AllowedIps"
$startIpAddress = "0.0.0.0"
$endIpAddress = "255.255.255.255"

#Parameters for Azure SQL Database
#$sqlDbName="nyctaxihive"
$sqlDbName = $prefix + "hive"
$sqlDbSize="S0"

try {
	$sqlServer = Get-AzSqlServer `
		-ResourceGroupName $resourceGroupName `
		-ServerName $sqlServerName
}
catch {
	$sqlServer = New-AzSqlServer `
		-ServerName $sqlServerName `
		-ResourceGroupName $resourceGroupName `
		-Location $location `
		-ServerVersion "12.0" `
		-SqlAdministratorCredentials $sqlCredential
}

$sqlServer

try {
	$sqlDb = Get-AzSqlDatabase `
		-ResourceGroupName $resourceGroupName `
		-ServerName $sqlServerName `
		-DatabaseName $sqlDbName
}
catch {
	$sqlDb = New-AzSqlDatabase `
			-DatabaseName $sqlDbName `
			-ResourceGroupName $resourceGroupName `
			-ServerName $sqlServerName `
			-RequestedServiceObjectiveName $sqlDbSize
}

$sqlDb

#Enable firewall IP Addresses (All IP addresses just for testing/tutorial purposes)
try
{
	Get-AzSqlServerFirewallRule `
		-FirewallRuleName $fwRuleName `
		-ResourceGroupName $resourceGroupName `
		-ServerName $sqlServerName
}
catch{
	New-AzSqlServerFirewallRule `
		-FirewallRuleName $fwRuleName `
		-StartIpAddress $startIpAddress `
		-EndIpAddress $endIpAddress `
		-ResourceGroupName $resourceGroupName `
		-ServerName $sqlServerName
}
#Get server name (FQDN) to connect
$sqlDomain = Get-AzSqlServer -ServerName $sqlServerName `
	-ResourceGroupName $resourceGroupName | Select-Object FullyQualifiedDomainName

$sqlDomain

# Execute the script file to create all Hive related tables ( for external metastore )
try
{
	Write-Host Import Hive SQL Tables ... -ForegroundColor Green
	Invoke-Sqlcmd `
		-ServerInstance $sqlDomain.FullyQualifiedDomainName `
		-Database $sqlDbName `
		-Username $sqlUserName `
		-Password $sqlPassword `
		-InputFile "$ScriptRoot\..\templates\hiveTables.sql"
}
catch
{
	Write-Host Re Deploying, so skip the hive SQL Table reimport ... -ForegroundColor Green
}

#----------------------------------------------------------------#
#   Step 4 - Create Service Principal and permissions	 		 #
#----------------------------------------------------------------#

# Create new Service Principal
$adbScope = "/subscriptions/" + $subscriptionId + "/resourceGroups/" + $resourceGroupName
$spnName = "http://" + $resourceGroupName
$adbSp = Get-AzADServicePrincipal -DisplayName $resourceGroupName
			
if ( $null -eq $adbSp )
{
	Write-Host Create New Service Principal ... -ForegroundColor Green
	$adbSp = New-AzADServicePrincipal `
		-Scope $adbScope `
		-DisplayName $resourceGroupName

	$bStr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($adbSp.Secret)
	$spnSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bStr)
	$spnAppId = $adbSp.ApplicationId.Guid
	$spnTenantId = (Get-AzContext).Tenant.Id
	
	Start-Sleep 45
	try {
		# Grant permission as Contributor at RG level
		New-AzRoleAssignment -ApplicationId $spnAppId `
			-RoleDefinitionName "Contributor" `
			-Scope  $adbScope
	}
	catch {
		Write-Host Assigned Permission ... -ForegroundColor Green	
	}
	

}
else {
	
	Write-Host Get existing Service Principal ... -ForegroundColor Green
	$spnAppId = $adbSp.ApplicationId.Guid
	#13a8dc13-a751-4099-9c53-6deea6ce24a1
	$spnTenantId = (Get-AzContext).Tenant.Id
	#72f988bf-86f1-41af-91ab-2d7cd011db47
	$adbSp1 = New-AzADSpCredential -ServicePrincipalName $spnName
	$bStr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($adbSp1.Secret)
	$spnSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bStr)
	#ae93f4d9-e79e-4c12-97ae-910b5c3d35fd
	Start-Sleep 45

}

Write-Host Service Principal AppId $spnAppId... -ForegroundColor Green
Write-Host Service Principal Name $spnName... -ForegroundColor Green
Write-Host Service Principal Secret $spnSecret... -ForegroundColor Green

# Grant Service principal Contributor access to ADLS ( or use Pass Through Authentication )
# Get ObjectId
$adlsScope = $adbScope + "/providers/Microsoft.Storage/storageAccounts/" + $storageAccountName + "/blobServices/default/containers/" + $storageContainerNycTaxi
Write-Host Get Role Assignment - $adlsScope ... -ForegroundColor Green
$roleAssgn = Get-AzRoleAssignment -ServicePrincipalName $spnName -Scope $adlsScope

try 
{
	New-AzRoleAssignment -ApplicationId $spnAppId `
	-RoleDefinitionName "Storage Blob Data Contributor" `
	-Scope  $adlsScope
}
catch
{
Write-Host Permission already assigned 
}

#----------------------------------------------------------------#
#   Step 5 - Create Azure Databricks Workspace 			 		 #
#----------------------------------------------------------------#

$adbParamTemplateFilePath = "$ScriptRoot\..\templates\adbtpl.json"
$adbParamFilePath = "$ScriptRoot\..\templates\adbparameters.json"
$adbWsName = $prefix + "adb"

$adbParamTemplate = Get-Content $adbParamFilePath | ConvertFrom-Json
$adbParameters = $adbParamTemplate.parameters
$adbParameters.nsgName.value = $prefix + "nsg"
$adbParameters.vnetName.value = $prefix + "vnet"
$adbParameters.workspaceName.value = $adbWsName
$adbParameters.privateSubnetName.value = $prefix + "prvnet"
$adbParameters.publicSubnetName.value = $prefix + "pbvnet"
$adbParameters.pricingTier.value = "premium"
$adbParameters.location.value = $location
$adbParameters.vnetCidr.value = "10.179.0.0/16"
$adbParameters.privateSubnetCidr.value = "10.179.0.0/18"
$adbParameters.publicSubnetCidr.value = "10.179.64.0/18"
$adbParamTemplate | ConvertTo-Json | Out-File $adbParamFilePath

Write-Host Verify databricks was created  ... -ForegroundColor Green
$existingadbWs = Get-AzResource `
		-ResourceGroupName $resourceGroupName `
		-ResourceType 'Microsoft.Databricks/workspaces'

if ( $null -eq $existingadbWs.Name)
{
	Write-Host Deploying Azure Databricks workspace ... -ForegroundColor Green
	$adbWorkspace = New-AzResourceGroupDeployment `
			-ResourceGroupName $resourceGroupName `
			-TemplateFile $adbParamTemplateFilePath `
			-TemplateParameterFile $adbParamFilePath

	Start-Sleep 150
	$adbWorkspace
}

$adbWsScope = $adbScope + "/providers/Microsoft.Databricks/workspaces/" + $adbWsName
Write-Host Get Role Assignment - $adlsScope ... -ForegroundColor Green
$roleAssgnadbWs = Get-AzRoleAssignment -ServicePrincipalName $spnName -Scope $adbWsScope

if ( $null -eq $roleAssgnadbWs )
{
	Write-Host Assign Role to databricks workspace... -ForegroundColor Green
	New-AzRoleAssignment -ApplicationId $spnAppId `
    -RoleDefinitionName "Contributor" `
	-Scope  $adbWsScope
}

#----------------------------------------------------------------#
#   Step 5 - Create Azure Databricks Cluster with Advance Config #
#----------------------------------------------------------------#

# Connect to Databricks
while ($true)
{
	try {
		Write-Host Connect to Databricks ... -ForegroundColor Green
		Connect-Databricks `
			-Region $location `
			-ApplicationId $spnAppId `
			-Secret $spnSecret `
			-ResourceGroupName $resourceGroupName `
			-SubscriptionId $subscriptionId `
			-WorkspaceName $adbWsName `
			-TenantId $spnTenantId
		break;
	}
	catch {
		Start-Sleep 30
	}
}
$sConfig = @{}
$sConfig.Add("datanucleus.schema.autoCreateAll", $true)
$sConfig.Add("spark.hadoop.hive.metastore.schema.verification", $false)
$sConfig.Add("datanucleus.autoCreateSchema", $true)
$sConfig.Add("spark.sql.hive.metastore.jars","maven")
$sConfig.Add("javax.jdo.option.ConnectionDriverName", "com.microsoft.sqlserver.jdbc.SQLServerDriver")
$sConfig.Add("spark.sql.hive.metastore.version", "2.3.0")
$jdbcUrl = "jdbc:sqlserver://" + $sqlDomain.FullyQualifiedDomainName + ":1433;database=" + $sqlDbName + ";encrypt=true;trustServerCertificate=true;loginTimeout=300" 
$sConfig.Add("spark.hadoop.javax.jdo.option.ConnectionURL",$jdbcUrl)
$sConfig.Add("datanucleus.fixedDatastore", $false)
$sConfig.Add("spark.hadoop.javax.jdo.option.ConnectionUserName", $sqlUserName)
$sConfig.Add("spark.hadoop.javax.jdo.option.ConnectionPassword", $sqlPassword)

$adbClusterName ="externalhive"
$sparkVersion="7.0.x-scala2.12"
$nodeType="Standard_D3_v2"
$minWorkers=1
$maxWorkers=4
$autoTermination = 15
$pythonVersion = 3

$existingCluster = Get-DatabricksClusters
if ( $null -eq $existingCluster )
{
	Write-Host Cluster Not found. Create new Cluster ... -ForegroundColor Green
	Start-Sleep 150

	$clusterId = New-DatabricksCluster `
					-ClusterName $adbClusterName `
					-SparkVersion $sparkVersion `
					-NodeType $nodeType `
					-MinNumberOfWorkers $minWorkers `
					-MaxNumberOfWorkers $maxWorkers `
					-Spark_conf $sConfig `
					-AutoTerminationMinutes $autoTermination `
					-Verbose `
					-PythonVersion $pythonVersion `
					-UniqueNames `
					-Update
					
	Write-Host Databricks ClusterId new1  $clusterId.cluster_id... -ForegroundColor Green
do {
	Start-Sleep 30
	$existingCluster = Get-DatabricksClusters
	Write-Host Databricks new cluster  $existingCluster.cluster_id... -ForegroundColor Yellow
	
} while ($null -eq $existingCluster)

	$dbClusterId = $existingCluster.cluster_id
}
else 
{
	Write-Host Cluster Found ... -ForegroundColor Green
	$existingClusterName = $existingCluster.cluster_name
	$dbClusterId = $existingCluster.cluster_id

	if ( $existingClusterName -ne $adbClusterName)
	{
		Write-Host Cluster Found but not matching ... -ForegroundColor Green
		$clusterId = New-DatabricksCluster `
						-ClusterName $adbClusterName `
						-SparkVersion $sparkVersion `
						-NodeType $nodeType `
						-MinNumberOfWorkers $minWorkers `
						-MaxNumberOfWorkers $maxWorkers `
						-Spark_conf $sConfig `
						-AutoTerminationMinutes $autoTermination `
						-Verbose `
						-PythonVersion $pythonVersion `
						-UniqueNames `
						-Update

		$dbClusterId = $clusterId.cluster_id
	}
	else {
		$existingCluster = Get-DatabricksClusters
		$existingClusterName = $existingCluster.cluster_name
		$dbClusterId = $existingCluster.cluster_id
	}
}

Write-Host Databricks ClusterId $dbClusterId... -ForegroundColor Green

# Currently we have to manually enable the pass through authentication as API or PS is not available
# https://docs.microsoft.com/en-us/azure/databricks/data/data-sources/azure/adls-passthrough

# Below command is not working, TBD
# Start the Cluster
#Start-DatabricksCluster `
#	-Region $location `
#	-ClusterName $adbClusterName

#if ($executeAdf -eq $true)
#{
	# Get Bearer Token for ADF Connection
	Write-Host Create Bearer Token - ADF related ... -ForegroundColor Green
	$adbToken = New-DatabricksBearerToken -LifetimeSeconds 31536000 -Comment "ADF Token"
	$adbTokenValue = $adbToken.token_value
	Write-Host ADB Bearer Token $adbTokenValue... -ForegroundColor Green
	#dapi07c5c5b865e6e6274152305c319df8fb
	$adbTokenId = $adbToken.token_info.token_id
	Write-Host ADB Bearer Id $adbTokenId... -ForegroundColor Green
#}

# Import the Databricks Notebooks & Folders
$ImportPath = "/Shared/msdaie2e"

$dbcContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$ScriptRoot\..\notebooks\msdaie2e.dbc"))

Write-Host Import Databricks Notebooks ... -ForegroundColor Green
$ImportBody = @{path= $ImportPath;format="DBC"; content=$dbcContent}
try
{
	$ImportPost = Invoke-DatabricksAPI -API "api/2.0/workspace/import" -Method POST -Body $ImportBody
	$ImportPost
}
catch
{
	Write-Host Overwrite on Databricks Notebooks not available, continuing... -ForegroundColor Green
}

#----------------------------------------------------------------#
#Step 6 - Create ADF, connection, Pipeline, dataflow and datasets#
#----------------------------------------------------------------#
# Pipeline for Copying source data to Staging Zone
# Create Linked Service for Http
$dfName = $prefix + "adf";

if ($deployAdf  -eq $true)
{
	Write-Host Create ADF v2 ... -ForegroundColor Green

	try {
		Get-AzDataFactoryV2 `
			-ResourceGroupName $resourceGroupName `
			-Name $dfName
	}
	catch {
		Set-AzDataFactoryV2 `
			-ResourceGroupName $resourceGroupName `
			-Location $location `
			-Name $dfName
	}

	$msAdbRegion = "https://" + $location + ".azuredatabricks.net"
	$deAdfTemplateFilePath = "$ScriptRoot\..\datafactory\detemplate\detemplate.json"
	$deAdfParametersFilePath = "$ScriptRoot\..\datafactory\detemplate\deparameters.json"
	$deAdfParametersTemplate = Get-Content $deAdfParametersFilePath | ConvertFrom-Json
	$deAdfParameters = $deAdfParametersTemplate.parameters
	$deAdfParameters.factoryName.value = $dfName
	$deAdfParameters.msdaieteir.value =  "msdaieteir"
	$deAdfParameters.nycTaxiAccountKey.value = $storageAccountKey
	$deAdfParameters.nycTaxiadbToken.value = $adbTokenValue
	$deAdfParameters.nycTaxiStorageUrl.value = $storageAccountV2Url
	$deAdfParameters.adbClusterId.value = $dbClusterId
	$deAdfParameters.msadbregion.value = $msAdbRegion
	$deAdfParameters.nycTaxiSourceStorageUrl.value = 'https://msdataaisa.dfs.core.windows.net'
	$deAdfParameters.nycTaxiSourceAccountKey.value = ""
	$deAdfParametersTemplate | ConvertTo-Json | Out-File $deAdfParametersFilePath

	$deAdfParameters

	Write-Host Deploying $dfName"..." -ForegroundColor Green
	New-AzResourceGroupDeployment `
			-ResourceGroupName $resourceGroupName `
			-Name $dfName `
			-TemplateFile $deAdfTemplateFilePath `
			-TemplateParameterFile $deAdfParametersFilePath
}

#----------------------------------------------------------------#
#   Step 7 - Execute ADF Pipelines in sequence					 #
#----------------------------------------------------------------#
# Connect to Databricks
Connect-Databricks `
	-Region $location `
	-ApplicationId $spnAppId `
	-Secret $spnSecret `
	-ResourceGroupName $resourceGroupName `
	-SubscriptionId $subscriptionId `
	-WorkspaceName $adbWsName `
	-TenantId $spnTenantId

$jobTimeOut = 1000
$maxRetries = 0
$notebookPathStep0 = "/Shared/msdaie2e/adb/0_Common/0_Setup"
$notebookParamStep0 = '{"clientId": "' + $spnAppId + '"' `
				+ ', "tenantId": "' + $spnTenantId + '"' `
				+ ', "clientSecret": "' + $spnSecret + '"' `
				+ ', "storageName": "' + $storageAccountName + '"' `
				+ ', "fileRoot": "' + $storageContainerNycTaxi + '"' `
				+ '}'
# Execute 0-Setup Notebook
$step0RunId = Add-DatabricksNotebookJob `
			-JobName "setup" `
			-Timeout $jobTimeOut `
			-MaxRetries $maxRetries `
			-NotebookPath $notebookPathStep0 `
			-NotebookParametersJson $notebookParamStep0 `
			-ClusterId $dbClusterId 

Write-Host Run $notebookPathStep0 Notebook.  It takes few minutes ... -ForegroundColor Green

Start-DatabricksJob -JobId $step0RunId

if ($executeCopyStaging  -eq $true)
{
	# Run the Green Taxi Copy to Staging Pipeline
	$copySourceToStaging = "0_CopySourceToStaging"

	Write-Host Run $copySourceToStaging pipeline.  It takes about 5 minutes ... -ForegroundColor Green

	$parameters = @{
		"SourceFileFolder" = "nyctaxi"
		"DestinationFileFolder" = "nyctaxi"
	}

	$step0CopyRunId = Invoke-AzDataFactoryV2Pipeline `
	-DataFactoryName $dfName `
	-ResourceGroupName $resourceGroupName `
	-PipelineName $copySourceToStaging `
	-Parameter $parameters

	while ($True) {
		$copyRun = Get-AzDataFactoryV2PipelineRun `
			-ResourceGroupName $resourceGroupName `
			-DataFactoryName $dfName `
			-PipelineRunId $step0CopyRunId

		if ($copyRun) {
			if ($copyRun.Status -ne 'InProgress') {
				Write-Output ("Pipeline run finished. The status is: " +  $copyRun.Status)
				$gtRun
				break
			}
			Write-Output "Pipeline is running...status: InProgress"
		}

		Start-Sleep -Seconds 10
	}
}

if ($executeStagingLoad  -eq $true)
{
	# Run the Green Taxi Copy to Staging Pipeline
	$greenTaxiCopyToStaging = "0_GreenTaxiCopyToStaging"

	Write-Host Run $greenTaxiCopyToStaging pipeline.  It takes about 20 minutes ... -ForegroundColor Green

	$step0GtRunId = Invoke-AzDataFactoryV2Pipeline `
	-DataFactoryName $dfName `
	-ResourceGroupName $resourceGroupName `
	-PipelineName $greenTaxiCopyToStaging 

	#Run the Yellow Taxi Copy to Staging Pipeline
	$yellowTaxiCopyToStaging = "0_YellowTaxiCopyToStaging"

	Write-Host Run $yellowTaxiCopyToStaging pipeline. It takes about an hour and 30 minutes ... -ForegroundColor Green

	$step0YtRunId = Invoke-AzDataFactoryV2Pipeline `
	-DataFactoryName $dfName `
	-ResourceGroupName $resourceGroupName `
	-PipelineName $yellowTaxiCopyToStaging

	# Find the information on the Pipeline Run 
	# Green Taxi takes about 13 minutes to run and Yellow Taxi about an hour
	while ($True) {
		$gtRun = Get-AzDataFactoryV2PipelineRun `
			-ResourceGroupName $resourceGroupName `
			-DataFactoryName $dfName `
			-PipelineRunId $step0YtRunId

		if ($gtRun) {
			if ($gtRun.Status -ne 'InProgress') {
				Write-Output ("Pipeline run finished. The status is: " +  $gtRun.Status)
				$gtRun
				break
			}
			Write-Output "Pipeline is running...status: InProgress"
		}

		Start-Sleep -Seconds 10
	}
	$ytStep0Run = Get-AzDataFactoryV2PipelineRun `
	-ResourceGroupName $resourceGroupName `
	-DataFactoryName $dfName `
	-PipelineRunId $step0YtRunId

	$gtStep0Run = Get-AzDataFactoryV2PipelineRun `
	-ResourceGroupName $resourceGroupName `
	-DataFactoryName $dfName `
	-PipelineRunId $step0GtRunId
}

if ($executeAdf -eq $true)
{
	
	# Step 1 - Copy the data from Staging to Raw ( CSV to Parquet )
	# Run the Reference Data Load
	$referenceDataStagingToRaw = "1_ReferenceStagingToRaw"

	Write-Host Run $referenceDataStagingToRaw pipeline. It takes about 7-9 minutes ... -ForegroundColor Green

	Invoke-AzDataFactoryV2Pipeline `
	-DataFactoryName $dfName `
	-ResourceGroupName $resourceGroupName `
	-PipelineName $referenceDataStagingToRaw

	if ( $gtStep0Run.Status -eq 'Succeeded' -or ($executeStagingLoad -eq $false))
	{
			# Run the Green Taxi Copy to Staging Pipeline
			$greenTaxiStagingToRaw = "1_GreenTaxiStagingToRaw"

			Write-Host Run $greenTaxiStagingToRaw pipeline. It takes about 15-20 Minutes ... -ForegroundColor Green

			$step1GtRunId = Invoke-AzDataFactoryV2Pipeline `
			-DataFactoryName $dfName `
			-ResourceGroupName $resourceGroupName `
			-PipelineName $greenTaxiStagingToRaw
	}

	if ( $ytStep0Run.Status -eq 'Succeeded' -or ($executeStagingLoad  -eq $false))
	{
		#Run the Yellow Taxi Copy to Staging Pipeline
		$yellowTaxiStagingToRaw = "1_YellowTaxiStagingToRaw"

		Write-Host Run $yellowTaxiStagingToRaw pipeline. It takes about 2 hour 15 minutes ... -ForegroundColor Green

		$step1YtRunId = Invoke-AzDataFactoryV2Pipeline `
		-DataFactoryName $dfName `
		-ResourceGroupName $resourceGroupName `
		-PipelineName $yellowTaxiStagingToRaw
	}
	# Find the information on the Pipeline Run 
	# Reference data takes about 7 minutes to Run
	# Green Taxi takes about 20 minutes to run and Yellow Taxi about an 2 hours 30 minutes
	while ($True) {
		$gtRun = Get-AzDataFactoryV2PipelineRun `
			-ResourceGroupName $resourceGroupName `
			-DataFactoryName $dfName `
			-PipelineRunId $step1YtRunId

		if ($gtRun) {
			if ($gtRun.Status -ne 'InProgress') {
				Write-Output ("Pipeline run finished. The status is: " +  $gtRun.Status)
				$gtRun
				break
			}
			Write-Output "Pipeline is running...status: InProgress"
		}

		Start-Sleep -Seconds 10
	}

	$gtStep1Run = Get-AzDataFactoryV2PipelineRun `
	-ResourceGroupName $resourceGroupName `
	-DataFactoryName $dfName `
	-PipelineRunId $step1GtRunId

	$ytStep1Run = Get-AzDataFactoryV2PipelineRun `
	-ResourceGroupName $resourceGroupName `
	-DataFactoryName $dfName `
	-PipelineRunId $step1YtRunId

	# Step 2 - Raw zone to Curated Zone
	# Run the Green Taxi Raw to Curated Pipeline
	if ( $gtStep1Run.Status -eq 'Succeeded')
	{
		$greenTaxiRawToCurated = "2_GreenTaxiRawToCurated"

		Write-Host Run $greenTaxiRawToCurated pipeline. It takes about 30-35 minutes ... -ForegroundColor Green

		$step2GtRunId = Invoke-AzDataFactoryV2Pipeline `
		-DataFactoryName $dfName `
		-ResourceGroupName $resourceGroupName `
		-PipelineName $greenTaxiRawToCurated
	}

	if ( $ytStep1Run.Status -eq 'Succeeded')
	{
		#Run the Yellow Taxi Copy to Staging Pipeline
		$yellowTaxiRawToCurated = "2_YellowTaxiRawToCurated"

		Write-Host Run $yellowTaxiRawToCurated pipeline. It takes about 5 hours 10 minutes ... -ForegroundColor Green

		$step2YtRunId = Invoke-AzDataFactoryV2Pipeline `
		-DataFactoryName $dfName `
		-ResourceGroupName $resourceGroupName `
		-PipelineName $yellowTaxiRawToCurated
	}

	# Find the information on the Pipeline Run 
	# Green Taxi takes about 50 minutes to run and Yellow Taxi about an 3 hours 10 minutes
	while ($True) {
		$gtRun = Get-AzDataFactoryV2PipelineRun `
			-ResourceGroupName $resourceGroupName `
			-DataFactoryName $dfName `
			-PipelineRunId $step2YtRunId

		if ($gtRun) {
			if ($gtRun.Status -ne 'InProgress') {
				Write-Output ("Pipeline run finished. The status is: " +  $gtRun.Status)
				$gtRun
				break
			}
			Write-Output "Pipeline is running...status: InProgress"
		}

		Start-Sleep -Seconds 10
	}

	$gtStep2Run = Get-AzDataFactoryV2PipelineRun `
	-ResourceGroupName $resourceGroupName `
	-DataFactoryName $dfName `
	-PipelineRunId $step2GtRunId

	$ytStep2Run = Get-AzDataFactoryV2PipelineRun `
	-ResourceGroupName $resourceGroupName `
	-DataFactoryName $dfName `
	-PipelineRunId $step2YtRunId

	if ( $ytStep2Run.Status -eq 'Succeeded' -and $gtStep2Run.Status -eq 'Succeeded')
	{
		#Step 3 - Curated to Consumption Zone
		$nycTaxiCuratedToConsumption = "3_CuratedToConsumption"

		Write-Host Run $nycTaxiCuratedToConsumption pipeline. It takes about an 2 hours 45 minutes ... -ForegroundColor Green

		Invoke-AzDataFactoryV2Pipeline `
		-DataFactoryName $dfName `
		-ResourceGroupName $resourceGroupName `
		-PipelineName $nycTaxiCuratedToConsumption
	}
}

#----------------------------------------------------------------#
#   Step 8 - Run Databricks Notebooks							 #
#----------------------------------------------------------------#
# Run the Databricks Notebooks

if ($executeAdb -eq $true)
{
	# Connect to Databricks
	Connect-Databricks `
		-Region $location `
		-ApplicationId $spnAppId `
		-Secret $spnSecret `
		-ResourceGroupName $resourceGroupName `
		-SubscriptionId $subscriptionId `
		-WorkspaceName $adbWsName `
		-TenantId $spnTenantId

	$notebookPathReferenceData = "/Shared/msdaie2e/adb/1_LoadData/0_ReferenceData"
	# Execute Reference Data Load Notebook
	$referenceDataRunId = Add-DatabricksNotebookJob `
				-JobName "loadrefdata" `
				-Timeout $jobTimeOut `
				-MaxRetries $maxRetries `
				-NotebookPath $notebookPathReferenceData `
				-ClusterId $dbClusterId 

	Write-Host Run $notebookPathReferenceData Notebook . It takes about 5-10 minutes... -ForegroundColor Green

	Start-DatabricksJob -JobId $referenceDataRunId

	$jobTimeOut = 20000

	# Connect to Databricks
	Connect-Databricks `
		-Region $location `
		-ApplicationId $spnAppId `
		-Secret $spnSecret `
		-ResourceGroupName $resourceGroupName `
		-SubscriptionId $subscriptionId `
		-WorkspaceName $adbWsName `
		-TenantId $spnTenantId
		
	$notebookPathGreenTaxiData = "/Shared/msdaie2e/adb/1_LoadData/1_GreenTaxi"
	# Execute Green Taxi Notebook
	# GreenTaxi takes about 30 minutes
	$loadGreenTaxiRunId = Add-DatabricksNotebookJob `
				-JobName "loadgreentaxi" `
				-Timeout $jobTimeOut `
				-MaxRetries $maxRetries `
				-NotebookPath $notebookPathGreenTaxiData `
				-ClusterId $dbClusterId 

	Write-Host Run $notebookPathGreenTaxiData Notebook . It takes about 50-55 minutes... -ForegroundColor Green

	Start-DatabricksJob -JobId $loadGreenTaxiRunId

	# Connect to Databricks
	Connect-Databricks `
		-Region $location `
		-ApplicationId $spnAppId `
		-Secret $spnSecret `
		-ResourceGroupName $resourceGroupName `
		-SubscriptionId $subscriptionId `
		-WorkspaceName $adbWsName `
		-TenantId $spnTenantId

	$notebookPathYellowTaxiData = "/Shared/msdaie2e/adb/1_LoadData/2_YellowTaxi"
	# Execute Yellow Taxi Notebook
	# YellowTaxi takes about 4.5 hours
	$loadYellowTaxiRunId = Add-DatabricksNotebookJob `
				-JobName "loadyellowtaxi" `
				-Timeout $jobTimeOut `
				-MaxRetries $maxRetries `
				-NotebookPath $notebookPathYellowTaxiData `
				-ClusterId $dbClusterId 

	Write-Host Run $notebookPathYellowTaxiData Notebook . It takes about 4 hours 20 minutes... -ForegroundColor Green

	Start-DatabricksJob -JobId $loadYellowTaxiRunId

	# Check the Run Status
	while ($True) 
	{

		Connect-Databricks `
			-Region $location `
			-ApplicationId $spnAppId `
			-Secret $spnSecret `
			-ResourceGroupName $resourceGroupName `
			-SubscriptionId $subscriptionId `
			-WorkspaceName $adbWsName `
			-TenantId $spnTenantId

		$loadYellowTaxiStatus = Get-DatabricksRun -RunId $loadYellowTaxiRunId #-StateOnly

		if ($loadYellowTaxiStatus) {
			if ($loadYellowTaxiStatus.state.life_cycle_state -eq 'TERMINATED' -and $loadYellowTaxiStatus.state.result_state -eq 'Succeeded')
			{
				Write-Output ("Pipeline run finished. The status is: " +  $loadYellowTaxiStatus)
				$loadYellowTaxiStatus
				break
			}
			Write-Output "Pipeline is running...status: " + $loadYellowTaxiStatus.state.life_cycle_state
			Start-Sleep -Seconds 60
		}
	}

	Connect-Databricks `
		-Region $location `
		-ApplicationId $spnAppId `
		-Secret $spnSecret `
		-ResourceGroupName $resourceGroupName `
		-SubscriptionId $subscriptionId `
		-WorkspaceName $adbWsName `
		-TenantId $spnTenantId

	$loadYellowTaxiStatus = Get-DatabricksRun -RunId $loadYellowTaxiRunId -StateOnly
	$loadGreenTaxiStatus = Get-DatabricksRun -RunId $loadGreenTaxiRunId -StateOnly

	$jobTimeOut = 20000
	if ($loadGreenTaxiStatus -eq 'SUCCESS')
	{
		$notebookPathGreenTaxiTransformData = "/Shared/msdaie2e/adb/2_TransformData/1_GreenTaxi"
		# Execute Green Taxi Transform Data Notebook
		# GreenTaxi takes about 15 minutes
		$loadGreenTaxiTransformRunId = Add-DatabricksNotebookJob `
					-JobName "transformgreentaxi" `
					-Timeout $jobTimeOut `
					-MaxRetries $maxRetries `
					-NotebookPath $notebookPathGreenTaxiTransformData `
					-ClusterId $dbClusterId 

		Write-Host Run $notebookPathGreenTaxiTransformData Notebook . It takes about 15-20 Minutes... -ForegroundColor Green

		Start-DatabricksJob -JobId $loadGreenTaxiTransformRunId
	}

	if ($loadGreenTaxiStatus -eq 'SUCCESS')
	{
		$notebookPathYellowTaxiTransformData = "/Shared/msdaie2e/adb/2_TransformData/2_YellowTaxi"
		# Execute Yellow Taxi Transform Data Notebook
		# Yellow Taxi takes about 15 minutes
		$loadYellowTaxiTransformRunId = Add-DatabricksNotebookJob `
					-JobName "transformyellowtaxi" `
					-Timeout $jobTimeOut `
					-MaxRetries $maxRetries `
					-NotebookPath $notebookPathYellowTaxiTransformData `
					-ClusterId $dbClusterId 

		Write-Host Run $notebookPathYellowTaxiTransformData Notebook. It takes about 4 hours 30 minutes ... -ForegroundColor Green

		Start-DatabricksJob -JobId $loadYellowTaxiTransformRunId

		Connect-Databricks `
				-Region $location `
				-ApplicationId $spnAppId `
				-Secret $spnSecret `
				-ResourceGroupName $resourceGroupName `
				-SubscriptionId $subscriptionId `
				-WorkspaceName $adbWsName `
				-TenantId $spnTenantId

		# Check the Run Status
		while ($True) 
		{

			Connect-Databricks `
				-Region $location `
				-ApplicationId $spnAppId `
				-Secret $spnSecret `
				-ResourceGroupName $resourceGroupName `
				-SubscriptionId $subscriptionId `
				-WorkspaceName $adbWsName `
				-TenantId $spnTenantId
				
			$transformYellowTaxiStatus = Get-DatabricksRun -RunId $loadYellowTaxiTransformRunId #-StateOnly

			if ($transformYellowTaxiStatus) {
				if ($transformYellowTaxiStatus.state.life_cycle_state -eq 'TERMINATED' -and $transformYellowTaxiStatus.state.result_state -eq 'Succeeded')
				{
					Write-Output ("Pipeline run finished. The status is: " +  $transformYellowTaxiStatus)
					$transformYellowTaxiStatus
					break
				}
				Write-Output "Pipeline is running...status: " + $transformYellowTaxiStatus.state.life_cycle_state
				Start-Sleep -Seconds 60
			}
		}
	}
	
	Connect-Databricks `
		-Region $location `
		-ApplicationId $spnAppId `
		-Secret $spnSecret `
		-ResourceGroupName $resourceGroupName `
		-SubscriptionId $subscriptionId `
		-WorkspaceName $adbWsName `
		-TenantId $spnTenantId

	$loadYellowTaxiTransformStatus = Get-DatabricksRun -RunId $loadYellowTaxiTransformRunId -StateOnly
	$loadGreenTaxiTransformStatus = Get-DatabricksRun -RunId $loadGreenTaxiTransformRunId -StateOnly
	
	if ($loadYellowTaxiTransformStatus -eq 'SUCCESS' -and $loadGreenTaxiTransformStatus -eq 'SUCCESS')
	{
		$notebookPathConsumption = "/Shared/msdaie2e/adb/3_Consumption/1_MaterializedView"
		# Execute Consumption Data Notebook
		# Consumption takes about 4 Hours
		$consumptionRunId = Add-DatabricksNotebookJob `
					-JobName "consumption" `
					-Timeout $jobTimeOut `
					-MaxRetries $maxRetries `
					-NotebookPath $notebookPathConsumption `
					-ClusterId $dbClusterId 

		Write-Host Run $notebookPathConsumption Notebook. It takes about 3 Hours ... -ForegroundColor Green

		Start-DatabricksJob -JobId $consumptionRunId
		Start-Sleep -s 30
	}
}

#----------------------------------------------------------------#
#   Step 9 - Create Azure Machine Learning Services				 #
#----------------------------------------------------------------#

Write-Host Create AML Service ... -ForegroundColor Green

$amlWsName = $prefix + "aml"
$amlTier = "enterprise"
$amlStorageAccountName = $prefix + "amlsa"
$amlKeyVaultName = $prefix + "amlkv"
$amlAppInsightName = $prefix + "amlai"
$amlContainerRegistryName = $prefix + "amlcr"

$amlTemplateFilePath = "$ScriptRoot\..\templates\amltpl.json"
$amlParametersFilePath = "$ScriptRoot\..\templates\amlparameters.json"
$amlParametersTemplate = Get-Content $amlParametersFilePath | ConvertFrom-Json
$amlParameters = $amlParametersTemplate.parameters
$amlParameters.workspaceName.value = $amlWsName
$amlParameters.location.value = $location
$amlParameters.sku.value = $amlTier
$amlParameters.storageAccountName.value = $amlStorageAccountName
$amlParameters.keyVaultName.value = $amlKeyVaultName
$amlParameters.tenantId.value = $tenantId
$amlParameters.applicationInsightsName.value = $amlAppInsightName
$amlParameters.containerRegistryName.value = $amlContainerRegistryName
$amlParametersTemplate | ConvertTo-Json | Out-File $amlParametersFilePath

Write-Host Deploying $amlWsName"..." -ForegroundColor Green
New-AzResourceGroupDeployment `
		-ResourceGroupName $resourceGroupName `
		-Name $amlWsName `
		-TemplateFile $amlTemplateFilePath `
		-TemplateParameterFile $amlParametersFilePath

Connect-Databricks `
	-Region $location `
	-ApplicationId $spnAppId `
	-Secret $spnSecret `
	-ResourceGroupName $resourceGroupName `
	-SubscriptionId $subscriptionId `
	-WorkspaceName $adbWsName `
	-TenantId $spnTenantId

Add-DatabricksLibrary `
	-LibraryType "pypi" -LibrarySettings 'azureml-sdk[automl_databricks,explain]' `
	-ClusterId $dbClusterId

Start-Sleep -s 30

$jobTimeOut = 1000
$maxRetries = 0
$notebookPathamlSetup = "/Shared/msdaie2e/adb/4_DataScience/0_AmlSetup"
$notebookParamamlSetup = '{"subscriptionId": "' + $subscriptionId + '"' `
				+ ', "rgName": "' + $resourceGroupName + '"' `
				+ ', "wsName": "' + $amlWsName + '"' `
				+ ', "tenantId": "' + $spnTenantId + '"' `
				+ ', "clientId": "' + $spnAppId + '"' `
				+ ', "clientSecret": "' + $spnSecret + '"' `
				+ '}'

# Execute 0-AmlSetup Notebook
$amlStep0RunId = Add-DatabricksNotebookJob `
			-JobName "amlsetup" `
			-Timeout $jobTimeOut `
			-MaxRetries $maxRetries `
			-NotebookPath $notebookPathamlSetup `
			-NotebookParametersJson $notebookParamamlSetup `
			-ClusterId $dbClusterId 

Start-DatabricksJob -JobId $amlStep0RunId

if ($executeAml -eq $true)
{
	# Execute Feature Engineering notebook
	$jobTimeOut = 20000

	$notebookPathFeatureEngg = "/Shared/msdaie2e/adb/4_DataScience/1_FeatureEngg"
	$FeatureEnggRunId = Add-DatabricksNotebookJob `
				-JobName "featureengg" `
				-Timeout $jobTimeOut `
				-MaxRetries $maxRetries `
				-NotebookPath $notebookPathFeatureEngg `
				-ClusterId $dbClusterId 

	Start-DatabricksJob -JobId $FeatureEnggRunId

	$jobTimeOut = 20000

	$notebookPathModelTraining = "/Shared/msdaie2e/adb/4_DataScience/2_ModelTraining"
	$notebookParamModelTraining = '{"subscriptionId": "' + $subscriptionId + '"' `
					+ ', "rgName": "' + $resourceGroupName + '"' `
					+ ', "wsName": "' + $amlWsName + '"' `
					+ ', "tenantId": "' + $spnTenantId + '"' `
					+ ', "clientId": "' + $spnAppId + '"' `
					+ ', "clientSecret": "' + $spnSecret + '"' `
					+ '}'

	# Execute 0-AmlSetup Notebook
	$amlmodelTrainRunId = Add-DatabricksNotebookJob `
				-JobName "modeltraining" `
				-Timeout $jobTimeOut `
				-MaxRetries $maxRetries `
				-NotebookPath $notebookPathModelTraining `
				-NotebookParametersJson $notebookParamModelTraining `
				-ClusterId $dbClusterId 

	Start-DatabricksJob -JobId $amlmodelTrainRunId
}
Write-Host Deployment complete. -ForegroundColor Green `n