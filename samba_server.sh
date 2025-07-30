#!/bin/bash

# Variables Which Can Any System Admin Change As Per Their Need!
SHARE_DIR_PATH="/data"
SHARE_FILE_NAME="demo.txt"
SAMBA_USERNAME="tejas"
SAMBA_PASSWORD="redhat"
SAMBA_CONF_FILE="/etc/samba/smb.conf"
SERVER_IP_CIDR="192.168.0.0/24"

# Installing SAMBA Package To Give Access To Clients To Access It!
dnf install samba -y

# Creating Share Directories, User and Giving Permissions!
mkdir -p $SHARE_DIR_PATH
touch $SHARE_DIR_PATH/$SHARE_FILE_NAME
ls -lZ $SHARE_DIR_PATH
chcon -R -t samba_share_t $SHARE_DIR_PATH
ls -lZ $SHARE_DIR_PATH
useradd -r $SAMBA_USERNAME
echo -e "$SAMBA_PASSWORD\n$SAMBA_PASSWORD" | smbpasswd -a "$SAMBA_USERNAME"

# Configuring SAMBA Server
echo "[$SHARE_DIR_PATH]" >> $SAMBA_CONF_FILE
echo "comment = Shared Folder $SHARE_DIR_PATH" >> $SAMBA_CONF_FILE
echo "path = $SHARE_DIR_PATH" >> $SAMBA_CONF_FILE
echo "valid users = $SAMBA_USERNAME" >> $SAMBA_CONF_FILE
echo "writeable = yes" >> $SAMBA_CONF_FILE
echo "browseable = yes" >> $SAMBA_CONF_FILE
echo "hosts allow = $SERVER_IP_CIDR" >> $SAMBA_CONF_FILE

# Giving Neccessary Permissions
testparm -s
setfacl -m u:$SAMBA_USERNAME:rwx $SHARE_DIR_PATH

# Service Restart & Enable
systemctl restart smb
systemctl enable smb

# Adding Service To Firewall
firewall-cmd --permanent --add-service=samba
firewall-cmd --reload
firewall-cmd --list-all