<#       
  	THE SCRIPT IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SCRIPT OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
#>

PARAM(    
    [Parameter(Mandatory = $true)] $LogAnalyticsWorkspaceName,
    [Parameter(Mandatory = $true)] $LogAnalyticsResourceGroup,
    [Parameter(Mandatory = $true)] $AdxResourceGroup,
    [Parameter(Mandatory = $true)] $AdxClusterURL,
    [Parameter(Mandatory = $true)] $AdxDBName,   
        
    [Parameter(Mandatory = $false)]$AdxEngineUrl = "$AdxClusterURL/$AdxDBName",
    [Parameter(Mandatory = $false)]$KustoToolsPackage = "microsoft.azure.kusto.tools",
    [Parameter(Mandatory = $false)]$KustoConnectionString = "$AdxEngineUrl;Fed=True",
  
    [Parameter(Mandatory = $false)]$NuGetPackageLocation = "$($env:USERPROFILE)\.nuget\packages",
    [Parameter(Mandatory = $false)]$NuGetIndex = "https://api.nuget.org/v3/index.json",
    [Parameter(Mandatory = $false)]$NuGetDownloadUrl = "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe"
)

Function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Message,
        [string]$LogFileName,
 
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Severity = 'Information'
    )
    try {
        [PSCustomObject]@{
            Time     = (Get-Date -f g)
            Message  = $Message
            Severity = $Severity
        } | Export-Csv -Path "$PSScriptRoot\$LogFileName" -Append -NoTypeInformation
    }
    catch {
        Write-Error "An error occurred in Write-Log() method" -ErrorAction Continue
    }
    
}
Function CheckModules($module) {
    try {
        $installedModule = Get-InstalledModule -Name $module -ErrorAction SilentlyContinue
        if ($null -eq $installedModule) {
            Write-Warning "The $module PowerShell module is not found"
            Write-Log -Message "The $module PowerShell module is not found" -LogFileName $LogFileName -Severity Warning
            #check for Admin Privleges
            $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())

            if (-not ($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
                #Not an Admin, install to current user            
                Write-Warning -Message "Can not install the $module module. You are not running as Administrator"
                Write-Log -Message "Can not install the $module module. You are not running as Administrator" -LogFileName $LogFileName -Severity Warning

                Write-Warning -Message "Installing $module module to current user Scope"
                Write-Log -Message "Installing $module module to current user Scope" -LogFileName $LogFileName -Severity Warning
                
                Install-Module -Name $module -Scope CurrentUser -Force
                Import-Module -Name $module -Force
            }
            else {
                #Admin, install to all users
                Write-Warning -Message "Installing the $module module to all users"
                Write-Log -Message "Installing the $module module to all users" -LogFileName $LogFileName -Severity Warning
                Install-Module -Name $module -Force
                Import-Module -Name $module -Force
            }
        }
        #Install-Module will obtain the module from the gallery and install it on your local machine, making it available for use.
        #Import-Module will bring the module and its functions into your current powershell session, if the module is installed.  
    }
    catch {
        Write-Host "An error occurred in CheckModules() method" -ForegroundColor Red
        Write-Log -Message "An error occurred in CheckModules() method" -LogFileName $LogFileName -Severity Error        
        exit
    }
}

