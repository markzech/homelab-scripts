#!/bin/bash
# GitHub Integration Setup for Home Lab
# Run this on each VM that needs scripts

set -e

# Configuration
GITHUB_REPO="https://github.com/markzech/homelab-scripts"
INSTALL_DIR="/opt/homelab"
CONFIG_DIR="/etc/homelab"

echo "Setting up GitHub integration for homelab scripts..."

# Create directories
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

# Clone or update repository
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "Updating existing repository..."
    cd "$INSTALL_DIR"
    git pull
else
    echo "Cloning repository..."
    git clone "$GITHUB_REPO" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# Make scripts executable
find "$INSTALL_DIR/scripts" -name "*.sh" -type f -exec chmod +x {} \;

# Create symlinks for easy access
mkdir -p /usr/local/bin/homelab
for script in "$INSTALL_DIR"/scripts/*/*.sh; do
    script_name=$(basename "$script")
    ln -sf "$script" "/usr/local/bin/homelab/$script_name"
done

# Install systemd services if they exist
if [ -d "$INSTALL_DIR/configs/systemd" ]; then
    cp "$INSTALL_DIR"/configs/systemd/*.service /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload
fi

# Create update script
cat > /usr/local/bin/update-homelab-scripts << 'EOF'
#!/bin/bash
cd /opt/homelab
git pull
find /opt/homelab/scripts -name "*.sh" -type f -exec chmod +x {} \;
systemctl daemon-reload
echo "Homelab scripts updated successfully"
EOF

chmod +x /usr/local/bin/update-homelab-scripts

# Create daily update cron job
echo "0 6 * * * root /usr/local/bin/update-homelab-scripts >> /var/log/homelab-update.log 2>&1" > /etc/cron.d/homelab-update

echo "GitHub integration setup complete!"
echo "Repository cloned to: $INSTALL_DIR"
echo "Scripts available in: /usr/local/bin/homelab/"
echo "Update with: update-homelab-scripts"