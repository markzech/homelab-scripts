#!/bin/bash

# Nextcloud WebDAV sync script - Improved version with timeouts and progress
# Place in: /opt/homelab/scripts/nextcloud-sync/nextcloud-sync.sh

set -e

# Script metadata
SCRIPT_NAME="nextcloud-sync"
SCRIPT_VERSION="2.1.0"

# Secrets file location
SECRETS_FILE="/etc/homelab/secrets/config.env"

# Load configuration from secrets file
if [ -f "$SECRETS_FILE" ]; then
    source "$SECRETS_FILE"
    echo "Loaded configuration from $SECRETS_FILE"
else
    echo "ERROR: Secrets file not found at $SECRETS_FILE"
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

# Sync timeout (30 minutes)
SYNC_TIMEOUT=1800

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
    if timeout 30 rclone lsd nextcloud: --config "$RCLONE_CONFIG" >/dev/null 2>&1; then
        log "Nextcloud connection successful"
        return 0
    else
        log "Nextcloud connection failed or timed out"
        return 1
    fi
}

# Send MQTT message
send_mqtt() {
    local topic="$1"
    local message="$2"
    if command -v mosquitto_pub >/dev/null 2>&1; then
        timeout 10 mosquitto_pub -h "$HASS_IP" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$message" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log "MQTT sent: $topic = $message"
        else
            log "MQTT failed: $topic = $message"
        fi
    else
        log "mosquitto_pub not available, skipping MQTT"
    fi
}

# Check available memory before sync
check_resources() {
    local available_mem=$(free -m | awk 'NR==2{printf "%d", $7}')
    local available_space=$(df "$MOUNT_POINT" | awk 'NR==2 {print $4}')
    
    log "Available memory: ${available_mem}MB"
    log "Available storage: ${available_space}KB"
    
    if [ "$available_mem" -lt 200 ]; then
        log "WARNING: Low memory (${available_mem}MB), sync may fail"
        send_mqtt "nextcloud-sync/warning" "low_memory"
    fi
}

log "=== Starting Nextcloud Sync (version $SCRIPT_VERSION) ==="
log "Using Nextcloud: $NEXTCLOUD_URL"
log "Syncing to: $SYNC_DIR"

# Check resources
check_resources

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

log "Starting Nextcloud WebDAV sync with timeout of ${SYNC_TIMEOUT}s..."
send_mqtt "nextcloud-sync/status" "syncing"

# Perform sync with WebDAV with timeout and reduced parallelism for low-resource VM
timeout $SYNC_TIMEOUT rclone sync "nextcloud:" "$SYNC_DIR" \
    --config "$RCLONE_CONFIG" \
    --log-level INFO \
    --log-file "$LOGFILE" \
    --transfers 2 \
    --checkers 4 \
    --retries 2 \
    --low-level-retries 3 \
    --timeout 60s \
    --contimeout 30s \
    --stats 60s \
    --stats-one-line \
    --exclude ".DS_Store" \
    --exclude "Thumbs.db" \
    --exclude "*.tmp" \
    --exclude ".*" \
    --exclude "desktop.ini" \
    --exclude "*.lock" \
    --max-size 100M \
    --progress

SYNC_RESULT=$?

if [ $SYNC_RESULT -eq 0 ]; then
    SIZE=$(du -sh "$SYNC_DIR" 2>/dev/null | cut -f1 || echo "unknown")
    FILES=$(find "$SYNC_DIR" -type f 2>/dev/null | wc -l || echo "unknown")
    log "Sync completed successfully - $FILES files ($SIZE total)"
    
    # Send success status to Home Assistant
    send_mqtt "nextcloud-sync/status" "success"
    send_mqtt "nextcloud-sync/last_sync" "$(date -Iseconds)"
    send_mqtt "nextcloud-sync/file_count" "$FILES"
    send_mqtt "nextcloud-sync/size" "$SIZE"
elif [ $SYNC_RESULT -eq 124 ]; then
    log "Sync timed out after ${SYNC_TIMEOUT} seconds"
    send_mqtt "nextcloud-sync/status" "timeout"
else
    log "Sync failed with exit code $SYNC_RESULT"
    send_mqtt "nextcloud-sync/status" "failed"
fi

log "Sync process completed"