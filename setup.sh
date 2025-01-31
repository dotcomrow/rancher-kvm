mkdir /home/chris/images
chown -R libvirt-qemu:kvm /home/chris/images

terraform init
terraform apply --auto-approve

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
virsh list --all | grep off

# Gracefully shutdown VMs
echo "starting VMs..."
virsh list --all | grep off | awk '{print $2}' | while read vm_name; do
    virsh start $vm_name
done