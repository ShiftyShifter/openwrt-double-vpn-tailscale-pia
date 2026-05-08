#!/bin/sh

# Ensure we are running from the script's directory
cd "$(dirname "$0")" || exit 1

echo "Starting System Bootstrap..."

if [ ! -f "requirements.txt" ]; then
    echo "ERROR: 'requirements.txt' file not found in $(pwd)"
    exit 1
fi

echo "Updating package lists..."
opkg update || { echo "ERROR: opkg update failed"; exit 1; }

echo "Installing required packages from requirements.txt..."
cat requirements.txt | xargs opkg install

echo "Setting permissions..."
chmod +x pia_vpn_manager.sh setup_native_double_vpn.sh

echo "Running network setup..."
sh setup_native_double_vpn.sh

echo "----------------------------------------------------------------"
echo "BOOTSTRAP COMPLETE"
echo "1. Wait for network to change IP and then reconnect to 192.168.2.1"
echo "2. Approve routes/exit node at: https://login.tailscale.com/admin/machines"
echo "3. Run: sh pia_vpn_manager.sh configure"
echo "4. Run: sh pia_vpn_manager.sh start"
echo "----------------------------------------------------------------"