#!/bin/bash
# ============================================================
# Script Name : 03_dhcp_server.sh
# Purpose     : Configure DHCP Server automatically
#
# Supported DHCP implementations:
#   1. ISC DHCP Server (dhcp-server)
#   2. Kea DHCP Server
#
# Automatic network detection:
#   - Network interface
#   - Server IPv4 address
#   - Network
#   - Netmask
#
# Automatic DHCP settings:
#   - Gateway/DNS : <network>.254
#   - DHCP Start  : <network>.10
#   - DHCP End    : <network>.100
#
# Example:
#
#   Server IP : 192.168.78.128
#   Network   : 192.168.78.0/24
#   Gateway   : 192.168.78.254
#   DHCP Pool : 192.168.78.10 - 192.168.78.100
#
# Rocky Linux 10:
#   ISC DHCP may not be available.
#   In that case the script offers Kea DHCP.
# ============================================================

set -Eeuo pipefail

# ============================================================
# ROOT CHECK
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    echo
    echo "ERROR: This script must be run as root."
    echo
    echo "Example:"
    echo "  sudo ./03_dhcp_server.sh"
    echo
    exit 1
fi


# ============================================================
# REQUIRED COMMAND CHECK
# ============================================================

for cmd in ip python3 dnf systemctl rpm; do

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo
        echo "ERROR: Required command '$cmd' is not installed."
        echo
        exit 1
    fi

done


# ============================================================
# HEADER
# ============================================================

clear 2>/dev/null || true

echo
echo "============================================================"
echo "          AUTOMATIC DHCP SERVER CONFIGURATION"
echo "============================================================"
echo


# ============================================================
# DETECT NETWORK INTERFACE
# ============================================================

echo "Detecting network interface..."

# First preference:
# Interface used by the default IPv4 route.

INTERFACE="$(
    ip -4 route show default |
    awk '
    NR == 1 {
        for (i = 1; i <= NF; i++) {
            if ($i == "dev") {
                print $(i + 1)
                exit
            }
        }
    }'
)"


# If default route is not available,
# find the first global IPv4 interface.

if [[ -z "$INTERFACE" ]]; then

    INTERFACE="$(
        ip -o -4 addr show scope global |
        awk '
        $2 !~ /^(docker|br-|veth)/ {
            print $2
            exit
        }'
    )"

fi


if [[ -z "$INTERFACE" ]]; then

    echo
    echo "ERROR: Could not detect a suitable network interface."
    echo
    echo "Run:"
    echo "  ip -4 addr"
    echo
    exit 1

fi


# ============================================================
# DETECT SERVER IP + PREFIX
# ============================================================

IP_CIDR="$(
    ip -o -4 addr show dev "$INTERFACE" scope global |
    awk 'NR == 1 {print $4}'
)"


if [[ -z "$IP_CIDR" ]]; then

    echo
    echo "ERROR: No global IPv4 address found on:"
    echo "  $INTERFACE"
    echo
    exit 1

fi


# ============================================================
# CALCULATE NETWORK INFORMATION
# ============================================================

#
# This script intentionally requires /24.
#
# Reason:
#
#   Gateway    = .254
#   DHCP Start = .10
#   DHCP End   = .100
#
# These values are based on the requested /24 layout.
#

if ! NETWORK_INFO="$(
    python3 - "$IP_CIDR" <<'PY'
import ipaddress
import sys

try:

    interface = ipaddress.IPv4Interface(sys.argv[1])

    network = interface.network

    if interface.ip.is_loopback:
        raise ValueError("Loopback address cannot be used.")

    if interface.ip.is_link_local:
        raise ValueError("Link-local address cannot be used.")

    # This script expects /24.
    if network.prefixlen != 24:

        raise ValueError(
            f"Detected subnet is /{network.prefixlen}. "
            "This script requires a /24 network because "
            "the DHCP pool uses .10 - .100 and gateway .254."
        )

    server = interface.ip

    gateway = network.network_address + 254

    range_start = network.network_address + 10

    range_end = network.network_address + 100

    # Server must not be inside DHCP pool.

    if range_start <= server <= range_end:

        raise ValueError(
            f"Server IP {server} is inside the DHCP pool "
            f"{range_start} - {range_end}. "
            "Move the server to a static IP outside the DHCP pool."
        )

    # Server must not be gateway.

    if server == gateway:

        raise ValueError(
            f"Server IP {server} conflicts with gateway {gateway}."
        )

    print(
        str(server),
        str(network),
        str(network.netmask),
        str(gateway),
        str(range_start),
        str(range_end)
    )

