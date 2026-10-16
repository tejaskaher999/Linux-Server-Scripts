#!/bin/bash
# ============================================================
# Script Name : 03_dhcp_server.sh
# Purpose     : Automatically detect, install and configure
#               ISC DHCP or Kea DHCP on Rocky Linux.
#
# Features:
#   1. Automatically detect interface and IPv4 settings.
#   2. Allow detected configuration values to be edited.
#   3. Check ISC DHCP and Kea package availability.
#   4. Offer Kea when ISC DHCP is unavailable.
#   5. Generate and validate the selected server config.
#   6. Back up the existing configuration.
#   7. Configure firewall and start the selected service.
#
# No terminal screen clearing is performed.
# ============================================================

set -Eeuo pipefail

# -------------------- ROOT CHECK -----------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    echo "Example: sudo ./03_dhcp_server.sh"
    exit 1
fi

# -------------------- REQUIRED COMMANDS ----------------------

for cmd in ip python3 dnf rpm systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' is missing."
        exit 1
    fi
done

echo
echo "============================================================"
echo "          AUTOMATIC DHCP SERVER CONFIGURATION"
echo "============================================================"
echo

# -------------------- DETECT NETWORK INTERFACE ---------------

echo "Detecting network interface..."

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

# Fallback: find the first global IPv4 interface.
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
    echo "ERROR: No suitable network interface was detected."
    exit 1
fi

# Detect the current IPv4 address and CIDR prefix.
IP_CIDR="$(
    ip -o -4 addr show dev "$INTERFACE" scope global |
    awk 'NR == 1 {print $4}'
)"

if [[ -z "$IP_CIDR" ]]; then
    echo "ERROR: No global IPv4 address found on $INTERFACE."
    exit 1
fi

# -------------------- AUTOMATIC NETWORK CALCULATION ----------

if ! NETWORK_INFO="$(
    python3 - "$IP_CIDR" <<'PY'
import ipaddress
import sys

try:
    interface = ipaddress.IPv4Interface(sys.argv[1])
    network = interface.network
    server = interface.ip

    if server.is_loopback or server.is_link_local:
        raise ValueError("Detected IP is not suitable for DHCP.")

    if network.prefixlen != 24:
        raise ValueError(
            f"Detected subnet is /{network.prefixlen}, not /24. "
            "This script uses the requested .10-.100 pool "
            "and .254 gateway convention for /24 networks."
        )

    gateway = network.network_address + 254
    start = network.network_address + 10
    end = network.network_address + 100

    if start <= server <= end:
        raise ValueError(
            f"Server IP {server} is inside the proposed DHCP pool "
            f"{start}-{end}. Use a static server IP outside the pool."
        )

    if server == gateway:
        raise ValueError("Server IP conflicts with the gateway.")

    print(
        server,
        network,
        network.netmask,
        gateway,
        start,
        end
    )

except Exception as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    sys.exit(1)
PY
)"; then
    echo "ERROR: Could not calculate network settings."
    exit 1
fi

read -r SERVER_IP NETWORK NETMASK GATEWAY RANGE_START RANGE_END \
    <<< "$NETWORK_INFO"

DNS_SERVERS="$GATEWAY"
DOMAIN_NAME="tejas.com"

# Preserve the detected values for reference and validation.
DETECTED_INTERFACE="$INTERFACE"
DETECTED_SERVER_IP="$SERVER_IP"

# -------------------- DISPLAY DETECTED VALUES ----------------

show_settings() {
    echo
    echo "Network configuration:"
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
}

show_settings

# -------------------- EDIT DETECTED VALUES -------------------

echo
echo "You can keep the detected values or change them."
echo "Press ENTER at any prompt to keep its current value."
echo

read -r -p "Edit configuration values? (y/N): " EDIT_VALUES

if [[ "$EDIT_VALUES" =~ ^[Yy]$ ]]; then

    read -r -p "Interface [$INTERFACE]: " INPUT_VALUE
    INTERFACE="${INPUT_VALUE:-$INTERFACE}"

    read -r -p "Server IP [$SERVER_IP]: " INPUT_VALUE
    SERVER_IP="${INPUT_VALUE:-$SERVER_IP}"

    read -r -p "Network CIDR [$NETWORK]: " INPUT_VALUE
    NETWORK="${INPUT_VALUE:-$NETWORK}"

    read -r -p "Subnet mask [$NETMASK]: " INPUT_VALUE
    NETMASK="${INPUT_VALUE:-$NETMASK}"

    read -r -p "Gateway [$GATEWAY]: " INPUT_VALUE
    GATEWAY="${INPUT_VALUE:-$GATEWAY}"

    read -r -p "DHCP range start [$RANGE_START]: " INPUT_VALUE
    RANGE_START="${INPUT_VALUE:-$RANGE_START}"

    read -r -p "DHCP range end [$RANGE_END]: " INPUT_VALUE
    RANGE_END="${INPUT_VALUE:-$RANGE_END}"

    read -r -p "DNS server(s), comma-separated [$DNS_SERVERS]: " INPUT_VALUE
    DNS_SERVERS="${INPUT_VALUE:-$DNS_SERVERS}"

    read -r -p "Domain name [$DOMAIN_NAME]: " INPUT_VALUE
    DOMAIN_NAME="${INPUT_VALUE:-$DOMAIN_NAME}"

