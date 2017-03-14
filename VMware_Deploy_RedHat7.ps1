<#.DESCRIPTION
			Script that will connect to a Vsphere enviroment and create a Linux Server. This example
            was tested with RedHat7.2.
            
            Pre-requirements:
            This will require to have PowerCli installed. 
            Will also require that you have a server template created.
            Have a customization created.

            The intention is to script a server deployment and initial configuration.
            This example will create a server with 2 Nics and 2 drives.
            Once the server is ready the NICs will be configured at the OS level. 
            In my case I needed to set NIC1 (PROD) as primary and use custom routes on the second NIC (ADMIN).
            THe second drive will be formatted and configured to auto mount.
            In this example I also wanted to create a new user. 

            This example is using a standard vSwitch. The commands for a Distibuted vSwitch are slightly different

#>

##Create Transcript for logging purposes - Edit the outpath according to your needs
#Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
$date = get-date -f yyyy-MM-dd
$outPath = "YourPath" # This is the path to save the results
Start-Transcript -path $outPath -Append


##This section contains the commands to connect to Vcenter Edit according to your enviroment---
Get-Module -ListAvailable VMware* | Import-Module | Out-Null
# ------vSphere Targeting Variables tracked below------
$vCenterInstance = "YourIP or vCenterNAme"
$vCenterUser = "YourUser"
$vCenterPass = "YourPassword"
# This section logs on to the defined vCenter instance above
Connect-VIServer $vCenterInstance -User $vCenterUser -Password $vCenterPass -WarningAction SilentlyContinue


######################################################-User-Definable Variables In This Section - Edit According to your enviroment##########################################################################################
$VMName= "YourVmName" # Name for VM
$VMFolder = "YourFolder" # VmWare Folder to place VM
$VMCluster = Get-cluster -Name "YourCluster"  # VMware Cluster
$ResourcePool = Get-ResourcePool -Name "YourResourcePool" # VMware resourcepool
$VMtemplate = Get-Template -Name "YourTemplate" # Template Name which will be used to generate the new VM
$VMDatastore = Get-Datastore -Name "YourDatastore" # Datastore where to place the OS drive of the new VM
$VMCustomization = Get-OSCustomizationSpec -Name "YourCustomization" # Customization profile name 
$VMProdPort = "YourPort" # Port Group for the production NIC
$VMAdminPort = "YourPort" # Port Group for the ADmin NIC
$NewDiskDatastore = "YourDatastore" # Datastore where to place the new drive. You can usethe Get-DataStore command to confirm the name of the existing datastores 
$NewDiskSize = "DIskSize" # Size in GB
$VMMem = "2" # Memory in GB
$VmCPU = "2" # Number of vCPUs
$VMCores = "1"# Number of Cores Per Socket
$VMNotes = "Get-Date" # Notes for the summary section on VMware  
$ESXi = "ESXIServer" #Needed with standard vSwitches.   
$GuestCred = "root" # User with root level 
$GuestPass = "YOurPassword"
#Command to assign the PROD nic as gateway device
$command1 = 'echo "GATEWAYDEV=eno16780032" >> /etc/sysconfig/network'

#command2 and command3 will set the persisten route(s). You will need to specify what is the correct laber of the NIC (ifconfig)
$command2 = 'touch /etc/sysconfig/network-scripts/route-eno33559296' 
$command3 = 'echo "ADDRESS0=192.168.10.20
NETMASK0=255.255.255.0
GATEWAY0=192.30.5.158" >> /etc/sysconfig/network-scripts/route-eno33559296'

#This will use fdisk to format your second drive. In my case /dev/sdb
$command4 = 'echo -e "n\np\n1\n\n\nw" | fdisk /dev/sdb'

#This command will format the second drive with ext4
$command5 = '/sbin/mkfs.ext4 -L /data1 /dev/sdb1'

#This command will create the directory to mount the second drive
$command6 = 'mkdir /data1'

#This command will mount the second drive
$command7 = 'mount /dev/sdb1 /data1'

#This command will make the second drive mount persistently
$command8 = 'echo "LABEL=/data1           /data1                   ext4    defaults        1 2" >> /etc/fstab'

#command9 will create a user
$command9 = 'useradd UserName -s /bin/bash -m'

#command10 will assign a password to the user created with command9
$command10 = 'echo Username:Password | chpasswd'

#Command to reboot the system
$reboot = 'reboot'


##Send Completion report through email. EDIT according to your needs.
$Body = $VMname
$users = "email@email.com "  # Recipient for the email. Can be more than one sepparated by a comma
$fromemail = "FromUserName <email2@email2.com>" # Email sender
$server = "aspmx.l.google.com" # Your SMTP Server. The example us using gmail open relay 
$CurrentTime = Get-Date

######################################################Excecution#################################

