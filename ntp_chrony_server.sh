#!/bin/bash

# Variables Which Can Any System Admin Change As Per Their Need!
FILE_PATH="/etc/chrony.conf"
SERVER_IP="192.168.0.254"
SERVER_IP_CIDR="192.168.0.0/24"

# Installing NTP Package To Give Access To Clients To Access It!
dnf install chrony -y

# Configuring NTP Server
sed -i -e "3{/iburst/ s/^/#/}" -e "4i server $SERVER_IP iburst" -e "27i allow $SERVER_IP_CIDR" -e "30i local stratum 10" "$FILE_PATH"

# Service Restart & Enable
systemctl restart chronyd
systemctl enable chronyd

# Adding Service To Firewall
firewall-cmd --permanent --add-service=ntp
firewall-cmd --reload
firewall-cmd --list-all