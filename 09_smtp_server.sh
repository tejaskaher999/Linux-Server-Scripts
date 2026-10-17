#!/bin/bash

# ============================================================
# INTERACTIVE SMTP SERVER SETUP
# Supported OS: RHEL / Rocky Linux
# Services: Postfix + Mutt
# ============================================================

# -------------------- DEFAULT VARIABLES ---------------------

DEFAULT_HOSTNAME="server"
DEFAULT_DOMAIN="skynet.com"
DEFAULT_SMTP_PORT="25"
DEFAULT_INET_INTERFACES="all"
DEFAULT_FIREWALL_SERVICE="smtp"

# -------------------- COLORS -------------------------------

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

# -------------------- ROOT CHECK ----------------------------

if [[ $EUID -ne 0 ]]; then
    error "Please execute this script as root."
    echo "Example: sudo bash 09_smtp_server.sh"
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
    error "This script is intended for RHEL / Rocky Linux."
    exit 1
fi

# -------------------- HEADER --------------------------------

clear
print_line
echo "          INTERACTIVE SMTP SERVER SETUP"
echo "          RHEL / ROCKY LINUX"
print_line
echo "Press Enter to accept the displayed default values."
echo

# -------------------- SYSTEM INFORMATION --------------------

echo -e "${BLUE}Current Host Information${NC}"
hostnamectl
echo
ip -br addr
echo

# -------------------- USER CONFIGURATION --------------------

SMTP_HOST_SHORT=$(ask_value \
    "SMTP server hostname (short name)" "$DEFAULT_HOSTNAME")

SMTP_DOMAIN=$(ask_value \
    "SMTP domain name" "$DEFAULT_DOMAIN")

SMTP_PORT=$(ask_value \
    "SMTP listening port" "$DEFAULT_SMTP_PORT")

SMTP_INET_INTERFACES=$(ask_value \
    "Postfix network interfaces (all or loopback-only)" \
    "$DEFAULT_INET_INTERFACES")

FIREWALL_SERVICE=$(ask_value \
    "Firewall service name" "$DEFAULT_FIREWALL_SERVICE")

SMTP_HOSTNAME="${SMTP_HOST_SHORT}.${SMTP_DOMAIN}"
SMTP_ORIGIN='$mydomain'
SMTP_DESTINATION="\$myhostname, localhost.\$mydomain, localhost, \$mydomain"

echo
print_line
echo "             CONFIGURATION SUMMARY"
print_line
echo "Hostname            : $SMTP_HOSTNAME"
echo "Domain              : $SMTP_DOMAIN"
echo "Mail origin         : $SMTP_DOMAIN"
echo "Listening port      : $SMTP_PORT"
echo "Network interfaces  : $SMTP_INET_INTERFACES"
echo "Firewall service    : $FIREWALL_SERVICE"
print_line
echo

read -r -p "Continue with this configuration? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warning "Setup cancelled. No configuration changes made."
    exit 0
fi

# -------------------- VALIDATION ----------------------------

if [[ ! "$SMTP_PORT" =~ ^[0-9]+$ ]] ||
   (( SMTP_PORT < 1 || SMTP_PORT > 65535 )); then
    error "Invalid TCP port: $SMTP_PORT"
    exit 1
fi

