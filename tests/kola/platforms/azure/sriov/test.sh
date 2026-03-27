#!/bin/bash
## kola:
##   # This test is targeted at Azure
##   platforms: azure
##   # This test requires an instance type that supports Accelerated Networking (SRIOV)
##   # Standard_D2s_v3 and larger sizes support Accelerated Networking
##   instanceType: "Standard_D2s_v3"
##   description: Verify that udev rules for Azure SRIOV network interfaces
##                correctly mark them as unmanaged by NetworkManager.

set -xeuo pipefail

. "$KOLA_EXT_DATA/commonlib.sh"

# Find SRIOV network interfaces
# Azure SR-IOV interfaces are PCI devices (not vmbus) and use vendor drivers like mlx5_core
# The synthetic interface uses hv_netvsc driver and is on the vmbus
sriov_interfaces=()
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    # Skip loopback
    if [ "$iface_name" = "lo" ]; then
        continue
    fi

    if [ -e "$iface/device/driver" ]; then
        driver=$(basename "$(readlink "$iface/device/driver")")
        # SR-IOV interfaces are on PCI bus, not vmbus (hv_netvsc is the synthetic interface)
        if [ "$driver" != "hv_netvsc" ] && [ -e "$iface/device/subsystem" ]; then
            subsystem=$(basename "$(readlink "$iface/device/subsystem")")
            if [ "$subsystem" = "pci" ]; then
                sriov_interfaces+=("$iface_name")
                echo "Found SRIOV interface: $iface_name with driver: $driver on PCI bus"
            fi
        fi
    fi
done

# If no SRIOV interfaces found, this might be a VM size without Accelerated Networking
# or the feature might not be enabled. We should have at least one SRIOV interface.
if [ ${#sriov_interfaces[@]} -eq 0 ]; then
    fatal "No SRIOV interfaces found. Expected at least one PCI network interface (non-hv_netvsc)."
fi

# Check that each SRIOV interface has the AZURE_UNMANAGED_SRIOV property set
# This property is set by the azure-vm-utils udev rules
for iface in "${sriov_interfaces[@]}"; do
    echo "Checking if $iface has AZURE_UNMANAGED_SRIOV property..."

    # Use udevadm to check the interface properties
    if ! udevadm info --query=property --path="/sys/class/net/$iface" | grep -q "AZURE_UNMANAGED_SRIOV=1"; then
        fatal "SRIOV interface $iface does not have AZURE_UNMANAGED_SRIOV=1 property. The azure-vm-utils udev rules may not be working correctly."
    fi

    echo "✓ Interface $iface correctly has AZURE_UNMANAGED_SRIOV=1"
done

# Verify that NetworkManager is not managing these interfaces
echo "Verifying NetworkManager is not managing SRIOV interfaces..."
nm_devices=$(nmcli -t -f DEVICE,STATE device)

for iface in "${sriov_interfaces[@]}"; do
    # Check NetworkManager's device list from cached output
    if echo "$nm_devices" | grep -q "^$iface:"; then
        # If the interface appears in nmcli output, check its state
        state=$(echo "$nm_devices" | grep "^$iface:" | cut -d: -f2)
        if [ "$state" != "unmanaged" ]; then
            fatal "NetworkManager is managing SRIOV interface $iface (state: $state). It should be unmanaged."
        fi
    fi

    echo "✓ NetworkManager correctly ignores $iface"
done

echo "All SRIOV interfaces are correctly configured as unmanaged by NetworkManager"
