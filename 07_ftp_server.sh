#!/bin/bash

# ============================================================
# RHEL / ROCKY LINUX FTP SERVER CONFIGURATION
# ============================================================

# ------------------------------------------------------------
# 1. Default Variables
# ------------------------------------------------------------

FTP_PACKAGE="vsftpd"
FTP_SERVICE="vsftpd"
FTP_CONFIG="/etc/vsftpd/vsftpd.conf"
FTP_PUB_DIR="/var/ftp/pub"
FTP_PORT="21"

ANONYMOUS_ENABLE="YES"
ANON_UPLOAD_ENABLE="NO"
WRITE_ENABLE="YES"
LOCAL_ENABLE="YES"

# ------------------------------------------------------------
# 2. Check Root Privileges
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Error: Please run this script as root."
    echo "Usage: sudo bash 03_ftp_server.sh"
    exit 1
fi

# ------------------------------------------------------------
# 3. Display Variables
# ------------------------------------------------------------

echo
echo "============================================================"
echo "              FTP SERVER CONFIGURATION"
echo "============================================================"
echo "FTP_PACKAGE       = $FTP_PACKAGE"
echo "FTP_SERVICE       = $FTP_SERVICE"
echo "FTP_CONFIG        = $FTP_CONFIG"
echo "FTP_PUB_DIR       = $FTP_PUB_DIR"
echo "FTP_PORT          = $FTP_PORT"
echo "ANONYMOUS_ENABLE  = $ANONYMOUS_ENABLE"
echo "ANON_UPLOAD_ENABLE= $ANON_UPLOAD_ENABLE"
echo "WRITE_ENABLE      = $WRITE_ENABLE"
echo "LOCAL_ENABLE      = $LOCAL_ENABLE"
echo "============================================================"

read -rp "Do you want to modify variables? (yes/no): " MODIFY

case "$MODIFY" in
    yes|YES|Yes|y|Y)
        read -rp "FTP package [$FTP_PACKAGE]: " INPUT
        FTP_PACKAGE="${INPUT:-$FTP_PACKAGE}"

        read -rp "FTP service [$FTP_SERVICE]: " INPUT
        FTP_SERVICE="${INPUT:-$FTP_SERVICE}"

        read -rp "FTP config [$FTP_CONFIG]: " INPUT
        FTP_CONFIG="${INPUT:-$FTP_CONFIG}"

        read -rp "FTP public directory [$FTP_PUB_DIR]: " INPUT
        FTP_PUB_DIR="${INPUT:-$FTP_PUB_DIR}"

        read -rp "FTP port [$FTP_PORT]: " INPUT
        FTP_PORT="${INPUT:-$FTP_PORT}"

        read -rp "Allow anonymous access? YES/NO [$ANONYMOUS_ENABLE]: " INPUT
        ANONYMOUS_ENABLE="${INPUT:-$ANONYMOUS_ENABLE}"

        read -rp "Allow anonymous uploads? YES/NO [$ANON_UPLOAD_ENABLE]: " INPUT
        ANON_UPLOAD_ENABLE="${INPUT:-$ANON_UPLOAD_ENABLE}"

        read -rp "Enable write commands? YES/NO [$WRITE_ENABLE]: " INPUT
        WRITE_ENABLE="${INPUT:-$WRITE_ENABLE}"

        read -rp "Allow local users? YES/NO [$LOCAL_ENABLE]: " INPUT
        LOCAL_ENABLE="${INPUT:-$LOCAL_ENABLE}"
        ;;

    no|NO|No|n|N)
        echo "Using default values..."
        ;;

    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

# ------------------------------------------------------------
# 4. Validate Configuration
# ------------------------------------------------------------

for VALUE in "$ANONYMOUS_ENABLE" "$ANON_UPLOAD_ENABLE" \
             "$WRITE_ENABLE" "$LOCAL_ENABLE"; do
    if [[ ! "$VALUE" =~ ^(YES|NO)$ ]]; then
        echo "Error: Boolean settings must be YES or NO."
        exit 1
    fi
done

if [[ ! "$FTP_PORT" =~ ^[0-9]+$ ]] ||
   (( FTP_PORT < 1 || FTP_PORT > 65535 )); then
    echo "Error: Invalid FTP port."
    exit 1
fi

