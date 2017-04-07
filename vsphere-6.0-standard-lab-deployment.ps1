# Author: William Lam
# Website: www.virtuallyghetto.com
# Description: PowerCLI script to deploy a fully functional vSphere 6.0 lab consisting of 3
#               Nested ESXi hosts enable w/vSAN + VCSA 6.0u2. Expects a single physical ESXi host
#               as the endpoint and all four VMs will be deployed to physical ESXi host
# Reference: http://www.virtuallyghetto.com/2016/11/vghetto-automated-vsphere-lab-deployment-for-vsphere-6-0u2-vsphere-6-5.html
# Credit: Thanks to Alan Renouf as I borrowed some of his PCLI code snippets :)
#
# Changelog
# 11/22/16
#   * Automatically handle Nested ESXi on vSAN
# 01/20/17
#   * Resolved "Another task in progress" thanks to Jason M
# 02/12/17
#   * Support for deploying to VC Target
#   * Support for enabling SSH on VCSA
#   * Added option to auto-create vApp Container for VMs
#   * Added pre-check for required files
# 02/17/17
#   * Added missing dvFilter param to eth1 (missing in Nested ESXi OVA)

[CmdletBinding(DefaultParameterSetName="Default")]
param (
    ## Full path to the JSON Configuration File
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][string]$JSONConfigurationFile
)

if(!(Test-Path $JSONConfigurationFile)) {
    Write-Host -ForegroundColor Red "`nUnable to find JSON Configuration file at $JSONConfigurationFile ...`nexiting"
    exit
}else{
$DeployConfig = Get-Content -Raw $JSONConfigurationFile | convertfrom-json
}

# Full Path to both the Nested ESXi 6.0 VA + extracted VCSA 6.0 ISO
$NestedESXiApplianceOVA = $DeployConfig.FilePaths.NestedESXiApplianceOVA
$VCSAInstallerPath = $DeployConfig.FilePaths.VCSAInstaller

# Physical ESXi host or vCenter Server to deploy vSphere 6.5 lab
$DeploymentTarget = $DeployConfig.DeploymentTarget.Type
$VIServer = $DeployConfig.DeploymentTarget.Server
$VIUsername = $DeployConfig.DeploymentTarget.Username
$VIPassword = $DeployConfig.DeploymentTarget.Password

# Nested ESXi VMs to deploy
$NestedESXiHostnameToIPs = $null
$NestedESXICount = $DeployConfig.NestedESXi.HostName.count
foreach ($Item in 0..($NestedESXICount - 1)){
    $ESXiHostNameAndIP = @{
        $DeployConfig.NestedESXi.HostName[($Item)] = $DeployConfig.NestedESXi.IPAddress[($Item)]
    }
    $NestedESXiHostnameToIPs += $ESXiHostNameAndIP
}

# Nested ESXi VM Resources
$NestedESXivCPU = $DeployConfig.NestedESXi.vCPU
$NestedESXivMEM = $DeployConfig.NestedESXi.vMEM
$NestedESXiCachingvDisk = $DeployConfig.NestedESXi.CachingvDisk
$NestedESXiCapacityvDisk = $DeployConfig.NestedESXi.CapacityvDisk

# VCSA Deployment Configuration
$VCSADeploymentSize = $DeployConfig.VCSA.DeploymentSize
$VCSADisplayName = $DeployConfig.VCSA.Displayname
$VCSAIPAddress = $DeployConfig.VCSA.IPAddress
$VCSAHostname = $DeployConfig.VCSA.Hostname
$VCSAPrefix = $DeployConfig.VCSA.Prefix
$VCSARootPassword = $DeployConfig.NestedDeploymentConfig.VMPassword
$VCSASSHEnable = $DeployConfig.VCSA.SSHEnable
$VCSAGateway = $DeployConfig.VCSA.VCSAGateway

#SSO Configration
$VCSASSODomainName = $DeployConfig.SSO.DomainName
$VCSASSOSiteName = $DeployConfig.SSO.SiteName
$VCSASSOPassword = $DeployConfig.SSO.Password

#External PSC Configuration
$ExternalPSC = $DeployConfig.PSC.ExternalPSC
$PSCDisplayName = $DeployConfig.PSC.Displayname
$PSCIPAddress = $DeployConfig.PSC.IPAddress
$PSCHostname = $DeployConfig.PSC.Hostname
$PSCRootPassword = $DeployConfig.NestedDeploymentConfig.VMPassword

# General Deployment Configuration for Nested ESXi, VCSA & NSX VMs
$VirtualSwitchType = $DeployConfig.NestedDeploymentConfig.vSwitchType
$VMNetwork = $DeployConfig.NestedDeploymentConfig.VMNetwork
$VMDatastore = $DeployConfig.NestedDeploymentConfig.VMDatastore
$VMNetmask = $DeployConfig.NestedDeploymentConfig.VMNetmask
$VMGateway = $DeployConfig.NestedDeploymentConfig.VMGateway
$VMDNS = $DeployConfig.NestedDeploymentConfig.VMDNS
$VMNTP = $DeployConfig.NestedDeploymentConfig.VMNTP
$VMPassword = $DeployConfig.NestedDeploymentConfig.VMPassword
$VMDomain = $DeployConfig.NestedDeploymentConfig.VMDomain
$VMSyslog = $DeployConfig.NestedDeploymentConfig.VMSyslog
# Applicable to Nested ESXi only
$VMSSH = $DeployConfig.NestedESXi.ESXISSH
$VMVMFS = $DeployConfig.NestedESXi.ESXIVMFS
# Applicable to VC Deployment Target only
$VMCluster = $DeployConfig.DeploymentTarget.TargetCluster

# Name of new vSphere Datacenter/Cluster when VCSA is deployed
$NewVCDatacenterName = $DeployConfig.Misc.NewvDCName
$NewVCVSANClusterName = $DeployConfig.Misc.NewVSANClusterName

# Advanced Configurations
# Set to 1 only if you have DNS (forward/reverse) for ESXi hostnames
$addHostByDnsName = $DeployConfig.Misc.AddHostByDNSName

#### DO NOT EDIT BEYOND HERE ####

$verboseLogFile = "vsphere60-vghetto-lab-deployment.log"
$vSphereVersion = "6.0u2"
$deploymentType = "Standard"
$random_string = -join ((65..90) + (97..122) | Get-Random -Count 8 | % {[char]$_})
$VAppName = "vGhetto-Nested-vSphere-Lab-$vSphereVersion-$random_string"

