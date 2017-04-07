# vGhetto Automated vSphere Lab Deployment

## Table of Contents

* [Description](#description)
* [Usage](#usage)
* [Changelog](#changelog)
* [Requirements](#requirements)
* [Supported Deployments](#supported-deployments)
* [Configuration](#configuration)
* [Logging](#logging)
* [Verification](#verification)
* [Sample Execution](#sample-execution)

## Description

Building on from [William Lam's automated deployment script](http://www.virtuallyghetto.com/2016/11/vghetto-automated-vsphere-lab-deployment-for-vsphere-6-0u2-vsphere-6-5.html), I've added some additional functionality that was useful to me and I hope other might find helpful as well.

At this stage I've only worked on the 6.5 and 6.0 Standard deployments. If people like the functionality let me know and I will see if I have time to port it into the 6.0 and 6.5 self managed.

One of the major changes is that all of the configuration is now stored in a JSON files external to the script. There is no need to edit the .ps1 file.

## Usage
Download the PS1 and JSON files from the repository. There is one JSON file template per deployment versions. Check the requirements section below for additional media and requirements for running the script.

After editing the JSON file and putting in your desired configuration, run the PS1 and point it to the JSON file using the syntax below;

vsphere-6.5-standard-lab-deployment.ps1 -JSONConfigurationFile c:\scripts\65Lab.JSON

## Changelog

* **07/04/2017**

  * Modified the 6.0 deployment script to allow external PSC deployment, DNS check, add NTP to appliance deployment, separate gateway address for VCSA vs nested ESXi

* **06/04/2017**

  * Ported the configuration to an external JSON file, removing the requirement to edit the .PS1 script for deployments
  * Added a parameter to specify a path to the JSON file to use for deployment
  * Added a check to ensure the JSON file exists before executing the script
  * Added the ability to deploy VCSA as external or embedded
  * Added a section to perform DNS lookup of all nested VMs being deployed. Added option to automatically add DNS record if DNS server is windows Server
  * Added code to add the NTP configuration to VCSA JSON file used during deployment (embedded and external)
  * Added section to the pre-deployment summary to give a summary of PSC node configuration if external PSC is being deployed
  * Added section to VCSA configuration to report if there is an external PSC being deployed and if so, what the name is
  * Added relevant details so the resource requirements update if the deployment of VCSA is embedded vs external
  * Added the ability to define a separate gateway address for VCSA/PSC compared to nested ESXi hosts (Thanks @daunce_)

## Requirements
* 1 x Physical ESXi host or vCenter Server running at least vSphere 6.0u2 or later
* Windows system
* [PowerCLI 6.5 R1](https://my.vmware.com/group/vmware/details?downloadGroup=PCLI650R1&productId=568)
* [PowerNSX](https://github.com/vmware/powernsx) installed and loaded (required if you plan to do NSX 6.3 deployment)
* vCenter Server Appliance (VCSA) 6.0 or 6.5 extracted ISO
* Nested ESXi [6.0](http://www.virtuallyghetto.com/2015/12/deploying-nested-esxi-is-even-easier-now-with-the-esxi-virtual-appliance.html) or [6.5](http://www.virtuallyghetto.com/2016/11/esxi-6-5-virtual-appliance-is-now-available.html) Virtual Appliance OVA
* [NSX 6.3 OVA](https://my.vmware.com/web/vmware/details?downloadGroup=NSXV_630&productId=417&rPId=14427) (optional)
  * [ESXi 6.5a offline patch bundle](https://my.vmware.com/web/vmware/details?downloadGroup=ESXI650A&productId=614&rPId=14229) (extracted)

## Supported Deployments

William's original script supports Standard and Self Managed deployments of both vSphere 6 and 6.5. As mentioned in the intro, I have currently only made changes to the 6.0/6.5 Standard deployments.

## Configuration

This section describes the location of the files required for deployment. The first two are mandatory for the basic deployment and only the first two are appliacble for the 6.0 deployment. For advanced deployments such as NSX 6.3, you will need to download additional files and below are examples of what is required.

Note that "\" in JSON is an escape character, so for full UNC paths you need to start with four slashes and then have 2 slashes in the rest of the path. For local paths, use two slahes for each directory. Examples of both are below.

```console
  "FilePaths": {
  	"NestedESXiApplianceOVA": "\\\\10.0.0.100\\iso\\VMware\\ESXi\\6.5\\Nested_ESXi6.5_Appliance_Template_v1.ova",
	"VCSAInstaller": "\\\\10.0.0.100\\iso\\VMware\\Appliance\\6.5\\VMware-VCSA-all-6.5.0-4602587",
	"NSXOVA": "C:\\Users\\primp\\Desktop\\VMware-NSX-Manager-6.3.0-5007049.ova",
	"ESXi65aOfflineBundle": "C:\\Users\\primp\\Desktop\\ESXi650-201701001\\vmw-ESXi-6.5.0-metadata.zip"
  }
```

This section describes the credentials to your physical ESXi server or vCenter Server in which the vSphere lab environment will be deployed to.

```console
  "DeploymentTarget": {
    "Type": "ESXI",
    "Server": "10.0.0.171",
	"Username": "root",
	"Password": "VMware1!",
	"TargetCluster": "<VC Deployment Only>"
  }
```

This section describes the configuration of where the nested VMs (ESXI / VC / PSC / NSX) will be deployed to. Including the target vSwitch, port group, datastore, general network configuration, etc. 
```console
  "NestedDeploymentConfig": {
	"vSwitchType": "VSS",
	"VMNetwork": "VM Network",
	"VMDatastore": "SSD_DS01",
	"VMNetmask": "255.255.255.0",
	"VMGateway": "10.0.0.1",
	"VMDNS": "10.0.0.160",
	"VMNTP": "10.0.0.160",
	"VMPassword": "VMware1!",
	"VMDomain": "lab.virtualtassie.com",
	"VMSyslog": "10.0.0.1"
  }
```

This section describes the configuration for the nested ESXi servers, including the names and IP addresses. If you want to deploy more than 3 ESXi servers, simply add another value to the comma separated array and add in an appropriate IP address as well.

vCPU and vMEM define the virtual VPU count per nexted ESXi node and the RAM in GB.

CachingvDisk and CapacityvDisk define the size in GB for VMDKs to be added to the ESXi node that will later be used for nested VSAN.
```console
  "NestedESXi": {
	"HostName": ["vesxi65-1","vesxi65-2","vesxi65-3"],
	"IPAddress": ["10.0.0.180","10.0.0.181","10.0.0.182"],
  	"vCPU": "2",
	"vMEM": "6",
	"CachingvDisk": "4",
	"CapacityvDisk": "8",
	"ESXISSH": "true",
	"ESXIVMFS": "false"
  }
```

This section describes the VCSA deployment configuration such as the VCSA deployment size and networking configuration.
```console
  "VCSA": {
  	"DeploymentSize": "tiny",
	"Displayname": "vCenter65-1",
	"IPAddress": "10.0.0.185",
	"VCSAGateway": "10.0.0.1",
	"Hostname": "vCenter65-1.lab.virtualtassie.com",
	"Prefix": "24",
	"SSHEnable": "true"
  }
```

If you want to deploy VCSA in an external configuration with an external PSC, change the value for ExternalPSC in this section to '1' and then fill in the details for the PSC node.

Leaving ExternalPSC set to 0 will force an embedded VCSA deployment.
```console
  "PSC": {
  	"ExternalPSC": "0",
	"Displayname": "PSC65-1",
	"IPAddress": "10.0.0.186",
	"Hostname": "PSC65-1.lab.virtualtassie.com"
  }
```

This section describes the vSphere SSO configuration that is used regardless of VCSA being deployed as embedded or external
```console
  "SSO": {
  	"DomainName": "vsphere.local",
	"SiteName": "Site1",
	"Password": "VMware1!"
  }
```

This section describes the configuration of the nested deployment. A new virtual DC and cluster are created in the nested VCSA and the nested hosts are added to the cluster.

Toggle the last two settings with 0 (False) or 1 (True).
```console
  "Misc": {
  	"NewvDCName": "Datacenter1",
	"NewVSANClusterName": "Cluster1",
	"UpgradeESXiTo65a": "0",
	"AddHostByDNSName": "1"
  }
```

This section determines if you want to include a DNS check in the pre-checks. Setting "CheckDNS" to 1 will enable a Resolve-DNSName for all nested nodes to be performed.

Note that this uses the hostname value defined in the sections for ESXi / VC / PSC / NSX.

If your DNS server is a Windows server and the account you are using has privileges, you can opt for the deployment script to create the relative DNS records if the DNS lookup fails by filling in the other details in this section.
```console
  "DNSCheck": {
  	"CheckDNS": "1",
	"WindowsDNSServer": "0",
	"DNSServer": "DC01",
	"DNSZoneName": "lab.virtualtassie.com"
  }
```

**Only relevant to 6.5 deployment**
This section describes the NSX configuration if you choose to deploy which will require you to set $DeployNSX property to 1 and fill out all fields.
```console
  "NSX": {
  	"DeployNSX": "0",
	"vCPU": "2",
	"vMem": "8",
	"Displayname": "NSX63-1",
	"Hostname": "nsx63-1.primp-industries.com",
	"IPAddress": "172.30.0.250",
	"NetMask": "255.255.255.0",
	"Gateway": "172.30.0.1",
	"SSHEnable": "true",
	"CEIPEnable": "false",
	"UIPassword": "VMw@re123!",
	"CLIPassword": "VMw@re123!"
  }
```

**Only relevant to 6.5 deployment**
This section describes the VDS and VXLAN configurations which is required for NSX deployment. The only mandatory field here is $PrivateVXLANVMnetwork which is a private portgroup that must already exists which will be used to connect the second network adapter of the Nested ESXi VM for VXLAN traffic. You do not need a routable portgroup and the other properties can be left as default or you can modify them if you wish.
```console
# VDS / VXLAN Configurations
  "VXLAN": {
  	"PrivateVXLANVMNetwork": "dv-private-network",
	"VDSName": "VDS-6.5",
	"VXLANDVPortGroup": "VXLAN",
	"VXLANSubnet": "172.16.66.",
	"VXLANNetmask": "255.255.255.0"
  }
```


Once you have saved your changes, you can now run the PowerCLI script.

## Logging

There is additional verbose logging that outputs as a log file in your current working directory either **vsphere60-vghetto-lab-deployment.log** or **vsphere65-vghetto-lab-deployment.log** depending on the deployment you have selected.

## Verification

Once you have saved all your changes, you can then run the script. You will be provided with a summary of what will be deployed and you can verify that everything is correct before attempting the deployment. Below is a screenshot on what this would look like:

![](https://i1.wp.com/virtualtassie.com/wp-content/uploads/2017/04/65_Lab_Deployment_2.png)

## Sample Executions