if [[ "$FTP_CONFIG" != /* || "$FTP_PUB_DIR" != /* ]]; then
    echo "Error: Configuration and public paths must be absolute."
    exit 1
fi

if [[ "$ANON_UPLOAD_ENABLE" == "YES" &&
      "$ANONYMOUS_ENABLE" != "YES" ]]; then
    echo "Error: Anonymous uploads require anonymous access."
    exit 1
fi

echo
echo "Selected FTP configuration:"
echo "FTP service: $FTP_SERVICE"
echo "FTP config: $FTP_CONFIG"
echo "FTP public directory: $FTP_PUB_DIR"
echo "FTP port: $FTP_PORT"
echo "Anonymous access: $ANONYMOUS_ENABLE"
echo "Anonymous uploads: $ANON_UPLOAD_ENABLE"
echo "Local users: $LOCAL_ENABLE"

read -rp "Continue with these settings? (yes/no): " CONFIRM

case "$CONFIRM" in
    yes|YES|Yes|y|Y) ;;
    *) echo "Operation cancelled."; exit 0 ;;
esac

# ------------------------------------------------------------
# 5. Install FTP Package
# ------------------------------------------------------------

echo
echo "Installing FTP server..."
dnf install -y "$FTP_PACKAGE" || exit 1

rpm -q "$FTP_PACKAGE" || exit 1

if [[ ! -f "$FTP_CONFIG" ]]; then
    echo "Error: FTP configuration not found: $FTP_CONFIG"
    exit 1
fi

# ------------------------------------------------------------
# 6. Back Up Configuration
# ------------------------------------------------------------

BACKUP_PATH="${FTP_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

cp -a "$FTP_CONFIG" "$BACKUP_PATH" || exit 1

echo "Configuration backup: $BACKUP_PATH"

# ------------------------------------------------------------
# 7. Update vsftpd Configuration
# ------------------------------------------------------------

set_config() {
    local KEY="$1"
    local VALUE="$2"

    if grep -qE "^[[:space:]]*${KEY}=" "$FTP_CONFIG"; then
        sed -i -E \
            "s|^[[:space:]]*${KEY}=.*|${KEY}=${VALUE}|" \
            "$FTP_CONFIG"
    else
        echo "${KEY}=${VALUE}" >> "$FTP_CONFIG"
    fi
}

set_config anonymous_enable "$ANONYMOUS_ENABLE"
set_config anon_upload_enable "$ANON_UPLOAD_ENABLE"
set_config write_enable "$WRITE_ENABLE"
set_config local_enable "$LOCAL_ENABLE"
set_config listen "YES"
set_config listen_ipv6 "NO"
set_config listen_port "$FTP_PORT"

# ------------------------------------------------------------
# 8. Prepare Public FTP Directory
# ------------------------------------------------------------

mkdir -p "$FTP_PUB_DIR" || exit 1

chown ftp:ftp "$FTP_PUB_DIR" || exit 1

chmod 755 "$FTP_PUB_DIR"

# ------------------------------------------------------------
# 9. Configure SELinux
# ------------------------------------------------------------

if command -v getsebool >/dev/null 2>&1; then
    echo
    echo "Current FTP SELinux booleans:"
    getsebool -a | grep ftp || true

    if [[ "$ANON_UPLOAD_ENABLE" == "YES" ]]; then
        echo "Enabling SELinux anonymous FTP write access..."
        setsebool -P ftpd_anon_write on || exit 1
    fi

    if command -v semanage >/dev/null 2>&1; then
        if ! semanage port -l | grep -E \
            "^ftp_port_t[[:space:]]" |
            grep -qw "$FTP_PORT"; then
            echo "Checking whether FTP port needs an SELinux label..."
            if ! semanage port -a -t ftp_port_t -p tcp "$FTP_PORT"; then
                echo "Warning: Could not add the SELinux FTP port label."
                echo "Check whether the port is already assigned."
            fi
        fi
    fi
fi

# ------------------------------------------------------------
# 10. Configure Firewall
# ------------------------------------------------------------

if systemctl is-active --quiet firewalld; then
    echo
    echo "Configuring firewall..."

    firewall-cmd --permanent --add-port="${FTP_PORT}/tcp" || exit 1
    firewall-cmd --permanent --add-service=ftp || exit 1

    firewall-cmd --reload || exit 1
    firewall-cmd --list-all
else
    echo "Warning: firewalld is not running."
fi

# ------------------------------------------------------------
# 11. Enable and Start FTP Service
# ------------------------------------------------------------

echo
echo "Enabling FTP service..."
systemctl enable --now "$FTP_SERVICE" || exit 1

systemctl restart "$FTP_SERVICE" || exit 1

echo
echo "FTP service status:"
systemctl --no-pager --full status "$FTP_SERVICE"

# ------------------------------------------------------------
# 12. Verify FTP Server
# ------------------------------------------------------------

echo
echo "Checking listening TCP port $FTP_PORT..."
ss -ltnp | grep -E ":${FTP_PORT}[[:space:]]" || true

echo
echo "Checking FTP package:"
rpm -q "$FTP_PACKAGE"

echo
echo "Checking SELinux FTP booleans:"
getsebool -a 2>/dev/null | grep ftp || true

# ------------------------------------------------------------
# 13. Display Server Information
# ------------------------------------------------------------

SERVER_IP=$(hostname -I | awk '{print $1}')

echo
echo "============================================================"
echo "              FTP SERVER SETUP COMPLETED"
echo "============================================================"
echo "Server IP: $SERVER_IP"
echo "FTP port: $FTP_PORT"
echo "Public directory: $FTP_PUB_DIR"
echo "Anonymous access: $ANONYMOUS_ENABLE"
echo "Anonymous uploads: $ANON_UPLOAD_ENABLE"
echo
echo "Connect from a client using:"
echo "ftp $SERVER_IP $FTP_PORT"
echo
echo "Note: Standard FTP sends credentials and data without"
echo "encryption. Use SFTP or FTPS for sensitive transfers."
echo "============================================================"