if ($ExternalPSC -eq 1){
    $vcsaSize2MemoryStorageMap = @{
    "tiny"=@{"cpu"="2";"mem"="8";"disk"="86"};
    "small"=@{"cpu"="4";"mem"="16";"disk"="108"};
    "medium"=@{"cpu"="8";"mem"="24";"disk"="220"};
    "large"=@{"cpu"="16";"mem"="32";"disk"="280"};
    }
}ELSE{
    $vcsaSize2MemoryStorageMap = @{
    "tiny"=@{"cpu"="2";"mem"="8";"disk"="120"};
    "small"=@{"cpu"="4";"mem"="16";"disk"="150"};
    "medium"=@{"cpu"="8";"mem"="24";"disk"="300"};
    "large"=@{"cpu"="16";"mem"="32";"disk"="450"};
    }
}
$esxiTotalCPU = 0
$vcsaTotalCPU = 0
$nsxTotalCPU = 0
$esxiTotalMemory = 0
$vcsaTotalMemory = 0
$nsxTotalMemory = 0
$esxiTotStorage = 0
$vcsaTotalStorage = 0
$nsxTotalStorage = 0
$PSCTotalCPU = 0
$PSCTotalMemory = 0
$PSCTotalStorage = 0

$preCheck = 1
$confirmDeployment = 1
$deployNestedESXiVMs = 1
$deployVCSA = 1
$setupNewVC = 1
$addESXiHostsToVC = 1
$configureVSANDiskGroups = 1
$clearVSANHealthCheckAlarm = 1
$moveVMsIntovApp = 1

$StartTime = Get-Date

Function My-Logger {
    param(
    [Parameter(Mandatory=$true)]
    [String]$message
    )

    $timeStamp = Get-Date -Format "MM-dd-yyyy_hh:mm:ss"

    Write-Host -NoNewline -ForegroundColor White "[$timestamp]"
    Write-Host -ForegroundColor Green " $message"
    $logMessage = "[$timeStamp] $message"
    $logMessage | Out-File -Append -LiteralPath $verboseLogFile
}

if($preCheck -eq 1) {
    if(!(Test-Path $NestedESXiApplianceOVA)) {
        Write-Host -ForegroundColor Red "`nUnable to find $NestedESXiApplianceOVA ...`nexiting"
        exit
    }

    if(!(Test-Path $VCSAInstallerPath)) {
        Write-Host -ForegroundColor Red "`nUnable to find $VCSAInstallerPath ...`nexiting"
        exit
    }
}

$CheckDNS = $DeployConfig.DNSCheck.CheckDNS

if ($CheckDNS -eq 1){
    #Add IP and DNS to variable for ESXi, used for DNS check
    $NestedNamesAndIPs += $NestedESXiHostnameToIPs

    #Add IP and DNS to Variable for VCSA, used for DNS check
    $VCSAHostNameAndIP = @{
        $DeployConfig.VCSA.displayname = $DeployConfig.VCSA.IPAddress
    }
    $NestedNamesAndIPS += $VCSAHostNameAndIP

    #Add IP and DNS to variable for PSC, used for DNS check
    if ($ExternalPSC -eq 1){
        $PSCHostNameAndIP = @{
            $DeployConfig.PSC.Displayname = $DeployConfig.PSC.IPAddress
        }
        $NestedNamesAndIPS += $PSCHostNameAndIP
    }

    Write-Host -ForegroundColor Magenta "`nChecking DNS lookups for all nested nodes, results are:`n"

    foreach ($VM in $NestedNamesAndIPS.GetEnumerator()){
        try
        {
            Resolve-DnsName -name $VM.name -ErrorAction stop | Out-Null
            Write-Host "DNS check for $($VM.name) successful"
        }
        catch
        {
            Write-Host "DNS check for $($VM.name) failed" -ForegroundColor Red
            if ($DeployConfig.DNSCheck.WindowsDNSServer -eq 1){
                Write-Host "Windows DNS Server Detected in Config. Adding DNS Entry to $($DeployConfig.DNSCheck.DNSServer) for $($VM.Name)" -ForegroundColor Green
                Add-DnsServerResourceRecordA -Name $VM.Name -IPv4Address $VM.value -ZoneName $DeployConfig.DNSCheck.DNSZoneName -ComputerName $DeployConfig.DNSCheck.DNSServer -CreatePtr
            }
        }

    }
}

