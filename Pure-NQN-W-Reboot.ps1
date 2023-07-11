# This script automates https://support.purestorage.com/Solutions/VMware_Platform_Guide/How-To%27s_for_VMware_Solutions/NVMe_over_Fabrics/How_To%3A_Setup_NVMe-FC_with_VMware
# Supply the hostname/FQDN for your vcenter server, and the name of the cluster you want NVMe settings applied for
# Script reboots each ESXi server in the cluster, one at a time, only if the FC adapter module is changed
[CmdletBinding()]
Param(
    $vCenterServer = (Read-Host -Prompt 'vCenter FQDN'),
    $ClusterName = (Read-Host -Prompt 'Name of the cluster to apply NVMe changes to') ,
    $AdapterType = (Read-Host -Prompt 'Press 1 for Emulex, Press 2 for Qlogic') ,
    [PSCredential]$Credentials = (Get-Credential)
)
$EmulexCard = 'lpfc'
$EmulexCardOption = 'lpfc_enable_fc4_type=3'
$QlogicCard = 'qlnativefc'
$QlogicCardOption = 'ql2xnvmesupport=1'
$ReportPath = 'c:\temp' 
$ReportName = 'NQN'

#ClaimRule parameters
$ClaimRule = @{
    rule         = 102
    type         = 'vendor'
    plugin       = 'HPP'
    configstring = 'latency-eval-time=180000,pss=LB-Latency'
    vendor       = 'NVMe'
    model        = 'Pure*'
}

# Connect to vCenter
$vCStatus = (Connect-VIServer -Server $vCenterServer -Credential $Credentials)

# Get Server Objects from the cluster
$ESXiServers = @(get-cluster $ClusterName | get-vmhost)

# Start the Timer
$ScriptTimer = [System.Diagnostics.Stopwatch]::StartNew()

function RebootESXiServer ($CurrentServer) {
    # If the script made a change it will reboot the host

    # Variables
    $timeout = New-TimeSpan -Minutes 8
    $2ndtimeout = New-TimeSpan -Minutes 40
    $ServerName = $CurrentServer.Name
    
    # Write Output of Host being rebooted
    Write-Output "## Rebooting $ServerName ##"
    
    # Get the server state
    $ServerState = (get-vmhost $ServerName).ConnectionState
    
    # If the server was not in MM, then it sets the host for MM
    if ($ServerState -ne "Maintenance") {
        Write-Output "$ServerName is entering Maintenance Mode"
        Set-VMhost $CurrentServer -State maintenance -Evacuate | Out-Null
            
        # Get the Server State again to check for a server that did not enter MM
        $ServerState = (get-vmhost $ServerName).ConnectionState
    
        # If server did not enter maintenance mode the script will exit
        if ($ServerState -ne "Maintenance") {
            Write-Output “Server did not enter maintanenace mode. Cancelling remaining servers”
            
            # Stop the Stopwatch
            if ($ScriptTimer.IsRunning -eq "True") { $ScriptTimer.Stop() }
            
            # Disconnect vCenter
            (Disconnect-VIServer -Server $vCenterServer -Confirm:$false)
            Exit
        } # Close check that exits out of the script if server does not enter Maintenance Mode
    
        # Write Ouput the host is in MM
        Write-Output "$ServerName is in Maintenance Mode"
    } # Close set Maintenance Mode
        
    # If the server was already in MM, then report, and continue to reboot
    elseif ($ServerState -eq "Maintenance") {
            
        # Write Output if the host was already in MM before being set
        Write-Output "$ServerName is already in Maintenance Mode"
    } # Close catch if server was already in MM.
    
    # Reboot server
    Write-Output "$ServerName is Rebooting"
    Restart-VMHost $CurrentServer -Confirm:$false | Out-Null
    
    # Start the Timer
    $RebootTimer = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Check every second for server to show as down
    do {
        Start-Sleep 1
        $ServerState = (get-vmhost $ServerName).ConnectionState
    } # Close check for server state every second
    
    # A timeout was added here in case the server reboots without reporting "Not Responding status", behavior introduced in 7.0u3h
    until (($ServerState -eq "NotResponding") -or ($RebootTimer.Elapsed -ge $timeout)) 
    Write-Output "$ServerName is Down"
        
    # Check every minute for server to be back from reboot and in maintenance mode
    do {
        Start-Sleep 60
        $ServerState = (get-vmhost $ServerName).ConnectionState
        Write-Output "$ServerName is Waiting for Reboot"
    } # Close waiting for server to reboot
    
    # Wait for server to come back in Maintenance Mode, or passes $2ndtimeout
    until (($ServerState -eq "Maintenance") -or ($RebootTimer.Elapsed -ge $2ndtimeout)) 
    
    # If passed $2ndtimeout the job exits
    if ($RebootTimer.Elapsed -ge $2ndtimeout) {
                
        # Stop the Stopwatch
        if ($RebootTimer.IsRunning -eq "True") { $RebootTimer.Stop() }
        if ($ScriptTimer.IsRunning -eq "True") { $ScriptTimer.Stop() }
    
        # Inform user which server did not come back online after a reboot
        Write-Output "$ServerName did not complete reboot"
    
        # Prepare for exit by disconnecting vCenter
        Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null
    
        # Exit out
        Exit
    } # Close check for script timeout
    
    # If the server successfully comes back after reboot, the script continues
    else {
    
        # Report the total server reboot time.
        $Minutes = $RebootTimer.Elapsed.Minutes
        $Seconds = $RebootTimer.Elapsed.Seconds
        Write-Output "$ServerName is back up. Took $Minutes minutes and $Seconds seconds"
            
        # Stop the Stopwatch
        if ($RebootTimer.IsRunning -eq "True") { $RebootTimer.Stop() }
    } # Close output for Reboot time
          
    # Exit maintenance mode
    Write-Output "Exiting Maintenance mode"
    Set-VMhost $CurrentServer -State Connected | Out-Null
    do {
        Start-Sleep 10
        $ServerState = (get-vmhost $ServerName).ConnectionState
    } # Close check for server to be online and in Maintenance Mode
    while ($ServerState -eq "Maintenance") 
    Write-Output "## Reboot Complete ##"
} # Close Reboot Function

