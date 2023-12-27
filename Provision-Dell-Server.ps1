# Fill out the values for this script in "Dell-Server-Provisioning.xlsx
# This script changes the default "root" iDrac user password, and adds a second user, user ID and password defined in the spreadsheet
# Reverse DNS must work for the iDrac Name
# The script only looks at IP's set in the spreadsheet.

# Make sure the excel module is installed
$excelModule = "ImportExcel"
if (-not(Get-Module -ListAvailable -Name $excelModule)) {
    Install-Module $excelModule
    Import-Module $excelModule # Might not be needed
} 

# Load the Excel COM object
$excel = New-Object -ComObject Excel.Application

# Open the Excel spreadsheet
$workbook = $excel.Workbooks.Open("C:\Temp\Dell-Server-Provisioning.xlsx")
$worksheet = $workbook.Worksheets.Item(1)
$rowMax = $worksheet.UsedRange.Rows.Count - 1

# Define the iDRAC Redfish API endpoint URL, username, and password
$username = "root"
$password = "calvin"

# Conver the password into secure string
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)

# Define the new account parameters
$newUserID = "3"
$privilege = "Administrator"

# Function to perform DNS lookup
function Get-DnsNameFromIP {
    param([string]$ipAddress)
    try {
        $hostName = [System.Net.Dns]::GetHostEntry($ipAddress).HostName
        return $hostName
    }
    catch {
        Write-Host "Reverse DNS lookup failed for IP: $ipAddress"
        return $null
    }
}

