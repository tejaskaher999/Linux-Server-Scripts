#!/usr/bin/env bash

# ============================================================
# Rocky Linux DNS Server Setup
# Interactive configuration + local DNS + public forwarding
# Supports IPv4 /24 networks
# ============================================================

set -Eeuo pipefail

# ---------- Default values ----------
DEFAULT_DOMAIN="tejas.com"
DEFAULT_SERVER_IP="192.168.78.128"
DEFAULT_NETWORK_CIDR="192.168.78.0/24"
DEFAULT_INTERFACE="ens160"
DEFAULT_SERVER_HOST="docker"

DEFAULT_CLIENT1_NAME="client1"
DEFAULT_CLIENT1_IP="192.168.78.30"
DEFAULT_CLIENT2_NAME="client2"
DEFAULT_CLIENT2_IP="192.168.78.2"

DEFAULT_FORWARDER1="1.1.1.1"
DEFAULT_FORWARDER2="8.8.8.8"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/08_dns_server_${TIMESTAMP}.log"

# ---------- Logging ----------
mkdir -p /var/log
touch "$LOG_FILE"

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

ask() {
    local prompt="$1"
    local default="$2"
    local answer

    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
}

ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local answer

    read -r -p "$prompt [$default]: " answer
    answer="${answer:-$default}"

    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

# ---------- Initial checks ----------
[[ $EUID -eq 0 ]] || die "Run this script as root: sudo ./08_dns_server.sh"

command -v nmcli >/dev/null 2>&1 ||
    die "NetworkManager (nmcli) is required."

echo
echo "============================================================"
echo "       INTERACTIVE ROCKY LINUX DNS SERVER SETUP"
echo "============================================================"
echo "Press Enter to accept a displayed default value."
echo

# ---------- Interactive configuration ----------
DOMAIN="$(ask 'DNS domain name' "$DEFAULT_DOMAIN")"
DOMAIN="${DOMAIN%.}"

SERVER_IP="$(ask 'DNS server IPv4 address' "$DEFAULT_SERVER_IP")"
NETWORK_CIDR="$(ask 'Network CIDR (must be /24)' "$DEFAULT_NETWORK_CIDR")"
INTERFACE="$(ask 'Network interface' "$DEFAULT_INTERFACE")"
SERVER_HOST="$(ask 'DNS server hostname (short name)' "$DEFAULT_SERVER_HOST")"

CLIENT1_NAME="$(ask 'Client 1 hostname (short name)' "$DEFAULT_CLIENT1_NAME")"
CLIENT1_IP="$(ask 'Client 1 IPv4 address' "$DEFAULT_CLIENT1_IP")"

CLIENT2_NAME="$(ask 'Client 2 hostname (short name)' "$DEFAULT_CLIENT2_NAME")"
CLIENT2_IP="$(ask 'Client 2 IPv4 address' "$DEFAULT_CLIENT2_IP")"

FORWARDER1="$(ask 'Primary public DNS forwarder' "$DEFAULT_FORWARDER1")"
FORWARDER2="$(ask 'Secondary public DNS forwarder' "$DEFAULT_FORWARDER2")"

CONFIGURE_SYSTEM_RESOLVER="yes"
if ask_yes_no "Configure this machine to use this DNS server" "yes"; then
    CONFIGURE_SYSTEM_RESOLVER="yes"
else
    CONFIGURE_SYSTEM_RESOLVER="no"
fi

# Accept either short names or fully qualified hostnames.
SERVER_HOST="${SERVER_HOST%%.*}"
CLIENT1_NAME="${CLIENT1_NAME%%.*}"
CLIENT2_NAME="${CLIENT2_NAME%%.*}"

# ---------- Input validation ----------
valid_ipv4() {
    local ip="$1"
    local a b c d extra

    IFS=. read -r a b c d extra <<< "$ip"

    [[ -z "${extra:-}" ]] || return 1
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ &&
       "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1

    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

valid_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
}

