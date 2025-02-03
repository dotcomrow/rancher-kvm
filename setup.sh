#!/bin/bash

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root or use sudo"
    exit 1
fi

rm -rf /tmp/rks2-setup.log
exec 1>/tmp/rks2-setup.log 2>&1

terraform init
terraform apply --auto-approve

rm -rf ~/.ssh/known_hosts

# iterate over machines and add host entries to hosts file using qemu guest agent
virsh list --all | grep running | awk '{print $2}' | while read vm_name; do
    while ! grep -q "ens3" <(virsh domifaddr $vm_name --source agent 2>&1); do
        sleep 1;
    done
    IP=$(virsh domifaddr $vm_name --source agent | grep ens3 | awk '{print $4}' | cut -d "/" -f 1);
    sudo hostsed add $IP $vm_name;
    ssh-keyscan -H $vm_name >> ~/.ssh/known_hosts;
done


# Rancher Version
RKE2_VERSION="v1.31.3+rke2r1"

# SSH User
SSH_USER="rancher"

# Rancher master node
RANCHER_MASTER="srvr-node-00"

# Rancher domain
RANCHER_DOMAIN="rancher"

# Maximum number of retries
MAX_RETRIES=10
# Time to wait between retries
RETRY_DELAY=10

execute_with_retry() {
    local cmd="$1"
    local attempt=1

    while [ $attempt -le $MAX_RETRIES ]; do
        echo "Attempt $attempt: $cmd"
        eval "$cmd" && return 0  # If the command succeeds, exit the function
        echo "Command failed. Retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
        ((attempt++))
    done

    echo "Command failed after $MAX_RETRIES attempts: $cmd"
    return 1  # Return failure if all retries fail
}


virsh list --all | grep running | awk '{print $2}' | while read vm_name; do
    execute_with_retry "scp ~/.ssh/known_hosts $SSH_USER@$vm_name:~/.ssh/known_hosts"
    execute_with_retry "scp /etc/hosts $SSH_USER@$vm_name:/tmp/hosts"
    execute_with_retry "ssh -n $SSH_USER@$vm_name 'sudo cp /tmp/hosts /etc/hosts'"
    execute_with_retry "ssh -n $SSH_USER@$vm_name 'sudo cp ~/.ssh/known_hosts /root/.ssh/known_hosts'"

    echo "All operations completed on node $vm_name."
done


# Rancher RKE2 Cluster Installation Script

# Custom TLS Certificate Paths
CUSTOM_CA_CERT="certs/ca.crt"
CUSTOM_CA_KEY="certs/ca.key"
CUSTOM_KUBE_CERT="certs/kube-apiserver.crt"
CUSTOM_KUBE_KEY="certs/kube-apiserver.key"
CUSTOM_ETCD_CERT="certs/etcd-server.crt"
CUSTOM_ETCD_KEY="certs/etcd-server.key"
CUSTOM_NODE_CERT="certs/node.crt"
CUSTOM_NODE_KEY="certs/node.key"

# Function to Copy Certificates to Nodes and Add CA to Trust Store
copy_certs_and_trust() {
    local NODE_IP=$1
    echo "Copying certificates to $NODE_IP and adding CA to system trust store..."

    ssh -n $SSH_USER@$NODE_IP "mkdir -p /tmp/certs"

    # Copy certificates
    scp $CUSTOM_CA_CERT $SSH_USER@$NODE_IP:/tmp/certs/ca.crt
    scp $CUSTOM_CA_KEY $SSH_USER@$NODE_IP:/tmp/certs/ca.key
    scp $CUSTOM_KUBE_CERT $SSH_USER@$NODE_IP:/tmp/certs/kube-apiserver.crt
    scp $CUSTOM_KUBE_KEY $SSH_USER@$NODE_IP:/tmp/certs/kube-apiserver.key
    scp $CUSTOM_ETCD_CERT $SSH_USER@$NODE_IP:/tmp/certs/etcd-server.crt
    scp $CUSTOM_ETCD_KEY $SSH_USER@$NODE_IP:/tmp/certs/etcd-server.key
    scp $CUSTOM_NODE_CERT $SSH_USER@$NODE_IP:/tmp/certs/node.crt
    scp $CUSTOM_NODE_KEY $SSH_USER@$NODE_IP:/tmp/certs/node.key

    ssh -n $SSH_USER@$NODE_IP "sudo cp /tmp/certs/* /etc/rancher/rke2/"

    # Ensure correct permissions
    ssh -n $SSH_USER@$NODE_IP "sudo chmod 600 /etc/rancher/rke2/*"

    # Add CA to Ubuntu's trust store
    ssh -n $SSH_USER@$NODE_IP <<EOF
        sudo cp /etc/rancher/rke2/ca.crt /usr/local/share/ca-certificates/custom-ca.crt
        sudo update-ca-certificates
EOF
}

