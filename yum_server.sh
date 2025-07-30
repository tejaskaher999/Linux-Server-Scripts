#!/bin/bash

# Variables Which Can Any System Admin Change As Per Their Need!
HTTP_PATH=/var/www/html/rhel
AUTO_MOUNT_PATH=/dev/sr1
MOUNT_PATH=/mnt
PACKAGE_NAME=("AppStream" "BaseOS")
REPO_CONFIG_PATH=/etc/yum.repos.d/local.repo

# Copy The Packages To Own Server From ISO File
mkdir -p $HTTP_PATH
mount $AUTO_MOUNT_PATH $MOUNT_PATH
cd $MOUNT_PATH
cp -ivRu ${PACKAGE_NAME[0]} ${PACKAGE_NAME[1]} $HTTP_PATH
restorecon -Rv $HTTP_PATH
cd
umount $MOUNT_PATH
touch $REPO_CONFIG_PATH

# Creating Repo File With It's Content
# Looping Through Package Names To Create Repo File
for i in "${PACKAGE_NAME[@]}";
do
    echo "[${i}]" >> $REPO_CONFIG_PATH
    echo "name=${i}" >> $REPO_CONFIG_PATH
    echo "baseurl=file://$HTTP_PATH/${i}" >> $REPO_CONFIG_PATH
    echo "gpgcheck=0" >> $REPO_CONFIG_PATH
    echo "metadata_expire=-1" >> $REPO_CONFIG_PATH
    echo "enabled=1" >> $REPO_CONFIG_PATH
    echo "" >> $REPO_CONFIG_PATH
done

# Or You Can Use The Below Command To Create Repo File
# Uncomment the below lines to create a repo file manually

# echo "[${PACKAGE_NAME[0]}]" > $REPO_CONFIG_PATH
# echo "name=${PACKAGE_NAME[0]}" >> $REPO_CONFIG_PATH
# echo "baseurl=file://$HTTP_PATH/${PACKAGE_NAME[0]}" >> $REPO_CONFIG_PATH
# echo "gpgcheck=0" >> $REPO_CONFIG_PATH
# echo "metadata_expire=-1" >> $REPO_CONFIG_PATH
# echo "enabled=1" >> $REPO_CONFIG_PATH

# echo "[${PACKAGE_NAME[1]}]" >> $REPO_CONFIG_PATH
# echo "name=${PACKAGE_NAME[1]}" >> $REPO_CONFIG_PATH
# echo "baseurl=file://$HTTP_PATH/${PACKAGE_NAME[1]}" >> $REPO_CONFIG_PATH
# echo "gpgcheck=0" >> $REPO_CONFIG_PATH
# echo "metadata_expire=-1" >> $REPO_CONFIG_PATH
# echo "enabled=1" >> $REPO_CONFIG_PATH

# Set Up & Check Repos
dnf clean all
dnf repolist all -v

# Installing HTTPD Package To Give Access To Clients To Access It!
dnf install httpd -y

# Service Restart & Enable
systemctl restart httpd
systemctl enable httpd

# Adding Service To Firewall
firewall-cmd --permanent --add-service=http
firewall-cmd --reload
firewall-cmd --list-all