#!/bin/bash

# ==========================================================
# Script Name : 09_iscsi_server.sh
# Purpose     : Configure an iSCSI Target Server
# OS          : Rocky Linux / RHEL
# ==========================================================

set -Eeuo pipefail

# ---------- Default Variables (Changeable) ----------
DEFAULT_DISK="/dev/sda"
DEFAULT_PARTITION="/dev/sda1"
DEFAULT_PARTITION_SIZE="10G"

DEFAULT_BACKSTORE="block1"
DEFAULT_TARGET_IQN="iqn.2024-04.com.skynet:target1"
DEFAULT_CLIENT_IQN="iqn.2024-04.com.skynet:client1"

DEFAULT_PORT="3260"

# ---------- Helper Functions ----------
log() {
    echo -e "\n[INFO] $*"
}

error() {
    echo -e "\n[ERROR] $*" >&2
    exit 1
}

ask() {
    local prompt="$1"
    local default="$2"
    local answer

    read -r -p "$prompt [$default]: " answer
    echo "${answer:-$default}"
}

# ---------- Root Check ----------
[[ $EUID -eq 0 ]] || error "Run this script as root."

# ---------- Display Storage Information ----------
log "Available block devices"
lsblk
lsblk -f

# ---------- Collect Variables ----------
echo
echo "========== iSCSI Server Configuration =========="

DISK=$(ask "Disk to use" "$DEFAULT_DISK")
PARTITION=$(ask "Partition for iSCSI storage" "$DEFAULT_PARTITION")
PARTITION_SIZE=$(ask "Partition size for manual partitioning" "$DEFAULT_PARTITION_SIZE")

BACKSTORE=$(ask "Block backstore name" "$DEFAULT_BACKSTORE")
TARGET_IQN=$(ask "iSCSI target IQN" "$DEFAULT_TARGET_IQN")
CLIENT_IQN=$(ask "Client initiator IQN" "$DEFAULT_CLIENT_IQN")
PORT=$(ask "iSCSI TCP port" "$DEFAULT_PORT")

# ---------- Validate Inputs ----------
[[ -b "$DISK" ]] || error "$DISK is not an existing block device."

[[ "$PARTITION" == "$DISK"* ]] ||
    error "Partition $PARTITION does not appear to belong to $DISK."

[[ "$BACKSTORE" =~ ^[a-zA-Z0-9_.-]+$ ]] ||
    error "Invalid backstore name."

[[ "$TARGET_IQN" =~ ^iqn\.[a-zA-Z0-9:.-]+$ ]] ||
    error "Invalid target IQN."

[[ "$CLIENT_IQN" =~ ^iqn\.[a-zA-Z0-9:.-]+$ ]] ||
    error "Invalid client IQN."

[[ "$PORT" =~ ^[0-9]+$ ]] &&
    (( PORT >= 1 && PORT <= 65535 )) ||
    error "Invalid TCP port."

# ---------- Confirm Disk and Partition ----------
echo
echo "========== Review Before Continuing =========="
echo "Disk             : $DISK"
echo "Expected size    : $PARTITION_SIZE"
echo "Partition        : $PARTITION"
echo "Backstore        : $BACKSTORE"
echo "Target IQN       : $TARGET_IQN"
echo "Client IQN       : $CLIENT_IQN"
echo "TCP port         : $PORT"
echo
echo "WARNING: Partitioning the wrong disk can destroy data."
echo "Use a dedicated lab disk and do not format a partition"
echo "that contains data you need."

read -r -p "Open cfdisk to create/check the partition? (y/N): " CREATE_PART

if [[ "$CREATE_PART" =~ ^[Yy]$ ]]; then
    command -v cfdisk >/dev/null 2>&1 ||
        error "cfdisk is unavailable. Install the util-linux package."

    echo
    echo "In cfdisk:"
    echo "1. Inspect the partition table and select FREE SPACE."
    echo "2. Create a $PARTITION_SIZE partition."
    echo "3. Write changes and confirm with yes."
    echo "4. Select Quit."
    echo
    read -r -p "Press Enter to open cfdisk, or Ctrl+C to cancel."
    cfdisk "$DISK"

    partx -u "$DISK" || true
    udevadm settle
fi

# ---------- Verify Partition ----------
lsblk "$DISK"

[[ -b "$PARTITION" ]] ||
    error "Partition $PARTITION does not exist. Create it and rerun the script."

if findmnt -rn -S "$PARTITION" >/dev/null 2>&1; then
    error "$PARTITION is mounted. Do not use a mounted filesystem as a raw iSCSI backstore."
fi

if lsblk -nro FSTYPE "$PARTITION" | grep -q '[^[:space:]]'; then
    echo
    echo "WARNING: $PARTITION appears to contain a filesystem or signature."
    read -r -p "Use this partition as raw iSCSI storage anyway? (type YES): " RAW_CONFIRM
    [[ "$RAW_CONFIRM" == "YES" ]] ||
        error "Cancelled to protect existing data."
fi

echo
read -r -p "Confirm using $PARTITION as raw iSCSI storage? (type YES): " FINAL_CONFIRM
[[ "$FINAL_CONFIRM" == "YES" ]] ||
    error "Cancelled by user."

# ---------- Install Required Packages ----------
log "Installing targetcli and required tools"

dnf install -y targetcli firewalld util-linux

command -v targetcli >/dev/null 2>&1 ||
    error "targetcli command is not available after installation."

# ---------- Check Existing Configuration ----------
log "Checking existing iSCSI configuration"

if targetcli ls | grep -Fq "$BACKSTORE"; then
    error "Backstore $BACKSTORE may already exist. Inspect targetcli ls before rerunning."
fi

if targetcli ls | grep -Fq "$TARGET_IQN"; then
    error "Target $TARGET_IQN may already exist. Inspect targetcli ls before rerunning."
fi

# ---------- Configure iSCSI Target ----------
log "Creating block backstore, target, ACL and LUN"

targetcli <<EOF
/backstores/block create $BACKSTORE $PARTITION
/iscsi create $TARGET_IQN
/iscsi/$TARGET_IQN/tpg1/acls create $CLIENT_IQN
/iscsi/$TARGET_IQN/tpg1/luns create /backstores/block/$BACKSTORE
saveconfig
EOF

# ---------- Enable Target Service ----------
log "Enabling and starting target service"

systemctl enable --now target
systemctl --no-pager --full status target

# ---------- Configure Firewall ----------
log "Configuring firewall"

systemctl enable --now firewalld

if ! firewall-cmd --permanent --query-port="${PORT}/tcp" >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp"
fi

firewall-cmd --reload

# ---------- Validation ----------
log "Checking target service"
systemctl is-active target

log "Checking listening TCP port"
ss -ltnp | grep -E ":${PORT}[[:space:]]" ||
    echo "Note: Port is not shown as listening; inspect target service and TPG state."

log "Checking firewall configuration"
firewall-cmd --list-ports
firewall-cmd --list-services

log "Displaying final iSCSI configuration"
targetcli ls

log "Displaying disk and partition information"
lsblk -f "$DISK"

echo
echo "=================================================="
echo " iSCSI Target Server configuration completed"
echo "=================================================="
echo "Target IQN : $TARGET_IQN"
echo "Client IQN : $CLIENT_IQN"
echo "Backstore  : $BACKSTORE"
echo "Partition  : $PARTITION"
echo "Port       : $PORT"
echo
echo "Next: Configure the iSCSI Initiator on the client."

