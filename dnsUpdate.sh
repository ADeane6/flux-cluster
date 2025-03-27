#!/bin/bash
TUNNEL_NAME="home-tunnel"
CONFIG_FILE="cluster/apps/kube-system/cloudflared/config.yaml"

# Check if yq is installed (for proper YAML parsing)
if ! command -v yq &> /dev/null; then
    echo "yq is required but not installed. Please install it first."
    echo "https://github.com/mikefarah/yq#install"
    exit 1
fi

# Extract hostnames using yq (proper YAML parser)
HOSTNAMES=$(yq e '.ingress[] | select(.hostname != null) | .hostname' "$CONFIG_FILE")

# Create DNS records for each hostname
for HOSTNAME in $HOSTNAMES; do
  # Skip if hostname is empty or null
  if [[ -z "$HOSTNAME" || "$HOSTNAME" == "null" ]]; then
    continue
  fi
  
  echo "Creating DNS record for $HOSTNAME"
  cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"
done