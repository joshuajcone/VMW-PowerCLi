[CmdletBinding()]
Param(
    $vCenterServer = (Read-Host -Prompt 'vCenter FQDN') ,
    $ClusterName = (Read-Host -Prompt 'Name of the cluster to patch') ,
    [PSCredential]$Credentials = (Get-Credential)
)
# Define the network share path and VIB file name
$VIB = "ixgben"
$targetVersion = "1.7.1.35-1vmw.703.0.20.19193900" # Please change for your VIB
$VIBFileName = "INT_bootbank_ixgben_1.15.1.0-1OEM.700.1.0.15843807.vib" # Please change for your VIB
$NetworkSharePath = ""

# Check for PowerCLI module
$powerCLIModule = "VMware.PowerCLI"
if (-not(Get-Module -ListAvailable -Name $powerCLIModule)) {
    Install-Module $powerCLIModule
    Import-Module $powerCLIModule # Might not be needed
} 

# Connect to vCenter
$vCStatus = (Connect-VIServer -Server $vCenterServer -Credential $Credentials)

# Get Server Objects from the cluster
$ESXiServers = @(get-cluster $ClusterName | get-vmhost)

# Start the Timer
$ScriptTimer = [System.Diagnostics.Stopwatch]::StartNew()

function PatchESXiServer ($CurrentServer) {
    # Variables
    $timeout = New-TimeSpan -Minutes 8
    $2ndtimeout = New-TimeSpan -Minutes 60
    $ServerName = $CurrentServer.Name

    # Get Host Settings
    $ESXcli = Get-ESXCli -VMHost $ServerName -V2

    # Gets information about the vib
    $getVIB = $ESXcli.software.vib.list.Invoke() | Where-Object { $_.Name -eq $VIB }
    $vibVersion = $getVIB.Version
    $vibName = $getVIB.Name

    # Split out the short name
    $hostName = $ServerName.split('.')[0].ToUpper()

    if ($vibVersion -ne $targetVersion) {

        # Write Output if the Vib version didn't match expected version
        Write-Output "Updating $vibName on $hostname"

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
                Write-Output "Server did not enter maintanenace mode. Cancelling remaining servers"
    
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

        # Write Output if the Vib version didn't match the expected version
        Write-Output "Updating $vibname on $hostname"

        # Get the local Datastore
        $targetDatastore = Get-Datastore -Name $hostName* | Where-Object { $_.Name -imatch "local*" }
                    
        # Create PSDrive on DS in preparation to copy the file
        try {
            $PSDrive = New-PSDrive -Location $targetDatastore -Name VIB -PSProvider  VimDatastore -Root "/"
        } # Close try to create PSDrve
        catch {
        $PSRoot = $PSDrive.Root
        $PSDataStore = $PSRoot.split('\')[3].ToUpper()
        
        # Write the error
        Write-Output "PSDrive could not be created on host $hostname. The target datastore is $PSDataStore"
        } # Close catch

        # Transfer the VIB to the ESXi host's temporary directory
        Copy-DatastoreItem $NetworkSharePath* VIB:/.locker/var/tmp/ -Force

        # Get and Set the Arguments
        $ESXiArgs = $ESXcli.software.vib.update.CreateArgs()
        $ESXiArgs.viburl = "/vmfs/volumes/$targetDatastore/.locker/var/tmp/$VIBFileName"
        $ESXiArgs.nosigcheck = $true
        $ESXiArgs.force = $true

        # Install the VIB on the ESXi Host
        $Status = $ESXcli.software.vib.update.Invoke($ESXiArgs)

        # Write the status of the job
        $jobStatus = $Status.Message
        Write-Output "## $jobStatus on $hostname ##"

        # Remove the PSDrive
        Remove-PSDrive -Name VIB

        if (($Status).RebootRequired -inotmatch "false") {

            # Reboot Host
            Write-Output "## $ServerName is Rebooting ##"
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
            Write-Output ## $ServerName is Down ##
    
            # Check every minute for server to be back from reboot and in maintenance mode
            do {
                Start-Sleep 60
                $ServerState = (get-vmhost $ServerName).ConnectionState
                Write-Output "## $ServerName is Waiting for Reboot ##"
            } # Close waiting for server to reboot

            # Wait for server to come back in Maintenance Mode, or passes $2ndtimeout
            until (($ServerState -eq "Maintenance") -or ($RebootTimer.Elapsed -ge $2ndtimeout)) 

            # If passed $2ndtimeout the job exits
            if ($RebootTimer.Elapsed -ge $2ndtimeout) {
            
                # Stop the Stopwatch
                if ($RebootTimer.IsRunning -eq "True") { $RebootTimer.Stop() }
                if ($ScriptTimer.IsRunning -eq "True") { $ScriptTimer.Stop() }

                # Inform user which server did not come back online after a reboot
                Write-Output "## $ServerName did not complete reboot ##"

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
                Write-Output "## $ServerName is back up. Took $Minutes minutes and $Seconds seconds ##"
        
                # Stop the Stopwatch
                if ($RebootTimer.IsRunning -eq "True") { $RebootTimer.Stop() }
            } # Close output for Reboot time

        } # Close check for reboot required

        else {
            Write-Output "Maintenance Mode is NOT required for $hostname"
        }
      
        # Exit maintenance mode
        Write-Output "## Exiting Maintenance mode ##"
        Set-VMhost $CurrentServer -State Connected | Out-Null
        do {
            Start-Sleep 10
            $ServerState = (get-vmhost $ServerName).ConnectionState
        } # Close check for server to be online and in Maintenance Mode
        while ($ServerState -eq "Maintenance") 
        Write-Output "## Patch Complete ##"
    } # Close check for $VIB version
    elseif ($vibVersion -eq $targetVersion) {
        Write-Output "## $vibName on host $hostname is already set ##"
    } # Close Elseif

} # Close Patch Function

# Main loop for the "RebootESXiServer" function.
foreach ($ESXiServer in $ESXiServers) {
    PatchESXiServer ($ESXiServer)
}

# Report the total script time
$ScriptHours = $ScriptTimer.Elapsed.Hours
$ScriptMinutes = $ScriptTimer.Elapsed.Minutes
$ScriptSeconds = $ScriptTimer.Elapsed.Seconds
if ($ScriptHours -gt 0) {
    Write-Output "## The script is complete. Total time was $ScriptHours hours $ScriptMinutes minutes and $ScriptSeconds seconds ##"
}
else {
    Write-Output "## The script is complete. Total time was $ScriptMinutes minutes and $ScriptSeconds seconds ##" 
}
# Confirm all stopwatches are stopped
if ($RebootTimer.IsRunning -eq "True") { $RebootTimer.Stop() }
if ($ScriptTimer.IsRunning -eq "True") { $ScriptTimer.Stop() }

# Close vCenter connection
if ($vcstatus.IsConnected -eq "True") { $vCStatus = (Disconnect-VIServer -Server $vCenterServer -Confirm:$false) }