except Exception as exc:

    print(f"ERROR: {exc}", file=sys.stderr)

    sys.exit(1)

PY
)"; then

    echo
    echo "ERROR: Could not calculate network configuration."
    echo
    exit 1

fi


read -r \
    SERVER_IP \
    NETWORK \
    NETMASK \
    GATEWAY \
    RANGE_START \
    RANGE_END <<< "$NETWORK_INFO"


# ============================================================
# AUTOMATIC DNS
# ============================================================

DNS_SERVERS="$GATEWAY"


# ============================================================
# DOMAIN NAME
# ============================================================

DOMAIN_NAME="tejas.com"


# ============================================================
# DISPLAY NETWORK CONFIGURATION
# ============================================================

echo
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


# ============================================================
# IMPORTANT WARNING
# ============================================================

echo "IMPORTANT:"
echo "- Confirm that $GATEWAY is really your gateway."
echo "- Confirm that $GATEWAY provides DNS service."
echo "- Use a static IP or DHCP reservation for this server."
echo "- Make sure another DHCP server is not already serving"
echo "  this same LAN."
echo "- Run this only on a network where you are authorized"
echo "  to provide DHCP service."
echo


read -r -p "Continue with this configuration? (y/N): " CONFIRM


if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then

    echo
    echo "Cancelled. No DHCP configuration was changed."
    echo
    exit 0

fi


# ============================================================
# DETECT DHCP IMPLEMENTATIONS
# ============================================================

echo
echo "============================================================"
echo "          CHECKING DHCP SERVER AVAILABILITY"
echo "============================================================"
echo


# ------------------------------------------------------------
# Function: Check if a package is available in repositories
# ------------------------------------------------------------

package_available()
{
    local package="$1"

    if dnf -q list --available "$package" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}


# ============================================================
# CHECK ISC DHCP
# ============================================================

ISC_AVAILABLE=false

if package_available "dhcp-server"; then
    ISC_AVAILABLE=true
fi


# ============================================================
# CHECK KEA DHCP
# ============================================================

KEA_AVAILABLE=false

if package_available "kea"; then
    KEA_AVAILABLE=true
fi


# Also consider already-installed packages.

if rpm -q dhcp-server >/dev/null 2>&1; then
    ISC_AVAILABLE=true
fi

if rpm -q kea >/dev/null 2>&1; then
    KEA_AVAILABLE=true
fi


# ============================================================
# DISPLAY AVAILABILITY
# ============================================================

echo
echo "DHCP Server Availability:"
echo "------------------------------------------------------------"

if [[ "$ISC_AVAILABLE" == true ]]; then
    echo "ISC DHCP Server : AVAILABLE"
else
    echo "ISC DHCP Server : NOT AVAILABLE"
fi


if [[ "$KEA_AVAILABLE" == true ]]; then
    echo "Kea DHCP Server : AVAILABLE"
else
    echo "Kea DHCP Server : NOT AVAILABLE"
fi

echo "------------------------------------------------------------"
echo


# ============================================================
# NO DHCP SERVER AVAILABLE
# ============================================================

if [[ "$ISC_AVAILABLE" == false && "$KEA_AVAILABLE" == false ]]; then

    echo
    echo "ERROR: No DHCP server package is available."
    echo
    echo "Checked:"
    echo "  - dhcp-server"
    echo "  - kea"
    echo
    echo "Check your enabled repositories:"
    echo "  dnf repolist"
    echo

    exit 1

fi


# ============================================================
# SELECT DHCP IMPLEMENTATION
# ============================================================

