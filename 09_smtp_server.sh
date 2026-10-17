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

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# -------------------- FUNCTIONS ------------------------------

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

# -------------------- ROOT CHECK -----------------------------

if [[ $EUID -ne 0 ]]; then
    error "Run this script as root."
    echo "Example: sudo bash 09_smtp_server.sh"
    exit 1
fi

# -------------------- OS CHECK -------------------------------

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

# -------------------- DETECT SERVER IP -----------------------

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

# -------------------- HEADER ---------------------------------

clear
print_line
echo "          INTERACTIVE SMTP SERVER SETUP"
echo "          RHEL / ROCKY LINUX"
print_line
echo "Press Enter to accept the displayed defaults."
echo

echo -e "${BLUE}Current Host Information${NC}"
hostnamectl
echo
ip -br addr
echo

# -------------------- USER CONFIGURATION ---------------------

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

# Automatically construct the FQDN and recipient address.
SMTP_HOSTNAME="${SMTP_HOST_SHORT}.${SMTP_DOMAIN}"
SMTP_RECIPIENT="root@${SMTP_DOMAIN}"

echo
print_line
echo "             CONFIGURATION SUMMARY"
print_line
echo "SMTP Hostname       : $SMTP_HOSTNAME"
echo "Domain              : $SMTP_DOMAIN"
echo "Server IP           : $SERVER_IP"
echo "Mail origin         : $SMTP_DOMAIN"
echo "Listening port      : $SMTP_PORT"
echo "Network interfaces  : $SMTP_INET_INTERFACES"
echo "Firewall service    : $FIREWALL_SERVICE"
echo "Test recipient      : $SMTP_RECIPIENT"
print_line
echo

read -r -p "Continue with this configuration? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warning "Setup cancelled. No configuration changes made."
    exit 0
fi

# -------------------- VALIDATION -----------------------------

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
    error "Use 'all' or 'loopback-only'."
    exit 1
fi

if [[ "$SMTP_PORT" != "25" ]]; then
    error "This script currently configures the standard SMTP port 25 only."
    error "Use port 25 to ensure the listener and firewall match."
    exit 1
fi

if [[ "$SMTP_INET_INTERFACES" == "loopback-only" ]]; then
    warning "Loopback-only prevents connections from other machines."
    warning "Choose 'all' if remote client testing is required."
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

# -------------------- BACKUP CONFIGURATION -------------------

echo
echo "[2/7] Backing up existing Postfix configuration..."

POSTFIX_CONFIG="/etc/postfix/main.cf"
BACKUP_FILE="${POSTFIX_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"

if [[ -f "$POSTFIX_CONFIG" ]]; then
    if ! cp -a "$POSTFIX_CONFIG" "$BACKUP_FILE"; then
        error "Could not back up Postfix configuration."
        exit 1
    fi
    success "Backup created: $BACKUP_FILE"
fi

# -------------------- CONFIGURE POSTFIX ----------------------

echo
echo "[3/7] Configuring Postfix..."

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

# -------------------- VERIFY CONFIGURATION -------------------

echo
echo "[4/7] Checking Postfix configuration..."

if ! postfix check; then
    error "Postfix configuration validation failed."
    warning "Original configuration backup: $BACKUP_FILE"
    exit 1
fi

postconf myhostname
postconf mydomain
postconf myorigin
postconf inet_interfaces
postconf mydestination

# -------------------- START POSTFIX --------------------------

echo
echo "[5/7] Enabling and starting Postfix..."

if ! systemctl enable --now postfix; then
    error "Could not start Postfix."
    journalctl -u postfix -n 30 --no-pager
    exit 1
fi

systemctl --no-pager --full status postfix
success "Postfix is enabled and running."

# -------------------- FIREWALL CONFIGURATION -----------------

echo
echo "[6/7] Configuring firewalld..."

if systemctl is-active --quiet firewalld; then
    if ! firewall-cmd --permanent --add-service="$FIREWALL_SERVICE"; then
        error "Could not add SMTP firewall service."
        exit 1
    fi

    if ! firewall-cmd --reload; then
        error "Firewall reload failed."
        exit 1
    fi

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

# -------------------- COMPLETION -----------------------------

echo
print_line
success "SMTP SERVER SETUP COMPLETED"
print_line

echo "SMTP Hostname : $SMTP_HOSTNAME"
echo "Server IP     : $SERVER_IP"
echo "Domain        : $SMTP_DOMAIN"
echo "SMTP Port     : $SMTP_PORT"
echo "Recipient     : $SMTP_RECIPIENT"
echo "Config File   : $POSTFIX_CONFIG"
echo "Backup File   : $BACKUP_FILE"

echo
echo "Useful server commands:"
echo "  postfix check"
echo "  postconf -n"
echo "  systemctl status postfix"
echo "  ss -ltnp | grep ':${SMTP_PORT}'"
echo "  journalctl -u postfix --no-pager"

# -------------------- CLIENT VERIFICATION --------------------

echo
print_line
echo "       SMTP CLIENT MACHINE VERIFICATION"
print_line

echo "Run these commands on a DIFFERENT Rocky Linux machine."
echo
echo "1. Install Mutt and netcat:"
echo "   dnf install mutt nmap-ncat -y"
echo
echo "2. Verify connectivity to the SMTP server:"
printf '   nc -vz %s %s\n' "$SERVER_IP" "$SMTP_PORT"
echo
echo "3. Send a test email through this SMTP server:"
printf '   echo "Hello from my client Rocky Linux machine!" | \\\n'
printf '   mutt -e '\''set smtp_url="smtp://%s:%s"'\'' \\\n' \
    "$SERVER_IP" "$SMTP_PORT"
printf '        -s "SMTP Client Test" %s\n' "$SMTP_RECIPIENT"

echo
echo "4. Check the mail queue ON THE SMTP SERVER:"
echo "   postqueue -p"
echo
echo "5. Check Postfix logs ON THE SMTP SERVER:"
echo "   journalctl -u postfix -n 30 --no-pager"
echo
warning "Ensure the client can reach the server IP and TCP port."
warning "The recipient must exist or resolve to a local mailbox."
warning "This basic setup does not configure authenticated SMTP relay."
warning "External email delivery may require DNS, TLS, and a mail relay."
print_line

