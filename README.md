# GPU Passthrough in OpenShift & Kubevirt

## Table of Contents

<!-- TOC -->
- [GPU Passthrough in OpenShift & Kubevirt](#gpu-passthrough-in-openshift--kubevirt)
  - [Table of Contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Prerequisites](#prerequisites)
  - [Configuring the bare metal GPU hosts for Passthrough](#configuring-the-bare-metal-gpu-hosts-for-passthrough)
    - [Creating vfioConfig for pci passthrough](#creating-vfioconfig-for-pci-passthrough)
    - [Validate proper node configuration](#validate-proper-node-configuration)
  - [Install OpenShift Virtualization](#install-openshift-virtualization)
  - [Setup Storage](#setup-storage)
    - [NFS Client Storage](#nfs-client-storage)
    - [HostPath Provisioner](#hostpath-provisioner)
- [Deploying a Windows VM](#deploying-a-windows-vm)
  - [Create new VM](#create-new-vm)
  - [Windows 10 needs to be updated before the driver will install](#windows-10-needs-to-be-updated-before-the-driver-will-install)
    - [Accessing a Windows VM directly via RDP](#accessing-a-windows-vm-directly-via-rdp)
<!-- TOC -->

## Introduction

It is possible to support video card GPU passthrough using OpenShift and OpenShift Virtualization. The instructions below will help create a configuration that allows for running ONE virtual machine per physical NVidia GPU available. This is an unsupported setup, but will give you an idea of what functions and features are coming to OpenShift Virtualization in the coming releases.

## Prerequisites

This document will assume that you have already created a base OpenShift bare metal cluster with at least one baremetal host with a supported NVidia GPU card. These instructions were tested using a V100 card, but should work for other modern GPU cards. See [Installing a cluster on bare metal](https://docs.openshift.com/container-platform/4.6/installing/installing_bare_metal/installing-bare-metal.html) for details on getting a bare metal cluster up and running.

## Configuring the bare metal GPU hosts for Passthrough

Once your OpenShift cluster is up and running, we need to create some configuration changes to disable loading the default NVidia kernel driver. We will need to identify the hardware IDs for each card in each bare metal host. We will start by logging into each worker node with a GPU and record the PCI ID:

```
oc get nodes
# find the node name of the hardware with GPUs
oc debug node/<node name>
```

Once the debug node is up, we need to run a lspci:

```
$ chroot /host
$ lspci -nn
04:00.0 VGA compatible controller [0300]: NVIDIA Corporation GK208B [GeForce GT 710] [10de:128b] (rev a1)
04:00.1 Audio device [0403]: NVIDIA Corporation GK208 HDMI/DP Audio Controller [10de:0e0f] (rev a1)
09:00.0 3D controller [0302]: NVIDIA Corporation GV100GL [Tesla V100 PCIe 16GB] [10de:1db4] (rev a1)
```

In the above example, the PCI id we are looking for is "10de:1db4". Record this information for each card type you plan to use.

NOTE: If you are using a card that has subfunctions on it you need to ensure that ALL sub funtions are also configured for passthrough. Below is output that shows an example of a card that has multiple functions. For the example card below you would need to configure "10de:1e30,10de:10f7,10de:1ad6,10de:1ad7" for vfio passthrough in the Creating [vfioConfig for pci passthrough](#creating-vfioconfig-for-pci-passthrough) step.

```
# lspci -nn | grep -i nvidia
1a:00.0 VGA compatible controller [0300]: NVIDIA Corporation TU102GL [Quadro RTX 6000/8000] [10de:1e30] (rev a1)
1a:00.1 Audio device [0403]: NVIDIA Corporation TU102 High Definition Audio Controller [10de:10f7] (rev a1)
1a:00.2 USB controller [0c03]: NVIDIA Corporation TU102 USB 3.1 Host Controller [10de:1ad6] (rev a1)
1a:00.3 Serial bus controller [0c80]: NVIDIA Corporation TU102 USB Type-C UCSI Controller [10de:1ad7] (rev a1)
```

### Creating vfioConfig for pci passthrough

Now that we have identified all the PCI ids that identify the cards we want to run in passthrough, we need to configure our OpenShift cluster to specifically assign the "vfio" driver to the card. To do this we will apply a machineConfig to our cluster that specifically assigns the vfio driver to the associated GPU card.

We are going to create a base64 encoded string which we will put in our machineConfig file. To do this, run the following command with the VendorID(s) that you want to put into passthrough mode. Be sure to put the vendor IDs in using lowercase letters only:

```
$ echo "options vfio-pci ids=10de:1db4" | base64
b3B0aW9ucyB2ZmlvLXBjaSBpZHM9MTBkZToxZGI0Cg==
```

Using the base64 output from above update the storage section of the file called "template/vfioConfig.yaml" replacing the example base64 encoded string with the updated one from above.

```
storage:
  files:
    - contents:
        source: >-
          data:text/plain;charset=utf-8;base64,b3B0aW9ucyB2ZmlvLXBjaSBpZHM9MTBkZToxZGI0Cg==
```

Be sure to update the contents source with the base64 string you got from the prior step. In addition to enabling the vfio drivers we need to ensure that IOMMO is enabled for the worker nodes. Depending on your CPU brand (AMD or Intel) update the kernelArguments section to enable IOMMU for your particular processor.

Log into your cluster with the oc command and then apply the vfioConfig.yaml file to your cluster:

NOTE: This will reboot all your worker nodes one at a time to apply the changes.

```
$ oc login <cluster name>
$ oc create -f vfioConfig.yaml
$ oc get machineconfigpool
# WAIT for worker to have all machinecounts updated
```

### Validate proper node configuration

Once all the nodes have rebooted, use the debug pod to check the drivers loaded for your cards:

```
oc get nodes
# find the node name of the hardware with GPUs
oc debug node/<node name>
```

Once the debug node is up, we need to run a lspci:

```
$ chroot /host
$ lspci -nnk -d 10de:
1a:00.0 VGA compatible controller [0300]: NVIDIA Corporation TU102GL [Quadro RTX 6000/8000] [10de:1e30] (rev a1)
	Subsystem: NVIDIA Corporation Quadro RTX 8000 [10de:129e]
	Kernel driver in use: vfio-pci
# ensure that the target card has the vfio_pci driver attached.
$ dmesg | grep IOMMU 
[ 000000] DMAR: IOMMU enabled
# ensure that IOMMU is enabled
```

If you have a card with multiple functions, ensure that all functions have the vfio driver loaded for the function.

## Install OpenShift Virtualization

Follow standard [OpenShift Virtualization Install docs](https://docs.openshift.com/container-platform/4.7/virt/install/installing-virt-web.html) and return here when the default install is complete.

We now need to update the configuration for OpenShift Virtualization to enable the support for GPU and device management. We will edit the kubevirt-config:

oc edit cm kubevirt-config -n openshift-cnv

We need to update one line and then add a new section to the configuration. First update the "feature-gates" line and add ",GPU" to the end of this line:

The feature-gates line should now look like this:
```
  feature-gates: DataVolumes,SRIOV,LiveMigration,CPUManager,CPUNodeDiscovery,Snapshot,GPU
```

We now need to add a new configuration section. This section will enable OpenShift Virtualization to manage any physical GPU cards you may have within your compute nodes. Add the "permittedHostDevices" section of yaml to your configuration. Be sure to update the pciVendorSelector and resourceName appropriately for your specific hardware.

```
data:
  permittedHostDevices: |-
    pciHostDevices:
    - pciVendorSelector: "10DE:1DB4"
      resourceName: "nvidia.com/V100"
      externalResourceProvider: false
```

The completed kuebvirt-config should look similar to this:

```
apiVersion: v1
data:
  default-network-interface: masquerade
  feature-gates: DataVolumes,SRIOV,LiveMigration,CPUManager,CPUNodeDiscovery,Snapshot,GPU
  machine-type: pc-q35-rhel8.3.0
  permittedHostDevices: |-
    pciHostDevices:
    - pciVendorSelector: "10DE:1DB4"
      resourceName: "nvidia.com/V100"
      externalResourceProvider: false
  selinuxLauncherType: virt_launcher.process
  smbios: |-
    Family: Red Hat
    Product: Container-native virtualization
    Manufacturer: Red Hat
    Sku: 2.6.1
    Version: 2.6.1
kind: ConfigMap
```

Save your changes and OpenShift Virtualization will update. Check to ensure that your hardware was recognized by describing a node with a GPU card installed:

```
$ oc describe node/<node  with gpu card>
  Hostname:    node11.ocp4.example.com
Capacity:
  cpu:                            40
  devices.kubevirt.io/kvm:        110
  devices.kubevirt.io/tun:        110
  devices.kubevirt.io/vhost-net:  110
  ephemeral-storage:              975672300Ki
  hugepages-1Gi:                  0
  hugepages-2Mi:                  0
  memory:                         131620192Ki
  nvidia.com/V100:                1
  pods:                           250
```

Note that the capacity of this node has nvidia.com/V100 with a capacity of 1.

## Setup Storage

You will need storage to run your virtual machines. If you have already configured persistent storage for your cluster you can skip these steps and move onto the [Create new VM](#create-new-vm) step. Notes below are for setting up NFS or hostPath provisioner.

### NFS Client Storage

Clone this: https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner

```
$ oc new-project nfs-provisioner
$ export NAMESPACE=`oc project -q`
$ sed -i'' "s/namespace:.*/namespace: $NAMESPACE/g" ./deploy/rbac.yaml
$ oc create -f deploy/rbac.yaml
$ oc create role use-scc-hostmount-anyuid --verb=use --resource=scc --resource-name=hostmount-anyuid -n $NAMESPACE
$ oc adm policy add-role-to-user use-scc-hostmount-anyuid system:serviceaccount:$NAMESPACE:nfs-client-provisioner -n $NAMESPACE
$ oc adm policy add-scc-to-user hostmount-anyuid -z nfs-client-provisioner
```

Edit the deploy/deployment.yaml and update with your server information and be sure to also update the namespace you are running the provisioner in.

```
oc create -f deploy/deployment.yaml
oc create -f deploy/class.yaml
```

### HostPath Provisioner

Clone this: https://github.com/kubevirt/hostpath-provisioner.git

use oc debug node/<node name>
- chroot /host
- mkdir /var/hpvolumes

create a machineconfig.yaml file with the following contents:
```
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 50-set-selinux-for-hostpath-provisioner
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.1.0
    systemd:
      units:
        - contents: |
            [Unit]
            Description=Set SELinux chcon for hostpath provisioner
            Before=kubelet.service

            [Service]
            ExecStart=/usr/bin/chcon -Rt container_file_t /var/hpvolumes

            [Install]
            WantedBy=multi-user.target
          enabled: true
          name: hostpath-provisioner.service
```

create hostpathprovisioner_cr.yaml

```
apiVersion: hostpathprovisioner.kubevirt.io/v1beta1
kind: HostPathProvisioner
metadata:
  name: hostpath-provisioner
spec:
  imagePullPolicy: IfNotPresent
  pathConfig:
    path: "/var/hpvolumes" 
    useNamingPrefix: "false"
```

oc create -f hostpathprovisioner_cr.yaml -n kubevirt

OPTIONAL: set the hostpath-provisioner as the default storage class
set annotation on storage class "storageclass.kubernetes.io/is-default-class: true"

# Deploying a Windows VM

## Create new VM

We will start by uploading a ISO boot cd to our cluster. We will use the virtctl command to upload the ISO image. This requires that you installed the CDI operator in previous steps.
You can download the virtctl command from the [kubevirt github repo](https://github.com/kubevirt/kubevirt/releases)

```
$ oc new-project myvms
# Get the cdi route
$ oc -n cdi get routes
# update the url below to point to the output from the get routes command above
$ virtctl image-upload --uploadproxy-url=https://cdi-uploadproxy-cdi.apps.ocp4rhv.example.com dv iso-win10-dv --size=5Gi --image-path=/home/markd/en_windows_10_multiple_editions_x64_dvd_6846432.iso --insecure
```

Using the file "templates/win10vm1-pvc.yaml" create a PVC to store your virtual machine hard disk on, updating your required disk size and storageClass you want to use.

Create a VirtualMachine instance from yaml using file "templates/win10vm1.yaml". Be sure to update the device name under GPU for the name you gave your GPU in the kubevirt-cr configuration step.

From the console, power on the VM and follow standard install procedures for your Windows 10 OS. If you are using virtio for the hard disk controller you will need to follow the steps outlined [here](https://kubevirt.io/user-guide/#/creation/virtio-win?id=how-to-install-during-windows-install) but be sure to select the "w10" directory to load the proper drivers.
  
When the OS install is complete, open device manager and validate that the 3d device is identified.

## Windows 10 needs to be updated before the driver will install

Once you have a running VM the first thing you need to do is update the Windows OS to the latest release from Microsoft (run Windows Update until there are no updates to install.) This specifically applies to NVidia GPU cards, as the driver uses the WHQL model which was not supported in the original Windows 10 release.

For the hardware tested for this document (V100) the drivers are not auto-installed by Microsoft. You will need to goto the NVidia [driver website](https://www.nvidia.com/Download/index.aspx) and download the appropriate driver set.

### Accessing a Windows VM directly via RDP

If you enable RDP from within the WIndows VIrtual machine, it is possible to directly connect to that VM using RDP through the exposure of the RDP service via a NodePort service.

```
$ virtctl expose virtualmachine win10vm1 --name windows-app-server-rdp --port 3389 --target-port 3389 --type NodePort
$ oc get svc
NAME                     TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)          AGE
windows-app-server-rdp   NodePort   172.30.44.89   <none>        3389:30239/TCP   9s
```

Now open your favorite RDP tool and connect to ANY worker node IP address on the highport number in the above output (eg. 30239)
