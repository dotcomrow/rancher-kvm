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

resolvectl flush-caches

rm -rf ~/.ssh/known_hosts

# Maximum number of retries
MAX_RETRIES=10
# Time to wait between retries
RETRY_DELAY=20

execute_with_retry() {
    local cmd="$1"
    local verify_cmd="$2"
    local retries=$MAX_RETRIES  # Number of retries
    local delay=$RETRY_DELAY    # Delay between retries in seconds
    local count=0
    local timeout=15 # Timeout in seconds for SCP

    for ((count=1; count<=retries; count++)); do
        echo "Executing: $cmd"

        # Run command with timeout protection
        timeout "$timeout" bash -c "$cmd" && {
            echo "✅ Command succeeded"
            
            # Verify the file exists
            echo "Verifying: $verify_cmd"
            eval "$verify_cmd" && return 0

            echo "❌ Verification failed, retrying..."
        }

        echo "⚠️ Retry $count/$retries failed, retrying in $delay seconds..."
        sleep "$delay"
    done

    echo "❌ ERROR: Command failed after $retries attempts: $cmd"
    return 1  # Indicate failure
}

# iterate over machines and add host entries to hosts file using qemu guest agent
virsh list --all | grep running | awk '{print $2}' | while read vm_name; do
    echo "Adding host entry for $vm_name"
    while ! grep -q "ens3" <(virsh domifaddr $vm_name --source agent 2>&1); do
        sleep 1;
    done
    echo "Waiting for SSH..."

    execute_with_retry \
        "ssh -n $SSH_USER@$vm_name 'until [ -f /home/$SSH_USER/fin ]; do sleep 1; done'" \
        "ssh -n $SSH_USER@$vm_name 'echo /home/$SSH_USER/fin'"

    echo "Adding host entry for $vm_name"
    ssh-keyscan -H $vm_name >> ~/.ssh/known_hosts;
done

CERT_DIR="certs"
EXPECTED_CERTS=(
    "$CERT_DIR/ca.crt"
    "$CERT_DIR/ca.key"
    "$CERT_DIR/etcd-server.crt"
    "$CERT_DIR/etcd-server.key"
    "$CERT_DIR/kube-apiserver.crt"
    "$CERT_DIR/kube-apiserver.key"
    "$CERT_DIR/node.crt"
    "$CERT_DIR/node.key"
)

# Function to verify that certificates exist
verify_certs() {
    echo "🔍 Verifying generated certificates..."
    local missing_certs=0

    for cert in "${EXPECTED_CERTS[@]}"; do
        if [ ! -f "$cert" ]; then
            echo "❌ Missing certificate: $cert"
            missing_certs=1
        else
            echo "✅ Found: $cert"
        fi
    done

    return $missing_certs
}

verify_certs || exit 1

# SSH User
SSH_USER="rancher"

# Rancher master node
RANCHER_MASTER="srvr-node-00"

