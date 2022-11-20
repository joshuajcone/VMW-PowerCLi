#Assign tag on VM that matches the home ESXi hostname

$vCenterServer = "Your vCenter Name"
$cluster_name = "Your Cluster Name"
$tag_category = "The Category of the Tag"
$sendTo = "SendToAddress@Sterilized.com"
$From = "vCenter@Sterilized.com"
$Smtp = "SMTP-Relay.Sterilized.com"

#Connect to vCenterServer
Connect-VIServer -Server $vCenterServer | Out-Null

#Get The VM's in the Cluster
$VMs = Get-Cluster $cluster_name | Get-VM | Where-Object {$_.PowerState -eq 'PoweredOn'}

#Loop for VM's
foreach($VM in $VMs)
   {
    #Get the ESXi hostname of the VM
    $esxHost = Get-VMHost -VM $VM

    #Get the VM Tags 
    $VMTag = (Get-TagAssignment -Entity $vm -Category $tag_category).Tag.Name

    #Check to see if the assigned VMTag is Null
    if ($null -eq $VMTag) {

        #Uncomment the next line to output if a VM in the cluster doesn't have a tag assigned to local console
        #Write-Output "$VM does not have a tag assigned"

        #Email alert if a VM in the cluster doesn't have a tag assigned.
        $MailString = "VM $VM Does not have a tag assigned, it currently lives on $esxHost."
        Send-MailMessage -From $From -To $sendTo -Subject "EPICODB-VM $VM No Tag Assigned" -SmtpServer $Smtp -Body $MailString
   
   }
   #Check to see if the assigned VMTag matches the ESXi hostname
   Elseif ($VMTag -notlike $esxHost) {

        #Uncomment the next line to output the VMname in the wrong location to local console
        #Write-Output "$VM needs to move to $VMTag"

        #Output the VMname in the wrong location to email.
        $MailString = "VM $VM is on the wrong host, it needs to move to $VMTag."
        Send-MailMessage -From $From -To $sendTo -Subject "EPICODB-VM $VM Not Home" -SmtpServer $Smtp -Body $MailString
   } 
} # Close foreach loop

# Close vCenter connection
Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null