# Loop through the rows in the Excel spreadsheet and update iDRAC settings
for ($i = 1; $i -le $rowMax; $i++) {
    # Access the cells in each row
    $newUsername = $worksheet.Cells.Item($i + 1, 1).Text
    $newUserPassword = $worksheet.Cells.Item($i + 1, 2).Text
    $defaultUserPassword = $worksheet.Cells.Item($i + 1, 3).Text
    $registerDNSiDRAC = $worksheet.Cells.Item($i + 1, 4).Text
    $ipAddress = $worksheet.Cells.Item($i + 1, 5).Value2

    # Input Validation
    if ($null -eq $newUsername) { throw [System.ArgumentNullException] "New User username is empty, if you beleive the field is populated try deleting some empty rows in the Excel, as it might be counting them." }
    if ($null -eq $newUserPassword) { throw [System.ArgumentNullException] "New User password is empty for $username, if you beleive the field is populated try deleting some empty rows in the Excel, as it might be counting them." }
    if ($null -eq $defaultUserPassword -or $defaultUserPassword -inotmatch "enabled" -or $defaultUserPassword -inotmatch "disabled") { throw [System.ArgumentNullException] "New password entry for the default root user is blank, if you beleive the field is populated try deleting some empty rows in the Excel, as it might be counting them." }
    if ($null -eq $registerDNSiDRAC) { throw [System.ArgumentNullException] "Should the server register the iDRAC name on DNS is not set to Enabled/Disabled, if you beleive the field is populated correctly try deleting some empty rows in the Excel, as it might be counting them." }
    if ($null -eq $ipAddress) { throw [System.ArgumentNullException] "iDrac IP address is blank, if you beleive the field is populated try deleting some empty rows in the Excel, as it might be counting them." }

    # Performs DNS lookup function
    $FQDN = Get-DnsNameFromIP $ipAddress

    # If FQDN exists 
    if ($FQDN) {
        # Set Base URI path
        $iDracBaseUrl = "https://$ipAddress/redfish/v1"

        try {
            
            # iDRAC9 - Get List of users IDs
            $accountsListAPI = "$iDracBaseUrl/AccountService/Accounts/"
            $accountsList = Invoke-WebRequest -Uri $accountsListAPI -Method Get -Credential $credential -ContentType 'application/json' -SkipCertificateCheck -ErrorVariable RespErr
            $StatusCode = $accountsList.StatusCode
            $accountIDData = $accountsList.Content | ConvertFrom-Json | Select-Object -ExpandProperty Members
            if ($StatusCode -eq "200") {
                Write-Output "Successfully added users account $newUsername"
            }
        }   catch {
            Write-Host "Unable to get User ID's. Error:"$resperr.InnerException.Response.StatusCode""
            return
        } # Close catch

        # iDRAC9 - Account details
        $currentAccounts = foreach ($id in $accountIDData) {
            $accountId = Split-Path -Path $id.'@odata.id' -Leaf
            $accountAPI = "$iDracBaseUrl/AccountService/Accounts/$accountId"
            $accountInfo = Invoke-WebRequest -Uri $accountAPI -Method Get -Credential $credential -ContentType 'application/json' -SkipCertificateCheck
            $account = $accountInfo.Content | ConvertFrom-Json
            if (-not([string]::IsNullOrWhiteSpace($account.UserName))) {
                $account | Select-Object UserName, Id
            } # Close "if" check for empty accounts
        } # Close foreach
        # Check to see is new account already exists
        if ($currentAccounts.UserName -inotmatch $newUsername) {

            #Build the URI for adding new User
            $NewUserUrl = "$iDracBaseUrl/AccountService/Accounts/$newUserID"

            try {
                # Setup JsonBody for new User
                $NewAccountJsonBody = @{UserName = $newUsername; Password = $newUserPassword; RoleId = $privilege; Enabled = $true } | ConvertTo-Json -Compress
    
                # Call to add user
                $newUserAdd = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $NewUserUrl -Credential $credential -Method Patch -Body $NewAccountJsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json" } -ErrorVariable RespErr
                $StatusCode = $newUserAdd.StatusCode
                if ($StatusCode -eq "200") {
                    Write-Output "Successfully added users account $newUsername"
                }
            }   catch {
                Write-Host "Unable to add new user. Error:"$resperr.InnerException.Response.StatusCode""
                return
            } # Close catch 
        }# Close check for new username match

        # Else statement if the new user account already exists.
        else {
            Write-Output "The useraccount $newUsername already exists"
        }

        # Build the URI path for network settings
        $attributes = "$iDracBaseUrl/Managers/iDRAC.Embedded.1/Attributes"

        #Get Initial Results
        $networkInformation = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $attributes -Credential $credential -Method Get -UseBasicParsing -Headers @{"Accept" = "application/json" } -ErrorVariable RespErr 
        $network = ($networkInformation).Content | ConvertFrom-Json
        
		# Commented out, but saved for later use.
        # $ipAddress = $network.Attributes.'IPv4.1.Address'
        $DNS1 = $network.Attributes.'IPv4.1.DNS1'
        $DNS2 = $network.Attributes.'IPv4.1.DNS2'
        $defaultGateway = $network.Attributes.'IPv4.1.Gateway'
        $subnetMask = $network.Attributes.'IPv4.1.Netmask'

        $hostName = $FQDN.split('.')[0].ToUpper()
        $domain = $FQDN.split('.')[1] + "." + $FQDN.split('.')[2]
   
        try {
            #Build Json table for iDRAC settings
            $NewHostNameJsonBody = @{"Attributes" = @{ 
                    "IPv4Static.1.Address"      = $ipAddress
                    "IPv4Static.1.Gateway"      = $defaultGateway
                    "IPv4Static.1.Netmask"      = $subnetMask
                    "IPv4Static.1.DNS1"         = $DNS1
                    "IPv4Static.1.DNS2"         = $DNS2
                    "IPv4Static.1.DNSFromDHCP"  = "Disabled"
                    "NICStatic.1.DNSDomainName" = $domain
                    "NIC.1.DNSRacName"          = $hostname
                    "NIC.1.DNSDomainFromDHCP"   = "Disabled"
                    "NIC.1.DNSRegister"         = $registerDNSiDRAC
                    "IPv4.1.DHCPEnable"         = "Disabled" 
                }
            } | ConvertTo-Json -Compress
    
            #Call to Update iDRAC settings
            $networkUpdate = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $attributes -Credential $credential -Method Patch -Body $NewHostNameJsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json" } -ErrorVariable RespErr

            $StatusCode = $networkUpdate.StatusCode
            if ($StatusCode -eq "200") {
                Write-Output "Successfully set network settings on $hostname"
            }
        }   catch {
            Write-Host "Unable to set network settings on $hostname. Error:"$resperr.InnerException.Response.StatusCode""
            return
        } # Close catch 

            #Get Post change Results - Commented out, bet left for later use
            # $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $attributes -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"}

            # $Postresults = $result.Content | ConvertFrom-Json

        }   catch {
            Write-Host "Failed to change system settings for $hostname. Error:"$resperr.InnerException.Response.StatusCode""
            return
        } #End catch

        # Build the URI for changing default User password
        $DefaultUserPasswordUrl = "$iDracBaseUrl/AccountService/Accounts/2"

        #Setup JsonBody for changing default User password
        $DefaultUserPasswordJsonBody = @{Password = $defaultUserPassword } | ConvertTo-Json -Compress
        try {
            # Call to change default user password
            Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $DefaultUserPasswordUrl -Credential $credential -Method Patch -Body $DefaultUserPasswordJsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json" } -ErrorVariable RespErr
        }   catch {
            Write-Host "Unsuccessfully changed default users password. Error:"$resperr.InnerException.Response.StatusCode""
            return
        } # Close catch 
    } #End FQDN Check
    else {
        Write-Host "FQDN does not exist for $ipaddress"
        return
    } #End else
} #Close foreach for current accounts
 


# Close the Excel spreadsheet and release resources
$workbook.Close($false)
$excel.Quit()
[System.Runtime.Interopservices.Marshal]::ReleaseComObject($worksheet) | Out-Null
[System.Runtime.Interopservices.Marshal]::ReleaseComObject($workbook) | Out-Null
[System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Pause