Function Invoke-KustoCLI($adxCommandsFile) {
    try {
        $kustoToolsDir = "$env:USERPROFILE\.nuget\packages\$kustoToolsPackage\"
        $currentDir = Get-Location
        Set-Location $scriptDir

        if (!(Test-Path $KustoToolsDir)) {        
            if (!(Test-Path nuget)) {
                Write-Warning "The NuGet module is not found" -ErrorAction Continue
                Write-Log -Message "The NuGet module is not found" -LogFileName $LogFileName -Severity Warning
            
                Write-Output "Downloading NuGet package"
                Write-Log -Message "Downloading NuGet package" -LogFileName $LogFileName -Severity Information
                (New-Object net.webclient).downloadFile($NuGetDownloadUrl, "$pwd\nuget.exe")
            }

            Write-Output "Installing Kusto Tools Package"
            Write-Log -Message "Installing Kusto Tools Package" -LogFileName $LogFileName -Severity Information
            &.\nuget.exe install $kustoToolsPackage -Source $nugetIndex -OutputDirectory $nugetPackageLocation
        }

        $KustoExe = $KustoToolsDir + @(Get-ChildItem -Recurse -Path $KustoToolsDir -Name kusto.cli.exe)[-1]
        
        if (!(Test-Path $KustoExe)) {
            Write-Warning "Unable to find Kusto client tool $KustoExe. exiting"
            Write-Log -Message "Unable to find Kusto client tool $KustoExe. exiting" -LogFileName $LogFileName -Severity Warning
            return
        }
        
        Write-Output "Executing queries on Azure Data Explorer (ADX)"
        Write-Log -Message "Executing queries on Azure Data Explorer (ADX)" -LogFileName $LogFileName -Severity Information
        Invoke-Expression "$kustoExe `"$kustoConnectionString`" -script:$adxCommandsFile"
        Set-Location $currentDir

    }
    catch {
        Write-Host "An error occurred in Invoke-KustoCLI() method" -ForegroundColor Red
        Write-Log -Message "An error occurred in Invoke-KustoCLI() method" -LogFileName $LogFileName -Severity Error        
        exit
    }
}

Function New-AdxRawMappingTables() {    
    [CmdletBinding()]
    param (        
        [Parameter(Mandatory = $true)] $LaTables        
    )

    try {
        if (!(Test-Path "$PSScriptRoot\KustoQueries" -PathType Container)) { 
            New-Item -Path $PSScriptRoot -Name "KustoQueries" -ItemType "directory"
        }
        
        $supportedTables = Get-Content "$PSScriptRoot\ADXSupportedTables.json" | ConvertFrom-Json
        
        foreach ($table in $LaTables) {
            if ($decision -eq 0) {
                $TableName = $table.'$table'
            }
            else {
                $TableName = $table
            }
            if ($TableName -match '_CL$') {
                Write-Error "Custom log table : $TableName not supported" -ErrorAction Continue
                Write-Log -Message "Custom log table : $TableName not supported" -LogFileName $LogFileName -Severity Information
            }
            elseif ($supportedTables."SupportedTables" -contains $TableName.Trim()) {        
                Write-Output "`nRetrieving schema and mappings for $TableName"
                Write-Log -Message "Retrieving schema and mappings for $TableName" -LogFileName $LogFileName -Severity Information
                $query = $TableName + ' | getschema | project ColumnName, DataType'        
                $AdxTablesArray.Add($TableName.Trim())

                Write-Verbose "Executing: (Invoke-AzOperationalInsightsQuery -WorkspaceId $LogAnalyticsWorkspaceId -Query $query).Results"
                $output = (Invoke-AzOperationalInsightsQuery -WorkspaceId $LogAnalyticsWorkspaceId -Query $query).Results

                $TableExpandFunction = $TableName + 'Expand'
                $TableRaw = $TableName + 'Raw'
                $RawMapping = $TableRaw + 'Mapping'

                $FirstCommand = @()
                $ThirdCommand = @()

                foreach ($record in $output) {
                    if ($record.DataType -eq 'System.DateTime') {
                        $dataType = 'datetime'
                        $ThirdCommand += $record.ColumnName + " = todatetime(events." + $record.ColumnName + "),"
                    }
                    else {
                        $dataType = 'string'
                        $ThirdCommand += $record.ColumnName + " = tostring(events." + $record.ColumnName + "),"
                    }
                    $FirstCommand += $record.ColumnName + ":" + "$dataType" + ","    
                }

                $schema = ($FirstCommand -join '') -replace ',$'
                $function = ($ThirdCommand -join '') -replace ',$'

                $CreateRawTable = '.create table {0} (Records:dynamic)' -f $TableRaw

                $CreateRawMapping = @'
                .create table {0} ingestion json mapping '{1}' '[{{"column":"Records","Properties":{{"path":"$.records"}}}}]'
'@ -f $TableRaw, $RawMapping

                $CreateRetention = '.alter-merge table {0} policy retention softdelete = 0d' -f $TableRaw

                $CreateTable = '.create table {0} ({1})' -f $TableName, $schema

                $CreateFunction = @'
                .create-or-alter function {0} {{{1} | mv-expand events = Records | project {2} }}
'@ -f $TableExpandFunction, $TableRaw, $function

                $CreatePolicyUpdate = @'
                .alter table {0} policy update @'[{{"Source": "{1}", "Query": "{2}()", "IsEnabled": "True", "IsTransactional": true}}]'
'@ -f $TableName, $TableRaw, $TableExpandFunction

                $scriptDir = "$PSScriptRoot\KustoQueries"
                New-Item "$scriptDir\adxCommands.txt"
                Add-Content "$scriptDir\adxCommands.txt" "`n$CreateRawTable"
                Add-Content "$scriptDir\adxCommands.txt" "`n$CreateRawMapping"
                Add-Content "$scriptDir\adxCommands.txt" "`n$CreateRetention"
                Add-Content "$scriptDir\adxCommands.txt" "`n$CreateTable"
                Add-Content "$scriptDir\adxCommands.txt" "`n$CreateFunction"
                Add-Content "$scriptDir\adxCommands.txt" "`n$CreatePolicyUpdate"

                Invoke-KustoCLI -AdxCommandsFile "$scriptDir\adxCommands.txt"
                Remove-Item $scriptDir\adxCommands.txt -Force -ErrorAction Ignore        
                Write-Output "Successfully created Raw and Mapping tables for :$TableName in Azure Data Explorer Cluster Database"
                Write-Log -Message "Successfully created Raw and Mapping tables for :$TableName in Azure Data Explorer Cluster Database" -LogFileName $LogFileName -Severity Information
            }
            else {
                Write-Error "$TableName not supported by Data Export rule" -ErrorAction Continue
                Write-Log -Message "$TableName not supported by Data Export rule" -LogFileName $LogFileName -Severity Error
            }
        }   
    }
    catch {
        Write-Error "An error occurred in New-AdxRawMappingTables() method" -ErrorAction Continue
        Write-Log -Message "An error occurred in New-AdxRawMappingTables() method" -LogFileName $LogFileName -Severity Error        
        exit
    }
}

