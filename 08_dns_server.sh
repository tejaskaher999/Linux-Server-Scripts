
#!/usr/bin/env bash
# ============================================================
# 08_dns_server.sh
# Configure BIND DNS server on Rocky Linux / RHEL
#
# Features:
#   - Detects network interface, server IP, and network CIDR
#   - Interactive DNS domain and client configuration
#   - Creates forward and reverse DNS zones
#   - Fixes BIND configuration ownership and permissions
#   - Restores SELinux contexts
#   - Validates configuration before starting named
#   - Creates timestamped backups
# ============================================================

set -Eeuo pipefail

# -------------------- ROOT CHECK -----------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    echo "Example: sudo ./08_dns_server.sh"
    exit 1
fi

# -------------------- DEFAULT SETTINGS -----------------------

NAMED_CONF="/etc/named.conf"
MANAGED_DIR="/etc/named"
MANAGED_CONF="${MANAGED_DIR}/managed-zones.conf"
ZONE_DIR="/var/named"

DEFAULT_DOMAIN="skynet.com"
DEFAULT_SERVER_NAME="$(hostname -s 2>/dev/null || echo server)"
DEFAULT_CLIENT1="client1"
DEFAULT_CLIENT2="client2"

BACKUP_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# -------------------- HELPER FUNCTIONS -----------------------

print_line() {
    printf '%s\n' "============================================================"
}

read_value() {
    local prompt="$1"
    local default_value="$2"
    local entered_value

    read -r -p "${prompt} [${default_value}]: " entered_value
    printf '%s' "${entered_value:-$default_value}"
}

fail() {
    echo
    echo "ERROR: $*"
    exit 1
}

# -------------------- DETECT NETWORK -------------------------

echo
print_line
echo "               DNS SERVER CONFIGURATION"
print_line
echo
echo "Detecting network configuration..."
echo

command -v ip >/dev/null 2>&1 || fail "'ip' command is not available."
command -v python3 >/dev/null 2>&1 || fail "Python 3 is required."

DEFAULT_IFACE="$(ip -o route show default 2>/dev/null |
    awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"

if [[ -z "$DEFAULT_IFACE" ]]; then
    DEFAULT_IFACE="$(ip -o -4 addr show scope global |
        awk 'NR==1 {print $2}')"
fi

[[ -n "$DEFAULT_IFACE" ]] ||
    fail "Could not detect a network interface with an IPv4 address."

DETECTED_CIDR="$(ip -o -4 addr show dev "$DEFAULT_IFACE" scope global |
    awk 'NR==1 {print $4}')"

[[ -n "$DETECTED_CIDR" ]] ||
    fail "No global IPv4 address found on interface ${DEFAULT_IFACE}."

DETECTED_SERVER_IP="${DETECTED_CIDR%/*}"

# Calculate the network and default client addresses without
# enumerating every host in the network.
read -r DETECTED_NETWORK DEFAULT_CLIENT1_IP DEFAULT_CLIENT2_IP < <(
    python3 - "$DETECTED_CIDR" <<'PY'
import ipaddress
import sys

interface = ipaddress.ip_interface(sys.argv[1])
network = interface.network
hosts = network.num_addresses

if hosts < 4:
    raise SystemExit("Detected network is too small for this DNS setup.")

print(
    network,
    network.network_address + 1,
    network.network_address + 2
)
PY
) || fail "Could not calculate network details."

DEFAULT_SERVER_IP="$DETECTED_SERVER_IP"
DEFAULT_NETWORK="$DETECTED_NETWORK"

DEFAULT_CLIENT1_IP="${DEFAULT_CLIENT1_IP:-192.168.78.1}"
DEFAULT_CLIENT2_IP="${DEFAULT_CLIENT2_IP:-192.168.78.2}"