DHCP_TYPE=""


# ------------------------------------------------------------
# CASE 1:
# ISC and Kea both available
# ------------------------------------------------------------

if [[ "$ISC_AVAILABLE" == true && "$KEA_AVAILABLE" == true ]]; then

    echo "============================================================"
    echo "              DHCP SERVER SELECTION"
    echo "============================================================"
    echo
    echo "1. Configure ISC DHCP Server"
    echo "2. Configure Kea DHCP Server"
    echo "3. Exit"
    echo

    while true; do

        read -r -p "Enter your choice [1-3]: " CHOICE

        case "$CHOICE" in

            1)
                DHCP_TYPE="isc"
                break
                ;;

            2)
                DHCP_TYPE="kea"
                break
                ;;

            3)
                echo
                echo "Exiting. No DHCP configuration was changed."
                exit 0
                ;;

            *)
                echo
                echo "Invalid choice. Please enter 1, 2, or 3."
                ;;

        esac

    done


# ------------------------------------------------------------
# CASE 2:
# ISC available, Kea unavailable
# ------------------------------------------------------------

elif [[ "$ISC_AVAILABLE" == true && "$KEA_AVAILABLE" == false ]]; then

    echo "ISC DHCP Server is available."
    echo "Kea DHCP Server is not available."
    echo

    read -r -p \
        "Configure ISC DHCP Server? (Y/n): " CHOICE

    if [[ "$CHOICE" =~ ^[Nn]$ ]]; then

        echo
        echo "Cancelled."
        exit 0

    fi

    DHCP_TYPE="isc"


# ------------------------------------------------------------
# CASE 3:
# ISC unavailable, Kea available
# ------------------------------------------------------------

elif [[ "$ISC_AVAILABLE" == false && "$KEA_AVAILABLE" == true ]]; then

    echo
    echo "============================================================"
    echo "             ISC DHCP NOT AVAILABLE"
    echo "============================================================"
    echo
    echo "The traditional ISC DHCP Server package"
    echo "is NOT available from the configured repositories."
    echo
    echo "Kea DHCP Server IS available."
    echo
    echo "Would you like to continue with Kea DHCP?"
    echo
    echo "1. Yes - Configure Kea DHCP"
    echo "2. No  - Exit"
    echo

    while true; do

        read -r -p "Enter your choice [1-2]: " CHOICE

        case "$CHOICE" in

            1)
                DHCP_TYPE="kea"
                break
                ;;

            2)
                echo
                echo "Cancelled. No DHCP configuration was changed."
                exit 0
                ;;

            *)
                echo
                echo "Invalid choice. Please enter 1 or 2."
                ;;

        esac

    done

fi


# ============================================================
# DISPLAY SELECTED SERVER
# ============================================================

echo
echo "============================================================"

if [[ "$DHCP_TYPE" == "isc" ]]; then
    echo "       Selected DHCP Server : ISC DHCP Server"
else
    echo "       Selected DHCP Server : Kea DHCP Server"
fi

echo "============================================================"
echo


# ============================================================
# ============================================================
# ISC DHCP SERVER CONFIGURATION
# ============================================================
# ============================================================

if [[ "$DHCP_TYPE" == "isc" ]]; then

    echo "Installing ISC DHCP Server..."

    dnf install -y dhcp-server


    # --------------------------------------------------------
    # Verify installation
    # --------------------------------------------------------

    if ! command -v dhcpd >/dev/null 2>&1; then

        echo
        echo "ERROR: dhcpd command was not found."
        echo "ISC DHCP installation may have failed."
        exit 1

    fi


    # --------------------------------------------------------
    # Configuration files
    # --------------------------------------------------------

    ISC_CONFIG="/etc/dhcp/dhcpd.conf"

    ISC_CONFIG_DIR="/etc/dhcp"

    ISC_TEMP_CONFIG="$(mktemp "${ISC_CONFIG_DIR}/dhcpd.conf.tmp.XXXXXX")"


    # --------------------------------------------------------
    # Generate ISC DHCP configuration
    # --------------------------------------------------------

    echo
    echo "Generating ISC DHCP configuration..."


    cat > "$ISC_TEMP_CONFIG" <<EOF