Function Split-ArrayBySize() {
    [CmdletBinding()]
    param (        
        [Parameter(Mandatory = $true)] $AdxTabsArray,
        [Parameter(Mandatory = $true)] $ArraySize
    )    
    try {
        Write-Verbose "Splitting array into groups of up to $ArraySize" -ForegroundColor Green
        Write-Log -Message "Splitting array into groups of up to $ArraySize" -LogFileName $LogFileName -Severity Information
        $slicedArraysResult = SliceArray -Item $AdxTabsArray -Size $ArraySize | ForEach-Object { '{0}' -f ($_ -join '","') }
    
        return $slicedArraysResult
    }
    catch {

        Write-Log -Message "An error occurred in Split-ArrayBySize() method" -LogFileName $LogFileName -Severity Error
        Write-Error "An error occurred in Split-ArrayBySize() method" -ErrorAction Stop        
        exit
    }
}

Function New-EventHubNamespace() {
    [CmdletBinding()]
    param (        
        [Parameter(Mandatory = $true)] $ArraysObject        
    )
    try {
        $EventHubsArray = @()
        
        foreach ($slicedArray in $ArraysObject) {
            if ($slicedArray.Length -gt 0) {
                #Create EventHub NameSpace
                $randomNumber = Get-Random
                $EventHubNamespaceName = "$($LogAnalyticsWorkspaceName)-$($randomNumber)"        
                $EventHubsArray += $EventHubNamespaceName
                Write-Verbose "Executing: New-AzEventHubNamespace -ResourceGroupName $LogAnalyticsResourceGroup -NamespaceName $EventHubNamespaceName `
                -Location $LogAnalyticsLocation -SkuName Standard -SkuCapacity 12 -EnableAutoInflate -MaximumThroughputUnits 20 -Verbose"

                try {
                    Write-Host " Create a new EventHub-Namespace:$EventHubNamespaceName in Resource Group:$LogAnalyticsResourceGroup"
                    Write-Log -Message "Create a new EventHub-Namespace:$EventHubNamespaceName in Resource Group:$LogAnalyticsResourceGroup" -LogFileName $LogFileName -Severity Information
                    Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"

                    $resultEventHubNS = New-AzEventHubNamespace -ResourceGroupName $LogAnalyticsResourceGroup `
                        -NamespaceName $EventHubNamespaceName `
                        -Location $LogAnalyticsLocation `
                        -SkuName "Standard" `
                        -SkuCapacity 12 `
                        -EnableAutoInflate `
                        -MaximumThroughputUnits 20 `
                        -Verbose
                    
                    if ($resultEventHubNS.ProvisioningState.Trim().ToLower() -eq "succeeded") {
                        Write-Output "`n  $EventHubNamespaceName created successfully"
                        Write-Log -Message "$EventHubNamespaceName created successfully" -LogFileName $LogFileName -Severity Information
                    }                
                }
                catch {
                    Write-Error -message "StatusCode: $($_.Exception.Response.StatusCode.value__)" -ErrorAction Continue
                    Write-Log -Message "$($_.Exception.Response.StatusCode.value__)" -LogFileName $LogFileName -Severity Error
                    Write-Error "StatusDescription: $($_.Exception.Response.StatusDescription)" -ErrorAction Continue
                    Write-Log -Message "$($_.Exception.Response.StatusDescription)" -LogFileName $LogFileName -Severity Error
                }
            }
        } 
        return $EventHubsArray
    }
    catch {
        Write-Error "An error occurred in New-EventHubNamespace() method"
        Write-Log -Message "An error occurred in New-EventHubNamespace() method" -LogFileName $LogFileName -Severity Error        
        exit
    }
}

