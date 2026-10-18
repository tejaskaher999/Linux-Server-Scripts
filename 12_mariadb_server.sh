#!/bin/bash

# ==========================================================
# Script Name : 12_mariadb_server.sh
# Purpose     : Install and manage MariaDB interactively
# OS          : Rocky Linux / RHEL
# ==========================================================

set -o pipefail

DB_DEFAULT="skynet"
TABLE_DEFAULT="student"

# ---------- Colors ----------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
pause()   { read -rp "Press Enter to continue..."; }

# ---------- Root Check ----------
if [[ $EUID -ne 0 ]]; then
    error "Run this script as root or using sudo."
    exit 1
fi

# ---------- Install MariaDB ----------
clear
echo "=========================================="
echo "       MariaDB Server Installation"
echo "=========================================="

if ! rpm -q mariadb-server &>/dev/null; then
    info "Installing MariaDB server..."
    if ! dnf install -y mariadb-server; then
        error "MariaDB installation failed."
        exit 1
    fi
else
    success "MariaDB server is already installed."
fi

info "Enabling and starting MariaDB..."
if ! systemctl enable --now mariadb; then
    error "Could not start MariaDB. Check: journalctl -u mariadb"
    exit 1
fi

success "MariaDB service is running."

# ---------- Database Authentication ----------
ROOT_PASSWORD=""

if mariadb -u root -Nse "SELECT 1" &>/dev/null; then
    info "Root access through local socket is working."
else
    echo
    read -rsp "Enter MariaDB root password: " ROOT_PASSWORD
    echo

    if ! MYSQL_PWD="$ROOT_PASSWORD" mariadb -u root -Nse "SELECT 1" &>/dev/null; then
        error "MariaDB root login failed."
        unset ROOT_PASSWORD
        exit 1
    fi
fi

# Run MariaDB commands using the detected authentication method.
run_sql() {
    if [[ -n "$ROOT_PASSWORD" ]]; then
        MYSQL_PWD="$ROOT_PASSWORD" mariadb -u root "$@"
    else
        mariadb -u root "$@"
    fi
}

run_dump() {
    if [[ -n "$ROOT_PASSWORD" ]]; then
        MYSQL_PWD="$ROOT_PASSWORD" mariadb-dump -u root "$@"
    else
        mariadb-dump -u root "$@"
    fi
}

# ---------- Validation ----------
valid_name() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

ask_database() {
    read -rp "Enter database name [$DB_DEFAULT]: " DB
    DB=${DB:-$DB_DEFAULT}

    if ! valid_name "$DB"; then
        error "Invalid database name."
        return 1
    fi
}

ask_table() {
    read -rp "Enter table name [$TABLE_DEFAULT]: " TABLE
    TABLE=${TABLE:-$TABLE_DEFAULT}

    if ! valid_name "$TABLE"; then
        error "Invalid table name."
        return 1
    fi
}

database_exists() {
    [[ "$(run_sql -Nse \
        "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
         WHERE SCHEMA_NAME='$DB';" 2>/dev/null)" == "$DB" ]]
}

table_exists() {
    [[ "$(run_sql -Nse \
        "SELECT TABLE_NAME FROM information_schema.TABLES
         WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='$TABLE';" 2>/dev/null)" == "$TABLE" ]]
}

require_database() {
    ask_database || return 1

    if ! database_exists; then
        error "Database '$DB' does not exist. Create it first."
        return 1
    fi
}

require_table() {
    require_database || return 1
    ask_table || return 1

    if ! table_exists; then
        error "Table '$TABLE' does not exist in '$DB'."
        return 1
    fi
}