if($confirmDeployment -eq 1) {
    Write-Host -ForegroundColor Magenta "`nPlease confirm the following configuration will be deployed:`n"

    Write-Host -ForegroundColor Yellow "---- vGhetto vSphere Automated Lab Deployment Configuration ---- "
    Write-Host -NoNewline -ForegroundColor Green "Deployment Type: "
    Write-Host -ForegroundColor White $deploymentType
    Write-Host -NoNewline -ForegroundColor Green "vSphere Version: "
    Write-Host -ForegroundColor White  "vSphere $vSphereVersion"
    Write-Host -NoNewline -ForegroundColor Green "Nested ESXi Image Path: "
    Write-Host -ForegroundColor White $NestedESXiApplianceOVA
    Write-Host -NoNewline -ForegroundColor Green "VCSA Image Path: "
    Write-Host -ForegroundColor White $VCSAInstallerPath

    if($DeploymentTarget -eq "ESXI") {
        Write-Host -ForegroundColor Yellow "`n---- Physical ESXi Configuration ----"
        Write-Host -NoNewline -ForegroundColor Green "ESXi Address: "
    } else {
        Write-Host -ForegroundColor Yellow "`n---- vCenter Server Configuration ----"
        Write-Host -NoNewline -ForegroundColor Green "vCenter Server Address: "
    }

    Write-Host -ForegroundColor White $VIServer
    Write-Host -NoNewline -ForegroundColor Green "Username: "
    Write-Host -ForegroundColor White $VIUsername
    Write-Host -NoNewline -ForegroundColor Green "VM Network: "
    Write-Host -ForegroundColor White $VMNetwork
    Write-Host -NoNewline -ForegroundColor Green "VM Storage: "
    Write-Host -ForegroundColor White $VMDatastore

    if($DeploymentTarget -eq "VCENTER") {
        Write-Host -NoNewline -ForegroundColor Green "VM Cluster: "
        Write-Host -ForegroundColor White $VMCluster
        Write-Host -NoNewline -ForegroundColor Green "VM vApp: "
        Write-Host -ForegroundColor White $VAppName
    }

    Write-Host -ForegroundColor Yellow "`n---- vESXi Configuration ----"
    Write-Host -NoNewline -ForegroundColor Green "# of Nested ESXi VMs: "
    Write-Host -ForegroundColor White $NestedESXiHostnameToIPs.count
    Write-Host -NoNewline -ForegroundColor Green "vCPU: "
    Write-Host -ForegroundColor White $NestedESXivCPU
    Write-Host -NoNewline -ForegroundColor Green "vMEM: "
    Write-Host -ForegroundColor White "$NestedESXivMEM GB"
    Write-Host -NoNewline -ForegroundColor Green "Caching VMDK: "
    Write-Host -ForegroundColor White "$NestedESXiCachingvDisk GB"
    Write-Host -NoNewline -ForegroundColor Green "Capacity VMDK: "
    Write-Host -ForegroundColor White "$NestedESXiCapacityvDisk GB"
    Write-Host -NoNewline -ForegroundColor Green "IP Address(s): "
    Write-Host -ForegroundColor White $NestedESXiHostnameToIPs.Values
    Write-Host -NoNewline -ForegroundColor Green "Netmask "
    Write-Host -ForegroundColor White $VMNetmask
    Write-Host -NoNewline -ForegroundColor Green "Gateway: "
    Write-Host -ForegroundColor White $VMGateway
    Write-Host -NoNewline -ForegroundColor Green "DNS: "
    Write-Host -ForegroundColor White $VMDNS
    Write-Host -NoNewline -ForegroundColor Green "NTP: "
    Write-Host -ForegroundColor White $VMNTP
    Write-Host -NoNewline -ForegroundColor Green "Syslog: "
    Write-Host -ForegroundColor White $VMSyslog
    Write-Host -NoNewline -ForegroundColor Green "Enable SSH: "
    Write-Host -ForegroundColor White $VMSSH
    Write-Host -NoNewline -ForegroundColor Green "Create VMFS Volume: "
    Write-Host -ForegroundColor White $VMVMFS
    Write-Host -NoNewline -ForegroundColor Green "Root Password: "
    Write-Host -ForegroundColor White $VMPassword

    Write-Host -ForegroundColor Yellow "`n---- VCSA Configuration ----"
    Write-Host -NoNewline -ForegroundColor Green "Deployment Size: "
    Write-Host -ForegroundColor White $VCSADeploymentSize
    if ($ExternalPSC -eq 1){
        Write-Host -NoNewline -ForegroundColor Green "External PSC: "
        Write-Host -ForegroundColor White "True"
        Write-Host -NoNewline -ForegroundColor Green "PSC Name: "
        Write-Host -ForegroundColor White $PSCHostname
    }
    Write-Host -NoNewline -ForegroundColor Green "SSO Domain: "
    Write-Host -ForegroundColor White $VCSASSODomainName
    Write-Host -NoNewline -ForegroundColor Green "SSO Site: "
    Write-Host -ForegroundColor White $VCSASSOSiteName
    Write-Host -NoNewline -ForegroundColor Green "SSO Password: "
    Write-Host -ForegroundColor White $VCSASSOPassword
    Write-Host -NoNewline -ForegroundColor Green "Root Password: "
    Write-Host -ForegroundColor White $VCSARootPassword
    Write-Host -NoNewline -ForegroundColor Green "Enable SSH: "
    Write-Host -ForegroundColor White $VCSASSHEnable
    Write-Host -NoNewline -ForegroundColor Green "Hostname: "
    Write-Host -ForegroundColor White $VCSAHostname
    Write-Host -NoNewline -ForegroundColor Green "IP Address: "
    Write-Host -ForegroundColor White $VCSAIPAddress
    Write-Host -NoNewline -ForegroundColor Green "Netmask "
    Write-Host -ForegroundColor White $VMNetmask
    Write-Host -NoNewline -ForegroundColor Green "Gateway: "
    Write-Host -ForegroundColor White $VMGateway

    if ($ExternalPSC -eq 1){
        Write-Host -ForegroundColor Yellow "`n---- PSC Configuration ----"
        Write-Host -NoNewline -ForegroundColor Green "Host Name: "
        Write-Host -ForegroundColor White $PSCHostName
        Write-Host -NoNewline -ForegroundColor Green "IP Address: "
        Write-Host -ForegroundColor White $PSCIPAddress
        Write-Host -NoNewline -ForegroundColor Green "Root Password: "
        Write-Host -ForegroundColor White $PSCRootPassword
    }

        $esxiTotalCPU = $NestedESXiHostnameToIPs.count * [int]$NestedESXivCPU
    $esxiTotalMemory = $NestedESXiHostnameToIPs.count * [int]$NestedESXivMEM
    $esxiTotalStorage = ($NestedESXiHostnameToIPs.count * [int]$NestedESXiCachingvDisk) + ($NestedESXiHostnameToIPs.count * [int]$NestedESXiCapacityvDisk)
    $vcsaTotalCPU = $vcsaSize2MemoryStorageMap.$VCSADeploymentSize.cpu
    $vcsaTotalMemory = $vcsaSize2MemoryStorageMap.$VCSADeploymentSize.mem
    $vcsaTotalStorage = $vcsaSize2MemoryStorageMap.$VCSADeploymentSize.disk

    Write-Host -ForegroundColor Yellow "`n---- Resource Requirements ----"
    Write-Host -NoNewline -ForegroundColor Green "ESXi VM CPU: "
    Write-Host -NoNewline -ForegroundColor White $esxiTotalCPU
    Write-Host -NoNewline -ForegroundColor Green " ESXi VM Memory: "
    Write-Host -NoNewline -ForegroundColor White $esxiTotalMemory "GB "
    Write-Host -NoNewline -ForegroundColor Green "ESXi VM Storage: "
    Write-Host -ForegroundColor White $esxiTotalStorage "GB"
    Write-Host -NoNewline -ForegroundColor Green "VCSA VM CPU: "
    Write-Host -NoNewline -ForegroundColor White $vcsaTotalCPU
    Write-Host -NoNewline -ForegroundColor Green " VCSA VM Memory: "
    Write-Host -NoNewline -ForegroundColor White $vcsaTotalMemory "GB "
    Write-Host -NoNewline -ForegroundColor Green "VCSA VM Storage: "
    Write-Host -ForegroundColor White $vcsaTotalStorage "GB"

    if ($ExternalPSC -eq 1){
        $PSCTotalCPU = 2
        $PSCTotalMemory = 4
        $PSCTotalStorage = 30
        Write-Host -NoNewline -ForegroundColor Green "PSC VM CPU: "
        Write-Host -NoNewline -ForegroundColor White $PSCTotalCPU
        Write-Host -NoNewline -ForegroundColor Green " VCSA VM Memory: "
        Write-Host -NoNewline -ForegroundColor White $PSCTotalMemory "GB "
        Write-Host -NoNewline -ForegroundColor Green "VCSA VM Storage: "
        Write-Host -ForegroundColor White $PSCTotalStorage "GB"
    }

    Write-Host -ForegroundColor White "---------------------------------------------"
    Write-Host -NoNewline -ForegroundColor Green "Total CPU: "
    Write-Host -ForegroundColor White ($esxiTotalCPU + $vcsaTotalCPU + $nsxTotalCPU + $PSCTotalCPU)
    Write-Host -NoNewline -ForegroundColor Green "Total Memory: "
    Write-Host -ForegroundColor White ($esxiTotalMemory + $vcsaTotalMemory + $nsxTotalMemory + $PSCTotalMemory) "GB"
    Write-Host -NoNewline -ForegroundColor Green "Total Storage: "
    Write-Host -ForegroundColor White ($esxiTotalStorage + $vcsaTotalStorage + $nsxTotalStorage + $PSCTotalStorage) "GB"

    Write-Host -ForegroundColor Magenta "`nWould you like to proceed with this deployment?`n"
    $answer = Read-Host -Prompt "Do you accept (Y or N)"
    if($answer -ne "Y" -or $answer -ne "y") {
        exit
    }
    Clear-Host
}