fi

# -------------------- VALIDATE EDITED VALUES ------------------

echo
echo "Validating network settings..."

if ! python3 - \
    "$INTERFACE" \
    "$SERVER_IP" \
    "$NETWORK" \
    "$NETMASK" \
    "$GATEWAY" \
    "$RANGE_START" \
    "$RANGE_END" \
    "$DNS_SERVERS" \
    "$DOMAIN_NAME" <<'PY'
import ipaddress
import re
import subprocess
import sys

(
    interface,
    server_ip,
    network_cidr,
    netmask,
    gateway,
    range_start,
    range_end,
    dns_servers,
    domain
) = sys.argv[1:]

try:
    # Check that the selected interface exists.
    subprocess.run(
        ["ip", "link", "show", "dev", interface],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    server = ipaddress.IPv4Address(server_ip)
    network = ipaddress.ip_network(network_cidr, strict=False)
    mask = ipaddress.IPv4Address(netmask)
    gw = ipaddress.IPv4Address(gateway)
    start = ipaddress.IPv4Address(range_start)
    end = ipaddress.IPv4Address(range_end)

    if network.version != 4 or network.prefixlen != 24:
        raise ValueError("Network must be an IPv4 /24 network.")

    if str(network.netmask) != str(mask):
        raise ValueError(
            f"Subnet mask {mask} does not match network {network}."
        )

    if server not in network:
        raise ValueError("Server IP must belong to the selected network.")

    if gw not in network or gw in (network.network_address,
                                    network.broadcast_address):
        raise ValueError("Gateway must be a usable address in the network.")

    if start not in network or end not in network:
        raise ValueError("Both DHCP range addresses must be in the network.")

    if start >= end:
        raise ValueError("DHCP range start must be lower than its end.")

    if start <= server <= end:
        raise ValueError("Server IP must not fall inside the DHCP pool.")

    if start <= gw <= end:
        raise ValueError("Gateway must not fall inside the DHCP pool.")

    if start == network.network_address or end == network.broadcast_address:
        raise ValueError("DHCP pool cannot include network/broadcast address.")

    # DNS accepts one or more IPv4 addresses separated by commas.
    dns_list = [item.strip() for item in dns_servers.split(",")]

    if not dns_list or any(not item for item in dns_list):
        raise ValueError("Enter valid comma-separated DNS server addresses.")

    for dns in dns_list:
        ipaddress.IPv4Address(dns)

    # Basic domain-name validation.
    if not domain or len(domain) > 253:
        raise ValueError("Domain name is empty or too long.")

    if not re.fullmatch(
        r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}"
        r"[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}"
        r"[A-Za-z0-9])?))*",
        domain
    ):
        raise ValueError("Domain name format is invalid.")

    # Server IP must already be configured on the selected interface.
    actual_addresses = subprocess.check_output(
        ["ip", "-o", "-4", "addr", "show", "dev", interface],
        text=True
    )

    assigned_ips = []
    for line in actual_addresses.splitlines():
        fields = line.split()
        if "inet" in fields:
            assigned_ips.append(fields[fields.index("inet") + 1].split("/")[0])

    if server_ip not in assigned_ips:
        raise ValueError(
            f"{server_ip} is not currently assigned to {interface}. "
            "Configure that address on the machine first."
        )

    print("All network settings are valid.")

except subprocess.CalledProcessError:
    print(f"ERROR: Interface '{interface}' does not exist.", file=sys.stderr)
    sys.exit(1)
except Exception as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    sys.exit(1)
PY
then
    echo
    echo "ERROR: Correct the values and run the script again."
    echo "No DHCP configuration has been changed."
    exit 1
fi

show_settings

echo
echo "IMPORTANT:"
echo "- Confirm that $GATEWAY is your actual gateway."
echo "- Confirm that your DNS server address(es) provide DNS."
echo "- Use a static IP or DHCP reservation for this server."
echo "- Ensure no other DHCP server conflicts with this pool."
echo "- Run only on a network you are authorized to administer."
echo

read -r -p "Continue with this configuration? (y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo
    echo "Cancelled. No DHCP configuration was changed."
    exit 0
fi

# -------------------- PACKAGE AVAILABILITY -------------------