Function New-LaDataExportRule() {
    [CmdletBinding()]
    param (        
        [Parameter(Mandatory = $true)] $adxEventHubs,
        [Parameter(Mandatory = $true)] $tablesArrayCollection     
    )

    Write-Output "Creating Log Analytics data export rules"
    Write-Log -Message "Creating Log Analytics data export rules" -LogFileName $LogFileName -Severity Information
    try {

        $count = 0
                
        foreach ($adxEventHub in $adxEventHubs) {        
            Write-Verbose "Executing: Get-AzEventHubNamespace -ResourceGroupName $LogAnalyticsResourceGroup -NamespaceName $adxEventHub"
            $eventHubNameSpace = Get-AzEventHubNamespace -ResourceGroupName $LogAnalyticsResourceGroup -NamespaceName $adxEventHub -ErrorAction SilentlyContinue     
          
            $eventHubNameSpace| Format-Table -AutoSize
            Write-Verbose "`$adxEventHubs.count -eq $($adxEventHubs.Count)"

            if ($null -eq $eventHubNameSpace)
            {
                Write-Verbose "No data in `$eventHubNameSpace waiting and retrying to retrieve data."
                Start-Sleep -seconds 60
                $eventHubNameSpace = Get-AzEventHubNamespace -ResourceGroupName $LogAnalyticsResourceGroup -NamespaceName $adxEventHub -ErrorAction

            }

            white

            if ($adxEventHubs.Count -gt 1) {
                Write-Verbose "adxEventhubs.count is greater than 1"
                $exportRuleTables = '"{0}"' -f ($tablesArrayCollection[$count] -join '","')
            }
            else {
                Write-Verbose "adxEventhubs.count is 1"
                $exportRuleTables = '"{0}"' -f ($tablesArrayCollection -join '","')
            }

            if ($eventHubNameSpace.ProvisioningState -eq "Succeeded") {
                $randomNumber = Get-Random

                $LaDataExportRuleName = "$($LogAnalyticsWorkspaceName)-$($randomNumber)"
                $dataExportAPI = "https://management.azure.com/subscriptions/$SubscriptionId/resourcegroups/$LogAnalyticsResourceGroup/providers/Microsoft.operationalInsights/workspaces/$LogAnalyticsWorkspaceName/dataexports/$laDataExportRuleName" + "?api-version=2020-08-01"
                $LaAccessToken = (Get-AzAccessToken).Token   
                $LaAPIHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
                $LaAPIHeaders.Add("Content-Type", "application/json")
                $LaAPIHeaders.Add("Authorization", "Bearer $LaAccessToken")

                $DataExportBody = @"
                {
                    "properties": {
                        "destination": {
                        "resourceId": "$($eventHubNameSpace.Id)"
                        },
                        "tablenames": [$exportRuleTables],
                        "enable": true
                    }
                }
"@
                
                Write-Verbose "Executing: Invoke-RestMethod -Uri $DataExportAPI -Method 'PUT' -Headers $LaAPIHeaders -Body $DataExportBody"
                
                try {        
                    
                    $CreateDataExportRule = Invoke-RestMethod -Uri $DataExportAPI -Method "PUT" -Headers $LaAPIHeaders -Body $DataExportBody
                    Write-Output $CreateDataExportRule
                    Write-Log -Message $CreateDataExportRule -LogFileName $LogFileName -Severity Information
                }
                catch {    
                    Write-Error "StatusCode: $($_.Exception.Response.StatusCode.value__)" -ErrorAction Continue
                    Write-Log -Message $($_.Exception.Response.StatusCode.value__) -LogFileName $LogFileName -Severity Error
                    Write-Error "StatusDescription: $($_.Exception.Response.StatusDescription)" -ErrorAction Continue
                    Write-Log -Message $($_.Exception.Response.StatusDescription) -LogFileName $LogFileName -Severity Error
                }   
                $count++
            }
            else {
                Start-SleepMessage 300
            }
        }
    }
    catch {

        Write-Log -Message "An error occurred in New-LaDataExportRule" -LogFileName $LogFileName -Severity Error   
        Write-Error "An error occurred in New-LaDataExportRule" -ErrorAction Stop     
        exit
    }
}

