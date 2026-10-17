#!/usr/bin/env bash
#
# Script: 08_dns_server.sh
# Purpose: Configure a BIND DNS server on Rocky Linux / RHEL
# Domain:  tejas.com
#
# DNS server: 192.168.78.128
# Network:    192.168.78.0/24
#
# Forward zone: tejas.com
# Reverse zone: 78.168.192.in-addr.arpa
#
# IMPORTANT:
# Review the configuration variables below before running.
#

set -Eeuo pipefail

# ============================================================
# CONFIGURATION VARIABLES - EDIT THESE VALUES IF REQUIRED
# ============================================================

DOMAIN="tejas.com"
SERVER_IP="192.168.78.128"
NETWORK_CIDR="192.168.78.0/24"
NETWORK_PREFIX="192.168.78"
INTERFACE="ens160"

FORWARDERS=("1.1.1.1" "8.8.8.8")

# DNS records
CLIENT1_NAME="client1"
CLIENT1_IP="192.168.78.30"

CLIENT2_NAME="client2"
CLIENT2_IP="192.168.78.2"

SERVER_NAME="docker"

# BIND configuration paths
NAMED_CONF="/etc/named.conf"
MANAGED_ZONES="/etc/named/managed-zones.conf"
FORWARD_ZONE="/var/named/forward.zone"
REVERSE_ZONE="/var/named/reverse.zone"

# ============================================================
# HELPER FUNCTIONS
# ============================================================

