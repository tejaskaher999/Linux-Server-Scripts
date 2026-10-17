#!/bin/bash

# ============================================================
# Script Name : 05_samba_server.sh
# Purpose     : Configure a Samba Server on Rocky Linux
# Features    :
#   1. Auto-detect server IP and client network
#   2. Allow interactive configuration changes
#   3. Install Samba packages
#   4. Create a Samba share and user
#   5. Set directory permissions and SELinux context
#   6. Configure smb.conf with automatic backups
#   7. Configure and enable the firewall
#   8. Enable and start Samba services
#   9. Verify configuration and display client commands
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# 1. DEFAULT CONFIGURATION
# ------------------------------------------------------------

SHARE_DIR_PATH="/data"
SHARE_NAME="data"
SHARE_FILE_NAME="demo.txt"

SAMBA_USERNAME="tejas"
SAMBA_CONF_FILE="/etc/samba/smb.conf"

# These values are automatically updated when detection works.
SERVER_INTERFACE=""
SERVER_IP="192.168.0.1"
SERVER_IP_CIDR="192.168.0.0/24"

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

get_network_cidr() {
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

get_samba_network() {
    # Convert CIDR into network-address/netmask format for Samba.
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.IPv4Network(sys.argv[1], strict=False)
    print(f"{network.network_address}/{network.netmask}")
except ValueError:
    sys.exit(1)
PY
}

# ------------------------------------------------------------
# 3. CHECK ROOT PRIVILEGES AND REQUIRED COMMANDS
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    error "Run as root: sudo ./05_samba_server.sh"
fi

for command in ip python3 systemctl dnf awk grep sed; do
    command -v "$command" >/dev/null 2>&1 ||
        error "Required command not found: $command"
done

# ------------------------------------------------------------
# 4. AUTO-DETECT NETWORK INTERFACE AND SERVER IP
# ------------------------------------------------------------

echo
print_line
echo "             SAMBA SERVER CONFIGURATION"
print_line
echo
echo "Detecting network configuration..."

# Prefer the interface associated with the default route.
SERVER_INTERFACE="$(
    ip route show default 2>/dev/null |
    awk 'NR == 1 {print $5; exit}'
)"

# Fallback: use the first interface with a global IPv4 address.
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

    SERVER_IP_CIDR="$(get_network_cidr "$DETECTED_CIDR")" ||
        error "Could not calculate the client network."
else
    echo "WARNING: No global IPv4 address was detected."
    echo "Enter the correct server IP and network manually."
fi

# ------------------------------------------------------------
# 5. DISPLAY AND EDIT CONFIGURATION
# ------------------------------------------------------------

echo
echo "Automatically detected configuration:"
print_line
echo "Network interface : ${SERVER_INTERFACE:-Not detected}"
echo "Server IP         : $SERVER_IP"
echo "Share name        : $SHARE_NAME"
echo "Share directory   : $SHARE_DIR_PATH"
echo "Demo file         : $SHARE_FILE_NAME"
echo "Samba username    : $SAMBA_USERNAME"
echo "Client network    : $SERVER_IP_CIDR"
echo "Config file       : $SAMBA_CONF_FILE"
print_line
echo
echo "Press ENTER to keep each current value."
echo

read -r -p "Samba server IP [$SERVER_IP]: " INPUT_SERVER_IP
SERVER_IP="${INPUT_SERVER_IP:-$SERVER_IP}"

read -r -p "Share name [$SHARE_NAME]: " INPUT_SHARE_NAME
SHARE_NAME="${INPUT_SHARE_NAME:-$SHARE_NAME}"

read -r -p "Shared directory [$SHARE_DIR_PATH]: " INPUT_SHARE_DIR
SHARE_DIR_PATH="${INPUT_SHARE_DIR:-$SHARE_DIR_PATH}"

read -r -p "Demo filename [$SHARE_FILE_NAME]: " INPUT_FILE_NAME
SHARE_FILE_NAME="${INPUT_FILE_NAME:-$SHARE_FILE_NAME}"

read -r -p "Samba username [$SAMBA_USERNAME]: " INPUT_USERNAME
SAMBA_USERNAME="${INPUT_USERNAME:-$SAMBA_USERNAME}"

read -r -p "Allowed client network/CIDR [$SERVER_IP_CIDR]: " INPUT_NETWORK
SERVER_IP_CIDR="${INPUT_NETWORK:-$SERVER_IP_CIDR}"

# ------------------------------------------------------------
# 6. VALIDATE USER INPUT
# ------------------------------------------------------------

