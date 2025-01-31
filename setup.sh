DISK_DIR=/home/chris/disks

BASE_IMAGE=/home/chris/isos/ubuntu-24.04-server-cloudimg-amd64.img

CTRL_IMG_SIZE=20G
WORK_IMG_SIZE=20G
ETCD_IMG_SIZE=20G
SRVR_IMG_SIZE=20G

mkdir $DISK_DIR

cp $BASE_IMAGE /home/chris/isos/ctrl_node.img
cp $BASE_IMAGE /home/chris/isos/work_node.img
cp $BASE_IMAGE /home/chris/isos/etcd_node.img
cp $BASE_IMAGE /home/chris/isos/srvr_node.img

qemu-img resize /home/chris/isos/ctrl_node.img +$CTRL_IMG_SIZE
qemu-img resize /home/chris/isos/work_node.img +$WORK_IMG_SIZE
qemu-img resize /home/chris/isos/etcd_node.img +$ETCD_IMG_SIZE
qemu-img resize /home/chris/isos/srvr_node.img +$SRVR_IMG_SIZE

qemu-img create -f qcow2 /home/chris/disks/ctrl_node.qcow2 $CTRL_IMG_SIZE
qemu-img create -f qcow2 /home/chris/disks/work_node.qcow2 $WORK_IMG_SIZE
qemu-img create -f qcow2 /home/chris/disks/etcd_node.qcow2 $ETCD_IMG_SIZE
qemu-img create -f qcow2 /home/chris/disks/srvr_node.qcow2 $SRVR_IMG_SIZE

qemu-img convert -f raw /home/chris/isos/ctrl_node.img -O qcow2 /home/chris/disks/ctrl_node.qcow2
qemu-img convert -f raw /home/chris/isos/work_node.img -O qcow2 /home/chris/disks/work_node.qcow2
qemu-img convert -f raw /home/chris/isos/etcd_node.img -O qcow2 /home/chris/disks/etcd_node.qcow2
qemu-img convert -f raw /home/chris/isos/srvr_node.img -O qcow2 /home/chris/disks/srvr_node.qcow2

sudo chown -R libvirt-qemu:kvm $DISK_DIR

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