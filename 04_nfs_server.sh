#!/bin/bash

# ============================================================
# Script Name : 04_nfs_server.sh
# Purpose     : Configure an NFS server on Rocky Linux
# Features    :
#   1. Detect server IP automatically
#   2. Detect active network interface and network CIDR
#   3. Allow detected values to be edited
#   4. Install NFS utilities
#   5. Configure /etc/exports safely with a backup
#   6. Enable and start NFS service
#   7. Configure firewall
#   8. Verify exports and display client mount command
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# 1. DEFAULT CONFIGURATION
# ------------------------------------------------------------

FILE_PATH="/etc/exports"
SHARE_DIR_PATH="/srv/nfs"
SHARE_DEMO_FILE="export.txt"
EXPORT_OPTIONS="rw,sync,root_squash,no_subtree_check"

# Fallback values used only when automatic detection fails.
SERVER_INTERFACE=""
SERVER_IP="192.168.0.1"
CLIENT_NETWORK="192.168.0.0/24"

# ------------------------------------------------------------
# 2. HELPER FUNCTIONS
# ------------------------------------------------------------

print_line() {
    printf '%*s\n' 60 '' | tr ' ' '='
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

is_valid_ipv4() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv4Address(sys.argv[1])
except ValueError:
    sys.exit(1)
PY
}

is_valid_cidr() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv4Network(sys.argv[1], strict=False)
except ValueError:
    sys.exit(1)
PY
}

detect_network() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    interface = ipaddress.IPv4Interface(sys.argv[1])
    print(interface.network)
except ValueError:
    sys.exit(1)
PY
}

# ------------------------------------------------------------
# 3. CHECK ROOT PRIVILEGES AND REQUIRED COMMANDS
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    error "Run this script as root: sudo ./04_nfs_server.sh"
fi

for command in ip python3 systemctl dnf awk sed grep; do
    command -v "$command" >/dev/null 2>&1 ||
        error "Required command not found: $command"
done

# ------------------------------------------------------------
# 4. AUTOMATICALLY DETECT SERVER INTERFACE AND IP
# ------------------------------------------------------------

echo
print_line
echo "             NFS SERVER CONFIGURATION"
print_line
echo
echo "Detecting network configuration..."

# Prefer the interface used by the default route.
SERVER_INTERFACE="$(
    ip route show default 2>/dev/null |
    awk 'NR == 1 {print $5; exit}'
)"

# If there is no default route, use the first interface
# that has a global IPv4 address.
if [[ -z "$SERVER_INTERFACE" ]] ||
   ! ip -o -4 addr show dev "$SERVER_INTERFACE" scope global \
        2>/dev/null | grep -q 'inet'; then
    SERVER_INTERFACE="$(
        ip -o -4 addr show scope global 2>/dev/null |
        awk 'NR == 1 {print $2; exit}'
    )"
fi

DETECTED_CIDR=""

if [[ -n "$SERVER_INTERFACE" ]]; then
    DETECTED_CIDR="$(
        ip -o -4 addr show dev "$SERVER_INTERFACE" scope global \
            2>/dev/null |
        awk 'NR == 1 {print $4; exit}'
    )"
fi

if [[ -n "$DETECTED_CIDR" ]]; then
    SERVER_IP="${DETECTED_CIDR%/*}"
    CLIENT_NETWORK="$(detect_network "$DETECTED_CIDR")" ||
        error "Could not calculate the network CIDR."
else
    echo "WARNING: Could not automatically detect a global IPv4 address."
    echo "You can enter the server IP and client network manually."
fi

# ------------------------------------------------------------
# 5. DISPLAY AND EDIT CONFIGURATION
# ------------------------------------------------------------

echo
echo "Automatically detected configuration:"
print_line
echo "Network interface : ${SERVER_INTERFACE:-Not detected}"
echo "NFS server IP     : $SERVER_IP"
echo "Shared directory  : $SHARE_DIR_PATH"
echo "Demo file         : $SHARE_DEMO_FILE"
echo "Client network    : $CLIENT_NETWORK"
echo "Exports file      : $FILE_PATH"
echo "Export options    : $EXPORT_OPTIONS"
print_line
echo
echo "Press ENTER to keep each current value."
echo

read -r -p "NFS server IP [$SERVER_IP]: " INPUT_SERVER_IP
SERVER_IP="${INPUT_SERVER_IP:-$SERVER_IP}"

read -r -p "Shared directory [$SHARE_DIR_PATH]: " INPUT_SHARE_DIR
SHARE_DIR_PATH="${INPUT_SHARE_DIR:-$SHARE_DIR_PATH}"