# ============================================================
# ISC DHCP Server Configuration
# Automatically generated by 03_dhcp_server.sh
# ============================================================

authoritative;

default-lease-time 4000;
max-lease-time 7200;

option domain-name "$DOMAIN_NAME";
option domain-name-servers $DNS_SERVERS;

subnet $NETWORK netmask $NETMASK {

    range $RANGE_START $RANGE_END;

    option routers $GATEWAY;

    option subnet-mask $NETMASK;

    option broadcast-address ${NETWORK%.*}.255;

    option domain-name "$DOMAIN_NAME";

    option domain-name-servers $DNS_SERVERS;
}
EOF


    # --------------------------------------------------------
    # Validate ISC configuration
    # --------------------------------------------------------

    echo
    echo "Validating ISC DHCP configuration..."

    if ! dhcpd -t -cf "$ISC_TEMP_CONFIG"; then

        echo
        echo "ERROR: ISC DHCP configuration validation failed."
        echo
        rm -f "$ISC_TEMP_CONFIG"
        exit 1

    fi

    echo "ISC DHCP configuration validation successful."


    # --------------------------------------------------------
    # Backup existing configuration
    # --------------------------------------------------------

    if [[ -f "$ISC_CONFIG" ]]; then

        ISC_BACKUP="${ISC_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"

        cp -a "$ISC_CONFIG" "$ISC_BACKUP"

        echo
        echo "Existing ISC configuration backed up to:"
        echo "$ISC_BACKUP"

    fi


    # --------------------------------------------------------
    # Install validated configuration
    # --------------------------------------------------------

    install \
        -o root \
        -g root \
        -m 0644 \
        "$ISC_TEMP_CONFIG" \
        "$ISC_CONFIG"


    rm -f "$ISC_TEMP_CONFIG"


    # --------------------------------------------------------
    # Configure firewall
    # --------------------------------------------------------

    echo
    echo "Configuring firewall..."


    if systemctl is-active --quiet firewalld; then

        FIREWALL_ZONE="$(
            firewall-cmd \
                --get-zone-of-interface="$INTERFACE" \
                2>/dev/null || true
        )


        if [[ -z "$FIREWALL_ZONE" || "$FIREWALL_ZONE" == "no zone" ]]; then
            FIREWALL_ZONE="$(firewall-cmd --get-default-zone)"
        fi


        firewall-cmd \
            --permanent \
            --zone="$FIREWALL_ZONE" \
            --add-service=dhcp


        firewall-cmd --reload


        echo "DHCP firewall service enabled in zone: $FIREWALL_ZONE"

    else

        echo "WARNING: firewalld is not active."

    fi


    # --------------------------------------------------------
    # Enable and start ISC DHCP
    # --------------------------------------------------------

    echo
    echo "Enabling and starting ISC DHCP Server..."


    systemctl enable dhcpd

    systemctl restart dhcpd


    # --------------------------------------------------------
    # Verify ISC service
    # --------------------------------------------------------

    if ! systemctl is-active --quiet dhcpd; then

        echo
        echo "ERROR: ISC DHCP Server is not running."
        echo

        systemctl --no-pager --full status dhcpd || true

        echo
        echo "Recent DHCP logs:"
        journalctl -u dhcpd -n 50 --no-pager || true

        exit 1

    fi


    # --------------------------------------------------------
    # Final ISC information
    # --------------------------------------------------------

    echo
    echo "============================================================"
    echo "           ISC DHCP SERVER CONFIGURED"
    echo "============================================================"
    echo

    echo "Service status:"
    systemctl --no-pager --full status dhcpd || true

    echo
    echo "Configuration file:"
    echo "  $ISC_CONFIG"

    echo
    echo "DHCP network settings:"
    echo "  Interface : $INTERFACE"
    echo "  Server IP : $SERVER_IP"
    echo "  Network   : $NETWORK"
    echo "  Netmask   : $NETMASK"
    echo "  Gateway   : $GATEWAY"
    echo "  Pool      : $RANGE_START - $RANGE_END"
    echo "  DNS       : $DNS_SERVERS"
    echo "  Domain    : $DOMAIN_NAME"

    echo
    echo "Useful commands:"
    echo "  systemctl status dhcpd"
    echo "  journalctl -u dhcpd -f"
    echo "  cat $ISC_CONFIG"