package_available() {
    local package="$1"

    if rpm -q "$package" >/dev/null 2>&1; then
        return 0
    fi

    if dnf -q repoquery --available --qf '%{name}' "$package" \
        2>/dev/null | grep -Fxq "$package"; then
        return 0
    fi

    if dnf -q list --available "$package" 2>/dev/null |
        awk -v wanted="$package" '
            NR > 1 {
                name = $1
                sub(/\..*$/, "", name)
                if (name == wanted) found = 1
            }
            END { exit !found }
        '; then
        return 0
    fi

    return 1
}

echo
echo "Checking DHCP packages in enabled repositories..."
echo

ISC_AVAILABLE=false
KEA_AVAILABLE=false

if package_available dhcp-server; then
    ISC_AVAILABLE=true
    echo "[AVAILABLE] ISC DHCP (dhcp-server)"
else
    echo "[NOT AVAILABLE] ISC DHCP (dhcp-server)"
fi

if package_available kea; then
    KEA_AVAILABLE=true
    echo "[AVAILABLE] Kea DHCP (kea)"
else
    echo "[NOT AVAILABLE] Kea DHCP (kea)"
fi

# -------------------- SELECT DHCP IMPLEMENTATION -------------

echo

if [[ "$ISC_AVAILABLE" == true && "$KEA_AVAILABLE" == true ]]; then

    echo "Both implementations are available."
    echo "1. ISC DHCP Server"
    echo "2. Kea DHCP Server"
    echo "3. Cancel"
    read -r -p "Select option [1-3]: " CHOICE

    case "$CHOICE" in
        1) DHCP_TYPE="isc" ;;
        2) DHCP_TYPE="kea" ;;
        *) echo "Cancelled."; exit 0 ;;
    esac

elif [[ "$ISC_AVAILABLE" == true ]]; then

    echo "ISC DHCP is available."
    echo "1. Install and configure ISC DHCP"
    echo "2. Cancel"
    read -r -p "Select option [1-2]: " CHOICE

    case "$CHOICE" in
        1) DHCP_TYPE="isc" ;;
        *) echo "Cancelled."; exit 0 ;;
    esac

elif [[ "$KEA_AVAILABLE" == true ]]; then

    echo "ISC DHCP is not available in enabled repositories."
    echo "Kea DHCP is available as an alternative."
    echo "1. Continue with Kea DHCP"
    echo "2. Cancel"
    read -r -p "Select option [1-2]: " CHOICE

    case "$CHOICE" in
        1) DHCP_TYPE="kea" ;;
        *) echo "Cancelled."; exit 0 ;;
    esac

else

    echo "ERROR: Neither ISC DHCP nor Kea is installed or available."
    echo "Check enabled repositories using: dnf repolist"
    exit 1

fi

echo
echo "Selected DHCP implementation: $DHCP_TYPE"
read -r -p "Install/configure this implementation? (y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# -------------------- INSTALL SELECTED PACKAGE ---------------

if [[ "$DHCP_TYPE" == "isc" ]]; then

    if ! rpm -q dhcp-server >/dev/null 2>&1; then
        echo "Installing ISC DHCP..."
        dnf install -y dhcp-server
    fi

    if ! command -v dhcpd >/dev/null 2>&1; then
        echo "ERROR: dhcpd command was not found."
        exit 1
    fi

    CONFIG_DIR="/etc/dhcp"
    CONFIG_FILE="$CONFIG_DIR/dhcpd.conf"
    SERVICE_NAME="dhcpd"

else

    if ! rpm -q kea >/dev/null 2>&1; then
        echo "Installing Kea DHCP..."
        dnf install -y kea
    fi

    if ! command -v kea-dhcp4 >/dev/null 2>&1; then
        echo "ERROR: kea-dhcp4 command was not found."
        exit 1
    fi

    CONFIG_DIR="/etc/kea"
    CONFIG_FILE="$CONFIG_DIR/kea-dhcp4.conf"
    SERVICE_NAME="kea-dhcp4"

fi

mkdir -p "$CONFIG_DIR"

TEMP_CONFIG="$(mktemp "${CONFIG_DIR}/dhcp-config.tmp.XXXXXX")"

cleanup() {
    if [[ -n "${TEMP_CONFIG:-}" && -f "$TEMP_CONFIG" ]]; then
        rm -f "$TEMP_CONFIG"
    fi
}
trap cleanup EXIT

# -------------------- GENERATE CONFIGURATION -----------------

echo
echo "Generating $DHCP_TYPE configuration..."

if [[ "$DHCP_TYPE" == "isc" ]]; then

    # Convert comma-separated DNS addresses into ISC option syntax.
    DNS_ISC="$(
        python3 - "$DNS_SERVERS" <<'PY'
import ipaddress, sys
addresses = [x.strip() for x in sys.argv[1].split(",")]
for address in addresses:
    ipaddress.IPv4Address(address)