if [[ ! "$SMTP_HOST_SHORT" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
    error "Invalid hostname."
    exit 1
fi

if [[ ! "$SMTP_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    error "Invalid domain name."
    exit 1
fi

if [[ "$SMTP_INET_INTERFACES" != "all" &&
      "$SMTP_INET_INTERFACES" != "loopback-only" ]]; then
    error "Use 'all' or 'loopback-only' for network interfaces."
    exit 1
fi

# -------------------- INSTALL PACKAGES -----------------------

echo
echo "[1/7] Installing Postfix and Mutt..."

if ! dnf install -y postfix mutt; then
    error "Package installation failed. Check repository access."
    exit 1
fi

rpm -q postfix
rpm -q mutt

# -------------------- BACKUP CONFIGURATION ------------------

echo
echo "[2/7] Backing up existing Postfix configuration..."

POSTFIX_CONFIG="/etc/postfix/main.cf"
BACKUP_FILE="${POSTFIX_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"

if [[ -f "$POSTFIX_CONFIG" ]]; then
    cp -a "$POSTFIX_CONFIG" "$BACKUP_FILE" || {
        error "Could not back up $POSTFIX_CONFIG"
        exit 1
    }
    success "Backup created: $BACKUP_FILE"
fi

# -------------------- CONFIGURE POSTFIX ----------------------

echo
echo "[3/7] Configuring Postfix..."

# Update existing settings or append missing settings.
set_postfix_option() {
    local key="$1"
    local value="$2"

    if grep -qE "^[[:space:]#]*${key}[[:space:]]*=" "$POSTFIX_CONFIG"; then
        sed -i -E \
            "s|^[[:space:]#]*${key}[[:space:]]*=.*|${key} = ${value}|" \
            "$POSTFIX_CONFIG"
    else
        echo "${key} = ${value}" >> "$POSTFIX_CONFIG"
    fi
}

set_postfix_option "myhostname" "$SMTP_HOSTNAME"
set_postfix_option "mydomain" "$SMTP_DOMAIN"
set_postfix_option "myorigin" '$mydomain'
set_postfix_option "inet_interfaces" "$SMTP_INET_INTERFACES"
set_postfix_option "mydestination" \
    '$myhostname, localhost.$mydomain, localhost, $mydomain'

# Set a custom SMTP port in master.cf when not using port 25.
# The default Postfix SMTP service is already configured on port 25.
if [[ "$SMTP_PORT" != "25" ]]; then
    warning "A non-default SMTP port requires master.cf configuration."
    warning "This script leaves master.cf unchanged; configure and verify"
    warning "the custom listener separately before opening the firewall."
fi

# -------------------- VERIFY CONFIGURATION ------------------

echo
echo "[4/7] Checking Postfix configuration..."

if ! postfix check; then
    error "Postfix configuration validation failed."
    warning "Restore the backup if necessary: $BACKUP_FILE"
    exit 1
fi

postconf myhostname
postconf mydomain
postconf myorigin
postconf inet_interfaces
postconf mydestination

# -------------------- START POSTFIX -------------------------

echo
echo "[5/7] Enabling and starting Postfix..."

if ! systemctl enable --now postfix; then
    error "Could not start Postfix."
    journalctl -u postfix -n 30 --no-pager
    exit 1
fi

systemctl --no-pager --full status postfix
success "Postfix service is enabled and running."

# -------------------- FIREWALL CONFIGURATION -----------------

echo
echo "[6/7] Configuring firewalld..."

if systemctl is-active --quiet firewalld; then
    if [[ "$SMTP_PORT" == "25" ]]; then
        firewall-cmd --permanent --add-service="$FIREWALL_SERVICE"
    else
        firewall-cmd --permanent --add-port="${SMTP_PORT}/tcp"
    fi

    firewall-cmd --reload
    firewall-cmd --list-all
else
    warning "firewalld is not active. Firewall was not changed."
fi

# -------------------- FINAL VERIFICATION ---------------------

echo
echo "[7/7] Final verification..."

echo
echo "Postfix service:"
systemctl is-enabled postfix
systemctl is-active postfix

echo
echo "SMTP listening sockets:"
ss -ltnp | grep -E ":${SMTP_PORT}[[:space:]]" ||
    warning "No listener found on port $SMTP_PORT."

echo
echo "Postfix logs:"
journalctl -u postfix -n 20 --no-pager

# -------------------- COMPLETION ----------------------------

echo
print_line
success "SMTP SERVER SETUP COMPLETED"
print_line

echo "SMTP Hostname : $SMTP_HOSTNAME"
echo "Domain        : $SMTP_DOMAIN"
echo "SMTP Port     : $SMTP_PORT"
echo "Config File   : $POSTFIX_CONFIG"
echo "Backup File   : $BACKUP_FILE"
echo
echo "Useful commands:"
echo "  postfix check"
echo "  postconf -n"
echo "  systemctl status postfix"
echo "  ss -ltnp | grep ':25'"
echo "  journalctl -u postfix --no-pager"
echo
echo "Test mail locally:"
echo "  echo 'SMTP test email' | mutt -s 'SMTP Test' recipient@example.com"
echo
warning "Local SMTP setup does not guarantee external email delivery."
warning "External delivery may require DNS, a valid mail identity, TLS,"
warning "relay configuration, and permission to send outbound SMTP."
print_line

