param(
    [Parameter(Mandatory = $false)] 
    [String] $RecommendationId,

    [Parameter(Mandatory = $false)]
    [string] $RecommendationSubTypeId,

    [Parameter(Mandatory = $false)]
    [string] $RecommendationDescription,

    [Parameter(Mandatory = $false)]
    [string] $ResourceId,

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string] $SubscriptionId,

    [Parameter(Mandatory = $false)]
    [int] $SnoozeDays = -1,

    [Parameter(Mandatory = $true)]
    [string] $SuppressionAuthor,

    [Parameter(Mandatory = $false)]
    [string] $SuppressionNotes,

    [ValidateSet("Snooze", "Dismiss", "Exclude")]    
    [Parameter(Mandatory = $true)]
    [string] $SuppressionType
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrEmpty($RecommendationId) -and [string]::IsNullOrEmpty($RecommendationSubTypeId) -and [string]::IsNullOrEmpty($RecommendationDescription))
{
    throw "At least one of RecommendationId, RecommendationSubTypeId or RecommendationDescription must be provided as recommendation identifier."
}

if ([string]::IsNullOrEmpty($RecommendationId) -and [string]::IsNullOrEmpty($ResourceId) -and [string]::IsNullOrEmpty($ResourceGroupName) -and [string]::IsNullOrEmpty($SubscriptionId))
{
    throw "At least one of ResourceId, ResourceGroupName or SubscriptionId must be provided as scope for the suppression when no recommendation ID is given."
}

if ($SnoozeDays -lt 1 -and $SuppressionType -eq "Snooze")
{
    throw "SnoozeDays greater than 0 must be provided for Snooze suppressions."
}

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$authenticationOption = Get-AutomationVariable -Name  "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue # ManagedIdentity|UserAssignedManagedIdentity
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "ManagedIdentity"
}
if ($authenticationOption -eq "UserAssignedManagedIdentity")
{
    $uamiClientID = Get-AutomationVariable -Name "AzureOptimization_UAMIClientID"
}

$sqlserver = Get-AutomationVariable -Name  "AzureOptimization_SQLServerHostname"
$sqldatabase = Get-AutomationVariable -Name  "AzureOptimization_SQLServerDatabase" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($sqldatabase))
{
    $sqldatabase = "azureoptimization"
}

$SqlTimeout = 120
$recommendationsTable = "Recommendations"
$suppressionsTable = "Filters"

"Logging in to Azure with $authenticationOption..."

switch ($authenticationOption) {
    "UserAssignedManagedIdentity" { 
        Connect-AzAccount -Identity -EnvironmentName $cloudEnvironment -AccountId $uamiClientID
        break
    }
    Default { #ManagedIdentity
        Connect-AzAccount -Identity -EnvironmentName $cloudEnvironment 
        break
    }
}

$cloudDetails = Get-AzEnvironment -Name $CloudEnvironment
$azureSqlDomain = $cloudDetails.SqlDatabaseDnsSuffix.Substring(1)

if (-not([string]::IsNullOrEmpty($RecommendationId)))
{
    $query = "SELECT * FROM [dbo].[$recommendationsTable] WHERE RecommendationId = '$RecommendationId'"
}
else
{
    if (-not([string]::IsNullOrEmpty($RecommendationSubTypeId)))
    {
        $query = "SELECT TOP 1 * FROM [dbo].[$recommendationsTable] WHERE RecommendationSubTypeId = '$RecommendationSubTypeId'"
    }
    else
    {
        $query = "SELECT TOP 1 * FROM [dbo].[$recommendationsTable] WHERE RecommendationDescription = '$RecommendationDescription'"
    }    
}

$tries = 0
$connectionSuccess = $false

Write-Output "Getting recommendation details with query $query..."

