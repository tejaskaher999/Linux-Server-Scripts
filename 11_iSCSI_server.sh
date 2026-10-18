#!/bin/bash

lsblk
lsblk -f

cfdisk /dev/sda

Select the DOS partition-table label if appropriate for the lab disk.
Select the free space.
Select New.
Enter the partition size: 10G.
Select Primary if prompted.
Select Write.
Type yes to confirm writing the partition table.
Select Quit.

partx -u /dev/sda

lsblk

dnf install targetcli -y

targetcli

/> ls

/> backstores/block create block1 /dev/sda1

/> iscsi/ create iqn.2024-04.com.skynet:target1

/> cd iscsi/iqn.2024-04.com.skynet:target1/tpg1

/> ls

/> acls/ create iqn.2024-04.com.skynet:client1

/> luns/ create /backstores/block/block1

/> cd /
/> ls

Check that the configuration contains:

The block1 block backstore
The target iqn.2024-04.com.skynet:target1
The expected target portal group
The client ACL
The LUN mapping

/> exit

systemctl enable --now target

systemctl status target

firewall-cmd --permanent --add-service=iscsi-target
firewall-cmd --reload
firewall-cmd --list-services

firewall-cmd --get-services

firewall-cmd --permanent --add-port=3260/tcp
firewall-cmd --reload
ss -ltnp | grep ':3260'