Write-Verbose -Message "Configuring Ips for customization"
Get-OSCustomizationSpec RedHat7 | Get-OSCustomizationNicMapping | Set-OSCustomizationNicMapping -Position 1  -IpAddress 172.31.11.102 -IpMode UseStaticIP -SubnetMask 255.255.255.224 -DefaultGateway 172.31.11.126 -Confirm:$False
Get-OSCustomizationSpec RedHat7 | Get-OSCustomizationNicMapping | Set-OSCustomizationNicMapping -Position 2  -IpAddress 172.30.5.132 -IpMode UseStaticIP -SubnetMask 255.255.255.224 -DefaultGateway 172.30.5.158  -Confirm:$False 

Write-Verbose -Message "Deploying Virtual Machine with Name: [$VMname] using Template: [$VMtemplate] on Cluster: [$VmCluster] and waiting for completion" -Verbose
New-VM -Name $VMName -Template $VMtemplate -Location $VMFolder -VMHost $ESXi -OSCustomizationSpec $VMCustomization -Datastore $VMDatastore -DiskStorageFormat Thick 
start-sleep -Seconds 20



##--- Configures RAM and CPU according to values defined on the user variables section
##Note: If the RAM value needs to be decreased, the VM needs to be OFF with the command [STOP-VM $VMName]
Write-Verbose -Message "Configruing [$VMName] with Memory: [$VMMem] GB, CPU [$VmCPU] and [$VMCores]Cores" -Verbose
Set-VM -VM $VMName -MemoryGB $VMMem -NumCpu $VmCPU -CoresPerSocket $VMCores -Confirm:$False
Start-Sleep -Seconds 5

 
Write-Verbose -Message "Virtual Machine $VMName Deployed. Powering On" -Verbose 
Start-VM -VM $VMName 
# ------This Section Targets and Executes the Scripts on the New Guest VM------
# We first verify that the guest customization has finished on on the new VM by using the below loops to look for the relevant events within vCenter.
Write-Verbose -Message "Verifying that Customization for VM $VMName has started ..." -Verbose
	while($True)
	{
		$Events = Get-VIEvent -Entity $VMName
		$StartedEvent = $Events | Where { $_.GetType().Name -eq "CustomizationStartedEvent" }
		if ($StartedEvent)
		{
			break
		}
		else
		{
			Start-Sleep -Seconds 5
		}
	}
Write-Verbose -Message "Customization of VM $VMName has started. Checking for Completed Status......." -Verbose
	while($True)
	{
		$Events = Get-VIEvent -Entity $VMName
		$SucceededEvent = $Events | Where { $_.GetType().Name -eq "CustomizationSucceeded" }
        $FailureEvent = $Events | Where { $_.GetType().Name -eq "CustomizationFailed" }
		if ($DCFailureEvent)
		{
			Write-Warning -Message "Customization of VM $VMName failed" -Verbose
            return $False
		}
		if ($SucceededEvent)
		{
            break
		}
        Start-Sleep -Seconds 5
	}
Write-Verbose -Message "Customization of VM $VMName Completed Successfully!" -Verbose
# NOTE - The below Sleep command is to help prevent situations where the post customization reboot is delayed slightly causing
# the Wait-Tools command to think everything is fine and carrying on with the script before all services are ready. Value can be adjusted for your environment.
Start-Sleep -Seconds 30
Write-Verbose -Message "Waiting for VM $VMName to complete post-customization reboot." -Verbose
Wait-Tools -VM $VMName -TimeoutSeconds 300
# NOTE - Another short sleep here to make sure that other services have time to come up after VMware Tools are ready.
Start-Sleep -Seconds 30


##Configures NIC online and port group for PROD Interface
Write-Verbose -Message "Configuring Production Network Interfaces and portgroup for [$VMname]" -Verbose
$myNetworkAdapters = Get-VM $VMName | Get-NetworkAdapter -Name "Network adapter 1"
$myVDPortGroup = Get-VirtualPortGroup -Name $VMProdPort -VMHost $ESXi
Set-NetworkAdapter -NetworkAdapter $myNetworkAdapters -Portgroup $myVDPortGroup -Confirm:$False
Set-NetworkAdapter -NetworkAdapter $myNetworkAdapters -StartConnected $True -Connected $True  -Confirm:$False
Start-Sleep -Seconds 15

##Configures NIC online and port group for ADMIN Interface
Write-Verbose -Message "Configuring ADMIN Network Interfaces and portgroup for [$VMname]" -Verbose
$myNetworkAdapters = Get-VM $VMName | Get-NetworkAdapter -Name "Network adapter 2"
$myVDPortGroup2 = Get-VirtualPortGroup -Name $VMAdminPort -VMHost $ESXi
Set-NetworkAdapter -NetworkAdapter $myNetworkAdapters -Portgroup $myVDPortGroup2 -Confirm:$False
Set-NetworkAdapter -NetworkAdapter $myNetworkAdapters -StartConnected $True -Connected $True  -Confirm:$False
Start-Sleep -Seconds 15