Function New-ADXDataConnection() {
    [CmdletBinding()]
    param (        
        [Parameter(Mandatory = $true)] $AdxEventHubs        
    )
    
    try {   
        Register-AzResourceProvider -ProviderNamespace Microsoft.Kusto
        Write-Output "Creating Azure Data Explorer data connection"
        Write-Log -Message "Creating Azure Data Explorer Data Connection" -LogFileName $LogFileName -Severity Information
        Write-Verbose "`$AdxClusterURL: $AdxClusterUrl"
        $AdxClusterName = $AdxClusterURL.split('.')[0].split('//')[1].Trim()
        Write-Verbose "`$AdxClusterName: $AdxClusterName"
        foreach ($AdxEH in $AdxEventHubs) {
            Write-Verbose "Executing: Get-AzEventHub -ResourceGroup $LogAnalyticsResourceGroup -NamespaceName $AdxEH -Verbose"
            try {
                
                $eventHubTopics = Get-AzEventHub -ResourceGroup $LogAnalyticsResourceGroup -NamespaceName $adxEH        
                if ($null -ne $eventHubTopics) {
                    foreach ($eventHubTopic in $eventHubTopics) {
                        $tableEventHubTopic = $eventHubTopic.Name.split('-')[1]
                        # The above statement will return Table name in lower case
                        # Azure Kusto Data connection is expecting the table name in title case (Case Sensitive)
                        # In order to get exact same case table name, getting it from Source array                        
                        $AdxTables = $AdxTablesArray.ToArray()                        
                        $ArrIndex = $AdxTables.ForEach{ $_.ToLower() }.IndexOf($tableEventHubTopic)                        
                        $EventHubResourceId = $EventHubTopic.Id
                        $AdxTableRealName = $AdxTables[$arrIndex].Trim().ToString()
                        $AdxTableRaw = "$($AdxTableRealName)HistoricRaw"
                        $AdxTableRawMapping = "$($AdxTableRealName)HistoricMapping"
                        $DataConnName = "$($TableEventHubTopic)dataconnection"

                        $DataConnAPI = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$AdxResourceGroup/providers/Microsoft.Kusto/clusters/$AdxClusterName/databases/$AdxDBName/dataConnections/$DataConnName" + "?api-version=2021-01-01"
            
                        $LaAccessToken = (Get-AzAccessToken).Token            
                        $LaAPIHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
                        $LaAPIHeaders.Add("Content-Type", "application/json")
                        $LaAPIHeaders.Add("Authorization", "Bearer $LaAccessToken")
                                                                        
                        $DataConnBody = @"
                        {
                            "location": "$LogAnalyticsLocation",
                            "kind": "EventHub",
                            "properties": {
                              "eventHubResourceId": "$eventHubResourceId",                              
                              "consumerGroup": "$('$Default')",
                              "dataFormat":"MULTILINE JSON",
                              "tableName":"$adxTableRaw",
                              "mappingRuleName":"$adxTableRawMapping",
                              "compression":"None"
                            }
                        }
"@
                        Write-Verbose "Executing: Invoke-RestMethod -Uri $dataConnAPI -Method 'PUT' -Headers $LaAPIHeaders -Body $dataConnBody"
                        try {                                  
                            $CreateDataConnRule = Invoke-RestMethod -Uri $dataConnAPI -Method "PUT" -Headers $LaAPIHeaders -Body $dataConnBody                   
                            Write-Output $CreateDataConnRule
                            Write-Log -Message $CreateDataConnRule -LogFileName $LogFileName -Severity Information
                        }
                        catch {
                            Write-Error "An error occurred in creating Data Connection for $($EventHubTopic.Name)" -ErrorAction Continue
                            Write-Log -Message "An error occurred in creating Data Connection for $($EventHubTopic.Name)" -LogFileName $LogFileName -Severity Error            
                            Write-Error "StatusCode: $($_.Exception.Response.StatusCode.value__)" -ErrorAction Continue
                            Write-Log -Message $($_.Exception.Response.StatusCode.value__) -LogFileName $LogFileName -Severity Error
                            Write-Error "StatusDescription: $($_.Exception.Response.StatusDescription)" -ErrorAction Continue
                            Write-Log -Message $($_.Exception.Response.StatusDescription) -LogFileName $LogFileName -Severity Error
                        }                      
                                                                                                
                    }
                }
                else {                    
                    Write-Log -Message "EventHubTopics not available in $AdxEH" -LogFileName $LogFileName -Severity Error 
                    Write-Error "EventHubTopics not available in $AdxEH"       
                }
                
            }
            catch {
                Write-Log -Message "An error occurred in retrieving EventHub Topics from $AdxEH" -LogFileName $LogFileName -Severity Error   
                Write-Error "An error occurred in retrieving EventHub Topics from $AdxEH"
     
            }
        }
    }
    catch {
        Write-Error "An error occurred in New-AdxDataConnection() method" -ErrorAction Continue
        Write-Log -Message "An error occurred in New-AdxDataConnection() method" -LogFileName $LogFileName -Severity Error        
        exit
    }
}

