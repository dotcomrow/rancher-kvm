#!/bin/bash

# List running VMs
echo "Running VMs:"
virsh list --all | grep running

# Gracefully shutdown VMs
echo "Shutting down VMs..."
virsh list --all | grep running | awk '{print $2}' | while read vm_name; do
    virsh shutdown $vm_name
    
    # remove host entries from hosts file
    virsh domifaddr $vm_name --source agent | grep ipv4 | awk '{print $4}' | while read ip; do
        sed -i "/$ip/d" /etc/hosts
    done
done

# Wait for VMs to shutdown (optional)
echo "Waiting for VMs to shutdown..."
while virsh list --all | grep running > /dev/null; do
    sleep 1
done

echo "All VMs shutdown."

terraform destroy --auto-approve