is_valid_ipv4 "$SERVER_IP" ||
    error "Invalid server IPv4 address: $SERVER_IP"

is_valid_cidr "$SERVER_IP_CIDR" ||
    error "Invalid client network/CIDR: $SERVER_IP_CIDR"

if [[ "$SHARE_NAME" == *" "* ]] ||
   [[ "$SHARE_NAME" == *"["* ]] ||
   [[ "$SHARE_NAME" == *"]"* ]] ||
   [[ "$SHARE_NAME" == *$'\n'* ]] ||
   [[ -z "$SHARE_NAME" ]]; then
    error "Share name cannot be empty or contain spaces/brackets."
fi

if [[ "$SHARE_DIR_PATH" != /* ]] ||
   [[ "$SHARE_DIR_PATH" == "/" ]] ||
   [[ "$SHARE_DIR_PATH" == *$'\n'* ]]; then
    error "Shared directory must be a valid absolute path other than /."
fi

if [[ "$SHARE_FILE_NAME" == */* ]] ||
   [[ "$SHARE_FILE_NAME" == "." ]] ||
   [[ "$SHARE_FILE_NAME" == ".." ]] ||
   [[ -z "$SHARE_FILE_NAME" ]]; then
    error "Demo filename must be a filename, not a path."
fi

if [[ ! "$SAMBA_USERNAME" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]]; then
    error "Invalid Samba username."
fi

# Samba hosts allow uses network/netmask notation.
SAMBA_ALLOWED_NETWORK="$(get_samba_network "$SERVER_IP_CIDR")" ||
    error "Could not convert client network to Samba format."

# ------------------------------------------------------------
# 7. CONFIRM CONFIGURATION
# ------------------------------------------------------------

echo
echo "Final Samba configuration:"
print_line
echo "Network interface : ${SERVER_INTERFACE:-Not detected}"
echo "Server IP         : $SERVER_IP"
echo "Share name        : [$SHARE_NAME]"
echo "Shared directory  : $SHARE_DIR_PATH"
echo "Demo file         : $SHARE_FILE_NAME"
echo "Samba username    : $SAMBA_USERNAME"
echo "Client network    : $SERVER_IP_CIDR"
echo "Samba host range  : $SAMBA_ALLOWED_NETWORK"
echo "Config file       : $SAMBA_CONF_FILE"
print_line
echo
echo "IMPORTANT:"
echo "- Only the configured client network will be allowed by this share."
echo "- The Samba password will be requested securely."
echo "- File permissions and SELinux also control access."
echo

read -r -p "Continue with Samba server setup? (y/N): " CONFIRM

case "$CONFIRM" in
    y|Y|yes|YES|Yes) ;;
    *)
        echo "Setup cancelled."
        exit 0
        ;;
esac

# ------------------------------------------------------------
# 8. REQUEST SAMBA PASSWORD SECURELY
# ------------------------------------------------------------

echo
echo "Set the Samba password for user: $SAMBA_USERNAME"

while true; do
    read -r -s -p "Enter Samba password: " SAMBA_PASSWORD
    echo

    if [[ -z "$SAMBA_PASSWORD" ]]; then
        echo "Password cannot be empty. Try again."
        continue
    fi

    read -r -s -p "Confirm Samba password: " SAMBA_PASSWORD_CONFIRM
    echo

    if [[ "$SAMBA_PASSWORD" == "$SAMBA_PASSWORD_CONFIRM" ]]; then
        unset SAMBA_PASSWORD_CONFIRM
        break
    fi

    echo "Passwords do not match. Try again."
    unset SAMBA_PASSWORD SAMBA_PASSWORD_CONFIRM
done

# ------------------------------------------------------------
# 9. INSTALL REQUIRED PACKAGES
# ------------------------------------------------------------

echo
echo "Installing Samba packages..."

dnf install -y samba samba-common-tools acl policycoreutils-python-utils

# ------------------------------------------------------------
# 10. CREATE SYSTEM USER IF NECESSARY
# ------------------------------------------------------------

echo
echo "Creating or verifying Samba user..."

if ! id "$SAMBA_USERNAME" >/dev/null 2>&1; then
    useradd -r -M -s /sbin/nologin "$SAMBA_USERNAME"
    echo "System account created: $SAMBA_USERNAME"
else
    echo "System account already exists: $SAMBA_USERNAME"
fi

# ------------------------------------------------------------
# 11. SET SAMBA PASSWORD
# ------------------------------------------------------------

echo
echo "Adding/updating Samba password..."