# Function to install RKE2 on a node
install_rke2() {
    local NODE_IP=$1
    local NODE_TYPE=$2
    echo "Installing RKE2 on $NODE_IP ($NODE_TYPE)..."

    ssh -n $SSH_USER@$NODE_IP "sudo mkdir -p /etc/rancher/rke2";

    # Copy certificates to the node
    copy_certs_and_trust  $NODE_IP

    # Install RKE2
    ssh -n $SSH_USER@$NODE_IP "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=$RKE2_VERSION sh -"

    # Create custom RKE2 config with custom certificates
    ssh -n $SSH_USER@$NODE_IP "sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
tls-san:
  - ${NODE_IP}
  - ${RANCHER_DOMAIN}

etcd:
  peer-cert-file: /etc/rancher/rke2/etcd-server.crt
  peer-key-file: /etc/rancher/rke2/etcd-server.key
  trusted-ca-file: /etc/rancher/rke2/ca.crt

kube-apiserver:
  tls-cert-file: /etc/rancher/rke2/kube-apiserver.crt
  tls-private-key-file: /etc/rancher/rke2/kube-apiserver.key

tls:
  cert-file: /etc/rancher/rke2/node.crt
  key-file: /etc/rancher/rke2/node.key
  ca-file: /etc/rancher/rke2/ca.crt
EOF"

    if [ ! -z "$RKE2_TOKEN" ]; then
        ssh -n $SSH_USER@$NODE_IP "echo 'token: $RKE2_TOKEN' | sudo tee -a /etc/rancher/rke2/config.yaml";
        ssh -n $SSH_USER@$NODE_IP "echo 'server: https://$RANCHER_MASTER:9345' | sudo tee -a /etc/rancher/rke2/config.yaml";
    fi

    # Start RKE2
    if [[ "$NODE_TYPE" == "server" ]]; then
        ssh -n $SSH_USER@$NODE_IP "sudo systemctl enable rke2-server && sudo systemctl start rke2-server"
    else
        ssh -n $SSH_USER@$NODE_IP "sudo systemctl enable rke2-agent && sudo systemctl start rke2-agent"
    fi
}

# Step 1: Install RKE2 on Server Nodes (First node is the leader)
echo "Setting up Rancher Server Nodes..."
SERVER_NODE_PATTERN="srvr-node-"
ETCD_NODE_PATTERN="etcd-node-"
CONTROL_NODE_PATTERN="ctrl-node-"
WORKER_NODE_PATTERN="work-node-"

install_rke2 "$RANCHER_MASTER" "server";
# ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f https://docs.projectcalico.org/manifests/calico.yaml";
RKE2_TOKEN=$(ssh -n $SSH_USER@$RANCHER_MASTER "sudo cat /var/lib/rancher/rke2/server/node-token");

while IFS= read -r NODE; do
    if [ "$NODE" == "$RANCHER_MASTER" ]; then
        continue;
    fi
    install_rke2 "$NODE" "server";
done < <(virsh list --all | awk '/running/ && $2 ~ /'"$SERVER_NODE_PATTERN"'/ {print $2}')