# Rancher domain
RANCHER_HOSTNAME="k8s"
RANCHER_DOMAIN="suncoast.systems"



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
    echo "📜 Copying certificates to $NODE_IP and adding CA to system trust store..."

    # Copy certificates with verification
    execute_with_retry \
        "scp $CUSTOM_CA_CERT $SSH_USER@$NODE_IP:~/ca.crt" \
        "ssh -n $SSH_USER@$NODE_IP 'test -f ~/ca.crt'"

    execute_with_retry \
        "scp $CUSTOM_CA_KEY $SSH_USER@$NODE_IP:~/ca.key" \
        "ssh -n $SSH_USER@$NODE_IP 'test -f ~/ca.key'"

    execute_with_retry \
        "scp $CUSTOM_KUBE_CERT $SSH_USER@$NODE_IP:~/kube-apiserver.crt" \
        "ssh -n $SSH_USER@$NODE_IP 'test -f ~/kube-apiserver.crt'"

    execute_with_retry \
        "scp $CUSTOM_KUBE_KEY $SSH_USER@$NODE_IP:~/kube-apiserver.key" \
        "ssh -n $SSH_USER@$NODE_IP 'test -f ~/kube-apiserver.key'"

    execute_with_retry \
        "scp $CUSTOM_ETCD_CERT $SSH_USER@$NODE_IP:~/etcd-server.crt" \
        "ssh -n $SSH_USER@$NODE_IP 'test -f ~/etcd-server.crt'"

    execute_with_retry \
        "scp $CUSTOM_ETCD_KEY $SSH_USER@$NODE_IP:~/etcd-server.key" \
        "ssh -n $SSH_USER@$NODE_IP 'test -f ~/etcd-server.key'"

    execute_with_retry \
        "scp $CUSTOM_NODE_CERT $SSH_USER@$NODE_IP:~/node.crt" \
        "ssh -n $SSH_USER@$NODE_IP 'test -f ~/node.crt'"

    execute_with_retry \
        "scp $CUSTOM_NODE_KEY $SSH_USER@$NODE_IP:~/node.key" \
        "ssh -n $SSH_USER@$NODE_IP 'test -f ~/node.key'"

    # Move certificates to RKE2 directory
    execute_with_retry \
        "ssh -n $SSH_USER@$NODE_IP 'sudo mkdir -p /etc/rancher/rke2 && sudo cp ~/*.crt /etc/rancher/rke2/'" \
        "ssh -n $SSH_USER@$NODE_IP 'test -f /etc/rancher/rke2/ca.crt'"

    execute_with_retry \
        "ssh -n $SSH_USER@$NODE_IP 'sudo mkdir -p /etc/rancher/rke2 && sudo cp ~/*.key /etc/rancher/rke2/'" \
        "ssh -n $SSH_USER@$NODE_IP 'test -f /etc/rancher/rke2/ca.key'"

    # Ensure correct permissions
    execute_with_retry \
        "ssh -n $SSH_USER@$NODE_IP 'sudo chmod 600 /etc/rancher/rke2/*'" \
        "ssh -n $SSH_USER@$NODE_IP 'ls -l /etc/rancher/rke2/'"

    # Add CA to Ubuntu's trust store
    execute_with_retry \
        "ssh -n $SSH_USER@$NODE_IP 'sudo cp /etc/rancher/rke2/ca.crt /usr/local/share/ca-certificates/custom-ca.crt'" \
        "ssh -n $SSH_USER@$NODE_IP 'test -f /usr/local/share/ca-certificates/custom-ca.crt'"

    execute_with_retry \
        "ssh -n $SSH_USER@$NODE_IP 'sudo update-ca-certificates'" \
        "ssh -n $SSH_USER@$NODE_IP 'ls -al /etc/ssl/certs | grep custom-ca.crt'"
}

