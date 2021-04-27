# Enabling MDEV for Intel based GPU

## Table of Contents

<!-- TOC -->
- [Enabling MDEV for Intel based GPU](#enabling-mdev-for-intel-based-gpu)
  - [Table of Contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Prerequisites](#prerequisites)
  - [Configuring worker nodes for Intel vGPU](#configuring-worker-nodes-for-intel-vgpu)
    - [Validate proper node configuration](#validate-proper-node-configuration)
  - [Install upstream kubevirt](#install-upstream-kubevirt)
    - [Install Kubevirt from upstream](#install-kubevirt-from-upstream)
<!-- TOC -->

## Introduction

Starting with 5th generation Intel Core(TM) processors that have Intel Graphics Processors it is possible to create vGPUs (mediated pass-through GPUs) for use by kubevirt. Support for Intel based GPUs is dependent on the following pull request: https://github.com/kubevirt/kubevirt/pull/5215 being merged.

## Prerequisites

These instructions are based on the use of OpenShift 4.6 and above as well as upstream kubevirt. We will leverage MachineConfigs to create the proper host setup and enable the vGPUs. The total number of vGPUs you can create is dependent on your specific machine and the support for changing the Graphics aperture size as well as shared graphics memory. For more details on this see [Create VGPU \(KVMGT only\)](https://github.com/intel/gvt-linux/wiki/GVTg_Setup_Guide#53-create-vgpu-kvmgt-only) in the Intel GVTg wiki.

If you are using a Kubernetes distribution other than OpenShift, you will need to apply the host configuration settings per your Kubernetes distribution. Follow the generic steps in the [Intel GVTg Wiki](https://github.com/intel/gvt-linux/wiki/GVTg_Setup_Guide#5-basic-usage) as a guide.

The instructions below will assume that your Intel Graphics chip is located on PCI ID 00:02.0. To determine what PCI id your device is on use the following commands:

```
$ oc login
$ oc get nodes
NAME          STATUS   ROLES    AGE     VERSION
vmgpucp0      Ready    master   7d20h   v1.19.0+e49167a
vmgpucp1      Ready    master   7d21h   v1.19.0+e49167a
vmgpucp2      Ready    master   7d21h   v1.19.0+e49167a
vmgpuwk0      Ready    worker   7d20h   v1.19.0+e49167a
vmgpuwk1      Ready    worker   7d20h   v1.19.0+e49167a
vmgpuwk2      Ready    worker   7d20h   v1.19.0+e49167a
vmgpuwkgvt0   Ready    worker   7d20h   v1.19.0+e49167a
$ oc debug node/vmgpuwkgvt0
sh-4.4# lspci
00:00.0 Host bridge: Intel Corporation Device 9b53 (rev 03)
00:02.0 VGA compatible controller: Intel Corporation Device 9bc8 (rev 03)
```

In the above output the GPU is on 00:02.0.

## Configuring worker nodes for Intel vGPU

Review the contents of the `intel/templates/gvtgConfig.yaml` file. If your Intel GPU is not located on PCI ID 00:02.0, be sure to update the systemd commands with the proper PCI ID.

Log into your cluster with the oc command and then apply the intel/templates/gvtgConfig.yaml file to your cluster:

NOTE: This will reboot all your worker nodes one at a time to apply the changes.

```
$ oc login <cluster name>
$ oc create -f intel/templates/gvtgConfig.yaml
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

Once the debug node is up, we need to validate that the mediated devices (vGPUs) were created. This will create a bunch of output, but as long as it outputs something you should be good to go.

```
sh-4.4# chroot /hsot
sh-4.4# find -L -O2 /sys/bus/mdev/devices -name mdev_type
```

## Install upstream kubevirt

GPU Passthrough to virtualized machines is not yet supported in OpenShift Virtualization. It will be supported with an upcoming release. In the mean time, in order to try out this functionality we will leverage the upstream "kubevirt" project to enable PCI passthrough.

### Install Kubevirt from upstream

```
# get the latest release of kubevirt
$ export RELEASE=$(curl -s https://github.com/kubevirt/kubevirt/releases/latest | grep -o "v[0-9]\.[0-9]*\.[0-9]*")
$ echo $RELEASE
# Ensure that the release is the one you want to install
# Deploy the KubeVirt operator
$ oc apply -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-operator.yaml
```

This will create a new namespace called "kubevirt" and install the required CRDs.  

Once the operator has been applied we can go ahead and create our kubevirt custom-resource instance. This will allow us to enable the GPU feature gate as well as enable the kubevirt device manager to handle the GPU device we are going to pass through.

Review the file intel/templates/kubevirt-cr.yaml, and then apply it to your cluster. Take note of the resourceName as you will need this when you define new virtual machines.

```
$ oc apply -f intel/templates/kubevirt-cr.yaml
# wait until all KubeVirt components are up
$ oc -n kubevirt wait kv kubevirt --for condition=Available
```

To validate that the kubevirt device manager has successfully configured/recognized the cards, run the following oc command and look for the "resourceName" to be listed in the "Capacity" section and the "Allocatable" section as shown below:

```
$ oc describe node/vmgpuwkgvt0
Name:               vmgpuwkgvt0
Roles:              worker
Labels:             beta.kubernetes.io/arch=amd64
...
Capacity:
  cpu:                            32
  memory:                         131924860Ki
  intel.com/U630:                 2
  pods:                           250
Allocatable:
  cpu:                            31500m
  memory:                         130773884Ki
  intel.com/U630:                 2
  pods:                           250
...
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource                       Requests     Limits
  --------                       --------     ------
  cpu                            404m (1%)    0 (0%)
  memory                         1520Mi (1%)  512Mi (0%)
  ephemeral-storage              0 (0%)       0 (0%)
  hugepages-1Gi                  0 (0%)       0 (0%)
  hugepages-2Mi                  0 (0%)       0 (0%)
  devices.kubevirt.io/kvm        0            0
  devices.kubevirt.io/tun        0            0
  devices.kubevirt.io/vhost-net  0            0
  intel.com/U630                 0            0
```

At this point, you can follow the instructions in the main README.md file to create the CDI importer as well as creating a new virtual machine. When you get to the point of creating your first VM, be sure to update the "gpu" section to attach an instance of intel.com/U630, or use the intel/templates/win10vm1.yaml file to create your VM.
