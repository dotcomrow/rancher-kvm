#!/bin/bash

echo "Preparing environment..."

echo "public key detected: $(ssh-add -L)"

# Directory to search files in (default: current directory)
DIR=${1:-.}

# Fetch the SSH public key
SSH_PUB_KEY=$(ssh-add -L 2>/dev/null)

# Check if ssh-add returned a key
if [ -z "$SSH_PUB_KEY" ]; then
    echo "No SSH public key found. Ensure ssh-agent is running and a key is added."
    exit 1
fi

# Find and replace occurrences of ${SSH_KEY} in all .cfg files within the directory
find "$DIR" -type f -name "*.cfg" -exec sed -i "s#\${SSH_KEY}#$SSH_PUB_KEY#g" {} +

echo "Replacement completed in all files under $DIR."