# -s reads password input from standard input.
# The password is not passed as a command-line argument.
if ! printf '%s\n%s\n' "$SAMBA_PASSWORD" "$SAMBA_PASSWORD" |
    smbpasswd -s -a "$SAMBA_USERNAME"; then
    unset SAMBA_PASSWORD
    error "Could not set Samba password."
fi

unset SAMBA_PASSWORD

# ------------------------------------------------------------
# 12. CREATE SHARED DIRECTORY AND DEMO FILE
# ------------------------------------------------------------

echo
echo "Creating shared directory..."

mkdir -p "$SHARE_DIR_PATH"

DEMO_FILE_PATH="$SHARE_DIR_PATH/$SHARE_FILE_NAME"

if [[ ! -e "$DEMO_FILE_PATH" ]]; then
    cat > "$DEMO_FILE_PATH" <<EOF
Samba demo file
Server IP: $SERVER_IP
Share name: $SHARE_NAME
Shared directory: $SHARE_DIR_PATH
Allowed client network: $SERVER_IP_CIDR
Created by: 05_samba_server.sh
EOF
    echo "Demo file created: $DEMO_FILE_PATH"
else
    echo "Demo file already exists; keeping its contents."
fi

# Give the Samba user access without using chmod 777.
setfacl -m "u:$SAMBA_USERNAME:rwx" "$SHARE_DIR_PATH"
setfacl -d -m "u:$SAMBA_USERNAME:rwx" "$SHARE_DIR_PATH"

# ------------------------------------------------------------
# 13. CONFIGURE SELINUX
# ------------------------------------------------------------

echo
echo "Configuring SELinux..."

if command -v semanage >/dev/null 2>&1; then
    # Add a persistent SELinux file-context rule if it does not exist.
    if ! semanage fcontext -l |
        grep -Fq "$SHARE_DIR_PATH"; then
        semanage fcontext -a -t samba_share_t \
            "${SHARE_DIR_PATH}(/.*)?"
    else
        # Modify the matching path rule if an exact rule exists.
        semanage fcontext -a -t samba_share_t \
            "${SHARE_DIR_PATH}(/.*)?" 2>/dev/null ||
        semanage fcontext -m -t samba_share_t \
            "${SHARE_DIR_PATH}(/.*)?"
    fi

    restorecon -Rv "$SHARE_DIR_PATH"
else
    echo "WARNING: semanage is unavailable; applying a temporary context."
    chcon -R -t samba_share_t "$SHARE_DIR_PATH"
    echo "Install policycoreutils-python-utils to configure persistent labels."
fi

echo
echo "Current SELinux labels:"
ls -ldZ "$SHARE_DIR_PATH"
ls -lZ "$DEMO_FILE_PATH"

# ------------------------------------------------------------
# 14. BACK UP SAMBA CONFIGURATION
# ------------------------------------------------------------

echo
echo "Backing up Samba configuration..."

mkdir -p "$(dirname "$SAMBA_CONF_FILE")"

if [[ -f "$SAMBA_CONF_FILE" ]]; then
    BACKUP_FILE="${SAMBA_CONF_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$SAMBA_CONF_FILE" "$BACKUP_FILE"
    echo "Backup created: $BACKUP_FILE"
else
    touch "$SAMBA_CONF_FILE"
    echo "Created $SAMBA_CONF_FILE"
fi

# ------------------------------------------------------------
# 15. WRITE MANAGED SAMBA SHARE BLOCK
# ------------------------------------------------------------

# The managed block makes repeat runs idempotent.
# Existing configuration outside the block is preserved.

python3 - "$SAMBA_CONF_FILE" "$SHARE_NAME" "$SHARE_DIR_PATH" \
    "$SAMBA_USERNAME" "$SAMBA_ALLOWED_NETWORK" <<'PY'
import os
import sys
import tempfile

config_file, share_name, share_dir, username, allowed_network = sys.argv[1:]

begin = "# BEGIN managed by 05_samba_server.sh"
end = "# END managed by 05_samba_server.sh"

with open(config_file, "r", encoding="utf-8") as file:
    content = file.read()

result = []
inside_block = False

for line in content.splitlines():
    if line.strip() == begin:
        inside_block = True
        continue
    if line.strip() == end:
        inside_block = False
        continue
    if not inside_block:
        result.append(line)

while result and not result[-1].strip():
    result.pop()

result.extend([
    begin,
    f"[{share_name}]",
    f"    comment = Shared Folder {share_dir}",
    f"    path = {share_dir}",
    f"    valid users = {username}",
    "    read only = no",
    "    browseable = yes",
    "    guest ok = no",
    f"    hosts allow = {allowed_network}",
    end,
])

