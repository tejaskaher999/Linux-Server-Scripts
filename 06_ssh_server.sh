#!/bin/bash

# ============================================================
# 06. SSH SERVER CONFIGURATION
# Rocky Linux / RHEL
# ============================================================

# Check root privileges
if [[ "$EUID" -ne 0 ]]; then
    echo "Please run this script as root."
    exit 1
fi

# Install OpenSSH Server
dnf install openssh-server -y || exit 1

# SSH configuration file
SSHD_CONFIG="/etc/ssh/sshd_config"

# Create a backup before making changes
cp -p "$SSHD_CONFIG" "${SSHD_CONFIG}.bak" || exit 1

# ============================================================
# AUTOMATIC SSH SERVER CONFIGURATION
# ============================================================

# Add/update SSH settings without opening vim
set_ssh_setting() {
    local key="$1"
    local value="$2"

    # Remove existing active or commented directives
    sed -i -E \
        "/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+/d" \
        "$SSHD_CONFIG"

    # Add the required setting
    echo "${key} ${value}" >> "$SSHD_CONFIG"
}

set_ssh_setting "ListenAddress" "192.168.0.254"
set_ssh_setting "LoginGraceTime" "1m"
set_ssh_setting "PermitRootLogin" "yes"
set_ssh_setting "MaxAuthTries" "2"

# Validate SSH configuration
if sshd -t; then
    echo "SSH configuration updated successfully."
else
    echo "Invalid SSH configuration. Restoring backup."
    cp -p "${SSHD_CONFIG}.bak" "$SSHD_CONFIG"
    exit 1
fi

# Restart and enable SSH service
systemctl enable --now sshd || exit 1
systemctl restart sshd || exit 1

# Check SSH service status
systemctl status sshd --no-pager

# Configure firewall for default SSH
firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload
firewall-cmd --list-all

# Display home directories
ls /home/

# Optional connection test:
# ssh root@192.168.0.254


# ============================================================
# PASSWORDLESS AUTHENTICATION
# If the user wants passwordless authentication,
# execute this block.
# ============================================================

read -r -p "Do you want to configure passwordless authentication? (yes/no): " passwordless

if [[ "$passwordless" == "yes" || "$passwordless" == "y" ]]; then

    # Generate SSH key without interactive prompts
    if [[ ! -f /root/.ssh/id_rsa ]]; then
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh

        ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa -q

        if [[ $? -eq 0 ]]; then
            echo "SSH key generated successfully."
        else
            echo "SSH key generation failed."
            exit 1
        fi
    else
        echo "SSH key already exists. Skipping key generation."
    fi

    # Set correct SSH directory and key permissions
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/id_rsa
    chmod 644 /root/.ssh/id_rsa.pub

    # Copy public key to the remote server
    ssh-copy-id -i /root/.ssh/id_rsa.pub root@192.168.0.1

    if [[ $? -eq 0 ]]; then
        echo "Public key copied successfully."

        # Test passwordless authentication without opening a shell
        if ssh -o BatchMode=yes root@192.168.0.1 "true"; then
            echo "Passwordless SSH authentication is working."
        else
            echo "Passwordless authentication test failed."
        fi
    else
        echo "Failed to copy the public key."
    fi

else
    echo "Skipping passwordless authentication configuration."
fi


# ============================================================
# CHANGE SSH PORT
# If the user wants to change the SSH port,
# ask which port to use.
# ============================================================

read -r -p "Do you want to change the SSH port? (yes/no): " change_port

if [[ "$change_port" == "yes" || "$change_port" == "y" ]]; then

    # Install required packages
    dnf install policycoreutils-python-utils net-tools -y || exit 1

    # Display current SSH listening ports
    netstat -tunlp | grep sshd || true

    # Ask user for the new SSH port
    read -r -p "Enter the new SSH port (example: 6006): " SSH_PORT

    # Validate port number
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] ||
       (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        echo "Invalid port number. Use a port between 1 and 65535."
        exit 1
    fi

    # Prevent changing to the existing default SSH port
    if [[ "$SSH_PORT" == "22" ]]; then
        echo "Port 22 is already the default SSH port."
        echo "Choose another port if you want to change it."
        exit 1
    fi

    # Back up the current configuration
    cp -p "$SSHD_CONFIG" "${SSHD_CONFIG}.bak" || exit 1

    # Check whether the requested port is already assigned
    # to an SELinux port type
    if semanage port -l | awk -v p="$SSH_PORT" '
        $2 == "tcp" {
            n = split($3, ports, ",")
            for (i = 1; i <= n; i++) {
                if (ports[i] == p) found = 1
            }
        }
        END { exit !found }
    '; then

        # Check whether it is already an SSH port
        if semanage port -l | awk -v p="$SSH_PORT" '
            $1 == "ssh_port_t" && $2 == "tcp" {
                n = split($3, ports, ",")
                for (i = 1; i <= n; i++) {
                    if (ports[i] == p) found = 1
                }
            }
            END { exit !found }
        '; then
            echo "Port $SSH_PORT is already allowed for SSH in SELinux."
        else
            echo "Port $SSH_PORT is assigned to another SELinux port type."
            echo "Choose a different port or review SELinux configuration."
            exit 1
        fi

    else
        # Add the new port to the SSH SELinux port type
        semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" || exit 1
    fi

    # Automatically update SSH port in sshd_config
    # Remove all active Port directives and add the requested port
    sed -i -E \
        '/^[[:space:]]*Port[[:space:]]+/d' \
        "$SSHD_CONFIG"

    echo "Port ${SSH_PORT}" >> "$SSHD_CONFIG"

    # Validate configuration and restore backup on failure
    if sshd -t; then
        echo "SSH port configured to ${SSH_PORT}."
    else
        echo "Invalid SSH configuration. Restoring backup."
        cp -p "${SSHD_CONFIG}.bak" "$SSHD_CONFIG"
        exit 1
    fi

    # Display SSH SELinux port configuration
    semanage port -l | grep ssh_port_t

    # Configure firewall for the new SSH port
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" || exit 1
    firewall-cmd --reload || exit 1
    firewall-cmd --list-all

    # Restart SSH service
    systemctl restart sshd || {
        echo "SSH restart failed. Restoring previous configuration."
        cp -p "${SSHD_CONFIG}.bak" "$SSHD_CONFIG"
        systemctl restart sshd
        exit 1
    }

    systemctl enable sshd

    # Check SSH service status
    systemctl status sshd --no-pager

    # Display SSH listening ports
    netstat -tunlp | grep sshd || true

    # Test the new port without opening an interactive shell
    echo "Testing SSH connection on port ${SSH_PORT}..."
    ssh -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -p "$SSH_PORT" \
        root@192.168.0.254 "true" \
        && echo "SSH connection test succeeded." \
        || echo "Connection test failed. Verify network access and authentication."

else
    echo "Keeping the default SSH port configuration."
fi


# ============================================================
# END OF SSH SERVER CONFIGURATION
# ============================================================

echo "SSH server configuration script completed."