valid_ipv4 "$SERVER_IP" || die "Invalid server IPv4 address: $SERVER_IP"
valid_ipv4 "$CLIENT1_IP" || die "Invalid client 1 IPv4 address: $CLIENT1_IP"
valid_ipv4 "$CLIENT2_IP" || die "Invalid client 2 IPv4 address: $CLIENT2_IP"
valid_ipv4 "$FORWARDER1" || die "Invalid primary forwarder: $FORWARDER1"
valid_ipv4 "$FORWARDER2" || die "Invalid secondary forwarder: $FORWARDER2"

[[ "$NETWORK_CIDR" == */24 ]] ||
    die "This script currently supports /24 networks only."

NETWORK_BASE="${NETWORK_CIDR%/*}"
valid_ipv4 "$NETWORK_BASE" || die "Invalid network address: $NETWORK_BASE"

valid_hostname "$SERVER_HOST" || die "Invalid server hostname."
valid_hostname "$CLIENT1_NAME" || die "Invalid client 1 hostname."
valid_hostname "$CLIENT2_NAME" || die "Invalid client 2 hostname."

[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] ||
    die "Invalid domain name: $DOMAIN"

IFS=. read -r N1 N2 N3 N4 <<< "$NETWORK_BASE"
IFS=. read -r S1 S2 S3 S4 <<< "$SERVER_IP"

[[ "$N1.$N2.$N3" == "$S1.$S2.$S3" ]] ||
    die "Server IP must belong to the configured /24 network."

for IP in "$CLIENT1_IP" "$CLIENT2_IP"; do
    IFS=. read -r C1 C2 C3 C4 <<< "$IP"
    [[ "$C1.$C2.$C3" == "$N1.$N2.$N3" ]] ||
        die "Client IP $IP is outside $NETWORK_CIDR."
done

[[ "$SERVER_IP" != "$CLIENT1_IP" &&
   "$SERVER_IP" != "$CLIENT2_IP" &&
   "$CLIENT1_IP" != "$CLIENT2_IP" ]] ||
    die "Server and client IP addresses must be different."

[[ "$CLIENT1_NAME" != "$CLIENT2_NAME" &&
   "$SERVER_HOST" != "$CLIENT1_NAME" &&
   "$SERVER_HOST" != "$CLIENT2_NAME" ]] ||
    die "Server and client hostnames must be different."

NETWORK_PREFIX="$N1.$N2.$N3"
REVERSE_ZONE="$N3.$N2.$N1.in-addr.arpa"
SERVER_FQDN="${SERVER_HOST}.${DOMAIN}"
CLIENT1_FQDN="${CLIENT1_NAME}.${DOMAIN}"
CLIENT2_FQDN="${CLIENT2_NAME}.${DOMAIN}"

CLIENT1_LAST="${CLIENT1_IP##*.}"
CLIENT2_LAST="${CLIENT2_IP##*.}"
SERVER_LAST="${SERVER_IP##*.}"

FORWARD_ZONE="/var/named/forward.zone"
REVERSE_ZONE_FILE="/var/named/reverse.zone"
MANAGED_ZONES="/etc/named/managed-zones.conf"
NAMED_CONF="/etc/named.conf"

echo
echo "---------------- Configuration summary ----------------"
echo "Domain          : $DOMAIN"
echo "DNS server      : $SERVER_FQDN ($SERVER_IP)"
echo "Network         : $NETWORK_CIDR"
echo "Interface       : $INTERFACE"
echo "Client 1        : $CLIENT1_FQDN ($CLIENT1_IP)"
echo "Client 2        : $CLIENT2_FQDN ($CLIENT2_IP)"
echo "Reverse zone    : $REVERSE_ZONE"
echo "Forwarders      : $FORWARDER1, $FORWARDER2"
echo "System resolver : $CONFIGURE_SYSTEM_RESOLVER"
echo "--------------------------------------------------------"
echo

ask_yes_no "Continue with this configuration" "yes" ||
    die "Setup cancelled by user."