new_content = "\n".join(result) + "\n"
directory = os.path.dirname(config_file) or "."

fd, temp_path = tempfile.mkstemp(prefix=".smb.conf.", dir=directory)

try:
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        file.write(new_content)

    os.chmod(temp_path, 0o644)
    os.replace(temp_path, config_file)

except Exception:
    if os.path.exists(temp_path):
        os.unlink(temp_path)
    raise
PY

# ------------------------------------------------------------
# 16. VALIDATE SAMBA CONFIGURATION
# ------------------------------------------------------------

echo
echo "Validating Samba configuration..."

if ! testparm -s "$SAMBA_CONF_FILE"; then
    echo "ERROR: Samba configuration validation failed."

    if [[ -n "${BACKUP_FILE:-}" && -f "$BACKUP_FILE" ]]; then
        cp -a "$BACKUP_FILE" "$SAMBA_CONF_FILE"
        echo "Restored backup: $BACKUP_FILE"
    fi

    error "Fix the configuration before starting Samba."
fi

# ------------------------------------------------------------
# 17. START AND ENABLE SAMBA
# ------------------------------------------------------------

echo
echo "Enabling and starting Samba..."

systemctl enable --now smb

if ! systemctl is-active --quiet smb; then
    error "Samba service did not become active."
fi

# nmb provides NetBIOS name services and may not be needed
# for clients connecting directly through the server IP.
if systemctl list-unit-files nmb.service --no-legend 2>/dev/null |
    grep -q '^nmb.service'; then
    systemctl enable --now nmb
    echo "NetBIOS service enabled."
fi

# ------------------------------------------------------------
# 18. CONFIGURE FIREWALL
# ------------------------------------------------------------

echo
echo "Configuring firewall..."

if command -v firewall-cmd >/dev/null 2>&1 &&
   systemctl is-active --quiet firewalld; then

    firewall-cmd --permanent --add-service=samba
    firewall-cmd --reload

    echo "Firewall services:"
    firewall-cmd --list-services
else
    echo "WARNING: firewalld is not active or firewall-cmd is unavailable."
    echo "Check your firewall rules if clients cannot connect."
fi

# ------------------------------------------------------------
# 19. DISPLAY FINAL STATUS AND CLIENT INSTRUCTIONS
# ------------------------------------------------------------

echo
print_line
echo "             SAMBA SERVER CONFIGURED"
print_line

echo
echo "Samba Service Status:"
systemctl status smb --no-pager --full || true

echo
echo "Samba Configuration:"
echo "  $SAMBA_CONF_FILE"

echo
echo "Server IP:"
echo "  $SERVER_IP"

echo
echo "Allowed Client Network:"
echo "  $SERVER_IP_CIDR"

echo
echo "Share Name:"
echo "  [$SHARE_NAME]"

echo
echo "Shared Directory:"
echo "  $SHARE_DIR_PATH"

echo
echo "Samba Username:"
echo "  $SAMBA_USERNAME"

echo
echo "Demo File:"
echo "  $DEMO_FILE_PATH"

echo
echo "Configured Share:"
sed -n '/# BEGIN managed by 05_samba_server.sh/,/# END managed by 05_samba_server.sh/p' \
    "$SAMBA_CONF_FILE"

echo
echo "Useful server commands:"
echo "  testparm -s"
echo "  smbstatus"
echo "  pdbedit -L"
echo "  systemctl status smb"
echo "  firewall-cmd --list-services"
echo "  ls -ldZ $SHARE_DIR_PATH"

echo
echo "Example Linux client commands:"
echo "  dnf install -y cifs-utils"
echo "  mkdir -p /mnt/samba"
echo "  mount -t cifs //$SERVER_IP/$SHARE_NAME /mnt/samba -o username=$SAMBA_USERNAME"
echo
echo "The client will prompt for the Samba password."

echo
echo "Example Windows client path:"
echo "  \\\\$SERVER_IP\\$SHARE_NAME"
echo
echo "Sign in using the Samba username and password."

echo
echo "NOTES:"
echo "- Run client mount commands on the CLIENT, not the server."
echo "- Client IP must match the configured allowed network."
echo "- The server IP and client network are editable during setup."
echo "- Samba authentication is separate from the Linux login password."
echo "- Do not use chmod 777 as a shortcut for permissions."
echo "- Use a trusted network and keep Samba passwords private."

print_line

