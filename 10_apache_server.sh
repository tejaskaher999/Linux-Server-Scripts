#!/bin/bash

# ============================================================
# INTERACTIVE APACHE WEB SERVER SETUP
# Supported OS: RHEL / Rocky Linux
# Package: httpd
# Default HTTP Port: 80
# ============================================================

# -------------------- DEFAULT VARIABLES ---------------------

DEFAULT_SERVER_NAME="server.skynet.com"
DEFAULT_DOMAIN="skynet.com"
DEFAULT_ADMIN_EMAIL="root@server.skynet.com"
DEFAULT_DOCUMENT_ROOT="/var/www/html"
DEFAULT_WELCOME_MESSAGE="Welcome to web server"

DEFAULT_VIRTUAL_HOST="www.skynet.com"
DEFAULT_VIRTUAL_ADMIN="alex@www.skynet.com"
DEFAULT_VIRTUAL_ROOT="/var/www/virtual"
DEFAULT_VIRTUAL_MESSAGE="Welcome to virtual web server"

DEFAULT_HTTP_PORT="80"

# -------------------- COLORS --------------------------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# -------------------- FUNCTIONS -----------------------------

print_line() {
    echo "============================================================"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

ask_value() {
    local prompt="$1"
    local default="$2"
    local result

    read -r -p "$prompt [$default]: " result
    echo "${result:-$default}"
}

valid_hostname() {
    local name="$1"

    [[ ${#name} -le 253 &&
       "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ &&
       "$name" != *..* ]] || return 1

    local label
    local IFS='.'

    read -r -a labels <<< "$name"

    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 &&
           "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] ||
            return 1
    done
}

valid_document_root() {
    local path="$1"

    [[ "$path" == /* &&
       "$path" != *" "* &&
       "$path" != *".."* &&
       "$path" != "/" ]]
}

# -------------------- ROOT CHECK ----------------------------

if [[ $EUID -ne 0 ]]; then
    error "Run this script as root."
    echo "Example: sudo bash 10_apache_web_server.sh"
    exit 1
fi

# -------------------- OS CHECK ------------------------------

if [[ ! -f /etc/os-release ]]; then
    error "Cannot identify the operating system."
    exit 1
fi

source /etc/os-release

if [[ "$ID" != "rocky" && "$ID" != "rhel" &&
      "${ID_LIKE:-}" != *"rhel"* ]]; then
    error "This script supports RHEL / Rocky Linux."
    exit 1
fi

# -------------------- DETECT SERVER IP ----------------------

SERVER_IP=$(
    ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{
        for (i=1; i<=NF; i++)
            if ($i=="src") { print $(i+1); exit }
    }'
)

if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(
        ip -o -4 addr show scope global |
        awk 'NR==1 {
            split($4,a,"/");
            print a[1]
        }'
    )
fi

SERVER_IP=${SERVER_IP:-127.0.0.1}

HTTP_PORT="$DEFAULT_HTTP_PORT"

# -------------------- HEADER --------------------------------

clear
print_line
echo "         INTERACTIVE APACHE WEB SERVER SETUP"
echo "              RHEL / ROCKY LINUX"
print_line
echo "Press Enter to accept the displayed defaults."
echo

echo -e "${BLUE}Current Host Information${NC}"
hostnamectl
echo
ip -br addr
echo

# -------------------- PRIMARY WEBSITE -----------------------

echo
print_line
echo "             PRIMARY WEBSITE CONFIGURATION"
print_line

SERVER_NAME=$(ask_value \
    "Primary website hostname (FQDN)" "$DEFAULT_SERVER_NAME")

ADMIN_EMAIL=$(ask_value \
    "Primary website administrator email" "$DEFAULT_ADMIN_EMAIL")

DOCUMENT_ROOT=$(ask_value \
    "Primary website document root" "$DEFAULT_DOCUMENT_ROOT")

WELCOME_MESSAGE=$(ask_value \
    "Primary website welcome message" "$DEFAULT_WELCOME_MESSAGE")

# -------------------- VIRTUAL HOST OPTION -------------------

echo
read -r -p \
"Do you want to configure a second name-based virtual host? (y/n): " \
CONFIGURE_VHOST

CONFIGURE_VHOST=${CONFIGURE_VHOST:-n}

if [[ "$CONFIGURE_VHOST" =~ ^[Yy]$ ]]; then
    CONFIGURE_VHOST="yes"

    echo
    print_line
    echo "          VIRTUAL HOST CONFIGURATION"
    print_line

    VIRTUAL_HOST=$(ask_value \
        "Virtual website hostname (FQDN)" "$DEFAULT_VIRTUAL_HOST")

    VIRTUAL_ADMIN=$(ask_value \
        "Virtual website administrator email" "$DEFAULT_VIRTUAL_ADMIN")

    VIRTUAL_ROOT=$(ask_value \
        "Virtual website document root" "$DEFAULT_VIRTUAL_ROOT")

    VIRTUAL_MESSAGE=$(ask_value \
        "Virtual website welcome message" "$DEFAULT_VIRTUAL_MESSAGE")
else
    CONFIGURE_VHOST="no"
    VIRTUAL_HOST=""
    VIRTUAL_ADMIN=""
    VIRTUAL_ROOT=""
    VIRTUAL_MESSAGE=""
fi

# -------------------- VALIDATION ----------------------------

if ! valid_hostname "$SERVER_NAME"; then
    error "Invalid primary website hostname: $SERVER_NAME"
    exit 1
fi

if ! valid_document_root "$DOCUMENT_ROOT"; then
    error "Document root must be an absolute path without spaces or '..'."
    exit 1
fi

if [[ "$CONFIGURE_VHOST" == "yes" ]]; then
    if ! valid_hostname "$VIRTUAL_HOST"; then
        error "Invalid virtual hostname: $VIRTUAL_HOST"
        exit 1
    fi

    if [[ "$SERVER_NAME" == "$VIRTUAL_HOST" ]]; then
        error "Primary and virtual hostnames must be different."
        exit 1
    fi

    if ! valid_document_root "$VIRTUAL_ROOT"; then
        error "Virtual document root must be an absolute path without spaces or '..'."
        exit 1
    fi

    if [[ "$DOCUMENT_ROOT" == "$VIRTUAL_ROOT" ]]; then
        error "Use different document roots for the two websites."
        exit 1
    fi
fi

# -------------------- CONFIGURATION SUMMARY -----------------

echo
print_line
echo "             CONFIGURATION SUMMARY"
print_line
echo "Server IP          : $SERVER_IP"
echo "HTTP Port          : $HTTP_PORT"
echo "Primary hostname   : $SERVER_NAME"
echo "Primary admin      : $ADMIN_EMAIL"
echo "Primary root       : $DOCUMENT_ROOT"
echo "Virtual host       : $CONFIGURE_VHOST"

if [[ "$CONFIGURE_VHOST" == "yes" ]]; then
    echo "Virtual hostname   : $VIRTUAL_HOST"
    echo "Virtual admin      : $VIRTUAL_ADMIN"
    echo "Virtual root       : $VIRTUAL_ROOT"
fi

print_line
echo

read -r -p "Continue with this configuration? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warning "Setup cancelled. No configuration changes made."
    exit 0
fi

# -------------------- INSTALL APACHE ------------------------

echo
echo "[1/8] Installing Apache HTTP Server..."

if ! dnf install -y httpd curl; then
    error "Package installation failed. Check repository access."
    exit 1
fi

rpm -q httpd

# -------------------- BACKUP CONFIGURATION ------------------

echo
echo "[2/8] Backing up existing Apache configuration..."

BACKUP_DIR="/etc/httpd/backup.$(date +%Y%m%d_%H%M%S)"

if ! mkdir -p "$BACKUP_DIR"; then
    error "Could not create backup directory."
    exit 1
fi

if [[ -f /etc/httpd/conf/httpd.conf ]]; then
    cp -a /etc/httpd/conf/httpd.conf "$BACKUP_DIR/" || exit 1
fi

if [[ -d /etc/httpd/conf.d ]]; then
    cp -a /etc/httpd/conf.d "$BACKUP_DIR/" || exit 1
fi

success "Configuration backup: $BACKUP_DIR"

# -------------------- CREATE PRIMARY WEBSITE ----------------

echo
echo "[3/8] Creating primary website..."

PRIMARY_CONF="/etc/httpd/conf.d/10-primary-site.conf"

if ! mkdir -p "$DOCUMENT_ROOT"; then
    error "Could not create primary document root."
    exit 1
fi

printf '%s\n' "$WELCOME_MESSAGE" > "$DOCUMENT_ROOT/index.html"

cat > "$PRIMARY_CONF" <<EOF
<VirtualHost *:${HTTP_PORT}>
    ServerAdmin ${ADMIN_EMAIL}
    ServerName ${SERVER_NAME}
    DocumentRoot "${DOCUMENT_ROOT}"

    ErrorLog "logs/${SERVER_NAME}-error_log"
    CustomLog "logs/${SERVER_NAME}-access_log" combined

    <Directory "${DOCUMENT_ROOT}">
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF

success "Primary website created."
echo "Document root: $DOCUMENT_ROOT"
cat "$DOCUMENT_ROOT/index.html"

# -------------------- CREATE VIRTUAL HOST -------------------

if [[ "$CONFIGURE_VHOST" == "yes" ]]; then
    echo
    echo "[4/8] Creating name-based virtual host..."

    VHOST_CONF="/etc/httpd/conf.d/20-virtual-site.conf"

    if ! mkdir -p "$VIRTUAL_ROOT"; then
        error "Could not create virtual document root."
        exit 1
    fi

    printf '%s\n' "$VIRTUAL_MESSAGE" > "$VIRTUAL_ROOT/index.html"

    cat > "$VHOST_CONF" <<EOF
<VirtualHost *:${HTTP_PORT}>
    ServerAdmin ${VIRTUAL_ADMIN}
    ServerName ${VIRTUAL_HOST}
    DocumentRoot "${VIRTUAL_ROOT}"

    ErrorLog "logs/${VIRTUAL_HOST}-error_log"
    CustomLog "logs/${VIRTUAL_HOST}-access_log" combined

    <Directory "${VIRTUAL_ROOT}">
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF

    success "Virtual host created."
    echo "Document root: $VIRTUAL_ROOT"
    cat "$VIRTUAL_ROOT/index.html"
else
    echo
    echo "[4/8] Skipping virtual host configuration."
fi

# -------------------- SELINUX CONTEXT -----------------------

echo
echo "[5/8] Applying SELinux contexts where possible..."

if command -v restorecon >/dev/null 2>&1; then
    restorecon -RF "$DOCUMENT_ROOT"

    if [[ "$CONFIGURE_VHOST" == "yes" ]]; then
        restorecon -RF "$VIRTUAL_ROOT"
    fi
fi

# -------------------- CONFIGURATION VALIDATION ---------------

echo
echo "[6/8] Validating Apache configuration..."

if ! httpd -t; then
    error "Apache configuration test failed."
    warning "Review the configuration and backup at $BACKUP_DIR."
    exit 1
fi

success "Apache configuration syntax is valid."

echo
echo "Configured virtual hosts:"
httpd -S

# -------------------- START APACHE --------------------------

echo
echo "[7/8] Enabling and starting Apache..."

if ! systemctl enable --now httpd; then
    error "Could not start Apache."
    journalctl -u httpd -n 30 --no-pager
    exit 1
fi

systemctl --no-pager --full status httpd
success "Apache is enabled and running."

# -------------------- FIREWALL ------------------------------

echo
echo "[8/8] Configuring the firewall..."

if systemctl is-active --quiet firewalld; then
    if ! firewall-cmd --permanent --add-service=http; then
        error "Could not add HTTP firewall service."
        exit 1
    fi

    if ! firewall-cmd --reload; then
        error "Firewall reload failed."
        exit 1
    fi

    echo
    firewall-cmd --list-services
else
    warning "firewalld is not active. Firewall was not changed."
fi

# -------------------- RESTART AND VERIFY --------------------

echo
echo "Restarting Apache to apply all configuration..."

if ! systemctl restart httpd; then
    error "Apache restart failed."
    journalctl -u httpd -n 30 --no-pager
    exit 1
fi

echo
echo "Service status:"
systemctl is-enabled httpd
systemctl is-active httpd

echo
echo "Listening HTTP sockets:"
ss -ltnp | grep -E ":${HTTP_PORT}[[:space:]]" ||
    warning "No listener found on port $HTTP_PORT."

# -------------------- LOCAL WEBSITE TESTS -------------------

echo
echo "Testing primary website locally..."

if curl --fail --silent --show-error \
    --resolve "${SERVER_NAME}:${HTTP_PORT}:127.0.0.1" \
    "http://127.0.0.1:${HTTP_PORT}/" \
    -H "Host: ${SERVER_NAME}"; then
    echo
    success "Primary website responded."
else
    warning "Primary website local test failed."
fi

if [[ "$CONFIGURE_VHOST" == "yes" ]]; then
    echo
    echo "Testing virtual website locally..."

    if curl --fail --silent --show-error \
        "http://127.0.0.1:${HTTP_PORT}/" \
        -H "Host: ${VIRTUAL_HOST}"; then
        echo
        success "Virtual website responded."
    else
        warning "Virtual website local test failed."
    fi
fi

# -------------------- FINAL SERVER INFORMATION ---------------

echo
print_line
success "APACHE WEB SERVER SETUP COMPLETED"
print_line

echo "Web server package       : httpd"
echo "Service name             : httpd"
echo "Main configuration       : /etc/httpd/conf/httpd.conf"
echo "Virtual host config      : $PRIMARY_CONF"
echo "Default document root    : $DOCUMENT_ROOT"
echo "Server IP                : $SERVER_IP"
echo "Default HTTP port        : ${HTTP_PORT}/TCP"
echo "Default access log       : /var/log/httpd/access_log"
echo "Default error log        : /var/log/httpd/error_log"
echo "Primary website          : http://${SERVER_NAME}/"
echo "Check configuration      : httpd -t"
echo "List virtual hosts       : httpd -S"
echo "Start Apache             : systemctl start httpd"
echo "Restart Apache           : systemctl restart httpd"
echo "Enable at boot           : systemctl enable httpd"
echo "Allow HTTP in firewall   : firewall-cmd --permanent --add-service=http"
echo "Reload firewall          : firewall-cmd --reload"
echo "Test website              : curl http://${SERVER_NAME}/"

if [[ "$CONFIGURE_VHOST" == "yes" ]]; then
    echo
    echo "Virtual website          : http://${VIRTUAL_HOST}/"
    echo "Virtual document root    : $VIRTUAL_ROOT"
    echo "Virtual access log       : /var/log/httpd/${VIRTUAL_HOST}-access_log"
    echo "Virtual error log        : /var/log/httpd/${VIRTUAL_HOST}-error_log"
fi

echo
echo "Configuration backup     : $BACKUP_DIR"

# -------------------- CLIENT VERIFICATION --------------------

echo
print_line
echo "       CLIENT MACHINE VERIFICATION"
print_line

echo "Run these commands on a DIFFERENT Rocky Linux machine."
echo
echo "1. Install curl:"
echo "   dnf install -y curl"
echo
echo "2. Test the primary website by IP:"
printf '   curl http://%s:%s/ -H "Host: %s"\n' \
    "$SERVER_IP" "$HTTP_PORT" "$SERVER_NAME"

echo
echo "3. Test the primary hostname (requires DNS or /etc/hosts):"
printf '   curl http://%s:%s/\n' "$SERVER_NAME" "$HTTP_PORT"

if [[ "$CONFIGURE_VHOST" == "yes" ]]; then
    echo
    echo "4. Test the virtual host by IP:"
    printf '   curl http://%s:%s/ -H "Host: %s"\n' \
        "$SERVER_IP" "$HTTP_PORT" "$VIRTUAL_HOST"

    echo
    echo "5. Test the virtual hostname (requires DNS or /etc/hosts):"
    printf '   curl http://%s:%s/\n' "$VIRTUAL_HOST" "$HTTP_PORT"
fi

echo
echo "If hostname resolution is unavailable, add entries to"
echo "/etc/hosts on the client machine:"
printf '   %s %s' "$SERVER_IP" "$SERVER_NAME"

if [[ "$CONFIGURE_VHOST" == "yes" ]]; then
    printf ' %s' "$VIRTUAL_HOST"
fi

echo
echo
echo "Troubleshooting commands (run on the web server):"
echo "   httpd -t"
echo "   httpd -S"
echo "   systemctl status httpd"
echo "   journalctl -u httpd -n 30 --no-pager"
echo "   firewall-cmd --list-all"
echo
warning "Ensure the client can reach the server IP on TCP port 80."
warning "Hostname-based curl tests require DNS or a client /etc/hosts entry."
print_line

