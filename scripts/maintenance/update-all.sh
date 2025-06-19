# /usr/local/bin/check-homelab-updates
#!/bin/bash
cd /opt/homelab
git fetch origin >/dev/null 2>&1
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "Updates available for homelab scripts!"
    mosquitto_pub -h "$MQTT_BROKER" -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "homelab/system/updates_available" -m "true"
fi