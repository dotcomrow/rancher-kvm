#!/bin/bash

# SSH User
SSH_USER="rancher"

# Rancher master node
RANCHER_MASTER="srvr-node-00"

# Rancher domain
RANCHER_HOSTNAME="k8s"
RANCHER_DOMAIN="suncoast.systems"

# Maximum number of retries
MAX_RETRIES=10
# Time to wait between retries
RETRY_DELAY=20

CERT_DIR="$HOME/certs"
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


# Custom TLS Certificate Paths
CUSTOM_CA_CERT="$CERT_DIR/ca.crt"
CUSTOM_CA_KEY="$CERT_DIR/ca.key"
CUSTOM_KUBE_CERT="$CERT_DIR/kube-apiserver.crt"
CUSTOM_KUBE_KEY="$CERT_DIR/kube-apiserver.key"
CUSTOM_ETCD_CERT="$CERT_DIR/etcd-server.crt"
CUSTOM_ETCD_KEY="$CERT_DIR/etcd-server.key"
CUSTOM_NODE_CERT="$CERT_DIR/node.crt"
CUSTOM_NODE_KEY="$CERT_DIR/node.key"

SERVER_NODE_PATTERN="srvr-node-"
ETCD_NODE_PATTERN="etcd-node-"
CONTROL_NODE_PATTERN="ctrl-node-"
WORKER_NODE_PATTERN="work-node-"

# Load GitHub OAuth credentials from config file
CONFIG_FILE="~/github-auth.conf"
CONFIG_FILE=$(eval echo "$CONFIG_FILE")