My-Logger "Connecting to $VIServer ..."
$viConnection = Connect-VIServer $VIServer -User $VIUsername -Password $VIPassword -WarningAction SilentlyContinue

if($DeploymentTarget -eq "ESXI") {
    $datastore = Get-Datastore -Server $viConnection -Name $VMDatastore
    $vmhost = Get-VMHost -Server $viConnection
    $network = Get-VirtualPortGroup -Server $viConnection -Name $VMNetwork -VMHost $vmhost

    if($datastore.Type -eq "vsan") {
        My-Logger "VSAN Datastore detected, enabling Fake SCSI Reservations ..."
        Get-AdvancedSetting -Entity $vmhost -Name "VSAN.FakeSCSIReservations" | Set-AdvancedSetting -Value 1 -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
    }
} else {
    $datastore = Get-Datastore -Server $viConnection -Name $VMDatastore | Select -First 1
    $network = Get-VirtualPortGroup -Server $viConnection -Name $VMNetwork | Select -First 1
    $cluster = Get-Cluster -Server $viConnection -Name $VMCluster
    $datacenter = $cluster | Get-Datacenter
    $vmhost = $cluster | Get-VMHost | Select -First 1
}

if($deployNestedESXiVMs -eq 1) {
    if($DeploymentTarget -eq "ESXI") {
        $NestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
            $VMName = $_.Key
            $VMIPAddress = $_.Value

            My-Logger "Deploying Nested ESXi VM $VMName ..."
            $vm = Import-VApp -Server $viConnection -Source $NestedESXiApplianceOVA -Name $VMName -VMHost $vmhost -Datastore $datastore -DiskStorageFormat thin

            My-Logger "Updating VM Network ..."
            foreach($networkAdapter in ($vm | Get-NetworkAdapter))
            {
                My-Logger "Configuring adapter $networkAdapter in $vm"
                $networkAdapter | Set-NetworkAdapter -Portgroup $network -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
                sleep 5
            }

            My-Logger "Updating vCPU Count to $NestedESXivCPU & vMEM to $NestedESXivMEM GB ..."
            Set-VM -Server $viConnection -VM $vm -NumCpu $NestedESXivCPU -MemoryGB $NestedESXivMEM -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Updating vSAN Caching VMDK size to $NestedESXiCachingvDisk GB ..."
            Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 2" | Set-HardDisk -CapacityGB $NestedESXiCachingvDisk -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Updating vSAN Capacity VMDK size to $NestedESXiCapacityvDisk GB ..."
            Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 3" | Set-HardDisk -CapacityGB $NestedESXiCapacityvDisk -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            $orignalExtraConfig = $vm.ExtensionData.Config.ExtraConfig
            $a = New-Object VMware.Vim.OptionValue
            $a.key = "guestinfo.hostname"
            $a.value = $VMName
            $b = New-Object VMware.Vim.OptionValue
            $b.key = "guestinfo.ipaddress"
            $b.value = $VMIPAddress
            $c = New-Object VMware.Vim.OptionValue
            $c.key = "guestinfo.netmask"
            $c.value = $VMNetmask
            $d = New-Object VMware.Vim.OptionValue
            $d.key = "guestinfo.gateway"
            $d.value = $VMGateway
            $e = New-Object VMware.Vim.OptionValue
            $e.key = "guestinfo.dns"
            $e.value = $VMDNS
            $f = New-Object VMware.Vim.OptionValue
            $f.key = "guestinfo.domain"
            $f.value = $VMDomain
            $g = New-Object VMware.Vim.OptionValue
            $g.key = "guestinfo.ntp"
            $g.value = $VMNTP
            $h = New-Object VMware.Vim.OptionValue
            $h.key = "guestinfo.syslog"
            $h.value = $VMSyslog
            $i = New-Object VMware.Vim.OptionValue
            $i.key = "guestinfo.password"
            $i.value = $VMPassword
            $j = New-Object VMware.Vim.OptionValue
            $j.key = "guestinfo.ssh"
            $j.value = $VMSSH
            $k = New-Object VMware.Vim.OptionValue
            $k.key = "guestinfo.createvmfs"
            $k.value = $VMVMFS
            $l = New-Object VMware.Vim.OptionValue
            $l.key = "ethernet1.filter4.name"
            $l.value = "dvfilter-maclearn"
            $m = New-Object VMware.Vim.OptionValue
            $m.key = "ethernet1.filter4.onFailure"
            $m.value = "failOpen"
            $orignalExtraConfig+=$a
            $orignalExtraConfig+=$b
            $orignalExtraConfig+=$c
            $orignalExtraConfig+=$d
            $orignalExtraConfig+=$e
            $orignalExtraConfig+=$f
            $orignalExtraConfig+=$g
            $orignalExtraConfig+=$h
            $orignalExtraConfig+=$i
            $orignalExtraConfig+=$j
            $orignalExtraConfig+=$k
            $orignalExtraConfig+=$l
            $orignalExtraConfig+=$m

            $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
            $spec.ExtraConfig = $orignalExtraConfig

            My-Logger "Adding guestinfo customization properties to $vmname ..."
            $task = $vm.ExtensionData.ReconfigVM_Task($spec)
            $task1 = Get-Task -Id ("Task-$($task.value)")
            $task1 | Wait-Task | Out-Null

            My-Logger "Powering On $vmname ..."
            Start-VM -Server $viConnection -VM $vm -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        }
    } else {
        $NestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
            $VMName = $_.Key
            $VMIPAddress = $_.Value

            $ovfconfig = Get-OvfConfiguration $NestedESXiApplianceOVA
            $ovfconfig.NetworkMapping.VM_Network.value = $VMNetwork

            $ovfconfig.common.guestinfo.hostname.value = $VMName
            $ovfconfig.common.guestinfo.ipaddress.value = $VMIPAddress
            $ovfconfig.common.guestinfo.netmask.value = $VMNetmask
            $ovfconfig.common.guestinfo.gateway.value = $VMGateway
            $ovfconfig.common.guestinfo.dns.value = $VMDNS
            $ovfconfig.common.guestinfo.domain.value = $VMDomain
            $ovfconfig.common.guestinfo.ntp.value = $VMNTP
            $ovfconfig.common.guestinfo.syslog.value = $VMSyslog
            $ovfconfig.common.guestinfo.password.value = $VMPassword
            if($VMSSH -eq "true") {
                $VMSSHVar = $true
            } else {
                $VMSSHVar = $false
            }
            $ovfconfig.common.guestinfo.ssh.value = $VMSSHVar

            My-Logger "Deploying Nested ESXi VM $VMName ..."
            $vm = Import-VApp -Source $NestedESXiApplianceOVA -OvfConfiguration $ovfconfig -Name $VMName -Location $cluster -VMHost $vmhost -Datastore $datastore -DiskStorageFormat thin

            # Add the dvfilter settings to the exisiting ethernet1 (not part of ova template)
            My-Logger "Correcting missing dvFilter settings for Ethernet[1] ..."
            $vm | New-AdvancedSetting -name "ethernet1.filter4.name" -value "dvfilter-maclearn" -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
            $vm | New-AdvancedSetting -Name "ethernet1.filter4.onFailure" -value "failOpen" -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Updating vCPU Count to $NestedESXivCPU & vMEM to $NestedESXivMEM GB ..."
            Set-VM -Server $viConnection -VM $vm -NumCpu $NestedESXivCPU -MemoryGB $NestedESXivMEM -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Updating vSAN Caching VMDK size to $NestedESXiCachingvDisk GB ..."
            Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 2" | Set-HardDisk -CapacityGB $NestedESXiCachingvDisk -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Updating vSAN Capacity VMDK size to $NestedESXiCapacityvDisk GB ..."
            Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 3" | Set-HardDisk -CapacityGB $NestedESXiCapacityvDisk -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Powering On $vmname ..."
            $vm | Start-Vm -RunAsync | Out-Null
        }
    }
}