echo "Automatically detected configuration:"
print_line
printf '%-20s: %s\n' "Interface" "$DEFAULT_IFACE"
printf '%-20s: %s\n' "DNS server IP" "$DEFAULT_SERVER_IP"
printf '%-20s: %s\n' "Network CIDR" "$DEFAULT_NETWORK"
printf '%-20s: %s\n' "DNS domain" "$DEFAULT_DOMAIN"
printf '%-20s: %s\n' "DNS server name" "$DEFAULT_SERVER_NAME"
printf '%-20s: %s\n' "Named config" "$NAMED_CONF"
printf '%-20s: %s\n' "Zone directory" "$ZONE_DIR"
print_line

echo
echo "Press ENTER to keep each current value."
echo

# -------------------- USER INPUT -----------------------------

SERVER_IP="$(read_value "DNS server IP" "$DEFAULT_SERVER_IP")"
NETWORK_CIDR="$(read_value "Server network/CIDR" "$DEFAULT_NETWORK")"
DNS_DOMAIN="$(read_value "DNS domain" "$DEFAULT_DOMAIN")"
DNS_SERVER_NAME="$(read_value "DNS server hostname" "$DEFAULT_SERVER_NAME")"
CLIENT1_NAME="$(read_value "Client 1 hostname" "$DEFAULT_CLIENT1")"
CLIENT1_IP="$(read_value "Client 1 IPv4 address" "$DEFAULT_CLIENT1_IP")"
CLIENT2_NAME="$(read_value "Client 2 hostname" "$DEFAULT_CLIENT2")"
CLIENT2_IP="$(read_value "Client 2 IPv4 address" "$DEFAULT_CLIENT2_IP")"

# -------------------- VALIDATE INPUT -------------------------

python3 - \
    "$SERVER_IP" "$NETWORK_CIDR" "$DNS_DOMAIN" \
    "$DNS_SERVER_NAME" "$CLIENT1_NAME" "$CLIENT1_IP" \
    "$CLIENT2_NAME" "$CLIENT2_IP" <<'PY'
import ipaddress
import re
import sys

server_ip, cidr, domain, server_name, c1_name, c1_ip, c2_name, c2_ip = sys.argv[1:]

try:
    server = ipaddress.ip_address(server_ip)
    network = ipaddress.ip_network(cidr, strict=False)
    client1 = ipaddress.ip_address(c1_ip)
    client2 = ipaddress.ip_address(c2_ip)
except ValueError as exc:
    raise SystemExit(f"Invalid IP address or network CIDR: {exc}")

if any(ip.version != 4 for ip in (server, client1, client2)):
    raise SystemExit("Only IPv4 addresses are supported by this script.")

if server not in network or client1 not in network or client2 not in network:
    raise SystemExit("The server and both clients must belong to the selected network.")

if len({str(server), str(client1), str(client2)}) != 3:
    raise SystemExit("Server IP, Client 1 IP, and Client 2 IP must be different.")

if network.prefixlen not in (8, 16, 24):
    raise SystemExit(
        "This script supports /8, /16, and /24 networks for reverse DNS."
    )

if any(ip in (network.network_address, network.broadcast_address)
       for ip in (server, client1, client2)):
    raise SystemExit("A network or broadcast address cannot be assigned to a host.")

label_pattern = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"
)

if not domain or len(domain) > 253:
    raise SystemExit("Invalid DNS domain.")

domain = domain.rstrip(".")
labels = domain.split(".")

if len(labels) < 2 or any(not label_pattern.fullmatch(x) for x in labels):
    raise SystemExit("Enter a valid domain such as tejas.com.")

for name in (server_name, c1_name, c2_name):
    if not label_pattern.fullmatch(name):
        raise SystemExit(f"Invalid hostname label: {name}")

print("Input validation passed.")
PY

# Calculate normalized network and reverse zone.
read -r NETWORK_CIDR REVERSE_ZONE < <(
    python3 - "$NETWORK_CIDR" <<'PY'
import ipaddress
import sys

network = ipaddress.ip_network(sys.argv[1], strict=False)
octets = str(network.network_address).split(".")
prefix_octets = network.prefixlen // 8
reverse_zone = ".".join(reversed(octets[:prefix_octets])) + ".in-addr.arpa"

print(network, reverse_zone)
PY
)

