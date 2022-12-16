[CmdletBinding()]
Param(
    $vCenterServer = (Read-Host -Prompt 'vCenter FQDN') ,
    $ClusterName = (Read-Host -Prompt 'Name of the cluster to collect NQNs for') ,
    [PSCredential]$Credentials = (Get-Credential)
)

# Report path and name output
$ReportPath = 'c:\temp' 
$ReportName = 'NQN'

# Connect to vCenter
Connect-VIServer -Server $vCenterServer -Credential $Credentials | Out-Null
    
# Get Server Objects from the cluster
$ESXiServers = @(get-cluster $ClusterName | get-vmhost)

function NVMeDataCollect ($CurrentServer) {

    # Set the server Name
    $ServerName = $CurrentServer.Name

    # Get the Server Settings
    $EsxCli = Get-EsxCli -VMHost $ServerName -V2

    # Get Information for the Report
    [Ordered]@{
        'VMHost'  = $ServerName
        'HostNQN' = $EsxCli.nvme.info.get.invoke().HostNQN
    } # Close the Hash Table
} # Close NVMeDataCollect
    
# Loop to get NQN's
$NQNReport = foreach ($ESXiServer in $ESXiServers) { NVMeDataCollect ($ESXiServer) }

# Output the Report
$Out = @()
$NQNOut = $NQNReport | ForEach-Object -Parallel {
    $rollup = $using:Out
    $rollup += [PSCustomObject]@{
        Name = $_.VMHost
        NQN  = $_.HostNQN
    } # Close create object
    return $rollup
} # Close the data rollup 

# Output the NQN data
Write-Output $NQNOut

# Export the NQN's
$NQNOut | Export-Csv -Path $ReportPath\$ReportName.csv -UseCulture

# Write the output path
Write-Output "Report has been exported to $ReportPath\$ReportName.csv"

# Close vCenter connection
Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null
