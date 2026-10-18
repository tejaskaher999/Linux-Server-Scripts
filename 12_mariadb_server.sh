#!/bin/bash

# ==========================================================
# Script Name : 10_mariadb_server.sh
# Purpose     : Install and configure MariaDB Server
# OS          : Rocky Linux / RHEL
# ==========================================================

set -Eeuo pipefail

# ---------- Changeable Default Variables ----------
DEFAULT_DB="skynet"
DEFAULT_TABLE="student"
DEFAULT_DB_USER1="alex"
DEFAULT_DB_USER2="susan"
DEFAULT_BACKUP="/root/skynet.dump"
DEFAULT_PORT="3306"
DEFAULT_CONFIG="/etc/my.cnf.d/99-lab-server.cnf"

CONFIG_FILE="$DEFAULT_CONFIG"
BACKUP_FILE="$DEFAULT_BACKUP"

# ---------- Helper Functions ----------
log() {
    echo -e "\n[INFO] $*"
}

error() {
    echo -e "\n[ERROR] $*" >&2
    exit 1
}

ask() {
    local prompt="$1"
    local default="$2"
    local answer
    read -r -p "$prompt [$default]: " answer
    echo "${answer:-$default}"
}

# ---------- Root Check ----------
[[ $EUID -eq 0 ]] || error "Run this script as root."

# ---------- Collect Configuration ----------
echo "========== MariaDB Server Configuration =========="

DB_NAME=$(ask "Database name" "$DEFAULT_DB")
TABLE_NAME=$(ask "Table name" "$DEFAULT_TABLE")
DB_USER1=$(ask "Full-access local user" "$DEFAULT_DB_USER1")
DB_USER2=$(ask "Read/update local user" "$DEFAULT_DB_USER2")
DB_PORT=$(ask "MariaDB TCP port" "$DEFAULT_PORT")
CONFIG_FILE=$(ask "MariaDB configuration file" "$DEFAULT_CONFIG")
BACKUP_FILE=$(ask "Backup file path" "$DEFAULT_BACKUP")

echo
echo "Select database access:"
echo "1. Local access only (recommended for lab default)"
echo "2. Enable network access on TCP port $DB_PORT"
read -r -p "Choice [1]: " ACCESS_CHOICE
ACCESS_CHOICE=${ACCESS_CHOICE:-1}

[[ "$ACCESS_CHOICE" == "1" || "$ACCESS_CHOICE" == "2" ]] ||
    error "Invalid access choice."

[[ "$DB_PORT" =~ ^[0-9]+$ ]] &&
    (( DB_PORT >= 1 && DB_PORT <= 65535 )) ||
    error "Invalid TCP port."