read -r -p "Allowed client network/CIDR [$CLIENT_NETWORK]: " INPUT_NETWORK
CLIENT_NETWORK="${INPUT_NETWORK:-$CLIENT_NETWORK}"

read -r -p "Demo filename [$SHARE_DEMO_FILE]: " INPUT_DEMO_FILE
SHARE_DEMO_FILE="${INPUT_DEMO_FILE:-$SHARE_DEMO_FILE}"

# ------------------------------------------------------------
# 6. VALIDATE INPUTS
# ------------------------------------------------------------

is_valid_ipv4 "$SERVER_IP" ||
    error "Invalid NFS server IPv4 address: $SERVER_IP"

is_valid_cidr "$CLIENT_NETWORK" ||
    error "Invalid client network/CIDR: $CLIENT_NETWORK"

if [[ "$SHARE_DIR_PATH" != /* ]] ||
   [[ "$SHARE_DIR_PATH" == "/" ]] ||
   [[ "$SHARE_DIR_PATH" == *" "* ]] ||
   [[ "$SHARE_DIR_PATH" == *"("* ]] ||
   [[ "$SHARE_DIR_PATH" == *")"* ]]; then
    error "Enter a valid absolute shared directory path without spaces or parentheses."
fi

if [[ "$SHARE_DEMO_FILE" == */* ]] ||
   [[ -z "$SHARE_DEMO_FILE" ]] ||
   [[ "$SHARE_DEMO_FILE" == "." ]] ||
   [[ "$SHARE_DEMO_FILE" == ".." ]]; then
    error "Demo filename must be a filename, not a directory path."
fi

# ------------------------------------------------------------
# 7. SHOW FINAL CONFIGURATION AND ASK FOR CONFIRMATION
# ------------------------------------------------------------

echo
echo "Final NFS configuration:"
print_line
echo "Network interface : ${SERVER_INTERFACE:-Not detected}"
echo "NFS server IP     : $SERVER_IP"
echo "Shared directory  : $SHARE_DIR_PATH"
echo "Client network    : $CLIENT_NETWORK"
echo "Demo file         : $SHARE_DEMO_FILE"
echo "Exports file      : $FILE_PATH"
echo "Export options    : $EXPORT_OPTIONS"
print_line
echo
echo "IMPORTANT:"
echo "- Only clients matching the configured network are exported."
echo "- The export is read/write; filesystem permissions still apply."
echo "- Use a trusted network and appropriate client permissions."
echo

read -r -p "Continue with NFS server setup? (y/N): " CONFIRM

case "$CONFIRM" in
    y|Y|yes|YES|Yes) ;;
    *)
        echo "Setup cancelled. No NFS configuration changes were made."
        exit 0
        ;;
esac

# ------------------------------------------------------------
# 8. INSTALL NFS UTILITIES
# ------------------------------------------------------------

echo
echo "Installing NFS utilities..."
dnf install -y nfs-utils

# ------------------------------------------------------------
# 9. CREATE SHARED DIRECTORY AND DEMO FILE
# ------------------------------------------------------------

echo
echo "Creating NFS shared directory..."

mkdir -p "$SHARE_DIR_PATH"
chmod 0755 "$SHARE_DIR_PATH"

DEMO_FILE_PATH="$SHARE_DIR_PATH/$SHARE_DEMO_FILE"

if [[ ! -e "$DEMO_FILE_PATH" ]]; then
    cat > "$DEMO_FILE_PATH" <<EOF
NFS server demo file
Server IP: $SERVER_IP
Shared directory: $SHARE_DIR_PATH
Allowed client network: $CLIENT_NETWORK
Created by: 04_nfs_server.sh
EOF
    chmod 0644 "$DEMO_FILE_PATH"
    echo "Demo file created: $DEMO_FILE_PATH"
else
    echo "Demo file already exists; keeping its contents: $DEMO_FILE_PATH"
fi

echo "Shared directory ready: $SHARE_DIR_PATH"

# ------------------------------------------------------------
# 10. BACK UP /etc/exports
# ------------------------------------------------------------

echo
echo "Configuring NFS exports..."

if [[ -f "$FILE_PATH" ]]; then
    BACKUP_FILE="${FILE_PATH}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$FILE_PATH" "$BACKUP_FILE"
    echo "Backup created: $BACKUP_FILE"
else
    touch "$FILE_PATH"
    echo "Created $FILE_PATH"
fi

# ------------------------------------------------------------
# 11. UPDATE OUR MANAGED EXPORT BLOCK
# ------------------------------------------------------------