DNS_DOMAIN="${DNS_DOMAIN%.}"
SERVER_FQDN="${DNS_SERVER_NAME}.${DNS_DOMAIN}"
CLIENT1_FQDN="${CLIENT1_NAME}.${DNS_DOMAIN}"
CLIENT2_FQDN="${CLIENT2_NAME}.${DNS_DOMAIN}"

echo
echo "Final DNS configuration:"
print_line
printf '%-20s: %s\n' "Interface" "$DEFAULT_IFACE"
printf '%-20s: %s\n' "Server IP" "$SERVER_IP"
printf '%-20s: %s\n' "Allowed network" "$NETWORK_CIDR"
printf '%-20s: %s\n' "Domain" "$DNS_DOMAIN"
printf '%-20s: %s\n' "Server FQDN" "$SERVER_FQDN"
printf '%-20s: %s (%s)\n' "Client 1 FQDN" "$CLIENT1_FQDN" "$CLIENT1_IP"
printf '%-20s: %s (%s)\n' "Client 2 FQDN" "$CLIENT2_FQDN" "$CLIENT2_IP"
printf '%-20s: %s\n' "Forward zone" "$DNS_DOMAIN"
printf '%-20s: %s\n' "Reverse zone" "$REVERSE_ZONE"
print_line

echo
echo "NOTE: This script does not replace /etc/resolv.conf."
echo "It configures this machine as a DNS server."
echo

read -r -p "Continue with DNS server setup? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || {
    echo "Setup cancelled."
    exit 0
}

# -------------------- INSTALL BIND ---------------------------

echo
echo "Installing BIND DNS packages..."

if ! dnf install -y bind bind-utils; then
    fail "Could not install BIND packages."
fi

# -------------------- BACKUPS --------------------------------

echo
echo "Creating configuration backups..."

backup_file() {
    local file="$1"

    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.backup.${BACKUP_TIMESTAMP}"
        echo "Backup created: ${file}.backup.${BACKUP_TIMESTAMP}"
    fi
}

backup_file "$NAMED_CONF"
backup_file "$MANAGED_CONF"
backup_file "${ZONE_DIR}/forward.zone"
backup_file "${ZONE_DIR}/reverse.zone"

# -------------------- CONFIGURE NAMED.CONF -------------------

echo
echo "Configuring ${NAMED_CONF}..."

[[ -f "$NAMED_CONF" ]] || fail "${NAMED_CONF} does not exist."

# Update the existing options block without replacing unrelated
# settings. Configure DNS to listen on IPv4 and accept queries
# from localhost and the selected network.
python3 - "$NAMED_CONF" "$NETWORK_CIDR" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
network = sys.argv[2]
text = path.read_text()

match = re.search(r"(?ms)^options\s*\{.*?^\s*\};", text)
if not match:
    raise SystemExit("Could not find the options block in named.conf.")

block = match.group(0)

listen_pattern = r"(?m)^\s*listen-on\s+port\s+53\s*\{[^}]*\}\s*;"
listen_replacement = "    listen-on port 53 { any; };"

if re.search(listen_pattern, block):
    block = re.sub(listen_pattern, listen_replacement, block, count=1)
else:
    block = re.sub(
        r"(?m)^options\s*\{",
        "options {\n" + listen_replacement,
        block,
        count=1
    )

allow_pattern = r"(?m)^\s*allow-query\s*\{[^}]*\}\s*;"
allow_replacement = f"    allow-query {{ localhost; {network}; }};"

if re.search(allow_pattern, block):
    block = re.sub(allow_pattern, allow_replacement, block, count=1)
else:
    block = re.sub(
        r"(?m)^options\s*\{",
        "options {\n" + allow_replacement,
        block,
        count=1
    )

text = text[:match.start()] + block + text[match.end():]

include_line = 'include "/etc/named/managed-zones.conf";'
if include_line not in text:
    text = text.rstrip() + "\n\n" + include_line + "\n"

