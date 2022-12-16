[CmdletBinding()]
Param(
    $vCenterServer = (Read-Host -Prompt 'vCenter FQDN') ,
    $ClusterName = (Read-Host -Prompt 'Name of the cluster to collect WWPNs for') ,
    [PSCredential]$Credentials = (Get-Credential)
)

# Report path and name output
$ReportPath = 'c:\temp' 
$ReportName = 'WWPN'

# Connect to vCenter
Connect-VIServer -Server $vCenterServer -Credential $Credentials | Out-Null
    
# Get Server Objects from the cluster
$ESXiServers = @(get-cluster $ClusterName | get-vmhost)

function FCDataCollect ($CurrentServer) {

    # Set the server Name
    $ServerName = $CurrentServer.Name

    # Get the Server Settings
    $HBAs = Get-VMHostHBA -Type FibreChannel -VMHost $CurrentServer
    
    # Loop to get WWPN information for each server
    foreach ($HBA in $HBAs) {
        [Ordered]@{
            VMHost = $ServerName
            Device = Get-VMHostHBA -Type FibreChannel -VMHost $ServerName -Device $HBA.Device | Select-Object Device
            WWPN   = Get-VMHostHBA -Type FibreChannel -VMHost $ServerName -Device $HBA.Device | Select-Object @{N = "WWPN"; E = { "{0:X}" -f $_.PortWorldWideName } }
        } # Close Hash Table
    } # Close loop for HBA export
} # Close FCDataCollect Function
    
# Main loop
$WWPNReport = foreach ($ESXiServer in $ESXiServers) { FCDataCollect ($ESXiServer) }


$Out = @()
$WWPNOut = $WWPNReport | ForEach-Object -Parallel {
    $rollup = $using:Out
    $rollup += [PSCustomObject]@{
        Name = $_.VMHost
        HBA  = $_.Device
        WWPN = $_.WWPN
    } # Close create object
    return $rollup
} # Close the data rollup 

# Write the output of the WWPN data rollup
Write-Output $WWPNOut

# Export the NQN's
$WWPNOut | Export-Csv -Path $ReportPath\$ReportName.csv -UseCulture
  
# Write the output path
Write-Output "Report has been exported to $ReportPath\$ReportName.csv"

# Close vCenter connection
Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null