# These markers allow the script to update its own entry
# without deleting unrelated exports in /etc/exports.

python3 - "$FILE_PATH" "$SHARE_DIR_PATH" "$CLIENT_NETWORK" "$EXPORT_OPTIONS" <<'PY'
import os
import sys
import tempfile

exports_file, share_dir, network, options = sys.argv[1:]

begin = "# BEGIN managed by 04_nfs_server.sh"
end = "# END managed by 04_nfs_server.sh"

with open(exports_file, "r", encoding="utf-8") as file:
    content = file.read()

lines = content.splitlines()
result = []
inside_block = False

for line in lines:
    if line.strip() == begin:
        inside_block = True
        continue
    if line.strip() == end:
        inside_block = False
        continue
    if not inside_block:
        result.append(line)

# Remove only blank lines at the end before adding our block.
while result and not result[-1].strip():
    result.pop()

result.extend([
    begin,
    f"{share_dir} {network}({options})",
    end,
])

new_content = "\n".join(result) + "\n"
directory = os.path.dirname(exports_file) or "."

fd, temp_path = tempfile.mkstemp(prefix=".exports.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        file.write(new_content)
    os.chmod(temp_path, 0o644)
    os.replace(temp_path, exports_file)
except Exception:
    if os.path.exists(temp_path):
        os.unlink(temp_path)
    raise
PY

echo
echo "Current managed export entry:"
sed -n '/# BEGIN managed by 04_nfs_server.sh/,/# END managed by 04_nfs_server.sh/p' "$FILE_PATH"

# ------------------------------------------------------------
# 12. VALIDATE AND APPLY EXPORTS
# ------------------------------------------------------------

echo
echo "Validating NFS export configuration..."
exportfs -rav

# ------------------------------------------------------------
# 13. ENABLE AND START NFS SERVER
# ------------------------------------------------------------

echo
echo "Enabling and starting NFS server..."

systemctl enable --now nfs-server
systemctl is-active --quiet nfs-server ||
    error "NFS server service did not become active."

# ------------------------------------------------------------
# 14. CONFIGURE FIREWALL IF FIREWALLD IS ACTIVE
# ------------------------------------------------------------

echo
echo "Configuring firewall..."

if command -v firewall-cmd >/dev/null 2>&1 &&
   systemctl is-active --quiet firewalld; then

    firewall-cmd --permanent --add-service=nfs
    firewall-cmd --permanent --add-service=mountd
    firewall-cmd --permanent --add-service=rpc-bind
    firewall-cmd --reload

    echo "NFS firewall services configured."
    firewall-cmd --list-services
else
    echo "firewalld is not active or firewall-cmd is unavailable."
    echo "Check your firewall rules if remote clients cannot connect."
fi

# ------------------------------------------------------------
# 15. DISPLAY FINAL STATUS
# ------------------------------------------------------------

echo
echo "Exported NFS shares:"
exportfs -v

echo
print_line
echo "              NFS SERVER CONFIGURED"
print_line

echo
echo "NFS Service Status:"
systemctl status nfs-server --no-pager --full || true

echo
echo "NFS Configuration File:"
echo "  $FILE_PATH"

echo
echo "Network Interface:"
echo "  ${SERVER_INTERFACE:-Not detected}"

echo
echo "NFS Server IP:"
echo "  $SERVER_IP"

echo
echo "Shared Directory:"
echo "  $SHARE_DIR_PATH"

echo
echo "Allowed Client Network:"
echo "  $CLIENT_NETWORK"

echo
echo "Demo File:"
echo "  $DEMO_FILE_PATH"

echo
echo "Useful server commands:"
echo "  systemctl status nfs-server"
echo "  exportfs -v"
echo "  exportfs -rav"
echo "  cat /etc/exports"
echo "  showmount -e localhost"

echo
echo "Example client mount command:"
echo "  mkdir -p /mnt"
echo "  mount $SERVER_IP:$SHARE_DIR_PATH /mnt"
echo
echo "Example client verification:"
echo "  showmount -e $SERVER_IP"
echo "  ls -l /mnt"

echo
echo "NOTES:"
echo "- Run the mount commands on the NFS CLIENT, not the server."
echo "- The client must be able to reach $SERVER_IP over the network."
echo "- Its IP must match the exported network: $CLIENT_NETWORK"
echo "- File ownership and permissions control write access."
echo "- root_squash prevents remote root from automatically having local root privileges."
echo "- If SELinux denies access, inspect the audit logs before changing policies."
print_line