log() {
    printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

backup_file() {
    local file="$1"

    if [[ -e "$file" ]]; then
        local backup="${file}.backup.$(date '+%Y%m%d-%H%M%S')"
        cp -a -- "$file" "$backup"
        log "Backup created: $backup"
    fi
}

# ============================================================
# ROOT AND OS CHECKS
# ============================================================

[[ "${EUID}" -eq 0 ]] || die "Run this script as root."

[[ -f /etc/rocky-release || -f /etc/redhat-release ]] \
    || die "This script is intended for Rocky Linux / RHEL."

command -v dnf >/dev/null 2>&1 \
    || die "dnf package manager was not found."

log "Starting BIND DNS server configuration."

# ============================================================
# NETWORK VALIDATION
# ============================================================

log "Checking network configuration."

ip -4 addr show dev "$INTERFACE" >/dev/null 2>&1 \
    || die "Interface '$INTERFACE' does not exist. Check: ip -br -4 addr"

if ! ip -o -4 addr show | grep -Fq " ${SERVER_IP}/"; then
    die "Server IP $SERVER_IP is not assigned to this machine.
Check the IP with: ip -br -4 addr
Update SERVER_IP and INTERFACE at the top of this script."
fi

# Verify the expected network prefix.
if [[ "$SERVER_IP" != "$NETWORK_PREFIX".* ]]; then
    die "SERVER_IP does not match NETWORK_PREFIX."
fi

# ============================================================
# INSTALL BIND PACKAGES
# ============================================================

log "Installing BIND DNS packages."

dnf install -y bind bind-utils policycoreutils-python-utils

id named >/dev/null 2>&1 \
    || die "The named service account was not created by the bind package."

# ============================================================
# BACK UP EXISTING CONFIGURATION
# ============================================================

log "Backing up existing BIND configuration."

backup_file "$NAMED_CONF"
backup_file "$MANAGED_ZONES"
backup_file "$FORWARD_ZONE"
backup_file "$REVERSE_ZONE"

# ============================================================
# CREATE REQUIRED DIRECTORIES
# ============================================================

log "Creating DNS configuration directories."

install -d -o root -g named -m 0750 /etc/named
install -d -o root -g named -m 0770 /var/named

# IMPORTANT FIX:
# BIND uses /var/named as its working directory.
# The named account must be able to write to this directory.
chown root:named /var/named
chmod 0770 /var/named

# ============================================================
# GENERATE FORWARD ZONE FILE
# ============================================================

log "Creating forward DNS zone: $DOMAIN"

SERIAL="$(date '+%Y%m%d')01"

cat > "$FORWARD_ZONE" <<EOF
\$TTL 86400
@   IN  SOA ns1.${DOMAIN}. root.${DOMAIN}. (
        ${SERIAL} ; Serial
        3600      ; Refresh
        1800      ; Retry
        604800    ; Expire
        86400     ; Minimum TTL
)

@       IN  NS  ns1.${DOMAIN}.

ns1     IN  A   ${SERVER_IP}
${SERVER_NAME} IN A ${SERVER_IP}
${CLIENT1_NAME} IN A ${CLIENT1_IP}
${CLIENT2_NAME} IN A ${CLIENT2_IP}
EOF

chown root:named "$FORWARD_ZONE"
chmod 0640 "$FORWARD_ZONE"

# ============================================================
# GENERATE REVERSE ZONE FILE
# ============================================================

log "Creating reverse DNS zone."

# Reverse zone for 192.168.78.0/24:
# 192.168.78.X becomes X.78.168.192.in-addr.arpa

SERVER_OCTET="${SERVER_IP##*.}"
CLIENT1_OCTET="${CLIENT1_IP##*.}"
CLIENT2_OCTET="${CLIENT2_IP##*.}"

cat > "$REVERSE_ZONE" <<EOF
\$TTL 86400
@   IN  SOA ns1.${DOMAIN}. root.${DOMAIN}. (
        ${SERIAL} ; Serial
        3600      ; Refresh
        1800      ; Retry
        604800    ; Expire
        86400     ; Minimum TTL
)

@   IN  NS  ns1.${DOMAIN}.

${SERVER_OCTET}  IN PTR ${SERVER_NAME}.${DOMAIN}.
${CLIENT1_OCTET} IN PTR ${CLIENT1_NAME}.${DOMAIN}.
${CLIENT2_OCTET} IN PTR ${CLIENT2_NAME}.${DOMAIN}.
EOF

chown root:named "$REVERSE_ZONE"
chmod 0640 "$REVERSE_ZONE"

# ============================================================
# CREATE MANAGED ZONE DECLARATIONS
# ============================================================

log "Creating managed zone declarations."

cat > "$MANAGED_ZONES" <<EOF
zone "${DOMAIN}" IN {
    type master;
    file "forward.zone";
    allow-update { none; };
    allow-transfer { none; };
};

zone "78.168.192.in-addr.arpa" IN {
    type master;
    file "reverse.zone";
    allow-update { none; };
    allow-transfer { none; };
};
EOF

chown root:named "$MANAGED_ZONES"
chmod 0640 "$MANAGED_ZONES"

# ============================================================
# CREATE MAIN BIND CONFIGURATION
# ============================================================

log "Creating $NAMED_CONF."

cat > "$NAMED_CONF" <<EOF
options {
    directory "/var/named";

    listen-on port 53 {
        127.0.0.1;
        ${SERVER_IP};
    };

    listen-on-v6 { none; };

    allow-query {
        localhost;
        ${NETWORK_CIDR};
    };

    recursion yes;

    allow-recursion {
        localhost;
        ${NETWORK_CIDR};
    };

    allow-query-cache {
        localhost;
        ${NETWORK_CIDR};
    };

    forwarders {
        ${FORWARDERS[0]};
        ${FORWARDERS[1]};
    };

    forward only;

    dnssec-validation auto;

    allow-transfer { none; };
};

include "/etc/named.rfc1912.zones";
include "/etc/named/managed-zones.conf";
EOF

chown root:named "$NAMED_CONF"
chmod 0640 "$NAMED_CONF"

# ============================================================
# SELINUX CONFIGURATION
# ============================================================

log "Restoring SELinux contexts."

restorecon -RF /etc/named.conf /etc/named /var/named

# ============================================================
# VERIFY DIRECTORY WRITE ACCESS
# ============================================================

log "Checking named directory permissions."

if ! runuser -u named -- test -w /var/named; then
    die "/var/named is not writable by the named user.
Check directory ownership, permissions, and SELinux."
fi

log "Directory write-access check passed."

# ============================================================
# VALIDATE BIND CONFIGURATION AND ZONES
# ============================================================

log "Validating BIND configuration."

if ! named-checkconf -z "$NAMED_CONF"; then
    die "BIND configuration or zone validation failed.
Review $NAMED_CONF, $MANAGED_ZONES, and the zone files."
fi

log "BIND configuration and zone validation passed."

# ============================================================
# CONFIGURE FIREWALL
# ============================================================

log "Configuring firewall for DNS."

if systemctl is-active --quiet firewalld; then
    FW_ZONE="$(firewall-cmd --get-zone-of-interface "$INTERFACE" 2>/dev/null || true)"

    if [[ -z "$FW_ZONE" || "$FW_ZONE" == "no zone" ]]; then
        FW_ZONE="$(firewall-cmd --get-default-zone)"
    fi

    firewall-cmd --permanent --zone="$FW_ZONE" --add-service=dns
    firewall-cmd --reload

    log "DNS service allowed in firewall zone: $FW_ZONE"
else
    log "firewalld is not running; skipping firewall changes."
fi

# ============================================================
# ENABLE AND START BIND
# ============================================================

log "Enabling and restarting named service."

systemctl enable named
systemctl restart named

if ! systemctl is-active --quiet named; then
    systemctl status named --no-pager || true
    journalctl -u named -n 50 --no-pager || true
    die "BIND failed to start. Review the logs above."
fi

# ============================================================
# DNS TESTS
# ============================================================

log "Testing local DNS records."

if ! dig +time=3 +tries=1 @"127.0.0.1" \
    "${SERVER_NAME}.${DOMAIN}" A +short | grep -Fxq "$SERVER_IP"; then
    die "Server A-record lookup failed."
fi

if ! dig +time=3 +tries=1 @"127.0.0.1" \
    "${CLIENT1_NAME}.${DOMAIN}" A +short | grep -Fxq "$CLIENT1_IP"; then
    die "Client1 A-record lookup failed."
fi

if ! dig +time=3 +tries=1 @"127.0.0.1" \
    "${CLIENT2_NAME}.${DOMAIN}" A +short | grep -Fxq "$CLIENT2_IP"; then
    die "Client2 A-record lookup failed."
fi

if ! dig +time=3 +tries=1 @"127.0.0.1" \
    -x "$SERVER_IP" +short | grep -Fxq "${SERVER_NAME}.${DOMAIN}."; then
    die "Server reverse DNS lookup failed."
fi

log "Testing public DNS forwarding."

if dig +time=5 +tries=1 @"127.0.0.1" google.com A +short | grep -Eq '^[0-9]+\.'; then
    log "Public DNS forwarding test passed."
else
    log "WARNING: Public DNS forwarding test failed. Check internet access and forwarders."
fi

# ============================================================
# FINAL STATUS
# ============================================================

echo
echo "============================================================"
echo "             DNS SERVER CONFIGURED SUCCESSFULLY"
echo "============================================================"
echo "Domain          : $DOMAIN"
echo "DNS server      : $SERVER_IP"
echo "Interface       : $INTERFACE"
echo "Network         : $NETWORK_CIDR"
echo "Forwarders      : ${FORWARDERS[*]}"
echo
echo "DNS records:"
echo "  ${SERVER_NAME}.${DOMAIN}  -> ${SERVER_IP}"
echo "  ${CLIENT1_NAME}.${DOMAIN} -> ${CLIENT1_IP}"
echo "  ${CLIENT2_NAME}.${DOMAIN} -> ${CLIENT2_IP}"
echo
echo "Forward zone   : $FORWARD_ZONE"
echo "Reverse zone   : $REVERSE_ZONE"
echo "BIND config    : $NAMED_CONF"
echo "Service status : $(systemctl is-active named)"
echo "============================================================"
echo
echo "Verify with:"
echo "  dig @${SERVER_IP} ${SERVER_NAME}.${DOMAIN}"
echo "  dig @${SERVER_IP} ${CLIENT1_NAME}.${DOMAIN}"
echo "  dig @${SERVER_IP} ${CLIENT2_NAME}.${DOMAIN}"
echo "  dig @${SERVER_IP} -x ${SERVER_IP}"
echo "  dig @${SERVER_IP} google.com"
echo
echo "NOTE: The script does not change /etc/resolv.conf or"
echo "NetworkManager DNS settings."

