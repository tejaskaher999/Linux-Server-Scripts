#!/bin/bash

# Variables Which Can Any System Admin Change As Per Their Need!
FILE_PATH="/etc/exports"
SERVER_IP_CLASS="192.168.0.0/24"
SHARE_DIR_PATH="/srv/nfs"
SHARE_DEMO_FILE="export.txt"

dnf install nfs-utils -y

mkdir -p "$SHARE_DIR_PATH"
touch "$SHARE_DIR_PATH/$SHARE_DEMO_FILE"
chmod 777 $SHARE_DIR_PATH

# Configuring NFS Exports
echo "$SHARE_DIR_PATH *(ro,sync)" >> "$FILE_PATH"
echo "$SHARE_DIR_PATH $SERVER_IP_CLASS(rw,sync)" >> "$FILE_PATH"

# Service Restart & Enable
systemctl restart nfs-server
systemctl enable nfs-server

# Exporting NFS Shares
exportfs -ar
exportfs

# Adding Service To Firewall
firewall-cmd --permanent --add-service=nfs
firewall-cmd --reload
firewall-cmd --list-all