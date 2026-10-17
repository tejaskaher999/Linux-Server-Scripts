#!/bin/bash
# ============================================================
# Script Name : 04_nfs_server.sh
# Purpose     : Install and configure an NFS Server
# OS          : Rocky Linux / RHEL
#
# Features:
#   1. Install nfs-utils.
#   2. Configure NFS export directory and client network.
#   3. Create a demo file.
#   4. Update /etc/exports without duplicate entries.
#   5. Validate and export NFS shares.
#   6. Enable and start nfs-server.
#   7. Configure firewall when firewalld is active.
#   8. Verify the exported shares and service status.
#
# Run as root.
# ============================================================

set -Eeuo pipefail

# -------------------- VARIABLES ------------------------------

# Change these values according to your requirements.
FILE_PATH="/etc/exports"
SHARE_DIR_PATH="/srv/nfs"
SHARE_DEMO_FILE="export.txt"
CLIENT_NETWORK="192.168.0.0/24"

# NFS permissions:
# rw            = Read and write
# sync          = Write changes to stable storage before replying
# root_squash   = Map client root access to an unprivileged user
# no_subtree_check = Disable subtree checking
EXPORT_OPTIONS="rw,sync,root_squash,no_subtree_check"

# -------------------- ROOT CHECK -----------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    echo "Example: sudo ./04_nfs_server.sh"
    exit 1
fi

# -------------------- REQUIRED COMMANDS ----------------------

for cmd in dnf systemctl python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' is missing."
        exit 1
    fi
done

echo
echo "============================================================"
echo "                 NFS SERVER CONFIGURATION"
echo "============================================================"
echo

# -------------------- EDIT CONFIGURATION ---------------------

echo "Current configuration:"
echo "------------------------------------------------------------"
echo "Exports file    : $FILE_PATH"
echo "Shared folder   : $SHARE_DIR_PATH"
echo "Demo file       : $SHARE_DEMO_FILE"
echo "Client network  : $CLIENT_NETWORK"
echo "Export options  : $EXPORT_OPTIONS"
echo "------------------------------------------------------------"
echo
echo "Press ENTER to keep each current value."
echo

read -r -p "Shared directory [$SHARE_DIR_PATH]: " INPUT_VALUE
SHARE_DIR_PATH="${INPUT_VALUE:-$SHARE_DIR_PATH}"

read -r -p "Allowed client network/CIDR [$CLIENT_NETWORK]: " INPUT_VALUE
CLIENT_NETWORK="${INPUT_VALUE:-$CLIENT_NETWORK}"

read -r -p "Demo filename [$SHARE_DEMO_FILE]: " INPUT_VALUE
SHARE_DEMO_FILE="${INPUT_VALUE:-$SHARE_DEMO_FILE}"

# -------------------- VALIDATE INPUT -------------------------

if [[ "$SHARE_DIR_PATH" != /* ||
      "$SHARE_DIR_PATH" == "/" ||
      "$SHARE_DIR_PATH" == *" "* ]]; then
    echo "ERROR: Shared directory must be an absolute path,"
    echo "must not be /, and must not contain spaces."
    exit 1
fi

if [[ "$SHARE_DEMO_FILE" == */* ||
      -z "$SHARE_DEMO_FILE" ||
      "$SHARE_DEMO_FILE" == "." ||
      "$SHARE_DEMO_FILE" == ".." ]]; then
    echo "ERROR: Enter a filename, not a directory path."
    exit 1
fi

if ! python3 - "$CLIENT_NETWORK" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=True)
    if network.version != 4:
        raise ValueError("Only IPv4 client networks are supported.")
except Exception as exc:
    print(f"ERROR: Invalid client network: {exc}")
    sys.exit(1)
PY
then
    exit 1
fi

echo
echo "Final NFS configuration:"
echo "  Directory      : $SHARE_DIR_PATH"
echo "  Client network : $CLIENT_NETWORK"
echo "  Demo file      : $SHARE_DEMO_FILE"
echo

echo "IMPORTANT:"
echo "- Only the specified client network will be exported."
echo "- The export is read/write; file permissions still apply."
echo "- Use a trusted network and appropriate client permissions."
echo

read -r -p "Continue with NFS server setup? (y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled. No NFS configuration was changed."
    exit 0
fi

# -------------------- INSTALL NFS UTILITIES ------------------

echo
echo "Installing NFS utilities..."

dnf install -y nfs-utils

# Verify required NFS commands.
for cmd in exportfs showmount; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required NFS command '$cmd' was not installed."
        exit 1
    fi
done

# -------------------- CREATE SHARED DIRECTORY ----------------

echo
echo "Creating NFS shared directory..."

mkdir -p "$SHARE_DIR_PATH"
touch "$SHARE_DIR_PATH/$SHARE_DEMO_FILE"

