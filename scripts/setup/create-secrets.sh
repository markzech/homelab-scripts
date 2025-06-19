#!/bin/bash
# Secrets Management for Homelab Scripts

# Create secrets directory structure
mkdir -p /etc/homelab/secrets
chmod 700 /etc/homelab/secrets

# Create main secrets file (never commit this to GitHub)
cat > /etc/homelab/secrets/config.env << 'EOF'
# Nextcloud Configuration
NEXTCLOUD_URL="https://your-nextcloud-instance.com"
NEXTCLOUD_USER="your-username"
NEXTCLOUD_PASS="your-app-password"

# MQTT Configuration
MQTT_BROKER="10.0.0.110"
MQTT_USER="monitor"
MQTT_PASS="monitor-password"

# TrueNAS Configuration
TRUENAS_IP="10.0.0.111"
TRUENAS_USER="your-truenas-user"
TRUENAS_PASS="your-truenas-password"

# Proxmox Configuration
PROXMOX_IP="10.0.0.101"
PROXMOX_TOKEN="your-api-token"

# Home Assistant Configuration
HASS_IP="10.0.0.110"
HASS_TOKEN="your-long-lived-access-token"

# Notification Settings
NOTIFICATION_EMAIL="your-email@domain.com"
EOF

chmod 600 /etc/homelab/secrets/config.env

echo "Secrets configuration created at /etc/homelab/secrets/config.env"
echo "Please edit this file with your actual credentials"
echo "IMPORTANT: This file is never committed to GitHub!"