##--- Creates second drive 
#You will need to provide the Name of the Datastore for the $NewDiskDataStore value on the top of the script. THe size value is set with the $NewDiskSize variable
Write-Verbose -Message "Creating new drive on [$VMName] with size [$NewDiskSize]GB on Datastore: $NewDiskDatastore " -Verbose
New-HardDisk -VM $VMName -CapacityGB $NewDiskSize -Persistence persistent -Datastore $NewDiskDatastore -Confirm:$False 
start-sleep -Seconds 5

##--- Configures Custom Notes for the Summary section of the VM according to value $VMNotes defined on the user variables section
Write-Verbose -Message "Adding the Note: [$VMNotes] to [$VMName]" -Verbose
Set-VM -VM $VMName -Notes $VMNotes -Confirm:$False
Start-Sleep -Seconds 20

##---Configuration commands
Write-Verbose -Message "Triggering Command1 to set the default gateway interface on [$VMName]" -Verbose
Invoke-VMScript -VM $vmname -ScriptText $command1 -GuestUser $GuestCred -GuestPassword $GuestPass -ScriptType Bash

Write-Verbose -Message "Triggering Command2 to create the static route file on [$VMName]" -Verbose
Invoke-VMScript -VM $vmname -ScriptText $command2 -GuestUser $GuestCred -GuestPassword $GuestPass -ScriptType Bash

Write-Verbose -Message "Triggering Command3 to inject the static routes on [$VMName]" -Verbose
Invoke-VMScript -VM $vmname -ScriptText $command3 -GuestUser $GuestCred -GuestPassword $GuestPass -ScriptType Bash


Write-Verbose -Message "Triggering Command4 to create new partition for second drive on [$VMName]" -Verbose
Invoke-VMScript -VM $vmname -ScriptText $command4 -GuestUser $GuestCred -GuestPassword $GuestPass -ScriptType Bash
Start-Sleep -Seconds 2

Write-Verbose -Message "Triggering Command5 to format new partition for second drive on [$VMName]" -Verbose
Invoke-VMScript -VM $vmname -ScriptText $command5 -GuestUser $GuestCred -GuestPassword $GuestPass -ScriptType Bash
Start-Sleep -Seconds 2

Write-Verbose -Message "Triggering Command6 to create new mount point for second drive on [$VMName]" -Verbose
Invoke-VMScript -VM $vmname -ScriptText $command6 -GuestUser $GuestCred -GuestPassword $GuestPass -ScriptType Bash
Start-Sleep -Seconds 2

Write-Verbose -Message "Triggering Command7 to mount the second drive on [$VMName]" -Verbose
Invoke-VMScript -VM $vmname -ScriptText $command7 -GuestUser $GuestCred -GuestPassword $GuestPass -ScriptType Bash
Start-Sleep -Seconds 2

Write-Verbose -Message "Triggering Command8 to persistently mount the second drive on [$VMName]" -Verbose
Invoke-VMScript -VM $vmname -ScriptText $command8 -GuestUser $GuestCred -GuestPassword $GuestPass -ScriptType Bash
Start-Sleep -Seconds 2

Write-Verbose -Message "Triggering Command9 to create a new user on [$VMName]" -Verbose
Invoke-VMScript -VM $vmname -ScriptText $command9 -GuestUser $GuestCred -GuestPassword $GuestPass -ScriptType Bash
Start-Sleep -Seconds 2

Write-Verbose -Message "Triggering Command10 to reset the passowrd for the new user on [$VMName]" -Verbose
Invoke-VMScript -VM $vmname -ScriptText $command10 -GuestUser $GuestCred -GuestPassword $GuestPass -ScriptType Bash
Start-Sleep -Seconds 5

Write-Verbose -Message "Final reboot for [$VMName]" -Verbose
Invoke-VMScript -VM $vmname -ScriptText $reboot -GuestUser $GuestCred -GuestPassword $GuestPass -ScriptType Bash

##--- Script Ends
Write-Verbose -Message "Deplyment for VM [$VMName] has completed " -Verbose

##--- Disconnect from Vcenter
Write-Verbose -Message "Disconnecting from Vcenter" -Verbose
Disconnect-VIServer -Confirm:$False


##--- Transcript Ends
Stop-Transcript

##--- Send Email report
Start-Sleep -Seconds 10
Write-Verbose -Message "Sending Email report from [$VMName] " -Verbose
send-mailmessage -from $fromemail -to $users -subject "New VM $VMName created at $CurrentTime"  -Body $Body -Attachments $outPath   -priority Normal -smtpServer $server 