if ($deployVCSA -eq 1 -and $ExternalPSC -eq 1){
    if($DeploymentTarget -eq "ESXI") {
        #Deploy PSC to ESXi using the VCSA CLI Installer
        $config = (Get-Content -Raw "$($VCSAInstallerPath)\vcsa-cli-installer\templates\install\PSC_on_ESXi.json") | convertfrom-json
        $config.'target.vcsa'.esxi.hostname = $VIServer
        $config.'target.vcsa'.esxi.username = $VIUsername
        $config.'target.vcsa'.esxi.password = $VIPassword
        $config.'target.vcsa'.esxi.datastore = $datastore
        $config.'target.vcsa'.appliance.'deployment.network' = $VMNetwork
        $config.'target.vcsa'.appliance.'thin.disk.mode' = $true
        $config.'target.vcsa'.appliance.'deployment.option' = "infrastructure"
        $config.'target.vcsa'.appliance.name = $PSCDisplayName
        $config.'target.vcsa'.network.'ip.family' = "ipv4"
        $config.'target.vcsa'.network.mode = "static"
        $config.'target.vcsa'.network.ip = $PSCIPAddress
        $config.'target.vcsa'.network.'dns.servers'[0] = $VMDNS
        $config.'target.vcsa'.network.prefix = $VCSAPrefix
        $config.'target.vcsa'.network.gateway = $VCSAGateway
        $config.'target.vcsa'.network.hostname = $PSCHostname
        $config.'target.vcsa'.os.password = $PSCRootPassword
        if($VCSASSHEnable -eq "true") {
            $VCSASSHEnableVar = $true
        } else {
            $VCSASSHEnableVar = $false
        }
        $config.'target.vcsa'.os.'ssh.enable' = $VCSASSHEnableVar
        $config.'target.vcsa'.sso.password = $VCSASSOPassword
        $config.'target.vcsa'.sso.'domain-name' = $VCSASSODomainName
        $config.'target.vcsa'.sso.'site-name' = $VCSASSOSiteName
        #Add NTP Server to JSON config
        $config.'target.vcsa'.os | Add-Member -Type "NoteProperty" -Name 'ntp.servers' -Value $VMNTP

        My-Logger "Creating PSC JSON Configuration file for deployment ..."
        $config | ConvertTo-Json | Set-Content -Path "$($ENV:Temp)\PSCjsontemplate.json"

        My-Logger "Deploying the PSC ..."
        $output = Invoke-Expression "$($VCSAInstallerPath)\vcsa-cli-installer\win32\vcsa-deploy.exe install --no-esx-ssl-verify --accept-eula $($ENV:Temp)\PSCjsontemplate.json" -ErrorVariable vcsaDeployOutput 2>&1
        $vcsaDeployOutput | Out-File -Append -LiteralPath $verboseLogFile

        #Deploy VCSA to ESXi using the VCSA CLI Installer
        $config = (Get-Content -Raw "$($VCSAInstallerPath)\vcsa-cli-installer\templates\install\vCSA_on_ESXi.json") | convertfrom-json
        $config.'target.vcsa'.esxi.hostname = $VIServer
        $config.'target.vcsa'.esxi.username = $VIUsername
        $config.'target.vcsa'.esxi.password = $VIPassword
        $config.'target.vcsa'.esxi.datastore = $datastore
        $config.'target.vcsa'.appliance.'deployment.network' = $VMNetwork
        $config.'target.vcsa'.appliance.'thin.disk.mode' = $true
        $config.'target.vcsa'.appliance.'deployment.option' = "management-$($VCSADeploymentSize)"
        $config.'target.vcsa'.appliance.name = $VCSADisplayName
        $config.'target.vcsa'.network.'ip.family' = "ipv4"
        $config.'target.vcsa'.network.mode = "static"
        $config.'target.vcsa'.network.ip = $VCSAIPAddress
        $config.'target.vcsa'.network.'dns.servers'[0] = $VMDNS
        $config.'target.vcsa'.network.prefix = $VCSAPrefix
        $config.'target.vcsa'.network.gateway = $VCSAGateway
        $config.'target.vcsa'.network.hostname = $VCSAHostname
        $config.'target.vcsa'.os.password = $VCSARootPassword
        if($VCSASSHEnable -eq "true") {
            $VCSASSHEnableVar = $true
        } else {
            $VCSASSHEnableVar = $false
        }
        $config.'target.vcsa'.os.'ssh.enable' = $VCSASSHEnableVar
        $config.'target.vcsa'.sso.password = $VCSASSOPassword
        $config.'target.vcsa'.sso.'domain-name' = $VCSASSODomainName
        $config.'target.vcsa'.sso.'platform.services.controller' = $PSCHostname
        $config.'target.vcsa'.sso.'site-name' = $VCSASSOSiteName
        #Add NTP Server to JSON config
        $config.'target.vcsa'.os | Add-Member -Type "NoteProperty" -Name 'ntp.servers' -Value $VMNTP

        My-Logger "Creating VCSA JSON Configuration file for deployment ..."
        $config | ConvertTo-Json | Set-Content -Path "$($ENV:Temp)\VCSAjsontemplate.json"

        My-Logger "Deploying the VCSA ..."
        $output = Invoke-Expression "$($VCSAInstallerPath)\vcsa-cli-installer\win32\vcsa-deploy.exe install --no-esx-ssl-verify --accept-eula $($ENV:Temp)\VCSAjsontemplate.json" -ErrorVariable vcsaDeployOutput 2>&1
        $vcsaDeployOutput | Out-File -Append -LiteralPath $verboseLogFile
    }ELSE{
    #Deploy PSC to vCenter using the VCSA CLI Installer
        $config = (Get-Content -Raw "$($VCSAInstallerPath)\vcsa-cli-installer\templates\install\PSC_on_VC.json") | convertfrom-json
        $config.'target.vcsa'.vc.hostname = $VIServer
        $config.'target.vcsa'.vc.username = $VIUsername
        $config.'target.vcsa'.vc.password = $VIPassword
        $config.'target.vcsa'.vc.datastore = $datastore
        $config.'target.vcsa'.appliance.'deployment.network' = $VMNetwork
        $config.'target.vcsa'.appliance.'thin.disk.mode' = $true
        $config.'target.vcsa'.appliance.'deployment.option' = "infrastructure"
        $config.'target.vcsa'.appliance.name = $PSCDisplayName
        $config.'target.vcsa'.network.'ip.family' = "ipv4"
        $config.'target.vcsa'.network.mode = "static"
        $config.'target.vcsa'.network.ip = $PSCIPAddress
        $config.'target.vcsa'.network.'dns.servers'[0] = $VMDNS
        $config.'target.vcsa'.network.prefix = $VCSAPrefix
        $config.'target.vcsa'.network.gateway = $VCSAGateway
        $config.'target.vcsa'.network.hostname = $PSCHostname
        $config.'target.vcsa'.os.password = $PSCRootPassword
        if($VCSASSHEnable -eq "true") {
            $VCSASSHEnableVar = $true
        } else {
            $VCSASSHEnableVar = $false
        }
        $config.'target.vcsa'.os.'ssh.enable' = $VCSASSHEnableVar
        $config.'target.vcsa'.sso.password = $VCSASSOPassword
        $config.'target.vcsa'.sso.'domain-name' = $VCSASSODomainName
        $config.'target.vcsa'.sso.'site-name' = $VCSASSOSiteName
        #Add NTP Server to JSON config
        $config.'target.vcsa'.os | Add-Member -Type "NoteProperty" -Name 'ntp.servers' -Value $VMNTP

        My-Logger "Creating PSC JSON Configuration file for deployment ..."
        $config | ConvertTo-Json | Set-Content -Path "$($ENV:Temp)\PSCjsontemplate.json"

        My-Logger "Deploying the PSC ..."
        $output = Invoke-Expression "$($VCSAInstallerPath)\vcsa-cli-installer\win32\vcsa-deploy.exe install --no-esx-ssl-verify --accept-eula $($ENV:Temp)\PSCjsontemplate.json" -ErrorVariable vcsaDeployOutput 2>&1
        $vcsaDeployOutput | Out-File -Append -LiteralPath $verboseLogFile

    #Deploy VCSA to vCenter using the VCSA CLI Installer
        $config = (Get-Content -Raw "$($VCSAInstallerPath)\vcsa-cli-installer\templates\install\vCSA_on_VC.json") | convertfrom-json
        $config.'target.vcsa'.vc.hostname = $VIServer
        $config.'target.vcsa'.vc.username = $VIUsername
        $config.'target.vcsa'.vc.password = $VIPassword
        $config.'target.vcsa'.vc.datastore = $datastore
        $config.'target.vcsa'.appliance.'deployment.network' = $VMNetwork
        $config.'target.vcsa'.appliance.'thin.disk.mode' = $true
        $config.'target.vcsa'.appliance.'deployment.option' = "management-$($VCSADeploymentSize)"
        $config.'target.vcsa'.appliance.name = $VCSADisplayName
        $config.'target.vcsa'.network.'ip.family' = "ipv4"
        $config.'target.vcsa'.network.mode = "static"
        $config.'target.vcsa'.network.ip = $VCSAIPAddress
        $config.'target.vcsa'.network.'dns.servers'[0] = $VMDNS
        $config.'target.vcsa'.network.prefix = $VCSAPrefix
        $config.'target.vcsa'.network.gateway = $VCSAGateway
        $config.'target.vcsa'.network.hostname = $VCSAHostname
        $config.'target.vcsa'.os.password = $VCSARootPassword
        if($VCSASSHEnable -eq "true") {
            $VCSASSHEnableVar = $true
        } else {
            $VCSASSHEnableVar = $false
        }
        $config.'target.vcsa'.os.'ssh.enable' = $VCSASSHEnableVar
        $config.'target.vcsa'.sso.password = $VCSASSOPassword
        $config.'target.vcsa'.sso.'domain-name' = $VCSASSODomainName
        $config.'target.vcsa'.sso.'platform.services.controller' = $PSCHostname
        $config.'target.vcsa'.sso.'site-name' = $VCSASSOSiteName
        #Add NTP Server to JSON config
        $config.'target.vcsa'.os | Add-Member -Type "NoteProperty" -Name 'ntp.servers' -Value $VMNTP

        My-Logger "Creating VCSA JSON Configuration file for deployment ..."
        $config | ConvertTo-Json | Set-Content -Path "$($ENV:Temp)\VCSAjsontemplate.json"

        My-Logger "Deploying the VCSA ..."
        $output = Invoke-Expression "$($VCSAInstallerPath)\vcsa-cli-installer\win32\vcsa-deploy.exe install --no-esx-ssl-verify --accept-eula $($ENV:Temp)\VCSAjsontemplate.json" -ErrorVariable vcsaDeployOutput 2>&1
        $vcsaDeployOutput | Out-File -Append -LiteralPath $verboseLogFile

    }
}