fi


# ============================================================
# ============================================================
# KEA DHCP SERVER CONFIGURATION
# ============================================================
# ============================================================

if [[ "$DHCP_TYPE" == "kea" ]]; then

    echo "Installing Kea DHCP Server..."


    # --------------------------------------------------------
    # Install Kea
    # --------------------------------------------------------

    if ! rpm -q kea >/dev/null 2>&1; then

        dnf install -y kea

    else

        echo "Kea DHCP is already installed."

    fi


    # --------------------------------------------------------
    # Verify Kea command
    # --------------------------------------------------------

    if ! command -v kea-dhcp4 >/dev/null 2>&1; then

        echo
        echo "ERROR: kea-dhcp4 command was not found."
        echo "Kea installation may have failed."
        exit 1

    fi


    # --------------------------------------------------------
    # Kea configuration paths
    # --------------------------------------------------------

    KEA_CONFIG="/etc/kea/kea-dhcp4.conf"

    KEA_CONFIG_DIR="/etc/kea"

    KEA_LEASE_DIR="/var/lib/kea"


    mkdir -p "$KEA_CONFIG_DIR"

    mkdir -p "$KEA_LEASE_DIR"


    # --------------------------------------------------------
    # Temporary configuration
    # --------------------------------------------------------

    KEA_TEMP_CONFIG="$(
        mktemp "${KEA_CONFIG_DIR}/kea-dhcp4.conf.tmp.XXXXXX"
    )"


    cleanup_kea()
    {
        if [[ -n "${KEA_TEMP_CONFIG:-}" &&
              -f "$KEA_TEMP_CONFIG" ]]; then

            rm -f "$KEA_TEMP_CONFIG"

        fi
    }


    trap cleanup_kea EXIT


    # --------------------------------------------------------
    # Generate Kea JSON configuration
    # --------------------------------------------------------

    echo
    echo "Generating Kea DHCP configuration..."


    python3 - \
        "$KEA_TEMP_CONFIG" \
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

            "interfaces": [
                interface
            ]

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

                # Kea requires a unique subnet ID.
                "id": 1,

                "subnet": network,


                "pools": [

                    {

                        "pool":
                            f"{range_start} - {range_end}"

                    }

                ],


                "option-data": [

                    {

                        "name": "routers",

                        "data": gateway

                    },


                    {

                        "name":
                            "domain-name-servers",

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


with open(
    output_file,
    "w",
    encoding="utf-8"
) as file:

    json.dump(
        config,
        file,
        indent=4
    )

    file.write("\n")

PY


    # --------------------------------------------------------
    # Validate Kea configuration
    # --------------------------------------------------------

    echo
    echo "Validating Kea DHCP configuration..."


    if ! kea-dhcp4 -t "$KEA_TEMP_CONFIG"; then

        echo
        echo "ERROR: Kea configuration validation failed."
        echo "Existing configuration has NOT been replaced."
        echo

        exit 1

    fi


    echo "Configuration validation successful."


    # --------------------------------------------------------
    # Backup existing configuration
    # --------------------------------------------------------

    if [[ -f "$KEA_CONFIG" ]]; then

        KEA_BACKUP="${KEA_CONFIG}.backup.$(
            date +%Y%m%d-%H%M%S
        )"


        cp -a \
            "$KEA_CONFIG" \
            "$KEA_BACKUP"


        echo
        echo "Existing configuration backed up to:"
        echo "$KEA_BACKUP"

    fi


    # --------------------------------------------------------
    # Install validated configuration
    # --------------------------------------------------------

    install \
        -o root \
        -g root \
        -m 0644 \
        "$KEA_TEMP_CONFIG" \
        "$KEA_CONFIG"


    rm -f "$KEA_TEMP_CONFIG"

    KEA_TEMP_CONFIG=""


    # --------------------------------------------------------
    # Configure firewall
    # --------------------------------------------------------

    echo
    echo "Configuring firewall..."


    if systemctl is-active --quiet firewalld; then

        FIREWALL_ZONE="$(
            firewall-cmd \
                --get-zone-of-interface="$INTERFACE" \
                2>/dev/null || true
        )


        if [[ -z "$FIREWALL_ZONE" ||
              "$FIREWALL_ZONE" == "no zone" ]]; then

            FIREWALL_ZONE="$(
                firewall-cmd --get-default-zone
            )"

        fi


        firewall-cmd \
            --permanent \
            --zone="$FIREWALL_ZONE" \
            --add-service=dhcp


        firewall-cmd --reload


        echo "DHCP firewall service enabled in zone: $FIREWALL_ZONE"

    else

        echo "WARNING: firewalld is not active."

    fi


    # --------------------------------------------------------
    # Enable and start Kea
    # --------------------------------------------------------

    echo
    echo "Enabling and starting Kea DHCPv4..."


    systemctl enable kea-dhcp4

    systemctl restart kea-dhcp4


    # --------------------------------------------------------
    # Verify Kea service
    # --------------------------------------------------------

    if ! systemctl is-active --quiet kea-dhcp4; then

        echo
        echo "ERROR: Kea DHCPv4 is not running."
        echo

        systemctl \
            --no-pager \
            --full \
            status kea-dhcp4 || true


        echo
        echo "Recent Kea logs:"

        journalctl \
            -u kea-dhcp4 \
            -n 50 \
            --no-pager || true

        exit 1

    fi


    # --------------------------------------------------------
    # Final Kea information
    # --------------------------------------------------------

    echo
    echo "============================================================"
    echo "             KEA DHCP SERVER CONFIGURED"
    echo "============================================================"
    echo

    echo "Service status:"

    systemctl \
        --no-pager \
        --full \
        status kea-dhcp4 || true


    echo
    echo "Listening on UDP port 67:"

    if command -v ss >/dev/null 2>&1; then

        ss -lunp |
            grep -E '(:67[[:space:]]|:67$)' ||
            echo "No UDP port 67 listener found."

    fi


    echo
    echo "Configuration file:"
    echo "  $KEA_CONFIG"


    echo
    echo "DHCP network settings:"
    echo "  Interface : $INTERFACE"
    echo "  Server IP : $SERVER_IP"
    echo "  Network   : $NETWORK"
    echo "  Netmask   : $NETMASK"
    echo "  Gateway   : $GATEWAY"
    echo "  Pool      : $RANGE_START - $RANGE_END"
    echo "  DNS       : $DNS_SERVERS"
    echo "  Domain    : $DOMAIN_NAME"


    echo
    echo "Useful commands:"
    echo "  systemctl status kea-dhcp4"
    echo "  journalctl -u kea-dhcp4 -f"
    echo "  cat $KEA_CONFIG"
    echo "  cat /var/lib/kea/kea-leases4.csv"

fi


# ============================================================
# COMMON FINAL MESSAGE
# ============================================================

echo
echo "============================================================"
echo "                 DHCP CONFIGURATION COMPLETE"
echo "============================================================"
echo

echo "Selected DHCP server:"
if [[ "$DHCP_TYPE" == "isc" ]]; then
    echo "  ISC DHCP Server"
else
    echo "  Kea DHCP Server"
fi

echo
echo "Network:"
echo "  Interface : $INTERFACE"
echo "  Server IP : $SERVER_IP"
echo "  Network   : $NETWORK"
echo "  Gateway   : $GATEWAY"
echo "  DHCP Pool : $RANGE_START - $RANGE_END"
echo "  DNS       : $DNS_SERVERS"

echo
echo "NOTE:"
echo "DHCP clients must be on the same Layer-2 network or"
echo "reach this server through a correctly configured"
echo "DHCP relay."

echo
echo "============================================================"
echo "                     DONE"
echo "============================================================"
echo