# Step 2: Install RKE2 on ETCD Nodes
echo "Setting up ETCD Nodes..."
while IFS= read -r NODE; do
    echo "Installing Rancher RKE on $NODE";
    ssh -n $SSH_USER@$NODE "sudo mkdir -p /etc/rancher/rke2";
    ssh -n $SSH_USER@$NODE "echo 'token: $RKE2_TOKEN' | sudo tee /etc/rancher/rke2/config.yaml";
    ssh -n $SSH_USER@$NODE "echo 'server: https://$RANCHER_MASTER:9345' | sudo tee -a /etc/rancher/rke2/config.yaml";
    ssh -n $SSH_USER@$NODE "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=$RKE2_VERSION sh -";
    ssh -n $SSH_USER@$NODE "sudo systemctl enable rke2-server.service && sudo systemctl start rke2-server.service";
done < <(virsh list --all | awk '/running/ && $2 ~ /'"$ETCD_NODE_PATTERN"'/ {print $2}')

# Step 3: Install RKE2 on Additional Control Plane Nodes
echo "Setting up Control Plane Nodes..."
while IFS= read -r NODE; do
    echo "Installing Rancher RKE on $NODE";
    ssh -n $SSH_USER@$NODE "sudo mkdir -p /etc/rancher/rke2";
    ssh -n $SSH_USER@$NODE "echo 'token: $RKE2_TOKEN' | sudo tee /etc/rancher/rke2/config.yaml";
    ssh -n $SSH_USER@$NODE "echo 'server: https://$RANCHER_MASTER:9345' | sudo tee -a /etc/rancher/rke2/config.yaml";
    ssh -n $SSH_USER@$NODE "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=$RKE2_VERSION sh -";
    ssh -n $SSH_USER@$NODE "sudo systemctl enable rke2-server.service && sudo systemctl start rke2-server.service";
done < <(virsh list --all | awk '/running/ && $2 ~ /'"$CONTROL_NODE_PATTERN"'/ {print $2}')

# Step 4: Install RKE2 on Worker Nodes
echo "Setting up Worker Nodes..."
while IFS= read -r NODE; do
    echo "Installing Rancher RKE on $NODE";
    ssh -n $SSH_USER@$NODE "sudo mkdir -p /etc/rancher/rke2";
    ssh -n $SSH_USER@$NODE "echo 'token: $RKE2_TOKEN' | sudo tee /etc/rancher/rke2/config.yaml";
    ssh -n $SSH_USER@$NODE "echo 'server: https://$RANCHER_MASTER:9345' | sudo tee -a /etc/rancher/rke2/config.yaml";
    ssh -n $SSH_USER@$NODE "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=$RKE2_VERSION sh -";
    ssh -n $SSH_USER@$NODE "sudo systemctl enable rke2-agent.service && sudo systemctl start rke2-agent.service";
done < <(virsh list --all | awk '/running/ && $2 ~ /'"$WORKER_NODE_PATTERN"'/ {print $2}')

# Step 5: Validate Cluster Setup
echo "Verifying cluster status..."
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes"

echo "Rancher RKE2 Cluster setup completed!"

# Step 5: Install Helm on the first server node
echo "Installing Helm on the first server node..."
ssh -n $SSH_USER@$RANCHER_MASTER <<EOF
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
EOF

# Step 6: Install Cert-Manager for Rancher
echo "Installing Cert-Manager for TLS certificates..."
ssh -n $SSH_USER@$RANCHER_MASTER <<EOF
sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
EOF

# Step 7: Install Rancher via Helm
echo "Deploying Rancher UI on RKE2 cluster..."
ssh -n $SSH_USER@$RANCHER_MASTER <<EOF
sudo helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
sudo helm repo update
sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml create namespace cattle-system
sudo helm install rancher rancher-stable/rancher --namespace cattle-system --set hostname=$RANCHER_DOMAIN --set bootstrapPassword=admin --kubeconfig /etc/rancher/rke2/rke2.yaml
EOF

# Step 8: Wait for Rancher to Deploy
echo "Waiting for Rancher deployment to complete..."
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml wait --for=condition=available --timeout=600s deployment/rancher -n cattle-system"

# Verify installation
echo "Verifying cluster and Rancher status..."
ssh -n $SSH_USER@$RANCHER_MASTER <<EOF
sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -n cattle-system
EOF

echo "Rancher UI is now accessible at: https://$RANCHER_DOMAIN"