if($deployVCSA -eq 1 -and $ExternalPSC -eq 0) {
    # Deploy using the VCSA CLI Installer
    if($DeploymentTarget -eq "ESXI") {
        $config = (Get-Content -Raw "$($VCSAInstallerPath)\vcsa-cli-installer\templates\install\embedded_vCSA_on_ESXi.json") | convertfrom-json
        $config.'target.vcsa'.esxi.hostname = $VIServer
        $config.'target.vcsa'.esxi.username = $VIUsername
        $config.'target.vcsa'.esxi.password = $VIPassword
        $config.'target.vcsa'.esxi.datastore = $datastore
        $config.'target.vcsa'.appliance.'deployment.network' = $VMNetwork
        $config.'target.vcsa'.appliance.'thin.disk.mode' = $true
        $config.'target.vcsa'.appliance.'deployment.option' = $VCSADeploymentSize
        $config.'target.vcsa'.appliance.name = $VCSADisplayName
        $config.'target.vcsa'.network.'ip.family' = "ipv4"
        $config.'target.vcsa'.network.mode = "static"
        $config.'target.vcsa'.network.ip = $VCSAIPAddress
        $config.'target.vcsa'.network.'dns.servers'[0] = $VMDNS
        $config.'target.vcsa'.network.prefix = $VCSAPrefix
        $config.'target.vcsa'.network.gateway = $VCSAGateway
        $config.'target.vcsa'.network.hostname = $VCSAHostname
        $config.'target.vcsa'.os.password = $VCSARootPassword
        if($VCSASSHEnable -eq "true") {
            $VCSASSHEnableVar = $true
        } else {
            $VCSASSHEnableVar = $false
        }
        $config.'target.vcsa'.os.'ssh.enable' = $VCSASSHEnableVar
        $config.'target.vcsa'.sso.password = $VCSASSOPassword
        $config.'target.vcsa'.sso.'domain-name' = $VCSASSODomainName
        $config.'target.vcsa'.sso.'site-name' = $VCSASSOSiteName
        #Add NTP Server to JSON config
        $config.'target.vcsa'.os | Add-Member -Type "NoteProperty" -Name 'ntp.servers' -Value $VMNTP

        My-Logger "Creating VCSA JSON Configuration file for deployment ..."
        $config | ConvertTo-Json | Set-Content -Path "$($ENV:Temp)\jsontemplate.json"

        My-Logger "Deploying the VCSA ..."
        $output = Invoke-Expression "$($VCSAInstallerPath)\vcsa-cli-installer\win32\vcsa-deploy.exe install --no-esx-ssl-verify --accept-eula $($ENV:Temp)\jsontemplate.json" -ErrorVariable vcsaDeployOutput 2>&1
        $vcsaDeployOutput | Out-File -Append -LiteralPath $verboseLogFile
    } else {
        $config = (Get-Content -Raw "$($VCSAInstallerPath)\vcsa-cli-installer\templates\install\embedded_vCSA_on_VC.json") | convertfrom-json
        $config.'target.vcsa'.vc.hostname = $VIServer
        $config.'target.vcsa'.vc.username = $VIUsername
        $config.'target.vcsa'.vc.password = $VIPassword
        $config.'target.vcsa'.vc.datastore = $datastore
        $config.'target.vcsa'.vc.datacenter = $datacenter.name
        $config.'target.vcsa'.vc.target = $VMCluster
        $config.'target.vcsa'.appliance.'deployment.network' = $VMNetwork
        $config.'target.vcsa'.appliance.'thin.disk.mode' = $true
        $config.'target.vcsa'.appliance.'deployment.option' = $VCSADeploymentSize
        $config.'target.vcsa'.appliance.name = $VCSADisplayName
        $config.'target.vcsa'.network.'ip.family' = "ipv4"
        $config.'target.vcsa'.network.mode = "static"
        $config.'target.vcsa'.network.ip = $VCSAIPAddress
        $config.'target.vcsa'.network.'dns.servers'[0] = $VMDNS
        $config.'target.vcsa'.network.prefix = $VCSAPrefix
        $config.'target.vcsa'.network.gateway = $VCSAGateway
        $config.'target.vcsa'.network.hostname = $VCSAHostname
        $config.'target.vcsa'.os.password = $VCSARootPassword
        if($VCSASSHEnable -eq "true") {
            $VCSASSHEnableVar = $true
        } else {
            $VCSASSHEnableVar = $false
        }
        $config.'target.vcsa'.os.'ssh.enable' = $VCSASSHEnableVar
        $config.'target.vcsa'.sso.password = $VCSASSOPassword
        $config.'target.vcsa'.sso.'domain-name' = $VCSASSODomainName
        $config.'target.vcsa'.sso.'site-name' = $VCSASSOSiteName
        #Add NTP Server to JSON config
        $config.'target.vcsa'.os | Add-Member -Type "NoteProperty" -Name 'ntp.servers' -Value $VMNTP

        My-Logger "Creating VCSA JSON Configuration file for deployment ..."
        $config | ConvertTo-Json | Set-Content -Path "$($ENV:Temp)\jsontemplate.json"

        My-Logger "Deploying the VCSA ..."
        $output = Invoke-Expression "$($VCSAInstallerPath)\vcsa-cli-installer\win32\vcsa-deploy.exe install --no-esx-ssl-verify --accept-eula $($ENV:Temp)\jsontemplate.json" -ErrorVariable vcsaDeployOutput 2>&1
        $vcsaDeployOutput | Out-File -Append -LiteralPath $verboseLogFile
    }
}