# Safer default permissions than chmod 777.
# Root owns the directory; client write access also depends
# on the UID/GID and permissions used by NFS clients.
chmod 0755 "$SHARE_DIR_PATH"
chmod 0644 "$SHARE_DIR_PATH/$SHARE_DEMO_FILE"

echo "Shared directory created: $SHARE_DIR_PATH"
echo "Demo file created      : $SHARE_DIR_PATH/$SHARE_DEMO_FILE"

# -------------------- CONFIGURE /etc/exports -----------------

echo
echo "Configuring NFS exports..."

# Ensure the exports file exists.
touch "$FILE_PATH"

# Preserve a backup before changing the file.
BACKUP_FILE="${FILE_PATH}.backup.$(date +%Y%m%d-%H%M%S)"
cp -a "$FILE_PATH" "$BACKUP_FILE"

echo "Backup created: $BACKUP_FILE"

# Use a managed block so repeated script runs do not append
# duplicate entries.
python3 - \
    "$FILE_PATH" \
    "$SHARE_DIR_PATH" \
    "$CLIENT_NETWORK" \
    "$EXPORT_OPTIONS" <<'PY'
import sys

file_path, share_dir, client_network, options = sys.argv[1:]

begin = "# BEGIN managed by 04_nfs_server.sh"
end = "# END managed by 04_nfs_server.sh"

block = [
    begin,
    f"{share_dir} {client_network}({options})",
    end,
]

with open(file_path, "r", encoding="utf-8") as file:
    lines = file.read().splitlines()

# Remove only the previous block owned by this script.
updated = []
inside_block = False

for line in lines:
    if line.strip() == begin:
        inside_block = True
        continue

    if inside_block:
        if line.strip() == end:
            inside_block = False
        continue

    updated.append(line)

if inside_block:
    raise SystemExit(
        "ERROR: Managed exports block has no matching END marker."
    )

# Avoid adding an extra blank line to an empty file.
while updated and not updated[-1].strip():
    updated.pop()

if updated:
    updated.append("")

updated.extend(block)

with open(file_path, "w", encoding="utf-8") as file:
    file.write("\n".join(updated) + "\n")
PY

echo
echo "Current managed export entry:"
grep -A 1 -B 1 -F "BEGIN managed by 04_nfs_server.sh" "$FILE_PATH"

# -------------------- VALIDATE EXPORT CONFIGURATION -----------

echo
echo "Validating NFS export configuration..."

if ! exportfs -rav; then
    echo "ERROR: Export validation/application failed."
    echo "Restore the backup if necessary:"
    echo "  cp -a '$BACKUP_FILE' '$FILE_PATH'"
    exit 1
fi

# -------------------- ENABLE AND START NFS SERVER -------------

echo
echo "Enabling and starting NFS server..."

systemctl enable --now nfs-server

if ! systemctl is-active --quiet nfs-server; then
    echo "ERROR: NFS server failed to start."
    systemctl --no-pager --full status nfs-server || true
    journalctl -u nfs-server -n 50 --no-pager || true
    exit 1
fi

# -------------------- CONFIGURE FIREWALL ---------------------

echo
echo "Configuring firewall..."

if systemctl is-active --quiet firewalld; then

    # NFS service opens the NFS port. mountd and rpc-bind
    # are also enabled for compatibility with NFSv3 clients.
    firewall-cmd --permanent --add-service=nfs
    firewall-cmd --permanent --add-service=mountd
    firewall-cmd --permanent --add-service=rpc-bind

    firewall-cmd --reload

    echo "NFS firewall services configured."
    firewall-cmd --list-services

else
    echo "WARNING: firewalld is not active."
    echo "Check firewall rules separately if required."
fi

# -------------------- DISPLAY EXPORTED SHARES ----------------

echo
echo "Exported NFS shares:"
exportfs -v

# -------------------- FINAL VERIFICATION ---------------------

echo
echo "============================================================"
echo "                 NFS SERVER CONFIGURED"
echo "============================================================"
echo

echo "NFS Service Status:"
systemctl --no-pager --full status nfs-server || true

echo
echo "NFS Configuration File:"
echo "  $FILE_PATH"

echo
echo "Shared Directory:"
echo "  $SHARE_DIR_PATH"

echo
echo "Allowed Client Network:"
echo "  $CLIENT_NETWORK"

echo
echo "Demo File:"
echo "  $SHARE_DIR_PATH/$SHARE_DEMO_FILE"

echo
echo "Useful commands:"
echo "  systemctl status nfs-server"
echo "  exportfs -v"
echo "  exportfs -rav"
echo "  cat $FILE_PATH"
echo "  showmount -e localhost"

echo
echo "Example client mount command:"
echo "  mount <NFS_SERVER_IP>:$SHARE_DIR_PATH /mnt"

echo
echo "NOTE:"
echo "- Create /mnt on the client before mounting."
echo "- The client IP must match the exported network."
echo "- File ownership and permissions control write access."
echo "- For SELinux-related denials, check the audit logs."
echo "============================================================"

