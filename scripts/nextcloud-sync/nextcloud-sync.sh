#!/bin/bash

# Nextcloud WebDAV sync script - Secrets-integrated version
# Place in: /usr/local/bin/nextcloud-sync.sh

set -e

# Script metadata
SCRIPT_NAME="nextcloud-sync"
SCRIPT_VERSION="2.0.0"

# Secrets file location
SECRETS_FILE="/etc/homelab/secrets/config.env"

# Load configuration from secrets file
if [ -f "$SECRETS_FILE" ]; then
    source "$SECRETS_FILE"
    echo "Loaded configuration from $SECRETS_FILE"
else
    echo "ERROR: Secrets file not found at $SECRETS_FILE"
    echo "Please create the secrets file with your credentials:"
    echo "sudo mkdir -p /etc/homelab/secrets"
    echo "sudo nano $SECRETS_FILE"
    echo ""
    echo "Required variables in secrets file:"
    echo "NEXTCLOUD_URL=\"https://your-nextcloud-instance.com\""
    echo "NEXTCLOUD_USER=\"your-username\""
    echo "NEXTCLOUD_PASS=\"your-app-password\""
    echo "HASS_IP=\"10.0.0.110\""
    echo "MQTT_USER=\"nextcloud-sync\""
    echo "MQTT_PASS=\"sync-password\""
    exit 1
fi

# Verify required variables are set
required_vars=("NEXTCLOUD_URL" "NEXTCLOUD_USER" "NEXTCLOUD_PASS" "HASS_IP" "MQTT_USER" "MQTT_PASS")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "ERROR: Required variable $var is not set in $SECRETS_FILE"
        exit 1
    fi
done

# Default paths (can be overridden in secrets file)
LOGFILE="${LOGFILE:-/var/log/nextcloud-sync.log}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/truenas}"
SYNC_DIR="${SYNC_DIR:-$MOUNT_POINT/nextcloud-backup}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

# Create rclone config for Nextcloud WebDAV if it doesn't exist
setup_rclone_config() {
    if [ ! -f "$RCLONE_CONFIG" ]; then
        log "Creating rclone WebDAV config for Nextcloud..."
        mkdir -p "$(dirname "$RCLONE_CONFIG")"
        
        # Create encrypted password for rclone config
        ENCRYPTED_PASS=$(echo "$NEXTCLOUD_PASS" | rclone obscure -)
        
        cat > "$RCLONE_CONFIG" << EOF
[nextcloud]
type = webdav
url = ${NEXTCLOUD_URL}/remote.php/dav/files/${NEXTCLOUD_USER}/
vendor = nextcloud
user = ${NEXTCLOUD_USER}
pass = ${ENCRYPTED_PASS}
bearer_token = 
bearer_token_command = 
EOF
        log "Rclone WebDAV config created"
    fi
}

# Test Nextcloud connection
test_connection() {
    log "Testing Nextcloud WebDAV connection..."
    if rclone lsd nextcloud: --config "$RCLONE_CONFIG" >/dev/null 2>&1; then
        log "Nextcloud connection successful"
        return 0
    else
        log "Nextcloud connection failed"
        return 1
    fi
}

# Send MQTT message
send_mqtt() {
    local topic="$1"
    local message="$2"
    if command -v mosquitto_pub >/dev/null 2>&1; then
        mosquitto_pub -h "$HASS_IP" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$message" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log "MQTT sent: $topic = $message"
        else
            log "MQTT failed: $topic = $message"
        fi
    else
        log "mosquitto_pub not available, skipping MQTT"
    fi
}

log "=== Starting Nextcloud Sync (version $SCRIPT_VERSION) ==="
log "Using Nextcloud: $NEXTCLOUD_URL"
log "Syncing to: $SYNC_DIR"

# Check if TrueNAS is mounted
if ! mountpoint -q "$MOUNT_POINT"; then
    log "TrueNAS not mounted at $MOUNT_POINT"
    send_mqtt "nextcloud-sync/status" "mount_error"
    exit 1
fi

# Setup rclone config
setup_rclone_config

# Test connection before sync
if ! test_connection; then
    log "Cannot connect to Nextcloud, aborting sync"
    send_mqtt "nextcloud-sync/status" "connection_failed"
    exit 1
fi

# Create sync directory if needed
mkdir -p "$SYNC_DIR"

log "Starting Nextcloud WebDAV sync from root folder..."
send_mqtt "nextcloud-sync/status" "syncing"

# Perform sync with WebDAV (syncs entire Nextcloud root)
rclone sync "nextcloud:" "$SYNC_DIR" \
    --config "$RCLONE_CONFIG" \
    --log-level INFO \
    --log-file "$LOGFILE" \
    --transfers 4 \
    --checkers 8 \
    --retries 3 \
    --low-level-retries 10 \
    --stats 30s \
    --exclude ".DS_Store" \
    --exclude "Thumbs.db" \
    --exclude "*.tmp" \
    --exclude ".*" \
    --exclude "desktop.ini"

SYNC_RESULT=$?

if [ $SYNC_RESULT -eq 0 ]; then
    SIZE=$(du -sh "$SYNC_DIR" 2>/dev/null | cut -f1)
    FILES=$(find "$SYNC_DIR" -type f 2>/dev/null | wc -l)
    log "Sync completed successfully - $FILES files ($SIZE total)"
    
    # Send success status to Home Assistant
    send_mqtt "nextcloud-sync/status" "success"
    send_mqtt "nextcloud-sync/last_sync" "$(date -Iseconds)"
    send_mqtt "nextcloud-sync/file_count" "$FILES"
    send_mqtt "nextcloud-sync/size" "$SIZE"
else
    log "Sync failed with exit code $SYNC_RESULT"
    send_mqtt "nextcloud-sync/status" "failed"
fi

log "Sync process completed"