path.write_text(text)
PY

# -------------------- CREATE MANAGED ZONES -------------------

echo
echo "Creating DNS zone declarations..."

mkdir -p "$MANAGED_DIR"

cat > "$MANAGED_CONF" <<EOF
// Managed by 08_dns_server.sh
zone "${DNS_DOMAIN}" IN {
    type master;
    file "forward.zone";
    allow-update { none; };
};

zone "${REVERSE_ZONE}" IN {
    type master;
    file "reverse.zone";
    allow-update { none; };
};
EOF

# -------------------- CREATE FORWARD/REVERSE ZONES ------------

echo
echo "Creating forward and reverse zones..."

SERIAL="$(date +%Y%m%d)01"

python3 - \
    "$ZONE_DIR" "$DNS_DOMAIN" "$REVERSE_ZONE" "$SERIAL" \
    "$DNS_SERVER_NAME" "$SERVER_IP" \
    "$CLIENT1_NAME" "$CLIENT1_IP" \
    "$CLIENT2_NAME" "$CLIENT2_IP" "$NETWORK_CIDR" <<'PY'
import ipaddress
import sys
from pathlib import Path

(
    zone_dir, domain, reverse_zone, serial,
    server_name, server_ip,
    client1_name, client1_ip,
    client2_name, client2_ip, network_cidr
) = sys.argv[1:]

directory = Path(zone_dir)
directory.mkdir(parents=True, exist_ok=True)

network = ipaddress.ip_network(network_cidr, strict=False)

records = [
    (server_name, ipaddress.ip_address(server_ip)),
    (client1_name, ipaddress.ip_address(client1_ip)),
    (client2_name, ipaddress.ip_address(client2_ip)),
]

forward = [
    "$TTL 86400",
    f"@ IN SOA {server_name}.{domain}. admin.{domain}. (",
    f"    {serial} ; Serial",
    "    3600    ; Refresh",
    "    900     ; Retry",
    "    604800  ; Expire",
    "    86400   ; Negative Cache TTL",
    ")",
    "",
    f"@ IN NS {server_name}.{domain}.",
]

for hostname, address in records:
    forward.append(f"{hostname} IN A {address}")

(directory / "forward.zone").write_text("\n".join(forward) + "\n")

# Build PTR owners correctly for /8, /16, or /24 reverse zones.
prefix_octets = network.prefixlen // 8
reverse = [
    "$TTL 86400",
    f"@ IN SOA {server_name}.{domain}. admin.{domain}. (",
    f"    {serial} ; Serial",
    "    3600    ; Refresh",
    "    900     ; Retry",
    "    604800  ; Expire",
    "    86400   ; Negative Cache TTL",
    ")",
    "",
    f"@ IN NS {server_name}.{domain}.",
]

for hostname, address in records:
    if address not in network:
        raise SystemExit(f"{address} is outside {network}")

    octets = str(address).split(".")
    owner = ".".join(reversed(octets[prefix_octets:]))

    reverse.append(f"{owner} IN PTR {hostname}.{domain}.")

(directory / "reverse.zone").write_text("\n".join(reverse) + "\n")
PY

# -------------------- PERMISSIONS AND SELINUX -----------------

echo
echo "Setting configuration permissions and SELinux labels..."

# FIX FOR THE REPORTED FAILURE:
# named.service runs as the 'named' user. It must be able to read
# named.conf and the included configuration file.
chown root:named "$NAMED_CONF"
chmod 0640 "$NAMED_CONF"

# Allow the named group to traverse /etc/named and read the include.
chown root:named "$MANAGED_DIR"
chmod 0750 "$MANAGED_DIR"

chown root:named "$MANAGED_CONF"
chmod 0640 "$MANAGED_CONF"

# Zone files must be readable by the named service.
chown root:named "${ZONE_DIR}/forward.zone" "${ZONE_DIR}/reverse.zone"
chmod 0640 "${ZONE_DIR}/forward.zone" "${ZONE_DIR}/reverse.zone"

