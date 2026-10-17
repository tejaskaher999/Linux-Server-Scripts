#!/bin/bash

dnf install httpd -y

vim /etc/httpd/conf/httpd.conf

<VirtualHost *:80>
    ServerAdmin root@server.skynet.com
    DocumentRoot /var/www/html
    ServerName server.skynet.com
    ErrorLog logs/server-error_log
    CustomLog logs/server-access_log common
</VirtualHost>

httpd -t

echo "Welcome to web server" > /var/www/html/index.html

cat /var/www/html/index.html

systemctl enable --now httpd

systemctl status httpd

firewall-cmd --permanent --add-service=http
firewall-cmd --reload

firewall-cmd --list-services

# If else block to ask if you want to configure the same website for the name based virtual hosting.

mkdir /var/www/virtual
echo "Welcome to virtual web server" > /var/www/virtual/index.html
cat /var/www/virtual/index.html

vim /etc/httpd/conf/httpd.conf

<VirtualHost *:80>
    ServerAdmin alex@www.skynet.com
    DocumentRoot /var/www/virtual
    ServerName www.skynet.com
    ErrorLog logs/www-error_log
    CustomLog logs/www-access_log common
</VirtualHost>

httpd -t

systemctl restart httpd
systemctl enable httpd

systemctl status httpd

firefox http://www.skynet.com

