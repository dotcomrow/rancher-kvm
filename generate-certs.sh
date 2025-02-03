#!/bin/bash

# Directory to store generated certificates
CERT_DIR="./certs"
mkdir -p "$CERT_DIR"

# Certificate Details
COUNTRY="US"
STATE="Florida"
LOCALITY="Clearwater"
ORG="SuncoastSystemsRKE"
OU="IT Department"
CA_CN="RKE2-Root-CA"

# Generate Root CA
echo "🔹 Generating Root CA..."
openssl req -x509 -nodes -newkey rsa:4096 -days 3650 -keyout "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORG/OU=$OU/CN=$CA_CN"

# Function to Generate Certificates
generate_cert() {
    local NAME=$1
    local CN=$2
    echo "🔹 Generating $NAME certificate..."
    
    # Generate Private Key
    openssl genrsa -out "$CERT_DIR/$NAME.key" 4096
    
    # Create Certificate Signing Request (CSR)
    openssl req -new -key "$CERT_DIR/$NAME.key" -out "$CERT_DIR/$NAME.csr" -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORG/OU=$OU/CN=$CN"
    
    # Sign Certificate with Root CA
    openssl x509 -req -in "$CERT_DIR/$NAME.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/$NAME.crt" -days 365 -sha256
    
    # Remove CSR (not needed after signing)
    rm "$CERT_DIR/$NAME.csr"
}

# Generate Certificates for ETCD, Kube-API, and Nodes
generate_cert "etcd-server" "etcd-server"
generate_cert "kube-apiserver" "kube-apiserver"
generate_cert "node" "rke2-node"

# List Generated Certificates
echo "✅ Certificates generated in $CERT_DIR:"
ls -lah "$CERT_DIR"