log "Starting DNS server setup."

# ---------- Find active NetworkManager connection ----------
CONNECTION_NAME="$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null || true)"

[[ -n "$CONNECTION_NAME" && "$CONNECTION_NAME" != "--" ]] ||
    die "No active NetworkManager connection found for $INTERFACE."

log "Active connection: $CONNECTION_NAME"

# ---------- Bootstrap DNS before installing packages ----------
# This is important if BIND was removed and the current resolver
# cannot resolve Rocky Linux package mirrors.
log "Temporarily configuring public DNS for package installation."

if ! nmcli connection modify "$CONNECTION_NAME" \
    ipv4.dns "$FORWARDER1 $FORWARDER2" \
    ipv4.ignore-auto-dns yes; then
    die "Could not configure temporary public DNS."
fi

if ! nmcli device reapply "$INTERFACE"; then
    log "Device reapply failed; trying to reactivate the connection."
    nmcli connection up "$CONNECTION_NAME" ||
        die "Could not activate the network connection."
fi

if ! getent hosts mirrors.rockylinux.org >/dev/null 2>&1; then
    log "Public DNS test failed; retrying connection activation."
    nmcli connection up "$CONNECTION_NAME" ||
        die "Network connection activation failed."

    getent hosts mirrors.rockylinux.org >/dev/null 2>&1 ||
        die "Cannot resolve mirrors.rockylinux.org. Check internet access, gateway, and upstream DNS."
fi

log "Installing BIND and DNS utilities."
dnf install -y bind bind-utils policycoreutils-python-utils NetworkManager ||
    die "Package installation failed. Check network and DNF repository access."

# ---------- Back up existing configuration ----------
log "Backing up existing DNS configuration."

backup_file() {
    local file="$1"

    if [[ -e "$file" ]]; then
        cp -a "$file" "${file}.backup.${TIMESTAMP}"
        log "Backup created: ${file}.backup.${TIMESTAMP}"
    fi
}

backup_file "$NAMED_CONF"
backup_file "$MANAGED_ZONES"
backup_file "$FORWARD_ZONE"
backup_file "$REVERSE_ZONE_FILE"

# Restore a previously saved RPM configuration if needed.
if [[ ! -e "$NAMED_CONF" && -e /etc/named.conf.rpmsave ]]; then
    cp -a /etc/named.conf.rpmsave "$NAMED_CONF"
fi

# ---------- Prepare directories and permissions ----------
log "Preparing BIND directories."

mkdir -p /etc/named /var/named

chown root:named /var/named
chmod 0770 /var/named

# ---------- Create forward zone ----------
log "Creating forward zone."

TODAY="$(date +%Y%m%d)"
OLD_SERIAL=""

if [[ -f "$FORWARD_ZONE" ]]; then
    OLD_SERIAL="$(awk '/SOA/ { getline; gsub(/[;[:space:]]/, "", $1); print $1; exit }' "$FORWARD_ZONE" 2>/dev/null || true)"
fi

