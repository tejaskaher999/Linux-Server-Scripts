#!/bin/bash
# ============================================================
# Script Name : 03_dhcp_server.sh
# Purpose     : Automatically configure a DHCP server on
#               Rocky Linux 10 using Kea DHCPv4.
#
# Automatically detects:
#   - Network interface
#   - Server IPv4 address
#   - Network address and subnet mask
#
# Automatically generates:
#   - Gateway/DNS: network address ending in .254
#   - DHCP range:  network address ending in .10 to .100
#
# Example:
#   Server IP : 192.168.78.128
#   Network   : 192.168.78.0/24
#   Gateway   : 192.168.78.254
#   DHCP pool : 192.168.78.10 - 192.168.78.100
# ============================================================

set -Eeuo pipefail

# -------------------- ROOT CHECK -----------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    echo "Example: sudo ./03_dhcp_server.sh"
    exit 1
fi

# -------------------- REQUIRED COMMANDS ----------------------

for cmd in ip python3 dnf systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' is missing."
        exit 1
    fi
done

# -------------------- DETECT NETWORK INTERFACE ---------------

echo
echo "============================================================"
echo "        AUTOMATIC DHCP SERVER CONFIGURATION"
echo "============================================================"
echo

# Prefer the interface used for the default IPv4 route.
INTERFACE="$(
    ip -4 route show default |
    awk 'NR == 1 {
        for (i = 1; i <= NF; i++) {
            if ($i == "dev") {
                print $(i + 1)
                exit
            }
        }
    }'
)"

# If no default route exists, use the first global IPv4 interface.
if [[ -z "$INTERFACE" ]]; then
    INTERFACE="$(
        ip -o -4 addr show scope global |
        awk '$2 !~ /^(docker|br-|veth)/ {
            print $2
            exit
        }'
    )"
fi

if [[ -z "$INTERFACE" ]]; then
    echo "ERROR: Could not detect a suitable network interface."
    echo "Check: ip -4 addr"
    exit 1
fi

# Detect the IPv4 address and prefix of the selected interface.
IP_CIDR="$(
    ip -o -4 addr show dev "$INTERFACE" scope global |
    awk 'NR == 1 {print $4}'
)"

if [[ -z "$IP_CIDR" ]]; then
    echo "ERROR: No global IPv4 address found on $INTERFACE."
    echo "Check: ip -4 addr show"
    exit 1
fi

# -------------------- CALCULATE NETWORK SETTINGS -------------

# This script intentionally requires /24 because the requested
# gateway and DHCP pool use fixed final octets (.254, .10, .100).

if ! NETWORK_INFO="$(
    python3 - "$IP_CIDR" <<'PY'
import ipaddress
import sys

try:
    interface = ipaddress.IPv4Interface(sys.argv[1])
    network = interface.network

    if interface.ip.is_loopback or interface.ip.is_link_local:
        raise ValueError("Detected address is not suitable for DHCP.")

    if network.prefixlen != 24:
        raise ValueError(
            f"Detected subnet is /{network.prefixlen}, not /24. "
            "This script uses the requested .10-.100 pool and .254 "
            "gateway convention for /24 networks."
        )

    server = interface.ip
    gateway = network.network_address + 254
    start = network.network_address + 10
    end = network.network_address + 100

    if server in (gateway, start, end):
        raise ValueError("Server IP conflicts with a reserved address.")

    if start <= server <= end:
        raise ValueError(
            f"Server IP {server} is inside the DHCP pool "
            f"{start}-{end}. Move the server to a static address "
            "outside the pool before continuing."
        )

    print(
        str(server),
        str(network),
        str(network.netmask),
        str(gateway),
        str(start),
        str(end)
    )

except Exception as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    sys.exit(1)
PY
)"; then
    echo
    echo "Could not automatically calculate valid network settings."
    echo "Check the interface IP address and subnet mask."
    exit 1
fi

read -r SERVER_IP NETWORK NETMASK GATEWAY RANGE_START RANGE_END \
    <<< "$NETWORK_INFO"

# DNS is automatically set to the assumed gateway address.
DNS_SERVERS="$GATEWAY"

# Domain name can be changed here if required.
DOMAIN_NAME="tejas.com"

# -------------------- DISPLAY DETECTED VALUES ----------------

echo "Detected network configuration:"
echo "------------------------------------------------------------"
echo "Interface       : $INTERFACE"
echo "Server IP       : $SERVER_IP"
echo "Network         : $NETWORK"
echo "Subnet Mask     : $NETMASK"
echo "Gateway         : $GATEWAY"
echo "DHCP Start      : $RANGE_START"
echo "DHCP End        : $RANGE_END"
echo "DNS Server      : $DNS_SERVERS"
echo "Domain Name     : $DOMAIN_NAME"
echo "------------------------------------------------------------"
echo

echo "IMPORTANT:"
echo "- Confirm that $GATEWAY is really your gateway."
echo "- Confirm that $DNS_SERVERS provides DNS service."
echo "- Use a static IP or DHCP reservation for this server."
echo "- Run this only on a network where you are authorized"
echo "  to provide DHCP service."
echo

read -r -p "Continue with this configuration? (y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled. No DHCP configuration was changed."
    exit 0
fi

# -------------------- INSTALL KEA DHCP -----------------------

echo
echo "Checking for Kea DHCP package..."

if ! rpm -q kea >/dev/null 2>&1; then
    echo "Installing Kea DHCP..."
    dnf install -y kea
else
    echo "Kea DHCP is already installed."
fi

if ! command -v kea-dhcp4 >/dev/null 2>&1; then
    echo "ERROR: kea-dhcp4 command was not found after installation."
    exit 1
fi

