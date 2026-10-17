#!/bin/bash

hostnamectl
ip addr

dnf install postfix mutt -y
rpm -q postfix
rpm -q mutt

vim /etc/postfix/main.cf

myhostname = server.skynet.com
mydomain = skynet.com
myorigin = $mydomain
inet_interfaces = all
mydestination = $myhostname, localhost.$mydomain, localhost, $mydomain


postfix check
postconf myhostname
postconf mydomain
postconf mydestination

systemctl enable --now postfix
systemctl status postfix

ss -ltnp | grep ':25'
journalctl -u postfix --no-pager

firewall-cmd --permanent --add-service=smtp
firewall-cmd --reload
firewall-cmd --list-all