# Escape apostrophes in user-entered string values.
sql_escape() {
    local value=$1
    value=${value//\'/\'\'}
    printf '%s' "$value"
}

# ---------- Menu Operations ----------

create_database() {
    echo
    read -rp "New database name: " DB

    if ! valid_name "$DB"; then
        error "Use letters, numbers and underscores; start with a letter or underscore."
        return
    fi

    if database_exists; then
        info "Database '$DB' already exists."
    else
        if run_sql -e "CREATE DATABASE \`$DB\`;"; then
            success "Database '$DB' created."
        else
            error "Could not create database."
            return
        fi
    fi

    echo
    run_sql -e "SHOW DATABASES LIKE '$DB';"
}

display_databases() {
    echo
    info "Available databases:"
    run_sql -e "SHOW DATABASES;"
}

create_table() {
    require_database || return

    echo
    read -rp "New table name: " TABLE

    if ! valid_name "$TABLE"; then
        error "Invalid table name."
        return
    fi

    if table_exists; then
        error "Table '$TABLE' already exists."
        return
    fi

    echo
    echo "Supported column types:"
    echo "1. INT"
    echo "2. VARCHAR"
    echo "3. DATE"
    echo "4. DECIMAL"
    echo "5. TEXT"
    echo

    read -rp "How many columns? " COUNT

    if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || (( COUNT > 30 )); then
        error "Enter a number between 1 and 30."
        return
    fi

    local definitions=""
    local COL TYPE LENGTH SQLTYPE CHOICE
    local i

    for ((i=1; i<=COUNT; i++)); do
        echo
        echo "--- Column $i ---"
        read -rp "Column name: " COL

        if ! valid_name "$COL"; then
            error "Invalid column name."
            return
        fi

        if [[ "$definitions" == *"\`$COL\`"* ]]; then
            error "Duplicate column name."
            return
        fi

        echo "1) INT  2) VARCHAR  3) DATE  4) DECIMAL  5) TEXT"
        read -rp "Choose type [1-5]: " CHOICE

        case "$CHOICE" in
            1) SQLTYPE="INT" ;;
            2)
                read -rp "VARCHAR length [100]: " LENGTH
                LENGTH=${LENGTH:-100}
                if ! [[ "$LENGTH" =~ ^[1-9][0-9]*$ ]] || (( LENGTH > 4000 )); then
                    error "Invalid VARCHAR length."
                    return
                fi
                SQLTYPE="VARCHAR($LENGTH)"
                ;;
            3) SQLTYPE="DATE" ;;
            4) SQLTYPE="DECIMAL(10,2)" ;;
            5) SQLTYPE="TEXT" ;;
            *)
                error "Invalid type."
                return
                ;;
        esac

        if (( i == 1 )); then
            definitions="\`$COL\` $SQLTYPE NOT NULL PRIMARY KEY"
        else
            definitions+=", \`$COL\` $SQLTYPE"
        fi
    done

    if run_sql -e "CREATE TABLE \`$DB\`.\`$TABLE\` ($definitions);"; then
        success "Table '$TABLE' created in '$DB'."
        echo
        info "Table structure:"
        run_sql -e "DESCRIBE \`$DB\`.\`$TABLE\`;"
    else
        error "Table creation failed."
    fi
}

display_tables() {
    require_database || return

    echo
    info "Tables in database '$DB':"
    run_sql -e "SHOW TABLES FROM \`$DB\`;"
}

display_structure() {
    require_table || return

    echo
    info "Structure of '$DB.$TABLE':"
    run_sql -e "DESCRIBE \`$DB\`.\`$TABLE\`;"
}

