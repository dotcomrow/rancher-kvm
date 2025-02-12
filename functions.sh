#!/bin/bash

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

load_yaml_and_replace_variables() {
  local input_file="$1"

  if [[ ! -f "$input_file" ]]; then
      echo "Error: File '$input_file' not found!" >&2
      return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    while [[ "$line" =~ \{\{([A-Za-z_][A-Za-z0-9_]*)\}\} ]]; do
      VAR_NAME="${BASH_REMATCH[1]}"
      VAR_VALUE="${!VAR_NAME}"  # Get the value of the variable
      line="${line//\{\{$VAR_NAME\}\}/$VAR_VALUE}"
    done
    echo "$line"
  done < "$input_file"
}

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