# Restore expected SELinux contexts for configuration and zone files.
if command -v restorecon >/dev/null 2>&1; then
    restorecon -v "$NAMED_CONF" || true
    restorecon -Rv "$MANAGED_DIR" || true
    restorecon -v "${ZONE_DIR}/forward.zone" "${ZONE_DIR}/reverse.zone" || true
fi

echo
echo "Permission verification:"
ls -l "$NAMED_CONF" "$MANAGED_CONF"
ls -l "${ZONE_DIR}/forward.zone" "${ZONE_DIR}/reverse.zone"

# -------------------- VALIDATE CONFIGURATION -----------------

echo
echo "Validating named configuration..."

named-checkconf "$NAMED_CONF" ||
    fail "named-checkconf failed. Review ${NAMED_CONF}."

echo
echo "Validating all configured zones..."

named-checkconf -z "$NAMED_CONF" ||
    fail "Zone validation failed. The DNS service will not be restarted."

echo
echo "Validating forward zone..."
named-checkzone "$DNS_DOMAIN" "${ZONE_DIR}/forward.zone" ||
    fail "Forward zone validation failed."

echo
echo "Validating reverse zone..."
named-checkzone "$REVERSE_ZONE" "${ZONE_DIR}/reverse.zone" ||
    fail "Reverse zone validation failed."

# -------------------- FIREWALL -------------------------------

echo
echo "Configuring firewall..."

if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=dns
    firewall-cmd --reload
else
    echo "firewalld is not active; skipping firewall changes."
fi

# -------------------- START BIND -----------------------------

echo
echo "Enabling and starting named service..."

systemctl enable named

if ! systemctl restart named; then
    echo
    echo "ERROR: named failed to start."
    echo
    echo "Service status:"
    systemctl status named.service --no-pager -l || true
    echo
    echo "Recent service logs:"
    journalctl -u named.service -b --no-pager -n 60 || true
    fail "BIND could not start. Check the error above."
fi

systemctl is-active --quiet named ||
    fail "named did not reach the active state."

# -------------------- FINAL TESTS ----------------------------

echo
echo "Testing local DNS resolution..."

if command -v dig >/dev/null 2>&1; then
    dig @"127.0.0.1" "$SERVER_FQDN" A +noall +answer || true
    dig @"127.0.0.1" "$CLIENT1_FQDN" A +noall +answer || true
    dig @"127.0.0.1" "$CLIENT2_FQDN" A +noall +answer || true
fi

# -------------------- SUCCESS SUMMARY ------------------------

echo
print_line
echo "             DNS SERVER CONFIGURED SUCCESSFULLY"
print_line

printf '%-20s: %s\n' "Service status" "$(systemctl is-active named)"
printf '%-20s: %s\n' "DNS server IP" "$SERVER_IP"
printf '%-20s: %s\n' "DNS domain" "$DNS_DOMAIN"
printf '%-20s: %s\n' "Server FQDN" "$SERVER_FQDN"
printf '%-20s: %s\n' "Client 1" "$CLIENT1_FQDN -> $CLIENT1_IP"
printf '%-20s: %s\n' "Client 2" "$CLIENT2_FQDN -> $CLIENT2_IP"
printf '%-20s: %s\n' "Forward zone" "${ZONE_DIR}/forward.zone"
printf '%-20s: %s\n' "Reverse zone" "${ZONE_DIR}/reverse.zone"

print_line

echo
echo "Useful verification commands:"
echo "  systemctl status named"
echo "  named-checkconf -z /etc/named.conf"
echo "  dig @${SERVER_IP} ${SERVER_FQDN}"
echo "  dig @${SERVER_IP} ${CLIENT1_FQDN}"
echo "  dig @${SERVER_IP} -x ${CLIENT1_IP}"
echo
echo "Client DNS server address: ${SERVER_IP}"
echo "NOTE: Configure client machines to use this DNS server."
echo

