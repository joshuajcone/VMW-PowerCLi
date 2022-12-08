[CmdletBinding()]
Param(
    $vCenterServer = (Read-Host -Prompt 'vCenter FQDN') ,
    $ClusterName = (Read-Host -Prompt 'Name of the cluster to disable Bloom Filter for') ,
    [PSCredential]$Credentials = (Get-Credential)
)

# Connect to vCenter
Connect-VIServer -Server $vCenterServer -Credential $Credentials | Out-Null
    
# Get Server Objects from the cluster
$ESXiServers = @(get-cluster $ClusterName | get-vmhost)
        
# Puts an ESXI server in maintenance mode, changes the Bloom setting, and the puts it back online
# Requires fully automated DRS and enough HA capacity to take a host off line
        
Function BloomFilter ($CurrentServer) {
    # Get Server name
    $ServerName = $CurrentServer.Name
    
    # Check Bloom Status
    $esxcli = Get-EsxCli -VMHost $ServerName -V2
    $result = $esxcli.system.settings.advanced.list.Invoke(@{option = '/SE/BFEnabled'})

    # If the Bloom Filter was not disabled then runs workflow to disable
    if($result.intvalue -ne 0){
               
        # Put server in maintenance mode
        Write-Output "#### Maintenance Mode $ServerName ####"
        Set-VMhost $CurrentServer -State maintenance -Evacuate | Out-Null
        Write-Output "$ServerName is in Maintenance Mode"
        
        # Apply Bloom filter setting
        Write-Output "Apply Bloom"
        $esxcli.system.settings.advanced.set.Invoke((@{option = '/SE/BFEnabled'; intvalue = 0 }))
    } # Close apply Bloom Filter

    # Exit maintenance mode
    Write-Output "Exiting Maintenance mode"
    Set-VMhost $CurrentServer -State Connected | Out-Null
    Write-Output "#### Change Complete ####"
    Write-Output ""

    # Write if the server was already set
    else {
        Write-Output "$ServerName is already set"
    } # Close else    
} # Close BloomFilter Function

# Main loop
foreach ($ESXiServer in $ESXiServers) {
BloomFilter ($ESXiServer)
}
    
# Close vCenter connection
Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null
