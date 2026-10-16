#!/bin/bash

# ============================================================
# 06. SSH SERVER CONFIGURATION
# Rocky Linux 10
# ============================================================

set -o pipefail

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_CONFIG="/etc/ssh/sshd_config.bak"
KEY_FILE="/root/.ssh/id_ed25519"

# ------------------------------------------------------------
# Check root privileges
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run this script as root."
    echo "Example: sudo ./06_ssh_server.sh"
    exit 1
fi

# ------------------------------------------------------------
# Detect server IP address
# ------------------------------------------------------------

SERVER_IP=$(ip -4 -o addr show scope global |
    awk 'NR == 1 {split($4, a, "/"); print a[1]}')

if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

echo "============================================================"
echo "06. SSH SERVER CONFIGURATION"
echo "============================================================"
echo "Server IP: ${SERVER_IP:-Not detected}"
echo

# ------------------------------------------------------------
# Install required packages
# ------------------------------------------------------------

dnf install -y openssh-server policycoreutils-python-utils

if [[ $? -ne 0 ]]; then
    echo "ERROR: Required packages could not be installed."
    exit 1
fi

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

# Remove a setting from the main SSH configuration file.
# Handles active settings and commented-out settings.

remove_ssh_setting() {
    local setting="$1"

    awk -v key="$setting" '
    {
        if (tolower($1) == tolower(key)) {
            next
        }

        if ($1 == "#" && tolower($2) == tolower(key)) {
            next
        }

        print
    }' "$SSHD_CONFIG" > "${SSHD_CONFIG}.tmp" || return 1

    cat "${SSHD_CONFIG}.tmp" > "$SSHD_CONFIG"
    rm -f "${SSHD_CONFIG}.tmp"
}

# Set a setting in the main SSH configuration file.

set_ssh_setting() {
    local setting="$1"
    local value="$2"

    remove_ssh_setting "$setting" || return 1
    printf '%s %s\n' "$setting" "$value" >> "$SSHD_CONFIG"
}

# Validate SSH configuration syntax.

validate_ssh_config() {
    sshd -t -f "$SSHD_CONFIG"
}

# Check whether a TCP port is already listening.

port_is_listening() {
    local port="$1"

    ss -H -ltn | awk -v p=":$port" '
    $4 ~ (p "$") { found=1 }
    END { exit !found }
    '
}

# Find the SELinux type assigned to a TCP port.
#
# IMPORTANT:
# An explicit port mapping takes priority over a generic
# SELinux port range.

get_selinux_port_type() {
    local port="$1"

    semanage port -l 2>/dev/null | awk -v port="$port" '
    $2 == "tcp" {
        type = $1

        for (i = 3; i <= NF; i++) {
            token = $i
            gsub(/,/, "", token)

            # Explicit port assignment
            if (token ~ /^[0-9]+$/ && token == port) {
                exact_type = type
            }

            # Port range assignment
            if (token ~ /^[0-9]+-[0-9]+$/) {
                split(token, range, "-")

                if (port >= range[1] && port <= range[2]) {
                    if (range_type == "") {
                        range_type = type
                    }
                }
            }
        }
    }

    END {
        if (exact_type != "") {
            print exact_type
        } else if (range_type != "") {
            print range_type
        }
    }
    '
}

# ------------------------------------------------------------
# Back up the SSH configuration
# ------------------------------------------------------------

if [[ ! -f "$SSHD_CONFIG" ]]; then
    echo "ERROR: $SSHD_CONFIG was not found."
    exit 1
fi

cp -a "$SSHD_CONFIG" "$BACKUP_CONFIG" || {
    echo "ERROR: Could not back up SSH configuration."
    exit 1
}

# ------------------------------------------------------------
# Configure basic SSH settings
# ------------------------------------------------------------

echo
echo "Configuring SSH settings..."

set_ssh_setting "LoginGraceTime" "1m" || exit 1
set_ssh_setting "PermitRootLogin" "yes" || exit 1
set_ssh_setting "MaxAuthTries" "2" || exit 1

# Do not bind SSH to a hardcoded IP address.
remove_ssh_setting "ListenAddress" || exit 1

if ! validate_ssh_config; then
    echo "ERROR: Invalid SSH configuration."
    cp -a "$BACKUP_CONFIG" "$SSHD_CONFIG"
    exit 1
fi

CURRENT_PORT=$(sshd -T 2>/dev/null |
    awk '$1 == "port" {print $2; exit}')

echo "Currently configured SSH port: ${CURRENT_PORT:-Unknown}"

# ------------------------------------------------------------
# Optional passwordless authentication
# Supports same-machine and remote-machine SSH
# ------------------------------------------------------------

echo
read -r -p \
"Do you want to configure passwordless authentication? (yes/no): " \
PASSWORDLESS_CHOICE

