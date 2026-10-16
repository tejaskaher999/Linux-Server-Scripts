
#!/bin/bash

# ============================================================
# RHEL / ROCKY LINUX LOCAL YUM-DNF SERVER CONFIGURATION
# ============================================================

# ------------------------------------------------------------
# 1. Default Variables
# ------------------------------------------------------------

HTTP_PATH="/var/www/html/rhel"
AUTO_MOUNT_PATH="/dev/sr0"
MOUNT_PATH="/mnt"
PACKAGE_NAME=("AppStream" "BaseOS")
REPO_CONFIG_PATH="/etc/yum.repos.d/local.repo"

# ------------------------------------------------------------
# 2. Check Root Privileges
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Error: Please run this script as root."
    echo "Usage: sudo bash yum_server.sh"
    exit 1
fi

# ------------------------------------------------------------
# 3. Display Current Variable Values
# ------------------------------------------------------------

echo
echo "============================================================"
echo "       LOCAL YUM/DNF SERVER CONFIGURATION"
echo "============================================================"
echo
echo "Current variable values:"
echo
echo "1. HTTP_PATH          = $HTTP_PATH"
echo "2. AUTO_MOUNT_PATH    = $AUTO_MOUNT_PATH"
echo "3. MOUNT_PATH         = $MOUNT_PATH"
echo "4. PACKAGE_NAME       = ${PACKAGE_NAME[*]}"
echo "5. REPO_CONFIG_PATH   = $REPO_CONFIG_PATH"
echo
echo "============================================================"

# ------------------------------------------------------------
# 4. Ask Whether to Modify Variables
# ------------------------------------------------------------

read -rp "Do you want to modify any variable? (yes/no): " MODIFY

case "$MODIFY" in
    yes|YES|Yes|y|Y)

        echo
        echo "Press ENTER to keep the current value."
        echo

        read -rp "HTTP_PATH [$HTTP_PATH]: " INPUT
        HTTP_PATH="${INPUT:-$HTTP_PATH}"

        read -rp "AUTO_MOUNT_PATH [$AUTO_MOUNT_PATH]: " INPUT
        AUTO_MOUNT_PATH="${INPUT:-$AUTO_MOUNT_PATH}"

        read -rp "MOUNT_PATH [$MOUNT_PATH]: " INPUT
        MOUNT_PATH="${INPUT:-$MOUNT_PATH}"

        read -rp "PACKAGE_NAME [${PACKAGE_NAME[*]}] (space-separated): " INPUT
        if [[ -n "$INPUT" ]]; then
            read -r -a PACKAGE_NAME <<< "$INPUT"
        fi

        read -rp "REPO_CONFIG_PATH [$REPO_CONFIG_PATH]: " INPUT
        REPO_CONFIG_PATH="${INPUT:-$REPO_CONFIG_PATH}"

        echo
        echo "Updated variable values:"
        echo
        echo "HTTP_PATH          = $HTTP_PATH"
        echo "AUTO_MOUNT_PATH    = $AUTO_MOUNT_PATH"
        echo "MOUNT_PATH         = $MOUNT_PATH"
        echo "PACKAGE_NAME       = ${PACKAGE_NAME[*]}"
        echo "REPO_CONFIG_PATH   = $REPO_CONFIG_PATH"
        echo

        read -rp "Proceed with these values? (yes/no): " CONFIRM

        case "$CONFIRM" in
            yes|YES|Yes|y|Y)
                echo "Proceeding with updated values..."
                ;;
            *)
                echo "Operation cancelled by user."
                exit 0
                ;;
        esac
        ;;

    no|NO|No|n|N)
        echo
        echo "Using the default variable values..."
        ;;

    *)
        echo "Invalid choice. Please run the script again."
        exit 1
        ;;
esac

# ------------------------------------------------------------
# 5. Validate Variables
# ------------------------------------------------------------

