#!/bin/bash

terraform init
terraform apply --auto-approve

rm -rf ~/.ssh/known_hosts

# iterate over machines and add host entries to hosts file using qemu guest agent
virsh list --all | grep running | awk '{print $2}' | while read vm_name; do
    IP=$(virsh domifaddr $vm_name --source agent | grep ens3 | awk '{print $4}' | cut -d "/" -f 1)
    sudo hostsed add $IP $vm_name
    ssh-keyscan -H $vm_name >> ~/.ssh/known_hosts
done