if [[ "$PASSWORDLESS_CHOICE" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then

    echo
    echo "Configuring SSH key authentication..."

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # Create a key if it does not exist. If only the public key is
    # missing, recreate it from the existing private key.
    if [[ ! -f "$KEY_FILE" ]]; then
        ssh-keygen -t ed25519 -N "" -f "$KEY_FILE" || {
            echo "ERROR: SSH key generation failed."
            exit 1
        }
    elif [[ ! -f "${KEY_FILE}.pub" ]]; then
        ssh-keygen -y -f "$KEY_FILE" > "${KEY_FILE}.pub" || {
            echo "ERROR: Could not recreate the public key."
            exit 1
        }
    fi

    chmod 600 "$KEY_FILE"
    chmod 644 "${KEY_FILE}.pub"

    read -r -p "Enter remote target (user@host): " REMOTE_TARGET
    read -r -p "Enter remote SSH port [22]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}

    if [[ ! "$REMOTE_PORT" =~ ^[0-9]+$ ]] ||
       (( REMOTE_PORT < 1 || REMOTE_PORT > 65535 )); then
        echo "ERROR: Invalid remote SSH port."
        exit 1
    fi

    if [[ "$REMOTE_TARGET" != *@* ]]; then
        echo "ERROR: Enter the target as user@host."
        exit 1
    fi

    REMOTE_USER="${REMOTE_TARGET%@*}"
    REMOTE_HOST="${REMOTE_TARGET##*@}"

    if [[ -z "$REMOTE_USER" || -z "$REMOTE_HOST" ]]; then
        echo "ERROR: Invalid remote target."
        exit 1
    fi

    # Detect whether the destination is this machine by checking
    # local hostnames and all local IPv4 addresses.
    IS_LOCAL=false
    LOCAL_HOSTNAME=$(hostname 2>/dev/null)
    LOCAL_FQDN=$(hostname -f 2>/dev/null || true)

    if [[ "$REMOTE_HOST" == "localhost" ||
          "$REMOTE_HOST" == "127.0.0.1" ||
          "$REMOTE_HOST" == "::1" ||
          "$REMOTE_HOST" == "$LOCAL_HOSTNAME" ||
          ( -n "$LOCAL_FQDN" && "$REMOTE_HOST" == "$LOCAL_FQDN" ) ]]; then
        IS_LOCAL=true
    fi

    LOCAL_IPS=$(ip -o -4 addr show |
        awk '{split($4, a, "/"); print a[1]}')

    if printf '%s\n' "$LOCAL_IPS" | grep -Fxq -- "$REMOTE_HOST"; then
        IS_LOCAL=true
    fi

    # Also detect a hostname that resolves to one of this machine's IPs.
    if [[ "$IS_LOCAL" == false ]]; then
        while read -r RESOLVED_IP; do
            if printf '%s\n' "$LOCAL_IPS" | grep -Fxq -- "$RESOLVED_IP"; then
                IS_LOCAL=true
                break
            fi
        done < <(getent ahostsv4 "$REMOTE_HOST" 2>/dev/null |
                 awk '{print $1}' | sort -u)
    fi

    if [[ "$IS_LOCAL" == true ]]; then

        # Same machine: install the key directly into the target
        # account's authorized_keys, avoiding a password SSH login.
        echo "Same-machine target detected."
        echo "Installing the public key locally..."

        USER_INFO=$(getent passwd "$REMOTE_USER")

        if [[ -z "$USER_INFO" ]]; then
            echo "ERROR: Local user '$REMOTE_USER' does not exist."
            exit 1
        fi

        USER_HOME=$(printf '%s\n' "$USER_INFO" | cut -d: -f6)
        USER_GROUP=$(id -gn "$REMOTE_USER" 2>/dev/null)

        if [[ -z "$USER_HOME" || ! -d "$USER_HOME" || -z "$USER_GROUP" ]]; then
            echo "ERROR: Could not determine the home directory or group for '$REMOTE_USER'."
            exit 1
        fi

        SSH_DIR="${USER_HOME}/.ssh"
        AUTH_KEYS="${SSH_DIR}/authorized_keys"

        mkdir -p "$SSH_DIR"
        touch "$AUTH_KEYS"

        # Avoid adding duplicate public keys.
        if ! grep -qxF "$(cat "${KEY_FILE}.pub")" "$AUTH_KEYS"; then
            cat "${KEY_FILE}.pub" >> "$AUTH_KEYS" || {
                echo "ERROR: Could not install the public key."
                exit 1
            }
            echo "Public key added to $AUTH_KEYS."
        else
            echo "Public key is already installed."
        fi

        chown -R "${REMOTE_USER}:${USER_GROUP}" "$SSH_DIR" || {
            echo "ERROR: Could not set ownership on $SSH_DIR."
            exit 1
        }

        chmod 700 "$SSH_DIR"
        chmod 600 "$AUTH_KEYS"

        if command -v restorecon >/dev/null 2>&1; then
            restorecon -RF "$SSH_DIR" >/dev/null 2>&1 || true
        fi

    else

        # Remote machine: copy the key. Restrict SSH to the intended
        # identity to prevent 'Too many authentication failures'.
        echo "Remote-machine target detected."
        echo "Copying the public key to ${REMOTE_TARGET}..."

        if ! ssh-copy-id \
            -i "${KEY_FILE}.pub" \
            -o "IdentitiesOnly=yes" \
            -o "IdentityFile=${KEY_FILE}" \
            -p "$REMOTE_PORT" \
            "$REMOTE_TARGET"; then

            echo "ERROR: ssh-copy-id failed."
            echo "Check the remote username, host, port and credentials."
            echo "Confirm that the remote account can log in using SSH."
            exit 1
        fi
    fi

    # Test using public-key authentication only.
    echo
    echo "Testing passwordless authentication..."

    if ssh \
        -i "$KEY_FILE" \
        -o IdentitiesOnly=yes \
        -o PreferredAuthentications=publickey \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -p "$REMOTE_PORT" \
        "$REMOTE_TARGET" \
        "echo 'Passwordless SSH works'"; then

        echo "SUCCESS: Passwordless SSH authentication is working."
    else
        echo "ERROR: Passwordless authentication test failed."
        echo "Check the SSH port, public key, authorized_keys permissions,"
        echo "and the server's PubkeyAuthentication setting."
    fi

else
    echo "Skipping passwordless authentication configuration."
fi

# ------------------------------------------------------------
# Optional SSH port change
# ------------------------------------------------------------

echo
read -r -p \
"Do you want to change the SSH port? (yes/no): " \
CHANGE_PORT

if [[ "$CHANGE_PORT" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then

    SSH_PORT=""

    while true; do

        echo

        if systemctl is-active --quiet sshd; then
            echo "Current SSH listening ports:"
            ss -ltnp | grep sshd || true
        fi

        read -r -p \
"Enter the new SSH port (example: 2222): " SSH_PORT

        # Validate numeric input.
        if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]]; then
            echo "ERROR: Enter a numeric port."
            continue
        fi

        if (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
            echo "ERROR: Port must be between 1 and 65535."
            continue
        fi

        # Require a custom port instead of the default SSH port.
        if (( SSH_PORT == 22 )); then
            echo "Port 22 is the default SSH port."
            echo "Choose a custom port."
            continue
        fi

        # Reject ports already used by another listener.
        # Allow the currently configured port.
        if [[ "$SSH_PORT" != "$CURRENT_PORT" ]] &&
           port_is_listening "$SSH_PORT"; then
            echo "Port $SSH_PORT is already listening."
            echo "Choose another port."
            continue
        fi

        # ----------------------------------------------------
        # SELinux port handling
        # ----------------------------------------------------

        SELINUX_TYPE=$(get_selinux_port_type "$SSH_PORT")

        if [[ "$SELINUX_TYPE" == "ssh_port_t" ]]; then

            echo "Port $SSH_PORT is already allowed for SSH in SELinux."

        elif [[ -z "$SELINUX_TYPE" ]]; then

            echo "No SELinux port mapping was found for $SSH_PORT."
            echo "Adding an explicit SSH mapping..."

            if semanage port -a -t ssh_port_t \
                -p tcp "$SSH_PORT"; then

                echo "SUCCESS: SELinux mapping added."
            else
                echo "ERROR: Could not add the SELinux mapping."
                echo "Choose another port."
                continue
            fi

        elif [[ "$SELINUX_TYPE" == "unreserved_port_t" ]]; then

            echo "Port $SSH_PORT is covered by SELinux type:"
            echo "$SELINUX_TYPE"

            read -r -p \
"Add an explicit SSH SELinux mapping for this port? (yes/no): " \
            SELINUX_CHOICE

            if [[ "$SELINUX_CHOICE" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then

                # FIX:
                # Use -a, not -m. The port may only be covered
                # by a generic range and have no explicit entry.

                if semanage port -a -t ssh_port_t \
                    -p tcp "$SSH_PORT"; then

                    echo "SUCCESS: Port $SSH_PORT assigned to ssh_port_t."
                else
                    echo "ERROR: SELinux reassignment failed."
                    echo "Choose another port."
                    continue
                fi

            else
                echo "Keeping the existing SELinux assignment."
                continue
            fi

        elif [[ "$SELINUX_TYPE" == "ephemeral_port_t" ]]; then

            echo "Port $SSH_PORT is assigned to ephemeral_port_t."
            echo "Choose a different port."
            continue

        else

            echo "Port $SSH_PORT is assigned to SELinux type:"
            echo "$SELINUX_TYPE"
            echo "The existing service assignment will be preserved."
            echo "Choose another port."
            continue

        fi

        # Confirm that SELinux now recognizes the SSH mapping.
        SELINUX_TYPE=$(get_selinux_port_type "$SSH_PORT")

        if [[ "$SELINUX_TYPE" != "ssh_port_t" ]]; then
            echo "ERROR: SSH SELinux mapping could not be verified."
            echo "Choose another port."
            continue
        fi

        break
    done

else

    SSH_PORT="$CURRENT_PORT"

    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT=22
    fi

    echo "Keeping the current SSH port: $SSH_PORT"
fi

# ------------------------------------------------------------
# Apply selected SSH port
# ------------------------------------------------------------

echo
echo "Selected SSH port: $SSH_PORT"

# Back up the current config before changing the port.
cp -a "$SSHD_CONFIG" "$BACKUP_CONFIG" || {
    echo "ERROR: Could not back up SSH configuration."
    exit 1
}

if [[ "$CHANGE_PORT" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
    remove_ssh_setting "Port" || {
        echo "ERROR: Could not update SSH port setting."
        cp -a "$BACKUP_CONFIG" "$SSHD_CONFIG"
        exit 1
    }

    printf 'Port %s\n' "$SSH_PORT" >> "$SSHD_CONFIG"
fi

# ------------------------------------------------------------
# Validate before changing firewall or restarting SSH
# ------------------------------------------------------------

if ! validate_ssh_config; then
    echo "ERROR: SSH configuration validation failed."
    echo "Restoring the previous configuration..."
    cp -a "$BACKUP_CONFIG" "$SSHD_CONFIG"
    exit 1
fi

# ------------------------------------------------------------
# Configure firewall
# ------------------------------------------------------------

echo
echo "Configuring firewall..."

if systemctl is-active --quiet firewalld; then

    firewall-cmd --permanent --add-service=ssh

    if ! firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"; then
        echo "ERROR: Could not add the port to the firewall."
        cp -a "$BACKUP_CONFIG" "$SSHD_CONFIG"
        exit 1
    fi

    if ! firewall-cmd --reload; then
        echo "ERROR: Firewall reload failed."
        cp -a "$BACKUP_CONFIG" "$SSHD_CONFIG"
        exit 1
    fi

    echo
    echo "Current firewall configuration:"
    firewall-cmd --list-all

else
    echo "WARNING: firewalld is not active."
    echo "Configure the firewall before connecting remotely."
fi

# ------------------------------------------------------------
# Enable and restart SSH
# ------------------------------------------------------------

echo
echo "Enabling and restarting SSH service..."

if ! systemctl enable sshd; then
    echo "ERROR: Could not enable sshd."
    exit 1
fi

if ! systemctl restart sshd; then
    echo "ERROR: SSH restart failed."
    echo "Restoring the previous SSH configuration..."

    cp -a "$BACKUP_CONFIG" "$SSHD_CONFIG"
    systemctl restart sshd

    exit 1
fi

# ------------------------------------------------------------
# Verify SSH service
# ------------------------------------------------------------

echo
systemctl --no-pager --full status sshd

echo
echo "Listening SSH ports:"
ss -tlnp | grep sshd || true

EFFECTIVE_PORT=$(sshd -T 2>/dev/null |
    awk '$1 == "port" {print $2; exit}')

if [[ -z "$EFFECTIVE_PORT" ]]; then
    echo "ERROR: Could not determine the effective SSH port."
    exit 1
fi

# ------------------------------------------------------------
# Local TCP connectivity test
# ------------------------------------------------------------

echo
echo "Testing TCP connection to ${SERVER_IP}:${EFFECTIVE_PORT}..."

if [[ -n "$SERVER_IP" ]] &&
   timeout 3 bash -c \
   ":</dev/tcp/${SERVER_IP}/${EFFECTIVE_PORT}" 2>/dev/null; then

    echo "SUCCESS: SSH port $EFFECTIVE_PORT is reachable locally."

else
    echo "WARNING: Local TCP connection test failed."
    echo "Check the server IP, firewall and SSH listener."
fi

# ------------------------------------------------------------
# Final output
# ------------------------------------------------------------

echo
echo "============================================================"
echo "SSH SERVER CONFIGURATION COMPLETED"
echo "============================================================"
echo "Server IP   : $SERVER_IP"
echo "SSH Port    : $EFFECTIVE_PORT"
echo "SSH Service : $(systemctl is-active sshd)"
echo
echo "Connect from another machine using:"
echo "ssh -p $EFFECTIVE_PORT root@$SERVER_IP"
echo "============================================================"
echo
echo "IMPORTANT: Keep your current session open until you verify"
echo "that a new SSH connection works on the selected port."

