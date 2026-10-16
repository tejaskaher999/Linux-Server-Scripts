#!/bin/bash

dnf install vsftpd -y

rpm -q vsftpd

vim /etc/vsftpd/vsftpd.conf

anonymous_enable=YES
anon_upload_enable=YES

write_enable=YES
local_enable=YES

chown ftp:ftp /var/ftp/pub

getsebool -a | grep ftp

setsebool -P ftpd_anon_write on
setsebool -P ftpd_full_access on

systemctl enable --now vsftpd

systemctl status vsftpd

ss -ltnp | grep ':21'

firewall-cmd --permanent --add-service=ftp
firewall-cmd --reload
firewall-cmd --list-all