print(", ".join(addresses))
PY
    )"

    BROADCAST="$(
        python3 - "$NETWORK" <<'PY'
import ipaddress, sys
print(ipaddress.ip_network(sys.argv[1], strict=False).broadcast_address)
PY
    )"

    cat > "$TEMP_CONFIG" <<EOF
# Generated by 03_dhcp_server.sh

authoritative;

default-lease-time 4000;
max-lease-time 7200;

option domain-name "$DOMAIN_NAME";
option domain-name-servers $DNS_ISC;

subnet ${NETWORK%/*} netmask $NETMASK {
    range $RANGE_START $RANGE_END;
    option subnet-mask $NETMASK;
    option routers $GATEWAY;
    option broadcast-address $BROADCAST;
}
EOF

    echo "Validating ISC DHCP configuration..."

    if ! dhcpd -t -cf "$TEMP_CONFIG"; then
        echo "ERROR: ISC DHCP configuration validation failed."
        echo "Existing configuration has not been replaced."
        exit 1
    fi

else

    python3 - \
        "$TEMP_CONFIG" \
        "$INTERFACE" \
        "$NETWORK" \
        "$RANGE_START" \
        "$RANGE_END" \
        "$NETMASK" \
        "$GATEWAY" \
        "$DNS_SERVERS" \
        "$DOMAIN_NAME" <<'PY'
import json
import ipaddress
import sys

(
    output_file,
    interface,
    network,
    range_start,
    range_end,
    netmask,
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
                        "name": "subnet-mask",
                        "data": netmask
                    },
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

    echo "Validating Kea DHCP configuration..."

    if ! kea-dhcp4 -t "$TEMP_CONFIG"; then
        echo "ERROR: Kea configuration validation failed."
        echo "Existing configuration has not been replaced."
        exit 1
    fi

fi

echo "Configuration validation successful."

# -------------------- BACK UP OLD CONFIGURATION --------------

if [[ -f "$CONFIG_FILE" ]]; then
    BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG_FILE" "$BACKUP_FILE"
    echo "Existing configuration backed up to:"
    echo "$BACKUP_FILE"
fi

install -o root -g root -m 0644 "$TEMP_CONFIG" "$CONFIG_FILE"
rm -f "$TEMP_CONFIG"
TEMP_CONFIG=""

# -------------------- STOP OTHER DHCP IMPLEMENTATION ---------

if [[ "$SERVICE_NAME" == "dhcpd" ]]; then
    if systemctl list-unit-files kea-dhcp4.service --no-legend |
        grep -q 'kea-dhcp4.service'; then
        systemctl disable --now kea-dhcp4 2>/dev/null || true
    fi
else
    if systemctl list-unit-files dhcpd.service --no-legend |
        grep -q 'dhcpd.service'; then
        systemctl disable --now dhcpd 2>/dev/null || true
    fi
fi

# -------------------- FIREWALL CONFIGURATION -----------------

echo
echo "Configuring firewall..."

if systemctl is-active --quiet firewalld; then

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
fi

# -------------------- ENABLE AND START SERVICE ---------------

echo
echo "Enabling and starting $SERVICE_NAME..."

systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "ERROR: $SERVICE_NAME failed to start."
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
    exit 1
fi

# -------------------- FINAL VERIFICATION ---------------------

echo
echo "============================================================"
echo "                DHCP SERVER CONFIGURED"
echo "============================================================"
echo

echo "Implementation : $DHCP_TYPE"
echo "Service        : $SERVICE_NAME"
echo "Interface      : $INTERFACE"
echo "Server IP      : $SERVER_IP"
echo "Network        : $NETWORK"
echo "Subnet Mask    : $NETMASK"
echo "Gateway        : $GATEWAY"
echo "DHCP Pool      : $RANGE_START - $RANGE_END"
echo "DNS Server     : $DNS_SERVERS"
echo "Domain         : $DOMAIN_NAME"
echo "Config File    : $CONFIG_FILE"

echo
echo "Service status:"
systemctl --no-pager --full status "$SERVICE_NAME" || true

echo
echo "UDP port 67 listener:"
if command -v ss >/dev/null 2>&1; then
    ss -lunp | grep -E '(:67[[:space:]]|:67$)' ||
        echo "No UDP port 67 listener detected. Check service logs."
fi

echo
echo "Useful commands:"
echo "  systemctl status $SERVICE_NAME"
echo "  journalctl -u $SERVICE_NAME -f"
echo "  cat $CONFIG_FILE"

if [[ "$DHCP_TYPE" == "kea" ]]; then
    echo "  cat /var/lib/kea/kea-leases4.csv"
fi

echo
echo "NOTE:"
echo "- Verify the gateway and DNS addresses are correct."
echo "- Keep the server IP outside the DHCP pool."
echo "- DHCP clients must be on this LAN or use a DHCP relay."
echo "============================================================"

