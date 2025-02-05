#!/bin/bash

# Configurable Variables
DOMAIN="k8s.suncoast.systems"
EMAIL="administrator@suncoast.systems"
CERTBOT_CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
CERT_DIR="./certs"
rm -rf "$CERT_DIR"
mkdir -p "$CERT_DIR"

# Install Certbot & Cloudflare Plugin if Not Installed
if ! command -v certbot &> /dev/null; then
    echo "🔧 Installing Certbot..."
    sudo apt update && sudo apt install -y certbot python3-certbot-dns-cloudflare
fi

# Request Let's Encrypt Certificate Using DNS-01
echo "🔑 Requesting Let's Encrypt certificate for $DOMAIN using DNS-01 challenge..."
sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials ~/cloudflare.ini \
  -d "$DOMAIN" -d "*.$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive --expand

# Verify if certificates were generated
if [ ! -f "$CERTBOT_CERT_DIR/fullchain.pem" ] || [ ! -f "$CERTBOT_CERT_DIR/privkey.pem" ]; then
    echo "❌ ERROR: Let's Encrypt certificate generation failed!"
    exit 1
fi

# Copy Certificates to Working Directory
echo "📦 Copying certificates to $CERT_DIR..."
sudo cp "$CERTBOT_CERT_DIR/fullchain.pem" "$CERT_DIR/ca.crt"
sudo cp "$CERTBOT_CERT_DIR/privkey.pem" "$CERT_DIR/ca.key"
sudo chmod 600 "$CERT_DIR/ca."*

# Function to Copy and Rename Certificates for ETCD, Kube-API, and Nodes
generate_cert_links() {
    local NAME=$1
    echo "🔹 Generating $NAME certificate from Let's Encrypt..."

    # Use the Let's Encrypt cert for all components
    cp "$CERT_DIR/ca.crt" "$CERT_DIR/$NAME.crt"
    cp "$CERT_DIR/ca.key" "$CERT_DIR/$NAME.key"
}

# Generate Certificates for ETCD, Kube-API, and Nodes
generate_cert_links "etcd-server"
generate_cert_links "kube-apiserver"
generate_cert_links "node"

# List Generated Certificates
echo "✅ Certificates generated in $CERT_DIR:"
ls -lah "$CERT_DIR"