do {
    $tries++
    try {
        $dbToken = Get-AzAccessToken -ResourceUrl "https://$azureSqlDomain/" -AsSecureString
        $Conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$sqlserver,1433;Database=$sqldatabase;Encrypt=True;Connection Timeout=$SqlTimeout;") 
        $Conn.AccessToken = $dbToken.Token | ConvertFrom-SecureString -AsPlainText
        $Conn.Open() 
        $Cmd=new-object system.Data.SqlClient.SqlCommand
        $Cmd.Connection = $Conn
        $Cmd.CommandTimeout = $SqlTimeout
        $Cmd.CommandText = $query
    
        $sqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
        $sqlAdapter.SelectCommand = $Cmd
        $controlRows = New-Object System.Data.DataTable
        $sqlAdapter.Fill($controlRows) | Out-Null            
        $connectionSuccess = $true
    }
    catch {
        Write-Output "Failed to contact SQL at try $tries."
        Write-Output $Error[0]
        Write-Output "Waiting $($tries * 20) seconds..."
        Start-Sleep -Seconds ($tries * 20)
    }
    finally {
        $Conn.Close()    
        $Conn.Dispose()            
    }    
} while (-not($connectionSuccess) -and $tries -lt 3)

if (-not($connectionSuccess))
{
    throw "Could not establish connection to SQL."
}

if (-not([string]::IsNullOrEmpty($RecommendationId)))
{
    if (-not($controlRows.RecommendationId))
    {
        throw "The provided recommendation ID was not found. Please, try again with a valid GUID that exists in the SQL Database Recommendations table (RecommendationID column)."
    }
    $ResourceId = $controlRows.InstanceId
    $ResourceGroupName = $controlRows.ResourceGroup
    $SubscriptionId = $controlRows.SubscriptionGuid
}
else
{
    if (-not($controlRows.RecommendationId))
    {
        if (-not([string]::IsNullOrEmpty($RecommendationSubTypeId)))
        {
            $errorMessage = "The provided recommendation sub-type ID was not found. Please, try again with a valid GUID that exists in the SQL Database Recommendations table (RecommendationSubTypeID column)."
        }
        else
        {
            $errorMessage = "The provided recommendation description was not found. Please, try again with description that exists in the SQL Database Recommendations table (RecommendationDescription column)."
        }        
        throw $errorMessage
    }
}

$scope = $null
if ($SuppressionType -in ("Dismiss", "Snooze"))
{
    if (-not([string]::IsNullOrEmpty($ResourceId)))
    {
        $scope = $ResourceId
    }
    else
    {
        if (-not([string]::IsNullOrEmpty($ResourceGroupName)))
        {
            $scope = $ResourceGroupName
        }
        else
        {
            $scope = $SubscriptionId
        }
    }
}

if ($scope)
{
    $scope = "'$scope'"
}
else
{
    $scope = "NULL"    
}

if ($SnoozeDays -ge 1)
{
    $now = (Get-Date).ToUniversalTime()
    $endDate = "'$($now.Add($SnoozeDays).ToString("yyyy-MM-ddTHH:mm:00Z"))'"
}
else {
    $endDate = "NULL"
}

Write-Host "You are suppressing the recommendation with the below details"
Write-Host "Recommendation: $($controlRows.RecommendationDescription)"
Write-Host "Recommendation sub-type id: $($controlRows.RecommendationSubTypeId)"
Write-Host "Category: $($controlRows.Category)"
Write-Host "Suppression type: $SuppressionType"
Write-Host "Scope: $scope"
Write-Host "End date: $endDate"

$sqlStatement = "INSERT INTO [$suppressionsTable] VALUES (NEWID(), '$($controlRows.RecommendationSubTypeId)', '$SuppressionType', $scope, GETDATE(), $endDate, '$SuppressionAuthor', '$SuppressionNotes', 1)"

$dbToken = Get-AzAccessToken -ResourceUrl "https://$azureSqlDomain/" -AsSecureString
$Conn2 = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$sqlserver,1433;Database=$sqldatabase;Encrypt=True;Connection Timeout=$SqlTimeout;") 
$Conn2.AccessToken = $dbToken.Token | ConvertFrom-SecureString -AsPlainText
$Conn2.Open() 

$Cmd=new-object system.Data.SqlClient.SqlCommand
$Cmd.Connection = $Conn2
$Cmd.CommandText = $sqlStatement
$Cmd.CommandTimeout = $SqlTimeout
try
{
    $Cmd.ExecuteReader()
}
catch
{
    Write-Output "Failed statement: $sqlStatement"
    throw
}

$Conn2.Close()                

Write-Host "Suppression sucessfully added."
