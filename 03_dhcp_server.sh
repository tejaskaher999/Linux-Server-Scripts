#!/bin/bash

# Variables Which Can Any System Admin Change As Per Their Need!
FILE_PATH="/etc/dhcp/dhcpd.conf"
SERVER_IP="192.168.0.254"
SERVER_IP_CLASS="192.168.0.0"
SERVER_IP_CIDR="192.168.0.0/24"
NETMASK="255.255.255.0"
RANGE_START="192.168.0.10"
RANGE_END="192.168.0.100"
DOMAIN_NAME="example.com"

# Installing DHCP Server Package
dnf install dhcp-server -y

# Configuring DHCP Server
echo "subnet $SERVER_IP_CLASS netmask $NETMASK {" >> "$FILE_PATH"
echo "  option domain-name \"$DOMAIN_NAME\";" >> "$FILE_PATH"
echo "  option domain-name-servers $SERVER_IP;" >> "$FILE_PATH"
echo "  range $RANGE_START $RANGE_END;" >> "$FILE_PATH"
echo "  option routers $SERVER_IP;" >> "$FILE_PATH"
echo "}" >> "$FILE_PATH"

# Service Restart & Enable
systemctl restart dhcpd
systemctl enable dhcpd

# Adding Service To Firewall
firewall-cmd --permanent --add-service=dhcp
firewall-cmd --reload
firewall-cmd --list-all