if($moveVMsIntovApp -eq 1 -and $DeploymentTarget -eq "VCENTER") {
    My-Logger "Creating vApp $VAppName ..."
    $VApp = New-VApp -Name $VAppName -Server $viConnection -Location $cluster

    if($deployNestedESXiVMs -eq 1) {
        My-Logger "Moving Nested ESXi VMs into $VAppName vApp ..."
        $NestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
            $vm = Get-VM -Name $_.Key -Server $viConnection
            Move-VM -VM $vm -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        }
    }

    if($ExternalPSC -eq 1) {
        $PSCVM = Get-VM -Name $PSCDisplayName -Server $viConnection
        My-Logger "Moving $PSCDisplayName into $VAppName vApp ..."
        Move-VM -VM $PSCVM -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
    }

    if($deployVCSA -eq 1) {
        $vcsaVM = Get-VM -Name $VCSADisplayName
        My-Logger "Moving $vcsaVM into $VAppName vApp ..."
        Move-VM -VM $vcsaVM -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
    }
}

My-Logger "Disconnecting from $VIServer ..."
Disconnect-VIServer $viConnection -Confirm:$false

if($setupNewVC -eq 1) {
    My-Logger "Connecting to the new VCSA ..."
    $vc = Connect-VIServer $VCSAIPAddress -User "administrator@$VCSASSODomainName" -Password $VCSASSOPassword -WarningAction SilentlyContinue

    My-Logger "Creating Datacenter $NewVCDatacenterName ..."
    New-Datacenter -Server $vc -Name $NewVCDatacenterName -Location (Get-Folder -Type Datacenter -Server $vc) | Out-File -Append -LiteralPath $verboseLogFile

    My-Logger "Creating VSAN Cluster $NewVCVSANClusterName ..."
    New-Cluster -Server $vc -Name $NewVCVSANClusterName -Location (Get-Datacenter -Name $NewVCDatacenterName -Server $vc) -DrsEnabled -VsanEnabled -VsanDiskClaimMode 'Manual' | Out-File -Append -LiteralPath $verboseLogFile

    if($addESXiHostsToVC -eq 1) {
        $NestedESXiHostnameToIPs.GetEnumerator() | sort -Property Value | Foreach-Object {
            $VMName = $_.Key
            $VMIPAddress = $_.Value

            $targetVMHost = $VMIPAddress
            if($addHostByDnsName -eq 1) {
                $targetVMHost = $VMName
            }
            My-Logger "Adding ESXi host $targetVMHost to Cluster ..."
            Add-VMHost -Server $vc -Location (Get-Cluster -Name $NewVCVSANClusterName) -User "root" -Password $VMPassword -Name $targetVMHost -Force | Out-File -Append -LiteralPath $verboseLogFile
        }
    }

    if($configureVSANDiskGroups -eq 1) {
        # New vSAN cmdlets only works on 6.0u3+
        $VmhostToCheckVersion = (Get-Cluster -Server $vc | Get-VMHost)[0]
        $MajorVersion = $VmhostToCheckVersion.Version
        $UpdateVersion = (Get-AdvancedSetting -Entity $VmhostToCheckVersion -Name Misc.HostAgentUpdateLevel).value

        if( ($MajorVersion -eq "6.0.0" -and $UpdateVersion -eq "3") -or $MajorVersion -eq "6.5.0") {
            My-Logger "Enabling VSAN Space Efficiency/De-Dupe & disabling VSAN Health Check ..."
            Get-VsanClusterConfiguration -Server $vc -Cluster $NewVCVSANClusterName | Set-VsanClusterConfiguration -SpaceEfficiencyEnabled $true -HealthCheckIntervalMinutes 0 | Out-File -Append -LiteralPath $verboseLogFile
        }

        foreach ($vmhost in Get-Cluster -Server $vc | Get-VMHost) {
            $luns = $vmhost | Get-ScsiLun | select CanonicalName, CapacityGB

            My-Logger "Querying ESXi host disks to create VSAN Diskgroups ..."
            foreach ($lun in $luns) {
                if(([int]($lun.CapacityGB)).toString() -eq "$NestedESXiCachingvDisk") {
                    $vsanCacheDisk = $lun.CanonicalName
                }
                if(([int]($lun.CapacityGB)).toString() -eq "$NestedESXiCapacityvDisk") {
                    $vsanCapacityDisk = $lun.CanonicalName
                }
            }
            My-Logger "Creating VSAN DiskGroup for $vmhost ..."
            New-VsanDiskGroup -Server $vc -VMHost $vmhost -SsdCanonicalName $vsanCacheDisk -DataDiskCanonicalName $vsanCapacityDisk | Out-File -Append -LiteralPath $verboseLogFile
          }
    }

    if($clearVSANHealthCheckAlarm -eq 1) {
        My-Logger "Clearing default VSAN Health Check Alarms, not applicable in Nested ESXi env ..."
        $alarmMgr = Get-View AlarmManager -Server $vc
        Get-Cluster -Server $vc | where {$_.ExtensionData.TriggeredAlarmState} | %{
            $cluster = $_
            $Cluster.ExtensionData.TriggeredAlarmState | %{
                $alarmMgr.AcknowledgeAlarm($_.Alarm,$cluster.ExtensionData.MoRef)
            }
        }
    }

    My-Logger "Disconnecting from new VCSA ..."
    Disconnect-VIServer $vc -Confirm:$false
}
$EndTime = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)

My-Logger "vSphere $vSphereVersion Lab Deployment Complete!"
My-Logger "StartTime: $StartTime"
My-Logger "  EndTime: $EndTime"
My-Logger " Duration: $duration minutes"