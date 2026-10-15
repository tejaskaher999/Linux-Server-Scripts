#!/bin/bash

dnf install openssh-server -y

vim /etc/ssh/sshd_config

ListenAddress 192.168.0.254
LoginGraceTime 1m
PermitRootLogin yes
MaxAuthTries 2

sshd -t

systemctl restart sshd

systemctl enable --now sshd

systemctl status sshd

firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload
firewall-cmd --list-all

ssh root@192.168.0.254

ls /home/

exit

# If else condition if user wants to have the passwordless authentication then this block should execute.

ssh-keygen -t rsa
[Enter]
[Enter]
[Enter]

ssh-copy-id -i /root/.ssh/id_rsa.pub root@192.168.0.1

ssh root@192.168.0.1

exit

chmod 700 /root/.ssh
chmod 600 /root/.ssh/id_rsa
chmod 644 /root/.ssh/id_rsa.pub


# If else condition if user wants to the change the port for the SSH then only this next block should have executed and it should ask to give input from user that which port you want to use.

netstat -tunlp | grep sshd

vim /etc/ssh/sshd_config

Port 6006

sshd -t

semanage port -a -t ssh_port_t -p tcp 6006

dnf install policycoreutils-python-utils -y

semanage port -a -t ssh_port_t -p tcp 6006

semanage port -l | grep ssh_port_t

firewall-cmd --permanent --add-port=6006/tcp

firewalld-cmd --reload

firewall-cmd --list-all

systemctl restart sshd
systemctl enable sshd

systemctl status sshd

netstat -tunlp | grep sshd

ssh root@192.168.0.254 -p 6006

exit