if [[ "$OLD_SERIAL" =~ ^${TODAY}[0-9]{2}$ ]]; then
    RUN_NUMBER=$((10#${OLD_SERIAL:8:2} + 1))
    SERIAL="${TODAY}$(printf '%02d' "$RUN_NUMBER")"
else
    SERIAL="${TODAY}01"
fi

cat > "$FORWARD_ZONE" <<EOF
\$TTL 86400
@   IN  SOA ${SERVER_FQDN}. root.${DOMAIN}. (
        ${SERIAL}
        3600
        1800
        604800
        86400
)
@           IN  NS  ${SERVER_FQDN}.
${SERVER_HOST}  IN  A   ${SERVER_IP}
${CLIENT1_NAME} IN  A   ${CLIENT1_IP}
${CLIENT2_NAME} IN  A   ${CLIENT2_IP}
EOF

# ---------- Create reverse zone ----------
log "Creating reverse zone."

cat > "$REVERSE_ZONE_FILE" <<EOF
\$TTL 86400
@   IN  SOA ${SERVER_FQDN}. root.${DOMAIN}. (
        ${SERIAL}
        3600
        1800
        604800
        86400
)
@           IN  NS  ${SERVER_FQDN}.
${SERVER_LAST}  IN  PTR ${SERVER_FQDN}.
${CLIENT1_LAST} IN  PTR ${CLIENT1_FQDN}.
${CLIENT2_LAST} IN  PTR ${CLIENT2_FQDN}.
EOF

chown root:named "$FORWARD_ZONE" "$REVERSE_ZONE_FILE"
chmod 0640 "$FORWARD_ZONE" "$REVERSE_ZONE_FILE"

# ---------- Configure zone declarations ----------
log "Configuring authoritative local zones."

cat > "$MANAGED_ZONES" <<EOF
zone "${DOMAIN}" IN {
    type master;
    file "forward.zone";
    allow-update { none; };
    allow-transfer { none; };
};

zone "${REVERSE_ZONE}" IN {
    type master;
    file "reverse.zone";
    allow-update { none; };
    allow-transfer { none; };
};
EOF

# ---------- Configure BIND ----------
log "Configuring local-first DNS and public forwarding."

cat > "$NAMED_CONF" <<EOF
options {
    directory "/var/named";

    listen-on port 53 { 127.0.0.1; ${SERVER_IP}; };
    listen-on-v6 port 53 { none; };

    allow-query {
        localhost;
        ${NETWORK_PREFIX}.0/24;
    };

    recursion yes;

    allow-recursion {
        localhost;
        ${NETWORK_PREFIX}.0/24;
    };

    allow-query-cache {
        localhost;
        ${NETWORK_PREFIX}.0/24;
    };

    forwarders {
        ${FORWARDER1};
        ${FORWARDER2};
    };

    forward only;

    dnssec-validation auto;

    allow-transfer { none; };
};

include "/etc/named.rfc1912.zones";
include "${MANAGED_ZONES}";
EOF

# ---------- SELinux ----------
log "Restoring SELinux labels."

restorecon -Rv /var/named /etc/named /etc/named.conf 2>&1 | tee -a "$LOG_FILE" || true

# ---------- Validate configuration ----------
log "Validating configuration and DNS zones."

named-checkconf "$NAMED_CONF" ||
    die "named-checkconf failed. Check $NAMED_CONF."

named-checkzone "$DOMAIN" "$FORWARD_ZONE" ||
    die "Forward zone validation failed."

named-checkzone "$REVERSE_ZONE" "$REVERSE_ZONE_FILE" ||
    die "Reverse zone validation failed."

runuser -u named -- test -r "$FORWARD_ZONE" ||
    die "named user cannot read the forward zone."

runuser -u named -- test -r "$REVERSE_ZONE_FILE" ||
    die "named user cannot read the reverse zone."

runuser -u named -- test -w /var/named ||
    die "named user cannot write to /var/named. Check directory permissions."

# ---------- Firewall ----------
log "Configuring firewall."

if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=dns
    firewall-cmd --reload
    log "DNS allowed in firewall zone: $(firewall-cmd --get-default-zone)"
else
    log "firewalld is not active; skipping firewall configuration."
fi

# ---------- Start BIND ----------
log "Enabling and restarting named."

systemctl enable named
systemctl restart named
systemctl is-active --quiet named ||
    die "BIND service did not start. Check: journalctl -u named -xe"

# ---------- Test local DNS directly ----------
log "Testing local DNS records directly."

for RECORD in "$SERVER_FQDN" "$CLIENT1_FQDN" "$CLIENT2_FQDN"; do
    if ANSWER="$(dig +short @"$SERVER_IP" "$RECORD" A | head -n 1)" &&
       [[ -n "$ANSWER" ]]; then
        log "PASS: $RECORD -> $ANSWER"
    else
        die "DNS lookup failed for $RECORD"
    fi
done

PTR_ANSWER="$(dig +short @"$SERVER_IP" -x "$SERVER_IP" | head -n 1 || true)"
if [[ "$PTR_ANSWER" == "${SERVER_FQDN}." ]]; then
    log "PASS: Reverse lookup $SERVER_IP -> $PTR_ANSWER"
else
    log "WARNING: Reverse lookup returned: ${PTR_ANSWER:-no answer}"
fi

# ---------- Test public DNS forwarding ----------
log "Testing public DNS forwarding."

if dig +time=3 +tries=1 +short @"$SERVER_IP" google.com A | grep -Eq '^[0-9]+\.'; then
    log "PASS: public DNS forwarding works."
else
    log "WARNING: public DNS forwarding test failed. Check upstream network access."
fi

# ---------- Configure system resolver ----------
if [[ "$CONFIGURE_SYSTEM_RESOLVER" == "yes" ]]; then
    log "Configuring NetworkManager to use local DNS."

    nmcli connection modify "$CONNECTION_NAME" \
        ipv4.dns "$SERVER_IP" \
        ipv4.dns-search "$DOMAIN" \
        ipv4.ignore-auto-dns yes \
        ipv4.dns-priority -50 \
        ipv6.ignore-auto-dns yes

    if ! nmcli device reapply "$INTERFACE"; then
        log "Device reapply failed; reactivating connection to apply DNS settings."
        nmcli connection up "$CONNECTION_NAME" ||
            die "Could not reactivate the connection with local DNS settings."
    fi

    # Reapply may succeed without updating the resolver as expected.
    if ! grep -qE "^[[:space:]]*nameserver[[:space:]]+${SERVER_IP//./\\.}([[:space:]]*)$" /etc/resolv.conf; then
        log "Resolver does not yet show $SERVER_IP; reactivating the connection."
        nmcli connection up "$CONNECTION_NAME" ||
            die "Could not apply the local DNS resolver."
    fi

    log "Current resolver configuration:"
    cat /etc/resolv.conf | tee -a "$LOG_FILE"

    log "Testing short hostname resolution through the system resolver."

    if getent ahostsv4 "$CLIENT1_NAME" >/dev/null 2>&1; then
        log "PASS: short-name lookup for $CLIENT1_NAME works."
    else
        log "WARNING: short-name lookup failed. Try: getent ahostsv4 ${CLIENT1_FQDN}"
    fi

    log "Testing public hostname resolution through the system resolver."

    if getent ahostsv4 google.com >/dev/null 2>&1; then
        log "PASS: google.com resolves through the system resolver."
    else
        log "WARNING: google.com did not resolve through the system resolver."
    fi
else
    log "Skipping system resolver changes as requested."
fi

# ---------- Summary ----------
echo
echo "============================================================"
echo "          DNS SERVER CONFIGURATION FINISHED"
echo "============================================================"
echo "Domain             : $DOMAIN"
echo "DNS server         : $SERVER_IP"
echo "Interface          : $INTERFACE"
echo "Network            : $NETWORK_CIDR"
echo "Forwarders         : $FORWARDER1, $FORWARDER2"
echo "BIND service       : $(systemctl is-active named)"
echo "System DNS setup   : $CONFIGURE_SYSTEM_RESOLVER"
echo
echo "Local records:"
echo "  $SERVER_FQDN -> $SERVER_IP"
echo "  $CLIENT1_FQDN -> $CLIENT1_IP"
echo "  $CLIENT2_FQDN -> $CLIENT2_IP"
echo
echo "Test commands:"
echo "  dig @$SERVER_IP $CLIENT1_FQDN"
echo "  dig +search @$SERVER_IP $CLIENT1_NAME"
echo "  getent ahostsv4 $CLIENT1_NAME"
echo "  getent ahostsv4 google.com"
echo "  ping $CLIENT1_NAME"
echo
echo "Log file: $LOG_FILE"
echo "============================================================"

