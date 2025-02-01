#!/bin/bash

terraform init
terraform apply --auto-approve

# iterate over machines and add host entries to hosts file using qemu guest agent
virsh list --all | grep running | awk '{print $2}' | while read vm_name; do
    virsh domifaddr $vm_name --source agent | grep ipv4 | awk '{print $4 " " $2}' | while read ip hostname; do
        echo "$ip $hostname" >> /etc/hosts
    done
done