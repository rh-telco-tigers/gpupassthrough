#!/bin/bash
IDS=`lspci -nn -d 10de:1ad6 | cut -f1 -d ' '`
if [ ! -z "$IDS" ]
then
    for id in $IDS:
    do
        echo -n 0000:${id} > /sys/bus/pci/drivers/xhci_hcd/unbind
        echo -n 0000:${id} > /sys/bus/pci/drivers/vfio-pci/bind
    done
fi