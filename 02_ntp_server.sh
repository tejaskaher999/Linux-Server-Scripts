#!/bin/bash

# =====================================================
# RHEL / ROCKY LINUX NTP SERVER CONFIGURATION
# =====================================================

# Variables that the system administrator can change
NTP_PACKAGE="chrony"
NTP_SERVICE="chronyd"
NTP_CONFIG="/etc/chrony.conf"
NTP_PORT="123"
NTP_ALLOWED_NETWORK="192.168.78.0/24"

# -----------------------------------------------------
# 1. Check Root Privileges
# -----------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Error: Please run this script as root."
    echo "Usage: sudo bash 02_ntp_server.sh"
    exit 1
fi

# -----------------------------------------------------
# 2. Display Configuration
# -----------------------------------------------------

echo "====================================================="
echo "          NTP SERVER CONFIGURATION"
echo "====================================================="
echo "NTP_PACKAGE          = $NTP_PACKAGE"
echo "NTP_SERVICE          = $NTP_SERVICE"
echo "NTP_CONFIG           = $NTP_CONFIG"
echo "NTP_PORT             = $NTP_PORT"
echo "NTP_ALLOWED_NETWORK  = $NTP_ALLOWED_NETWORK"
echo "====================================================="

read -rp "Do you want to modify any variables? (yes/no): " MODIFY

case "$MODIFY" in
    yes|YES|Yes|y|Y)
        read -rp "NTP package [$NTP_PACKAGE]: " INPUT
        NTP_PACKAGE="${INPUT:-$NTP_PACKAGE}"

        read -rp "NTP service [$NTP_SERVICE]: " INPUT
        NTP_SERVICE="${INPUT:-$NTP_SERVICE}"

        read -rp "NTP config file [$NTP_CONFIG]: " INPUT
        NTP_CONFIG="${INPUT:-$NTP_CONFIG}"

        read -rp "NTP port [$NTP_PORT]: " INPUT
        NTP_PORT="${INPUT:-$NTP_PORT}"

        read -rp "Allowed client network [$NTP_ALLOWED_NETWORK]: " INPUT
        NTP_ALLOWED_NETWORK="${INPUT:-$NTP_ALLOWED_NETWORK}"
        ;;

    no|NO|No|n|N)
        echo "Using default configuration..."
        ;;

    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo
echo "Selected NTP configuration:"
echo "Package: $NTP_PACKAGE"
echo "Service: $NTP_SERVICE"
echo "Config: $NTP_CONFIG"
echo "Port: $NTP_PORT"
echo "Allowed network: $NTP_ALLOWED_NETWORK"

read -rp "Continue with this configuration? (yes/no): " CONFIRM

case "$CONFIRM" in
    yes|YES|Yes|y|Y) ;;
    *) echo "Operation cancelled."; exit 0 ;;
esac

# -----------------------------------------------------
# 3. Install Chrony
# -----------------------------------------------------

echo
echo "Installing NTP package..."
dnf install -y "$NTP_PACKAGE" || exit 1

rpm -q "$NTP_PACKAGE" || exit 1

# -----------------------------------------------------
# 4. Back Up Existing Configuration
# -----------------------------------------------------

if [[ -f "$NTP_CONFIG" ]]; then
    cp -a "$NTP_CONFIG" \
        "${NTP_CONFIG}.bak.$(date +%Y%m%d%H%M%S)" || exit 1
    echo "Existing configuration backed up."
else
    echo "Error: Configuration file not found: $NTP_CONFIG"
    exit 1
fi

# -----------------------------------------------------
# 5. Configure Chrony as an NTP Server
# -----------------------------------------------------

echo
echo "Configuring Chrony..."

# Remove existing allow directives so the intended
# client network can be configured explicitly.
sed -i '/^[[:space:]]*allow[[:space:]]/d' "$NTP_CONFIG"

# Allow NTP clients from the selected network.
echo "" >> "$NTP_CONFIG"
echo "# Allow clients from the configured network" >> "$NTP_CONFIG"
echo "allow $NTP_ALLOWED_NETWORK" >> "$NTP_CONFIG"

# -----------------------------------------------------
# 6. Enable and Start Chrony
# -----------------------------------------------------

echo
echo "Enabling and starting Chrony..."
systemctl enable --now "$NTP_SERVICE" || exit 1
systemctl restart "$NTP_SERVICE" || exit 1

systemctl --no-pager --full status "$NTP_SERVICE"

# -----------------------------------------------------
# 7. Configure Firewall
# -----------------------------------------------------

if systemctl is-active --quiet firewalld; then
    echo
    echo "Opening NTP service in the firewall..."
    firewall-cmd --permanent --add-service=ntp || exit 1
    firewall-cmd --reload || exit 1
    firewall-cmd --list-all
else
    echo "Warning: firewalld is not running."
    echo "Check network firewall rules if clients cannot connect."
fi

# -----------------------------------------------------
# 8. Verify NTP Server
# -----------------------------------------------------

echo
echo "Listening on UDP port $NTP_PORT:"
ss -lunp | grep -E ":${NTP_PORT}[[:space:]]" || true

echo
echo "Chrony tracking information:"
chronyc tracking

echo
echo "Chrony time sources:"
chronyc sources -v

echo
echo "====================================================="
echo "          NTP SERVER SETUP COMPLETED"
echo "====================================================="
echo "Allowed client network: $NTP_ALLOWED_NETWORK"
echo "NTP service: $NTP_SERVICE"
echo "NTP port: UDP $NTP_PORT"
echo
echo "On each client, configure /etc/chrony.conf with:"
echo "server <NTP_SERVER_IP> iburst"
echo
echo "Then run on the client:"
echo "systemctl enable --now chronyd"
echo "chronyc sources -v"
echo "chronyc tracking"
echo "====================================================="