Function NVMeSettings ($CurrentServer) {

    # Set the server name
    $ServerName = $CurrentServer.Name

    # Get the Server settings
    $esxcli = Get-EsxCli -VMHost $ServerName -V2

    # If adapter type is 1, then it checks for lpfc
    if ($AdapterType -eq 1 ) {   
        $lpfc = Get-VMHostModule -VMHost $Servername -Name 'lpfc'
    } # Close check for Emulex adapter

    # If adapter type is 2, then it checks for qlnativefc
    elseif ($AdapterType -eq 2 ) {
        $qlnativefc = Get-VMHostModule -VMHost $Servername -Name 'qlnativefc'
    } # Close check for Qlogic adapter

    # If the Emulex Module is not set, it sets it
    if ($AdapterType -eq 1 ) {
        if (-not( $lpfc.options -match $EmulexCardOption)) {
            Write-Output "Setting LPFC on $ServerName"
            $module = Get-VMHostModule -VMHost $ServerName -Name $EmulexCard
            Set-VMHostModule -HostModule $module -options $EmulexCardOption | Out-Null
            RebootESXiServer ($CurrentServer)
        } # Close setting the Adapter
    } # Close the switch for Emulex adapter settings

    # If the Qlogic Module is not set, it sets it
    elseif ($AdapterType -eq 2 ) {
        if (-not( $qlnativefc.options -match $QlogicCardOption)) {
            Write-Output "Setting qLnativefc on $ServerName"
            $module = Get-VMHostModule -VMHost $ServerName -Name $QlogicCard
            Set-VMHostModule -HostModule $module -options $QlogicCardOption | Out-Null
            RebootESXiServer ($CurrentServer)
        } # Close setting the Adapter
    } # Close the switch for Qlogic adapter settings
    else {
        Write-Output "Please try again. Choose 1 for Emulex, or 2 for Qlogic"
        Exit
    } # Close check for "1" or "2" for adapter type   
       
    # If the Claim rule has not been set, it will set the claim rule
    if (-not($esxcli.storage.core.claimrule.list.Invoke() | Where-Object Rule -EQ $Claimrule.rule)) {
        Write-Output "Adding Claim Rule $ServerName"
        $esxcli.storage.core.claimrule.add.Invoke($ClaimRule) | Out-Null
        $esxcli.storage.core.claimrule.load.invoke() | Out-Null
    } # Close If
} # Close NVMeSettings

function FCDataCollect ($CurrentServer) {

    # Set the server name
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
} # Close the FCDataCollect Function

function NVMeDataCollect ($CurrentServer) {

    $ServerName = $CurrentServer.Name

    # Get the Server Settings
    $NvmeData = Get-EsxCli -VMHost $ServerName -V2

    # Get Information for the Report
    [Ordered]@{
        'VMHost'  = $ServerName
        'HostNQN' = $NvmeData.nvme.info.get.invoke().HostNQN
    } # Close the Hash Table
} # Close the NVMeDataCollect Function

# Main Loop
foreach ($ESXiServer in $ESXiServers) {
    NVMeSettings ($ESXiServer)
} # Close the primary loop

# 2nd Loop for NVMe Report
$NVMeReport = foreach ($ESXiServer in $ESXiServers) {
    NVMeDataCollect ($ESXiServer)
}

# 3rd Loop for WWPN Report
$WWPNReport = foreach ($ESXiServer in $ESXiServers) {
    FCDataCollect ($ESXiServer)
} # Close the secondary loop

# Rollup the data for export
$Export = @()
$RolledOutPut = $WWPNReport + $NVMeReport | ForEach-Object -Parallel {
    $Rollup = $using:Export
    $Rollup += [PSCustomObject]@{
        Name = $_.VMHost
        NQN  = $_.HostNQN
        HBA  = $_.Device
        WWPN = $_.WWPN
    }
    return $Rollup
} # Close the data rollup

# Export the report
$RolledOutPut | Export-Csv -Path $ReportPath\$ReportName.csv -UseCulture

# Report the total script time
$ScriptHours = $ScriptTimer.Elapsed.Hours
$ScriptMinutes = $ScriptTimer.Elapsed.Minutes
$ScriptSeconds = $ScriptTimer.Elapsed.Seconds
if ($ScriptHours -gt 0) {
    Write-Output "The script is complete. Total time was $ScriptHours hours $ScriptMinutes minutes and $ScriptSeconds seconds"
}
else {
    Write-Output "The script is complete. Total time was $ScriptMinutes minutes and $ScriptSeconds seconds" 
}

# Confirm all stopwatches are stopped
if ($RebootTimer.IsRunning -eq "True") { $RebootTimer.Stop() }
if ($ScriptTimer.IsRunning -eq "True") { $ScriptTimer.Stop() }

# Close vCenter connection
if ($vcstatus.IsConnected -eq "True") { $vCStatus = (Disconnect-VIServer -Server $vCenterServer -Confirm:$false) }
