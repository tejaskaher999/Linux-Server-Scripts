#!/bin/bash

# ============================================================
# 06. SSH SERVER CONFIGURATION
# ============================================================

# Install OpenSSH Server
dnf install openssh-server -y

# Backup SSH configuration before making changes
cp -p /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Edit SSH configuration file
vim /etc/ssh/sshd_config

# Add/update the following settings in sshd_config:
#
# ListenAddress 192.168.0.254
# LoginGraceTime 1m
# PermitRootLogin yes
# MaxAuthTries 2

# Validate SSH configuration
sshd -t || exit 1

# Restart and enable SSH service
systemctl restart sshd
systemctl enable --now sshd

# Check SSH service status
systemctl status sshd --no-pager

# Configure firewall for SSH
firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload
firewall-cmd --list-all

# Connect to SSH server
ssh root@192.168.0.254

# List home directories
ls /home/

exit


# ============================================================
# PASSWORDLESS AUTHENTICATION
# If the user wants passwordless authentication,
# execute this block.
# ============================================================

read -r -p "Do you want to configure passwordless authentication? (yes/no): " passwordless

if [[ "$passwordless" == "yes" || "$passwordless" == "y" ]]; then

    # Generate SSH key
    ssh-keygen -t rsa
    # Press Enter
    # Press Enter
    # Press Enter

    # Copy public key to the remote server
    ssh-copy-id -i /root/.ssh/id_rsa.pub root@192.168.0.1

    # Test passwordless authentication
    ssh root@192.168.0.1

    exit

    # Set correct SSH directory and key permissions
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/id_rsa
    chmod 644 /root/.ssh/id_rsa.pub

else
    echo "Skipping passwordless authentication configuration."
fi


# ============================================================
# CHANGE SSH PORT
# If the user wants to change the SSH port,
# execute this block and ask which port to use.
# ============================================================

read -r -p "Do you want to change the SSH port? (yes/no): " change_port

if [[ "$change_port" == "yes" || "$change_port" == "y" ]]; then

    # Display current SSH listening port
    netstat -tunlp | grep sshd

    # Ask user for the new SSH port
    read -r -p "Enter the new SSH port (example: 6006): " SSH_PORT

    # Validate port number
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] ||
       (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        echo "Invalid port number. Please use a port between 1 and 65535."
        exit 1
    fi

    # Install required packages
    dnf install policycoreutils-python-utils -y
    dnf install net-tools -y

    # Edit SSH configuration file
    vim /etc/ssh/sshd_config

    # Add/update the following setting in sshd_config:
    #
    # Port 6006
    #
    # Replace 6006 with the port entered by the user.
    # Make sure there is only one active Port setting.

    # Validate SSH configuration
    sshd -t || exit 1

    # Configure SELinux for the new SSH port
    if semanage port -l | grep -q "^ssh_port_t.*\b${SSH_PORT}\b"; then
        echo "Port $SSH_PORT is already configured for SSH in SELinux."
    elif semanage port -l | grep -qE "^[^[:space:]]+[[:space:]]+tcp[[:space:]]+.*(^|,|[[:space:]])${SSH_PORT}([,[:space:]]|$)"; then
        echo "Port $SSH_PORT is already assigned to another SELinux port type."
        echo "Choose a different port or review the existing SELinux configuration."
        exit 1
    else
        semanage port -a -t ssh_port_t -p tcp "$SSH_PORT"
    fi

    # Display SSH SELinux port configuration
    semanage port -l | grep ssh_port_t

    # Configure firewall for the new SSH port
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
    firewall-cmd --reload
    firewall-cmd --list-all

    # Restart and enable SSH service
    systemctl restart sshd
    systemctl enable sshd

    # Check SSH service status
    systemctl status sshd --no-pager

    # Display SSH listening ports
    netstat -tunlp | grep sshd

    # Test connection using the new SSH port
    ssh root@192.168.0.254 -p "$SSH_PORT"

    exit

else
    echo "Keeping the default SSH port configuration."
fi

# ============================================================
# END OF SSH SERVER CONFIGURATION
# ============================================================