Function SliceArray {

    [CmdletBinding()]
    param (        
        [Parameter(Mandatory = $true)] [String[]]$Item,
        [Parameter(Mandatory = $true)] [int]$Size
    )
    
    BEGIN { $Items = @() }
    PROCESS {
        foreach ($i in $Item ) { $Items += $i }
    }
    END {
        0..[math]::Floor($Items.count / $Size) | ForEach-Object { 
            $x, $Items = $Items[0..($Size - 1)], $Items[$Size..$Items.Length]; , $x
        } 
    }  
}

Function Start-SleepMessage($Seconds, $WaitMessage) {
    $DoneDT = (Get-Date).AddSeconds($seconds)
    while ($DoneDT -gt (Get-Date)) {
        $SecondsLeft = $doneDT.Subtract((Get-Date)).TotalSeconds
        $Percent = ($Seconds - $SecondsLeft) / $seconds * 100
        Write-Progress -Activity $WaitMessage -Status "Please wait..." -SecondsRemaining $SecondsLeft -PercentComplete $Percent
        [System.Threading.Thread]::Sleep(500)
    }
    Write-Progress -Activity $waitMessage -Status "Please wait..." -SecondsRemaining 0 -Completed
}


CheckModules("Az.Resources")
CheckModules("Az.OperationalInsights")

$TimeStamp = Get-Date -Format yyyyMMdd_HHmmss 
$LogFileName = '{0}_{1}.csv' -f "ADXMigration", $TimeStamp

Write-Host "`r`nIf not logged in to Azure already, you will now be asked to log in to your Azure environment. `nFor this script to work correctly, you need to provide credentials `nAzure Log Analytics Workspace Read Permissions `nAzure Data Explorer Database User Permission. `nThis will allow the script to read all the Tables from Log Analytics Workspace `nand create tables in Azure Data Explorer.`r`n" -BackgroundColor Blue

Read-Host -Prompt "Press enter to continue or CTRL+C to quit the script"

$Context = Get-AzContext

if (!$Context) {
    Connect-AzAccount
    $Context = Get-AzContext
}

$SubscriptionId = $Context.Subscription.Id

Write-Verbose "Executing: Get-AzOperationalInsightsWorkspace -Name $LogAnalyticsWorkspaceName -ResourceGroupName $LogAnalyticsResourceGroup -DefaultProfile $context"