# Function to install RKE2 on a node
install_rke2() {
    local NODE_IP=$1
    local NODE_TYPE=$2
    echo "Installing RKE2 on $NODE_IP ($NODE_TYPE)..."

    ssh -n $SSH_USER@$NODE_IP "sudo mkdir -p /etc/rancher/rke2";
    
    copy_certs_and_trust  $NODE_IP

    # Create custom RKE2 config with custom certificates
    ssh -n $SSH_USER@$NODE_IP "sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
cluster-domain: $RANCHER_DOMAIN

node-label:
  - "cluster-name=k8s-cluster"

tls-san:
  - ${NODE_IP}
  - ${RANCHER_HOSTNAME}

etcd:
  peer-cert-file: /etc/rancher/rke2/etcd-server.crt
  peer-key-file: /etc/rancher/rke2/etcd-server.key
  trusted-ca-file: /etc/rancher/rke2/ca.crt

kube-apiserver:
  tls-cert-file: /etc/rancher/rke2/kube-apiserver.crt
  tls-private-key-file: /etc/rancher/rke2/kube-apiserver.key

tls-cert-file: /etc/rancher/ssl/ca.crt
tls-private-key-file: /etc/rancher/ssl/ca.key

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
    install_rke2 "$NODE" "server";
done < <(virsh list --all | awk '/running/ && $2 ~ /'"$ETCD_NODE_PATTERN"'/ {print $2}')

# Step 3: Install RKE2 on Additional Control Plane Nodes
echo "Setting up Control Plane Nodes..."
while IFS= read -r NODE; do
    install_rke2 "$NODE" "server";
done < <(virsh list --all | awk '/running/ && $2 ~ /'"$CONTROL_NODE_PATTERN"'/ {print $2}')

# Step 4: Install RKE2 on Worker Nodes
echo "Setting up Worker Nodes..."
while IFS= read -r NODE; do
    install_rke2 "$NODE" "agent";
done < <(virsh list --all | awk '/running/ && $2 ~ /'"$WORKER_NODE_PATTERN"'/ {print $2}')

# Step 5: Validate Cluster Setup
echo "Verifying cluster status..."
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes"

# Step 6: Install Cert-Manager for Rancher
echo "Installing Cert-Manager for TLS certificates..."
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml wait --for=condition=available --timeout=600s deployment/cert-manager -n cert-manager"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml wait --for=condition=available --timeout=600s deployment/cert-manager-webhook -n cert-manager"

echo "Cert-Manager installed successfully!"

# installing metallb
echo "Installing MetalLB..."
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.10/config/manifests/metallb-native.yaml"

echo "Waiting for MetalLB Webhook Service to be ready..."

echo "🔄 Waiting for MetalLB to be fully ready..."

while true; do
    echo "Checking MetalLB components..."

    # Check if all MetalLB pods are running
    PODS_READY=$(ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -n metallb-system --no-headers | grep -E 'controller|speaker|webhook-service' | awk '{print \$3}' | grep -v Running | wc -l")
    
    # Check if webhook-service has endpoints
    WEBHOOK_READY=$(ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get endpoints -n metallb-system webhook-service -o jsonpath='{.subsets}' | grep -Eo 'addresses' | wc -l")
    
    if [[ "$PODS_READY" -eq 0 && "$WEBHOOK_READY" -gt 0 ]]; then
        echo "✅ MetalLB is fully ready!"
        break
    fi

    echo "⏳ MetalLB is not ready yet, retrying in 5 seconds..."
    sleep 5
done

echo "✅ MetalLB Webhook is ready!"

# Configuring MetalLB
echo "Configuring MetalLB..."

ssh -n $SSH_USER@$RANCHER_MASTER "cat <<EOF | sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - 10.0.0.110-10.0.0.150  # Choose an unused IP range
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
EOF"


# Step 7: Install Rancher via Helm

BOOTSTRAP_PWD=$(openssl rand -base64 12)
echo "Deploying Rancher UI on RKE2 cluster..."
ssh -n $SSH_USER@$RANCHER_MASTER "sudo helm repo add rancher-stable https://releases.rancher.com/server-charts/stable"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo helm repo update"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml create namespace cattle-system"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo helm upgrade rancher rancher-stable/rancher --namespace cattle-system --kubeconfig /etc/rancher/rke2/rke2.yaml --set hostname=$RANCHER_HOSTNAME.$RANCHER_DOMAIN --set bootstrapPassword=$BOOTSTRAP_PWD --set ingress.tls.source=letsEncrypt --set letsEncrypt.email=administrator@$RANCHER_DOMAIN --set letsEncrypt.ingress.class=traefik"

# Step 8: Wait for Rancher to Deploy
echo "Waiting for Rancher deployment to complete..."
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml wait --for=condition=available --timeout=600s deployment/rancher -n cattle-system"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml patch svc rancher -n cattle-system --type='merge' -p '{\"spec\": {\"loadBalancerIP\": \"10.0.0.110\"}}'"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml expose deployment rancher -n cattle-system --type=LoadBalancer --name=rancher-service --port=443"

# Verify installation
echo "Verifying cluster and Rancher status..."
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -n cattle-system"

# add longhorn
echo "Adding Longhorn storage..."
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/longhorn.yaml"

echo "Bootstrap password is:"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}{{ \"\n\" }}'"

# Add kubernetes-dashboard repository
ssh -n $SSH_USER@$RANCHER_MASTER "sudo helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/"
# Deploy a Helm Release named "kubernetes-dashboard" using the kubernetes-dashboard chart
ssh -n $SSH_USER@$RANCHER_MASTER "sudo helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard --kubeconfig /etc/rancher/rke2/rke2.yaml"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml patch svc kubernetes-dashboard-kong-proxy -n kubernetes-dashboard --type='merge' -p '{\"spec\": {\"type\": \"LoadBalancer\", \"loadBalancerIP\": \"10.0.0.111\"}}'"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0/aio/deploy/recommended.yaml"

# configure github oidc
# Load GitHub OAuth credentials from config file
CONFIG_FILE="~/github-auth.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ ERROR: Config file $CONFIG_FILE not found!"
    exit 1
fi

# Read values from the config file
source "$CONFIG_FILE"

# Ensure required variables are set
if [[ -z "$GITHUB_CLIENT_ID" || -z "$GITHUB_CLIENT_SECRET" || -z "$GITHUB_ORG" ]]; then
    echo "❌ ERROR: Missing required variables in $CONFIG_FILE!"
    exit 1
fi

ssh -n $SSH_USER@$RANCHER_MASTER "cat <<EOF | sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
apiVersion: management.cattle.io/v3
kind: AuthConfig
metadata:
  name: github
  namespace: cattle-system
enabled: true
displayName: 'GitHub Authentication'
clientId: '$GITHUB_CLIENT_ID'
clientSecret: '$GITHUB_CLIENT_SECRET'
hostname: 'github.com'
rancherUrl: 'https://$RANCHER_HOSTNAME.$RANCHER_DOMAIN'
allowedPrincipalIds:
  - 'github_org:$GITHUB_ORG'  # Restrict access to a GitHub org 
scopes:
  - 'read:user'
  - 'user:email'
  - 'read:org'
EOF"

ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml rollout restart deployment rancher -n cattle-system"

ssh -n $SSH_USER@$RANCHER_MASTER "cat <<EOF | sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
apiVersion: management.cattle.io/v3
kind: OIDCClient
metadata:
  name: kubernetes-dashboard
  namespace: cattle-system
spec:
  displayName: 'Kubernetes Dashboard OIDC Client'
  allowedPrincipalIds: []  # Restrict access if needed, leave empty for all Rancher users
  redirectURIs:
    - 'https://$RANCHER_HOSTNAME.$RANCHER_DOMAIN/oauth2/callback'
  scopes:
    - 'openid'
    - 'profile'
    - 'email'
    - 'groups'
EOF"

OIDC_CLIENT=$(ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml  get oidcclient -n cattle-system kubernetes-dashboard -o jsonpath=\"{.spec.clientID}\"")
OIDC_SECRET=$(ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml  get secret -n cattle-system kubernetes-dashboard -o jsonpath=\"{.data.clientSecret}\" | base64 --decode")

# configure oidc for kubernetes-dashboard
ssh -n $SSH_USER@$RANCHER_MASTER "cat <<EOF | sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubernetes-dashboard-settings
  namespace: kubernetes-dashboard
data:
  # Enable OIDC Authentication
  enable-insecure-login: 'false'
  authentication-mode: oidc
  oidc-client-id: $OIDC_CLIENT
  oidc-client-secret: $OIDC_SECRET
  oidc-issuer-url: https://$RANCHER_HOSTNAME.$RANCHER_DOMAIN/v3/oidc
  oidc-redirect-url: https://$RANCHER_HOSTNAME.$RANCHER_DOMAIN/oauth2/callback
  oidc-scopes: openid profile email groups
  oidc-extra-params: prompt=consent
EOF"

ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml rollout restart deployment -n kubernetes-dashboard kubernetes-dashboard"


ssh -n $SSH_USER@$RANCHER_MASTER "cat <<EOF | sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF"

ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n kubernetes-dashboard create token admin-user"

# create longhorn storage classes
ssh -n $SSH_USER@$RANCHER_MASTER "cat <<EOF | sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: 'true'
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: '1'  # Adjust based on available nodes
  staleReplicaTimeout: '30'

apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-rwx
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: '1'
  staleReplicaTimeout: '30'
  fromBackup: ''  # Optional: Restore from backup if needed

apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ephemeral-fast
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF"