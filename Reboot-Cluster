[CmdletBinding()]
Param(
    $vCenterServer = (Read-Host -Prompt 'vCenter FQDN') ,
    $ClusterName = (Read-Host -Prompt 'Name of the cluster to do a rolling reboot to') ,
    [PSCredential]$Credentials = (Get-Credential)
)

# Connect to vCenter
(Connect-VIServer -Server $vCenterServer -Credential $Credentials)

# Get Server Objects from the cluster
$ESXiServers = @(get-cluster $ClusterName | get-vmhost)

# Start the Timer
$ScriptTimer = [System.Diagnostics.Stopwatch]::StartNew()

function RebootESXiServer ($CurrentServer) {
# Variables
$timeout = New-TimeSpan -Minutes 8
$2ndtimeout = New-TimeSpan -Minutes 40
$ServerName = $CurrentServer.Name

# Write Output of Host being rebooted
Write-Output “## Rebooting $ServerName ##”

# Get the server state
$ServerState = (get-vmhost $ServerName).ConnectionState

# If the server was not in MM, then it sets the host for MM
if ($ServerState -ne “Maintenance”){
    Write-Output “$ServerName is entering Maintenance Mode”
    Set-VMhost $CurrentServer -State maintenance -Evacuate | Out-Null
        
    # Get the Server State again to check for a server that did not enter MM
    $ServerState = (get-vmhost $ServerName).ConnectionState

    # If server did not enter maintenance mode the script will exit
    if ($ServerState -ne “Maintenance”) {
            Write-Output “Server did not enter maintanenace mode. Cancelling remaining servers”
        
        # Stop the Stopwatch
        if ($ScriptTimer.IsRunning -eq "True") {$ScriptTimer.Stop()}
        
        # Disconnect vCenter
        (Disconnect-VIServer -Server $vCenterServer -Confirm:$false)
        Exit
    } # Close check that exits out of the script if server does not enter Maintenance Mode

    # Write Ouput the host is in MM
    Write-Output “$ServerName is in Maintenance Mode”
} # Close set Maintenance Mode
    
# If the server was already in MM, then continue to reboot
elseif ($ServerState -eq “Maintenance”) {
        
    # Write Output if the host was already in MM before being set
    Write-Output “$ServerName is already in Maintenance Mode”
} # Close catch if server was already in MM.

# Reboot server
Write-Output “$ServerName is Rebooting”
Restart-VMHost $CurrentServer -Confirm:$false | Out-Null

# Start the Timer
$RebootTimer = [System.Diagnostics.Stopwatch]::StartNew()

# Wait for Server to show as down
do {
    Start-Sleep 1
    $ServerState = (get-vmhost $ServerName).ConnectionState
} # Close check for server state every second
until (($ServerState -eq "NotResponding") -or ($RebootTimer.Elapsed -ge $timeout)) 
    Write-Output “$ServerName is Down”
    
# Wait for server to be in maintenance mode
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
        if ($RebootTimer.IsRunning -eq "True") {$RebootTimer.Stop()}
        if ($ScriptTimer.IsRunning -eq "True") {$ScriptTimer.Stop()}

        # Prepare for exit by disconnecting vCenter
        Write-Output "$ServerName did not complete reboot"
        Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null

        # Exit out
        Exit
    } # Close check for script timeout
    else {
        $Minutes = $RebootTimer.Elapsed.Minutes
        $Seconds = $RebootTimer.Elapsed.Seconds
        Write-Output "$ServerName is back up. Took $Minutes minutes and $Seconds seconds"
        
        # Stop the Stopwatch
        if ($RebootTimer.IsRunning -eq "True") {$RebootTimer.Stop()}
    } # Close output for Maintenace Mode time
      
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

foreach ($ESXiServer in $ESXiServers) {
    RebootESXiServer ($ESXiServer)
}

# Report the total script time
$ScriptMinutes = $ScriptTimer.Elapsed.Minutes
$ScriptSeconds = $ScriptTimer.Elapsed.Seconds
Write-Output "The script is complete. Total time was $ScriptMinutes minutes and $ScriptSeconds seconds"

# Confirm all stopwatches are stopped
if ($RebootTimer.IsRunning -eq "True") {$RebootTimer.Stop()}
if ($ScriptTimer.IsRunning -eq "True") {$ScriptTimer.Stop()}

# Close vCenter connection
Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null