# Validate SQL identifiers to avoid unsafe SQL interpolation.
for identifier in "$DB_NAME" "$TABLE_NAME" "$DB_USER1" "$DB_USER2"; do
    [[ "$identifier" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] ||
        error "Invalid database, table, or username: $identifier"
done

[[ "$DB_USER1" != "$DB_USER2" ]] ||
    error "The two database usernames must be different."

[[ "$CONFIG_FILE" == /* ]] ||
    error "Configuration path must be absolute."

[[ "$BACKUP_FILE" == /* ]] ||
    error "Backup path must be absolute."

echo
echo "Database       : $DB_NAME"
echo "Table          : $TABLE_NAME"
echo "Full user      : $DB_USER1"
echo "Read/update user: $DB_USER2"
echo "TCP port       : $DB_PORT"
echo "Config file    : $CONFIG_FILE"
echo "Backup file    : $BACKUP_FILE"
echo "Network access : $([[ "$ACCESS_CHOICE" == "1" ]] && echo "Disabled" || echo "Enabled")"
echo

read -r -p "Continue with installation/configuration? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || error "Cancelled by user."

# ---------- Install Packages ----------
log "Installing MariaDB server and firewall packages"

dnf install -y mariadb-server firewalld

command -v mariadb >/dev/null 2>&1 ||
    error "MariaDB client command was not found."

# ---------- Configure MariaDB ----------
log "Creating MariaDB configuration"

mkdir -p "$(dirname "$CONFIG_FILE")"

if [[ -f "$CONFIG_FILE" ]]; then
    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    log "Existing configuration backed up."
fi

if [[ "$ACCESS_CHOICE" == "1" ]]; then
    cat > "$CONFIG_FILE" <<EOF
[mysqld]
port=$DB_PORT
skip-networking=1
EOF
else
    cat > "$CONFIG_FILE" <<EOF
[mysqld]
port=$DB_PORT
skip-networking=0
bind-address=0.0.0.0
EOF
fi

chmod 644 "$CONFIG_FILE"

echo "Configuration written to: $CONFIG_FILE"
cat "$CONFIG_FILE"

# ---------- Start Service ----------
log "Enabling and starting MariaDB"

systemctl enable --now mariadb
systemctl restart mariadb

systemctl is-active --quiet mariadb ||
    error "MariaDB failed to start. Check: journalctl -u mariadb"

# ---------- Secure Installation ----------
echo
read -r -p "Run mariadb-secure-installation interactively? (y/N): " SECURE_CHOICE

if [[ "$SECURE_CHOICE" =~ ^[Yy]$ ]]; then
    if command -v mariadb-secure-installation >/dev/null 2>&1; then
        mariadb-secure-installation
    else
        echo "mariadb-secure-installation command not found; skipping."
    fi
fi

# ---------- Root Database Connection ----------
# On typical Rocky Linux installations, root can authenticate
# through the local Unix socket. This script does not assume
# that MariaDB root has a password.
DB_CLIENT=(mariadb)

if ! "${DB_CLIENT[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
    echo
    echo "Local socket login did not work."
    echo "If root uses password authentication, enter the password below."
    read -r -s -p "MariaDB root password: " ROOT_PASSWORD
    echo

    MYSQL_PWD="$ROOT_PASSWORD" mariadb -u root -e "SELECT 1;" >/dev/null 2>&1 ||
        error "Cannot connect as MariaDB root. Check authentication."

    DB_CLIENT=(mariadb -u root -p"$ROOT_PASSWORD")
    unset ROOT_PASSWORD
fi

# ---------- Create Database and Table ----------
log "Creating database and student table"

"${DB_CLIENT[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
USE \`$DB_NAME\`;

CREATE TABLE IF NOT EXISTS \`$TABLE_NAME\` (
    ID INT PRIMARY KEY,
    NAME VARCHAR(50),
    EMAIL VARCHAR(100),
    Address VARCHAR(100)
);

INSERT INTO \`$TABLE_NAME\` (ID, NAME, EMAIL, Address)
VALUES
    (1, 'kishor', 'k@gmail.com', 'nashik'),
    (2, 'radhika', 'r@gmail.com', 'pune')
ON DUPLICATE KEY UPDATE
    NAME = VALUES(NAME),
    EMAIL = VALUES(EMAIL),
    Address = VALUES(Address);

SHOW DATABASES;
SHOW TABLES;
DESCRIBE \`$TABLE_NAME\`;
SELECT * FROM \`$TABLE_NAME\`;
SQL

# ---------- Create Local Database Users ----------
log "Creating local database users"

echo
echo "Enter passwords for the database users."
echo "Allowed characters: letters, digits, underscore, ! @ # . -"
echo "Use strong passwords; do not use the example password 'redhat'."

read -r -s -p "Password for $DB_USER1: " PASS1
echo
read -r -s -p "Password for $DB_USER2: " PASS2
echo

[[ "$PASS1" =~ ^[a-zA-Z0-9_!@#.-]+$ ]] ||
    error "Password for $DB_USER1 contains unsupported characters."

[[ "$PASS2" =~ ^[a-zA-Z0-9_!@#.-]+$ ]] ||
    error "Password for $DB_USER2 contains unsupported characters."

[[ -n "$PASS1" && -n "$PASS2" ]] ||
    error "Passwords cannot be empty."

"${DB_CLIENT[@]}" <<SQL
CREATE USER IF NOT EXISTS '$DB_USER1'@'localhost' IDENTIFIED BY '$PASS1';
CREATE USER IF NOT EXISTS '$DB_USER2'@'localhost' IDENTIFIED BY '$PASS2';

GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER1'@'localhost';
GRANT SELECT, UPDATE ON \`$DB_NAME\`.* TO '$DB_USER2'@'localhost';

SHOW GRANTS FOR '$DB_USER1'@'localhost';
SHOW GRANTS FOR '$DB_USER2'@'localhost';
SQL

unset PASS1 PASS2

# ---------- Firewall ----------
if [[ "$ACCESS_CHOICE" == "2" ]]; then
    log "Enabling firewall and opening MariaDB TCP port"

    systemctl enable --now firewalld

    firewall-cmd --permanent --add-port="${DB_PORT}/tcp"
    firewall-cmd --reload

    echo "WARNING: TCP port ${DB_PORT} is open in the active firewall zone."
    echo "For production, restrict access to trusted client IP addresses."
else
    log "Local-only mode selected; no MariaDB firewall port opened."
fi

# ---------- Verification ----------
log "Checking MariaDB service"
systemctl --no-pager --full status mariadb

log "Checking MariaDB configuration"
echo "Configuration file: $CONFIG_FILE"

log "Checking database and sample data"
"${DB_CLIENT[@]}" -e "
SHOW DATABASES LIKE '$DB_NAME';
USE \`$DB_NAME\`;
SHOW TABLES;
SELECT * FROM \`$TABLE_NAME\`;
"

if [[ "$ACCESS_CHOICE" == "2" ]]; then
    log "Checking TCP listener"
    ss -ltnp | grep -E ":${DB_PORT}[[:space:]]" ||
        echo "WARNING: No listener detected on port $DB_PORT."
fi

echo
echo "=================================================="
echo " MariaDB Server setup completed"
echo "=================================================="
echo "Database : $DB_NAME"
echo "Table    : $TABLE_NAME"
echo "Service  : mariadb"
echo "Port     : $DB_PORT"
echo "Config   : $CONFIG_FILE"
echo "Backup   : $BACKUP_FILE"
echo
echo "To connect locally:"
echo "  mariadb"
echo
echo "To create a backup:"
echo "  mariadb-dump $DB_NAME > '$BACKUP_FILE'"
echo
echo "To restore a backup:"
echo "  mariadb $DB_NAME < '$BACKUP_FILE'"
echo
echo "Service logs:"
echo "  journalctl -u mariadb"
echo "=================================================="