insert_data() {
    require_table || return

    local COL VALUE SQL_COLUMNS="" SQL_VALUES=""
    local -a COLUMNS=()

    while IFS= read -r COL; do
        [[ -n "$COL" ]] && COLUMNS+=("$COL")
    done < <(run_sql -Nse \
        "SHOW COLUMNS FROM \`$DB\`.\`$TABLE\`;" 2>/dev/null | cut -f1)

    if (( ${#COLUMNS[@]} == 0 )); then
        error "Could not read table columns."
        return
    fi

    echo
    echo "Enter values for one record."
    echo "For DATE columns, use YYYY-MM-DD."
    echo "For numeric columns, enter numbers."
    echo

    for COL in "${COLUMNS[@]}"; do
        read -rp "$COL: " VALUE
        VALUE=$(sql_escape "$VALUE")

        SQL_COLUMNS+="${SQL_COLUMNS:+, }\`$COL\`"
        SQL_VALUES+="${SQL_VALUES:+, }'$VALUE'"
    done

    if run_sql -e \
        "INSERT INTO \`$DB\`.\`$TABLE\` ($SQL_COLUMNS) VALUES ($SQL_VALUES);"; then
        success "Record inserted."
        echo
        info "Current table data:"
        run_sql -e "SELECT * FROM \`$DB\`.\`$TABLE\`;"
    else
        error "Insert failed. Check the values and column constraints."
    fi
}

insert_dummy_data() {
    require_database || return
    TABLE="student"

    if ! table_exists; then
        echo
        info "Creating the standard student table..."
        run_sql -e "
            CREATE TABLE \`$DB\`.student (
                ID INT PRIMARY KEY,
                NAME VARCHAR(50),
                EMAIL VARCHAR(100),
                Address VARCHAR(100)
            );" || return
    fi

    echo
    info "Adding sample student records..."

    if run_sql -e "
        INSERT INTO \`$DB\`.student (ID, NAME, EMAIL, Address)
        VALUES
          (1, 'Kishor', 'k@gmail.com', 'Nashik'),
          (2, 'Radhika', 'r@gmail.com', 'Pune')
        ON DUPLICATE KEY UPDATE
          NAME=VALUES(NAME),
          EMAIL=VALUES(EMAIL),
          Address=VALUES(Address);"; then
        success "Dummy data inserted or refreshed."
        echo
        run_sql -e "SELECT * FROM \`$DB\`.student;"
    else
        error "Could not insert sample data."
    fi
}

display_records() {
    require_table || return

    echo
    info "Records in '$DB.$TABLE':"
    run_sql -e "SELECT * FROM \`$DB\`.\`$TABLE\`;"
}

update_record() {
    require_table || return

    local COL VALUE KEYCOL KEYVAL

    echo
    run_sql -e "DESCRIBE \`$DB\`.\`$TABLE\`;"
    read -rp "Column to update: " COL
    read -rp "New value: " VALUE
    read -rp "Condition column (usually primary key): " KEYCOL
    read -rp "Condition value: " KEYVAL

    if ! valid_name "$COL" || ! valid_name "$KEYCOL"; then
        error "Invalid column name."
        return
    fi

    VALUE=$(sql_escape "$VALUE")
    KEYVAL=$(sql_escape "$KEYVAL")

    if run_sql -e "
        UPDATE \`$DB\`.\`$TABLE\`
        SET \`$COL\`='$VALUE'
        WHERE \`$KEYCOL\`='$KEYVAL';"; then
        success "Update command completed."
        run_sql -e "SELECT * FROM \`$DB\`.\`$TABLE\`;"
    else
        error "Update failed."
    fi
}

delete_record() {
    require_table || return

    local KEYCOL KEYVAL CONFIRM

    echo
    run_sql -e "SELECT * FROM \`$DB\`.\`$TABLE\`;"
    read -rp "Condition column (usually primary key): " KEYCOL
    read -rp "Condition value: " KEYVAL

    if ! valid_name "$KEYCOL"; then
        error "Invalid column name."
        return
    fi

    KEYVAL=$(sql_escape "$KEYVAL")

    echo
    echo "Matching rows will be deleted."
    read -rp "Continue? (y/N): " CONFIRM

    [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || {
        info "Delete cancelled."
        return
    }

    if run_sql -e \
        "DELETE FROM \`$DB\`.\`$TABLE\` WHERE \`$KEYCOL\`='$KEYVAL';"; then
        success "Delete command completed."
        run_sql -e "SELECT * FROM \`$DB\`.\`$TABLE\`;"
    else
        error "Delete failed."
    fi
}

add_column() {
    require_table || return

    local COL CHOICE LENGTH SQLTYPE

    read -rp "New column name: " COL

    if ! valid_name "$COL"; then
        error "Invalid column name."
        return
    fi

    echo "1) INT  2) VARCHAR  3) DATE  4) DECIMAL  5) TEXT"
    read -rp "Choose type [1-5]: " CHOICE

    case "$CHOICE" in
        1) SQLTYPE="INT" ;;
        2)
            read -rp "VARCHAR length [100]: " LENGTH
            LENGTH=${LENGTH:-100}
            if ! [[ "$LENGTH" =~ ^[1-9][0-9]*$ ]] || (( LENGTH > 4000 )); then
                error "Invalid length."
                return
            fi
            SQLTYPE="VARCHAR($LENGTH)"
            ;;
        3) SQLTYPE="DATE" ;;
        4) SQLTYPE="DECIMAL(10,2)" ;;
        5) SQLTYPE="TEXT" ;;
        *) error "Invalid type."; return ;;
    esac

    if run_sql -e \
        "ALTER TABLE \`$DB\`.\`$TABLE\` ADD COLUMN \`$COL\` $SQLTYPE;"; then
        success "Column added."
        run_sql -e "DESCRIBE \`$DB\`.\`$TABLE\`;"
    else
        error "Could not add column."
    fi
}

drop_column() {
    require_table || return

    local COL CONFIRM
    run_sql -e "DESCRIBE \`$DB\`.\`$TABLE\`;"
    read -rp "Column to remove: " COL

    if ! valid_name "$COL"; then
        error "Invalid column name."
        return
    fi

    echo
    error "This permanently removes the column and its data."
    read -rp "Confirm removal? (y/N): " CONFIRM

    [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || return

    if run_sql -e \
        "ALTER TABLE \`$DB\`.\`$TABLE\` DROP COLUMN \`$COL\`;"; then
        success "Column removed."
        run_sql -e "DESCRIBE \`$DB\`.\`$TABLE\`;"
    else
        error "Could not remove column."
    fi
}

backup_database() {
    require_database || return

    local FILE
    read -rp "Backup path [/root/$DB.sql]: " FILE
    FILE=${FILE:-/root/$DB.sql}

    if [[ -e "$FILE" ]]; then
        error "File already exists: $FILE"
        read -rp "Overwrite it? (y/N): " CONFIRM
        [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || return
    fi

    if run_dump --databases "$DB" > "$FILE"; then
        chmod 600 "$FILE"
        success "Backup saved to '$FILE'."
        ls -lh "$FILE"
    else
        error "Backup failed."
        rm -f "$FILE"
    fi
}

restore_database() {
    local FILE
    read -rp "Full path to SQL backup: " FILE

    if [[ ! -f "$FILE" || ! -r "$FILE" ]]; then
        error "Backup file does not exist or is unreadable."
        return
    fi

    echo
    error "Restoring executes SQL from this file and may overwrite data."
    read -rp "Continue? (y/N): " CONFIRM
    [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || return

    if run_sql < "$FILE"; then
        success "Restore command completed."
    else
        error "Restore failed. Check the SQL file and MariaDB output."
    fi
}

service_status() {
    echo
    systemctl status mariadb --no-pager
    echo
    info "Listening TCP ports:"
    ss -lntp | grep -E '(:3306[[:space:]]|:3306$)' ||
        echo "No TCP listener on port 3306 (local socket access may still work)."
}

# ---------- Main Menu ----------
while true; do
    clear
    echo "=================================================="
    echo "          MariaDB Database Management"
    echo "=================================================="
    echo " Service : MariaDB"
    echo " Status  : $(systemctl is-active mariadb)"
    echo "=================================================="
    echo " 1.  Create database"
    echo " 2.  Display all databases"
    echo " 3.  Create table with custom columns"
    echo " 4.  Display tables in a database"
    echo " 5.  Display table structure"
    echo " 6.  Insert one record into a table"
    echo " 7.  Insert dummy student data"
    echo " 8.  Display table records"
    echo " 9.  Update a record"
    echo "10.  Delete a record"
    echo "11.  Add a column"
    echo "12.  Drop a column"
    echo "13.  Back up a database"
    echo "14.  Restore a database backup"
    echo "15.  MariaDB service status"
    echo " 0.  Exit"
    echo "=================================================="

    read -rp "Enter your choice: " CHOICE

    case "$CHOICE" in
        1)  create_database; pause ;;
        2)  display_databases; pause ;;
        3)  create_table; pause ;;
        4)  display_tables; pause ;;
        5)  display_structure; pause ;;
        6)  insert_data; pause ;;
        7)  insert_dummy_data; pause ;;
        8)  display_records; pause ;;
        9)  update_record; pause ;;
        10) delete_record; pause ;;
        11) add_column; pause ;;
        12) drop_column; pause ;;
        13) backup_database; pause ;;
        14) restore_database; pause ;;
        15) service_status; pause ;;
        0)
            success "Exiting MariaDB management menu."
            unset ROOT_PASSWORD
            exit 0
            ;;
        *)
            error "Invalid choice. Select an option from the menu."
            sleep 2
            ;;
    esac
done