if [[ -z "$HTTP_PATH" || -z "$AUTO_MOUNT_PATH" ||
      -z "$MOUNT_PATH" || -z "$REPO_CONFIG_PATH" ||
      ${#PACKAGE_NAME[@]} -eq 0 ]]; then
    echo "Error: One or more required variables are empty."
    exit 1
fi

if [[ "$HTTP_PATH" != /* || "$MOUNT_PATH" != /* ||
      "$REPO_CONFIG_PATH" != /* ]]; then
    echo "Error: HTTP_PATH, MOUNT_PATH and REPO_CONFIG_PATH"
    echo "must be absolute paths."
    exit 1
fi

if [[ "$HTTP_PATH" == "/" || "$MOUNT_PATH" == "/" ]]; then
    echo "Error: HTTP_PATH and MOUNT_PATH cannot be /."
    exit 1
fi

# ------------------------------------------------------------
# 6. Prepare Repository Directory
# ------------------------------------------------------------

echo
echo "Creating repository directory..."
mkdir -p "$HTTP_PATH" || exit 1

# ------------------------------------------------------------
# 7. Mount ISO and Copy Packages
# ------------------------------------------------------------

if mountpoint -q "$MOUNT_PATH"; then
    echo "Error: $MOUNT_PATH is already a mount point."
    echo "Unmount it or choose another MOUNT_PATH."
    exit 1
fi

if [[ ! -b "$AUTO_MOUNT_PATH" ]]; then
    echo "Error: ISO device $AUTO_MOUNT_PATH not found."
    echo "Check the attached DVD/ISO device."
    exit 1
fi

echo
echo "Mounting ISO..."
mount -o ro "$AUTO_MOUNT_PATH" "$MOUNT_PATH" || exit 1

for i in "${PACKAGE_NAME[@]}"; do
    if [[ ! -d "$MOUNT_PATH/$i" ]]; then
        echo "Error: $i directory not found on mounted ISO."
        umount "$MOUNT_PATH"
        exit 1
    fi

    echo
    echo "Copying $i to $HTTP_PATH..."
    cp -ivRu "$MOUNT_PATH/$i" "$HTTP_PATH/" || {
        echo "Error: Failed to copy $i."
        umount "$MOUNT_PATH"
        exit 1
    }
done

# ------------------------------------------------------------
# 8. Restore SELinux Context and Unmount ISO
# ------------------------------------------------------------

echo
echo "Restoring SELinux contexts..."
restorecon -Rv "$HTTP_PATH"

echo
echo "Unmounting ISO..."
umount "$MOUNT_PATH" || {
    echo "Error: Could not unmount $MOUNT_PATH."
    exit 1
}

# ------------------------------------------------------------
# 9. Create Local Repository Configuration
# ------------------------------------------------------------

echo
echo "Creating local repository configuration..."

if [[ -f "$REPO_CONFIG_PATH" ]]; then
    cp -a "$REPO_CONFIG_PATH" \
        "${REPO_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)" ||
        exit 1
fi

: > "$REPO_CONFIG_PATH" || {
    echo "Error: Cannot write to $REPO_CONFIG_PATH."
    exit 1
}

for i in "${PACKAGE_NAME[@]}"; do
    cat >> "$REPO_CONFIG_PATH" <<EOF
[$i]
name=$i Local Repository
baseurl=file://$HTTP_PATH/$i
gpgcheck=0
metadata_expire=-1
enabled=1

EOF
done

echo
echo "Repository configuration:"
cat "$REPO_CONFIG_PATH"

# ------------------------------------------------------------
# 10. Clean Cache and Check Local Repositories
# ------------------------------------------------------------

echo
echo "Cleaning DNF cache..."
dnf clean all || exit 1

echo
echo "Refreshing local repository metadata..."
dnf --disablerepo='*' \
    --enablerepo="$(IFS=,; echo "${PACKAGE_NAME[*]}")" makecache ||
    exit 1

echo
echo "Configured local repositories:"
dnf --disablerepo='*' \
    --enablerepo="$(IFS=,; echo "${PACKAGE_NAME[*]}")" repolist -v

# ------------------------------------------------------------
# 11. Install Apache HTTP Server
# ------------------------------------------------------------

echo
echo "Installing HTTPD..."
dnf --disablerepo='*' \
    --enablerepo="$(IFS=,; echo "${PACKAGE_NAME[*]}")" \
    install httpd -y || {
        echo "Error: HTTPD installation failed."
        exit 1
    }

# ------------------------------------------------------------
# 12. Enable and Start Apache
# ------------------------------------------------------------

echo
echo "Enabling and restarting HTTPD..."
systemctl enable --now httpd || exit 1
systemctl restart httpd || exit 1

# ------------------------------------------------------------
# 13. Configure Firewall
# ------------------------------------------------------------

if systemctl is-active --quiet firewalld; then
    echo
    echo "Opening HTTP service in the firewall..."
    firewall-cmd --permanent --add-service=http || exit 1
    firewall-cmd --reload || exit 1
    firewall-cmd --list-all
else
    echo "Warning: firewalld is not running."
    echo "Check firewall/network rules if clients cannot connect."
fi


# ------------------------------------------------------------
# 14. Display Server IP and Correct Repository URLs
# ------------------------------------------------------------

echo
echo "============================================================"
echo "       LOCAL YUM/DNF SERVER SETUP COMPLETED"
echo "============================================================"

SERVER_IP=$(hostname -I | awk '{print $1}')

# Convert the filesystem path into an HTTP URL path.
# Apache document root: /var/www/html
HTTP_URL_PATH="${HTTP_PATH#/var/www/html}"

echo
echo "Server IP: $SERVER_IP"
echo "Repository directory: $HTTP_PATH"
echo

for i in "${PACKAGE_NAME[@]}"; do
    echo "$i: http://$SERVER_IP${HTTP_URL_PATH}/$i/"
done

echo
echo "Test repository metadata using:"

for i in "${PACKAGE_NAME[@]}"; do
    echo "curl -I http://$SERVER_IP${HTTP_URL_PATH}/$i/repodata/repomd.xml"
done

echo
echo "============================================================"

