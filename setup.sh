#!/bin/bash

terraform init
terraform apply --auto-approve

rm -rf ~/.ssh/known_hosts

# iterate over machines and add host entries to hosts file using qemu guest agent
virsh list --all | grep running | awk '{print $2}' | while read vm_name; do
    while grep -q "error" <(virsh domifaddr $vm_name --source agent 2>&1); do
        sleep 1
    done
    IP=$(virsh domifaddr $vm_name --source agent | grep ens3 | awk '{print $4}' | cut -d "/" -f 1)
    sudo hostsed add $IP $vm_name
    ssh-keyscan -H $vm_name >> ~/.ssh/known_hosts
done


# Rancher RKE2 Cluster Installation Script


# Rancher Version
RKE2_VERSION="v1.31.3+rke2r1"

# SSH User
SSH_USER="rancher"

# Function to install RKE2 on a node
install_rke2() {
    local NODE_IP=$1
    local NODE_TYPE=$2
    echo "Installing RKE2 on $NODE_IP ($NODE_TYPE)..."
    
    ssh $SSH_USER@$NODE_IP "sudo apt-get update -y && sudo apt-get install -y curl"
    ssh $SSH_USER@$NODE_IP "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=$RKE2_VERSION sh -"

    if [[ "$NODE_TYPE" == "server" ]]; then
        ssh $SSH_USER@$NODE_IP "sudo systemctl enable rke2-server.service && sudo systemctl start rke2-server.service"
    else
        ssh $SSH_USER@$NODE_IP "sudo systemctl enable rke2-agent.service && sudo systemctl start rke2-agent.service"
    fi
}

# Step 1: Install RKE2 on Server Nodes (First node is the leader)
echo "Setting up Rancher Server Nodes..."
SERVER_NODE_PATTERN="srvr-node-"
ETCD_NODE_PATTERN="etcd-node-"
CONTROL_NODE_PATTERN="ctrl-node-"
WORKER_NODE_PATTERN="work-node-"

# Get all server nodes
SERVER_NODES=($(virsh list --all | grep running | grep $SERVER_NODE_PATTERN | awk '{print $2}'))

while IFS= read -r NODE; do
    echo "Installing Rancher RKE on $NODE"
    install_rke2 "$NODE" "server"
done < <(virsh list --all | awk '/running/ && $2 ~ /'"$SERVER_NODE_PATTERN"'/ {print $2}')

# Get the first node's token for other servers to join
echo "Fetching RKE2 cluster token..."
RKE2_TOKEN=$(ssh $SSH_USER@srvr-node-00 "sudo cat /var/lib/rancher/rke2/server/node-token")

# Step 2: Install RKE2 on ETCD Nodes
echo "Setting up ETCD Nodes..."
while IFS= read -r NODE; do
    echo "Installing Rancher RKE on $NODE"
    ssh $SSH_USER@$NODE "export INSTALL_RKE2_TOKEN='$RKE2_TOKEN' && curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=$RKE2_VERSION sh -"
    ssh $SSH_USER@$NODE "sudo systemctl enable rke2-server.service && sudo systemctl start rke2-server.service"
done < <(virsh list --all | awk '/running/ && $2 ~ /'"$ETCD_NODE_PATTERN"'/ {print $2}')

# Step 3: Install RKE2 on Additional Control Plane Nodes
echo "Setting up Control Plane Nodes..."
while IFS= read -r NODE; do
    echo "Installing Rancher RKE on $NODE"
    ssh $SSH_USER@$NODE "export INSTALL_RKE2_TOKEN='$RKE2_TOKEN' && curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=$RKE2_VERSION sh -"
    ssh $SSH_USER@$NODE "sudo systemctl enable rke2-server.service && sudo systemctl start rke2-server.service"
done < <(virsh list --all | awk '/running/ && $2 ~ /'"$CONTROL_NODE_PATTERN"'/ {print $2}')

# Step 4: Install RKE2 on Worker Nodes
echo "Setting up Worker Nodes..."
while IFS= read -r NODE; do
    echo "Installing Rancher RKE on $NODE"
    ssh $SSH_USER@$NODE "export INSTALL_RKE2_TOKEN='$RKE2_TOKEN' && curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=$RKE2_VERSION sh -"
    ssh $SSH_USER@$NODE "sudo systemctl enable rke2-agent.service && sudo systemctl start rke2-agent.service"
done < <(virsh list --all | awk '/running/ && $2 ~ /'"$WORKER_NODE_PATTERN"'/ {print $2}')

# Step 5: Validate Cluster Setup
echo "Verifying cluster status..."
ssh $SSH_USER@${SERVER_NODES[0]} "kubectl get nodes"

echo "Rancher RKE2 Cluster setup completed!"
