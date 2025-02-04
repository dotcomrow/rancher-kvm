#!/bin/bash

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root or use sudo"
    exit 1
fi

rm -rf /tmp/rks2-teardown.log
exec 1>/tmp/rks2-teardown.log 2>&1

# List running VMs
echo "Running VMs:"
virsh list --all | grep running

# Gracefully shutdown VMs
echo "Shutting down VMs..."
virsh list --all | grep running | awk '{print $2}' | while read vm_name; do
    virsh shutdown $vm_name
done

# Wait for VMs to shutdown (optional)
echo "Waiting for VMs to shutdown..."
while virsh list --all | grep running > /dev/null; do
    sleep 1
done

echo "All VMs shutdown."

terraform destroy --auto-approve

resolvectl flush-caches