# -------------------- PREPARE CONFIGURATION ------------------

CONFIG_FILE="/etc/kea/kea-dhcp4.conf"
CONFIG_DIR="/etc/kea"
LEASE_DIR="/var/lib/kea"
TEMP_CONFIG="$(mktemp "${CONFIG_DIR}/kea-dhcp4.conf.tmp.XXXXXX")"

cleanup() {
    if [[ -n "${TEMP_CONFIG:-}" && -f "$TEMP_CONFIG" ]]; then
        rm -f "$TEMP_CONFIG"
    fi
}
trap cleanup EXIT

mkdir -p "$CONFIG_DIR" "$LEASE_DIR"

# Generate a valid JSON configuration using the detected values.
python3 - \
    "$TEMP_CONFIG" \
    "$INTERFACE" \
    "$NETWORK" \
    "$RANGE_START" \
    "$RANGE_END" \
    "$GATEWAY" \
    "$DNS_SERVERS" \
    "$DOMAIN_NAME" <<'PY'
import json
import sys

(
    output_file,
    interface,
    network,
    range_start,
    range_end,
    gateway,
    dns_servers,
    domain
) = sys.argv[1:]

config = {
    "Dhcp4": {
        "interfaces-config": {
            "interfaces": [interface]
        },
        "lease-database": {
            "type": "memfile",
            "persist": True,
            "name": "/var/lib/kea/kea-leases4.csv"
        },
        "valid-lifetime": 4000,
        "renew-timer": 1000,
        "rebind-timer": 2000,
        "subnet4": [
            {
                "id": 1,
                "subnet": network,
                "pools": [
                    {
                        "pool": f"{range_start} - {range_end}"
                    }
                ],
                "option-data": [
                    {
                        "name": "routers",
                        "data": gateway
                    },
                    {
                        "name": "domain-name-servers",
                        "data": dns_servers
                    },
                    {
                        "name": "domain-name",
                        "data": domain
                    }
                ]
            }
        ]
    }
}

with open(output_file, "w", encoding="utf-8") as file:
    json.dump(config, file, indent=4)
    file.write("\n")
PY

# -------------------- VALIDATE CONFIGURATION -----------------

echo
echo "Validating Kea DHCP configuration..."

if ! kea-dhcp4 -t "$TEMP_CONFIG"; then
    echo "ERROR: Kea configuration validation failed."
    echo "Existing configuration has not been replaced."
    exit 1
fi

echo "Configuration validation successful."

# -------------------- BACK UP OLD CONFIGURATION --------------

if [[ -f "$CONFIG_FILE" ]]; then
    BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG_FILE" "$BACKUP_FILE"
    echo "Existing configuration backed up to:"
    echo "$BACKUP_FILE"
fi

# Install the validated configuration.
install -o root -g root -m 0644 "$TEMP_CONFIG" "$CONFIG_FILE"
rm -f "$TEMP_CONFIG"
TEMP_CONFIG=""

# -------------------- FIREWALL CONFIGURATION -----------------

echo
echo "Configuring firewall..."

if systemctl is-active --quiet firewalld; then

    # Detect the zone assigned to this network interface.
    FIREWALL_ZONE="$(
        firewall-cmd --get-zone-of-interface="$INTERFACE" 2>/dev/null || true
    )"

    if [[ -z "$FIREWALL_ZONE" || "$FIREWALL_ZONE" == "no zone" ]]; then
        FIREWALL_ZONE="$(firewall-cmd --get-default-zone)"
    fi

    firewall-cmd --permanent \
        --zone="$FIREWALL_ZONE" \
        --add-service=dhcp

    firewall-cmd --reload

    echo "DHCP firewall service enabled in zone: $FIREWALL_ZONE"
else
    echo "WARNING: firewalld is not active."
    echo "Check your firewall rules before using this DHCP server."
fi

# -------------------- ENABLE AND START SERVICE ---------------

echo
echo "Enabling and starting Kea DHCPv4..."

systemctl enable kea-dhcp4
systemctl restart kea-dhcp4

if ! systemctl is-active --quiet kea-dhcp4; then
    echo
    echo "ERROR: Kea DHCPv4 is not running."
    systemctl --no-pager --full status kea-dhcp4 || true
    echo
    echo "Recent logs:"
    journalctl -u kea-dhcp4 -n 50 --no-pager || true
    exit 1
fi

# -------------------- FINAL VERIFICATION ---------------------

echo
echo "============================================================"
echo "             DHCP SERVER CONFIGURED"
echo "============================================================"
echo

echo "Service status:"
systemctl --no-pager --full status kea-dhcp4 || true

echo
echo "Listening on UDP port 67 (if ss is installed):"
if command -v ss >/dev/null 2>&1; then
    ss -lunp | grep -E '(:67[[:space:]]|:67$)' || \
        echo "No UDP port 67 listener found. Check service logs."
fi

echo
echo "Configuration file: $CONFIG_FILE"
echo
echo "DHCP network settings:"
echo "  Interface : $INTERFACE"
echo "  Server IP : $SERVER_IP"
echo "  Network   : $NETWORK"
echo "  Gateway   : $GATEWAY"
echo "  Pool      : $RANGE_START - $RANGE_END"
echo "  DNS       : $DNS_SERVERS"
echo "  Domain    : $DOMAIN_NAME"

echo
echo "Useful commands:"
echo "  systemctl status kea-dhcp4"
echo "  journalctl -u kea-dhcp4 -f"
echo "  cat $CONFIG_FILE"
echo "  cat /var/lib/kea/kea-leases4.csv"

echo
echo "NOTE: DHCP clients must be on this LAN or reach the server"
echo "through a correctly configured DHCP relay."
echo "============================================================"

