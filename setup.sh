#!/bin/bash

rm -rf ~/.ssh/known_hosts

source variables.sh
source functions.sh

# iterate over machines and add host entries to hosts file using qemu guest agent
virsh list --all | grep running | awk '{print $2}' | while read vm_name; do
    echo "Adding host entry for $vm_name"
    while ! grep -q "ens3" <(virsh domifaddr $vm_name --source agent 2>&1); do
        sleep 1;
    done
    echo "Waiting for SSH..."
    execute_with_retry "resolvectl flush-caches; ssh-keyscan -H $vm_name >> ~/.ssh/known_hosts" "resolvectl flush-caches; ssh -n $SSH_USER@$vm_name 'echo $vm_name'"

    execute_with_retry \
        "ssh -n $SSH_USER@$vm_name 'until [ -f /home/$SSH_USER/fin ]; do sleep 1; done'" \
        "ssh -n $SSH_USER@$vm_name 'echo /home/$SSH_USER/fin'"

    echo "Adding host entry for $vm_name"
    
done


# Run verification, if it fails, regenerate certs
if ! verify_certs; then
    echo "⚠️ Verification failed! Regenerating certificates..."
    ./generate-certs.sh $CERT_DIR
    # Re-run verification after regeneration
    if ! verify_certs; then
        echo "❌ ERROR: Certificate verification failed after regeneration!"
        cd $CERT_DIR
        exit 1
    fi
fi

echo "✅ All certificates verified successfully!"

# configure github oidc
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ ERROR: Config file $CONFIG_FILE not found!"
    exit 1
fi

# Read values from the config file
source "$CONFIG_FILE"

# Ensure required variables are set
if [[ -z "$GITHUB_CLIENT_ID" || -z "$GITHUB_CLIENT_SECRET" || -z "$GITHUB_AUTH_VAL" || -z "$GITHUB_ORG" || -z "$GITHUB_TEAM" ]]; then
    echo "❌ ERROR: Missing required variables in $CONFIG_FILE!"
    exit 1
fi
# Rancher RKE2 Cluster Installation Script
echo "Setting up Rancher Server Nodes..."

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
$(<"yaml/metal-lb-config.yaml")
EOF"

# Step 7: Install Rancher via Helm
BOOTSTRAP_PWD=$(openssl rand -base64 12)
echo "Deploying Rancher UI on RKE2 cluster..."
ssh -n $SSH_USER@$RANCHER_MASTER "sudo helm repo add rancher-stable https://releases.rancher.com/server-charts/stable"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo helm repo update"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml create namespace cattle-system"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo helm install rancher rancher-stable/rancher --namespace cattle-system --kubeconfig /etc/rancher/rke2/rke2.yaml --set hostname=$RANCHER_HOSTNAME.$RANCHER_DOMAIN --set bootstrapPassword=$BOOTSTRAP_PWD --set ingress.tls.source=letsEncrypt --set letsEncrypt.email=administrator@$RANCHER_DOMAIN --set letsEncrypt.ingress.class=traefik"

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

ssh -n $SSH_USER@$RANCHER_MASTER "cat <<EOF | sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
$(load_yaml_and_replace_variables 'yaml/github-auth-setup.yaml')
EOF"

ssh -n "$SSH_USER@$RANCHER_MASTER" "
  sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
    get users.management.cattle.io \
    -o jsonpath='{range .items[*]}{.metadata.name}{\"\\n\"}{end}' |
  xargs -I {} sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
    delete users.management.cattle.io {}
"

# create longhorn storage classes
ssh -n $SSH_USER@$RANCHER_MASTER "cat <<EOF | sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
$(<"yaml/storage-classes.yaml")
EOF"

# add github actions service account
ssh -n $SSH_USER@$RANCHER_MASTER "cat <<EOF | sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
$(load_yaml_and_replace_variables 'yaml/github-actions-sa.yaml')
EOF"

ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml patch settings.management.cattle.io first-login --type='merge' -p '{\"value\": \"admin\"}'"
ssh -n $SSH_USER@$RANCHER_MASTER "sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml rollout restart deployment rancher -n cattle-system"
echo "🎉 Rancher setup completed successfully!"