try {

    $WorkspaceObject = Get-AzOperationalInsightsWorkspace -Name $LogAnalyticsWorkspaceName -ResourceGroupName $LogAnalyticsResourceGroup -DefaultProfile $Context 
    $LogAnalyticsLocation = $WorkspaceObject.Location
    $LogAnalyticsWorkspaceId = $WorkspaceObject.CustomerId
    Write-Output "Workspace named $LogAnalyticsWorkspaceName in region $LogAnalyticsLocation exists."
    Write-Log -Message "Workspace named $LogAnalyticsWorkspaceName in region $LogAnalyticsLocation exists." -LogFileName $LogFileName -Severity Information
    Write-Output "`n"
    $Question = 'Do you want to create Azure Data Explorer (ADX) Raw and Mapping Tables for the tables in your Log Analytics workspace?'

    $Choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
    $Choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
    $Choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

    $Decision = $Host.UI.PromptForChoice($title, $question, $choices, 1)
    if ($Decision -eq 0) {
        Write-Verbose "Executing: Invoke-AzOperationalInsightsQuery -WorkspaceId $LogAnalyticsWorkspaceId -Query $queryAllTables" 
        try {       

            Write-Output "Retrieving tables from $LogAnalyticsWorkspaceName"
            Write-Log -Message "Retrieving tables from $LogAnalyticsWorkspaceName" -LogFileName $LogFileName -Severity Information
            $queryAllTables = 'search *| distinct $table| sort by $table asc nulls last'
            $resultsAllTables = (Invoke-AzOperationalInsightsQuery -WorkspaceId $LogAnalyticsWorkspaceId -Query $queryAllTables).Results
        }
        catch {
            Write-Error "An error occurred in querying tables from $LogAnalyticsWorkspaceName"
            Write-Log -Message "An error occurred in querying tables from $LogAnalyticsWorkspaceName" -LogFileName $LogFileName -Severity Error        
            exit
        }
    }
    else {
        try {
            Write-Host "Enter selected Log Analytics Table names separated by comma (,) (Case-Sensitive)" -ForegroundColor Blue
            $userInputTables = Read-Host 
            $resultsAllTables = $userInputTables.Split(',')
        }
        catch {
            Write-Error "Incorrect user input - table names should be separated with comma (,)"
            Write-Log -Message "Incorrect user input - table names should be separated with comma (,)" -LogFileName $LogFileName -Severity Error        
            exit
        }
        
    }
    $AdxTablesArray = New-Object System.Collections.Generic.List[System.Object]    
    New-AdxRawMappingTables -LaTables $resultsAllTables
    Write-Output "`n"
    $dataExportQuestion = 'Do you want to create Data Export and Data Ingestion rules in Azure Data Explorer (ADX)?'

    $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
    $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
    $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

    $dataExportDecision = $Host.UI.PromptForChoice($title, $dataExportQuestion, $choices, 0)
    if ($dataExportDecision -eq 0) {        
        $AdxMappedTables = Split-ArrayBySize -ADXTabsArray $AdxTablesArray.ToArray() -ArraySize 10
        Write-Verbose "Executing: New-EventHubNamespace -ArraysObject $AdxMappedTables"      
        $eventHubsForADX = New-EventHubNamespace -ArraysObject $AdxMappedTables
        Write-Verbose "Executing: New-LaDataExportRule -AdxEventHubs $eventHubsForADX -TablesArrayCollection $AdxMappedTables"        
        New-LaDataExportRule -AdxEventHubs $eventHubsForADX -TablesArrayCollection $AdxMappedTables
             
        $dataConnectionQuestionChoices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
        $dataConnectionQuestionChoices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
        $dataConnectionQuestionChoices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

        $dataConnectionDecision = $Host.UI.PromptForChoice($title, $dataConnectionQuestion, $dataConnectionQuestionChoices, 0)
        if ($dataConnectionDecision -eq 0) {
            Start-SleepMessage -Seconds 1800 -waitMessage "EventHubTopics for LA Tables are provisioning"                    
            New-ADXDataConnection -AdxEventHubs $eventHubsForADX
        }
        else {
            Write-Host "Creating data connection rules manually for $AdxDBName in $AdxEngineUrl"
            Write-Log -Message "Creating data connection rules manually for $AdxDBName in $AdxEngineUrl" -LogFileName $LogFileName -Severity Warning
            exit
        }
    } 
    else {
        Write-Host "Creating data export and data connection rules manually for $AdxDBName in $AdxEngineUrl"
        Write-Log -Message "Create data export data connection rules manually for $AdxDBName in $AdxEngineUrl" -LogFileName $LogFileName -Severity Warning
        exit
    }    

}
catch {
    Write-Error "$LogAnalyticsWorkspaceName not found" -ErrorAction Stop
    Write-Log -Message "$LogAnalyticsWorkspaceName not found" -LogFileName $LogFileName -Severity Error
}
