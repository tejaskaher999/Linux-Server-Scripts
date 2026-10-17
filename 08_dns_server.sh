#!/bin/bash

dnf install bind -y

rpm -q bind

vim /etc/named.conf

listen-on port 53 { SERVER_IP; };
allow-query { SERVER_IP_CIDR; };

zone "skynet.com" IN {
    type master;
    file "forward.zone";
};

zone "REVERSE_IP.in-addr.arpa" IN {
    type master;
    file "reverse.zone";
};

cd /var/named

cp -vp named.localhost forward.zone
cp -vp named.loopback reverse.zone

vim /var/named/forward.zone

$TTL 86400
@ IN SOA server.skynet.com. root.skynet.com. (
    2026101501 ; Serial
    3600       ; Refresh
    900        ; Retry
    604800     ; Expire
    86400      ; Negative Cache TTL
)

@                  IN NS     server.skynet.com.

server.skynet.com. IN A      SERVER_IP
skynet.com.        IN A      SERVER_IP
client1.skynet.com. IN A     IP_1
client2.skynet.com. IN A     IP_2

www.skynet.com.    IN CNAME  server.skynet.com.

@                  IN MX 10  server.skynet.com.

vim /var/named/reverse.zone

$TTL 86400
@ IN SOA server.skynet.com. root.skynet.com. (
    2026101501 ; Serial
    3600       ; Refresh
    900        ; Retry
    604800     ; Expire
    86400      ; Negative Cache TTL
)

@   IN NS   server.skynet.com.

254 IN PTR  server.skynet.com.
1   IN PTR  client1.skynet.com.
2   IN PTR  client2.skynet.com.


ls -lZ /var/named/forward.zone /var/named/reverse.zone

restorecon -v /var/named/forward.zone /var/named/reverse.zone

named-checkconf /etc/named.conf

named-checkzone skynet.com /var/named/forward.zone
named-checkzone REVERSE_IP.in-addr.arpa /var/named/reverse.zone

vim /etc/resolv.conf

search skynet.com
nameserver SERVER_IP

systemctl enable --now named
systemctl status named

ss -lntup | grep ':53'
firewall-cmd --permanent --add-service=dns
firewall-cmd --reload
firewall-cmd --list-all


