#!/bin/bash

# ==========================================================
# MariaDB Database Management Script
# Compatible with Rocky Linux / RHEL-based systems
# ==========================================================

# ---------- Colors ----------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ---------- Configuration ----------
ROOT_PASS=""
FIRST_INSTALL=0

# ---------- Helper functions ----------
success() { echo -e "${GREEN}[SUCCESS]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; }
info()    { echo -e "${CYAN}[INFO]${RESET} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${RESET} $1"; }

pause_screen() {
    echo
    read -r -p "Press Enter to continue..."
}

confirm_action() {
    local answer
    read -r -p "$1 (yes/no): " answer
    [[ "$answer" == "yes" ]]
}

# Run MariaDB commands as root.
# Uses socket authentication when possible, or a supplied password.
db() {
    if [[ -n "$ROOT_PASS" ]]; then
        MYSQL_PWD="$ROOT_PASS" mariadb -u root "$@"
    else
        mariadb -u root "$@"
    fi
}

db_dump() {
    if [[ -n "$ROOT_PASS" ]]; then
        MYSQL_PWD="$ROOT_PASS" mariadb-dump -u root "$@"
    else
        mariadb-dump -u root "$@"
    fi
}

valid_name() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

quote_value() {
    # Escape single quotes for SQL string values.
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"
    printf '%s' "$value"
}

read_database() {
    read -r -p "Enter database name: " DB_NAME
    if ! valid_name "$DB_NAME"; then
        error "Invalid database name. Use letters, numbers, and underscores."
        return 1
    fi
    return 0
}

read_table() {
    read -r -p "Enter table name: " TABLE_NAME
    if ! valid_name "$TABLE_NAME"; then
        error "Invalid table name. Use letters, numbers, and underscores."
        return 1
    fi
    return 0
}

database_exists() {
    local result
    result=$(db -N -B -e \
        "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';" \
        2>/dev/null) || return 1
    [[ "$result" == "1" ]]
}

table_exists() {
    local result
    result=$(db -N -B -e \
        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${TABLE_NAME}';" \
        2>/dev/null) || return 1
    [[ "$result" == "1" ]]
}

require_database() {
    read_database || return 1
    if ! database_exists; then
        error "Database '$DB_NAME' does not exist."
        return 1
    fi
    return 0
}

require_table() {
    require_database || return 1
    read_table || return 1
    if ! table_exists; then
        error "Table '$TABLE_NAME' does not exist in '$DB_NAME'."
        return 1
    fi
    return 0
}

show_databases() {
    db -e "SHOW DATABASES;"
}

show_tables() {
    db -e "SHOW TABLES FROM \`$DB_NAME\`;"
}

show_columns() {
    db -e "SHOW COLUMNS FROM \`$DB_NAME\`.\`$TABLE_NAME\`;"
}

# ---------- Installation and authentication ----------
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "Run this script as root."
        echo "Example: sudo bash $0"
        exit 1
    fi
}

install_mariadb() {
    if ! rpm -q mariadb-server >/dev/null 2>&1; then
        FIRST_INSTALL=1
        info "MariaDB Server is not installed."
        echo "Installing MariaDB Server..."
        if ! dnf install -y mariadb-server; then
            error "MariaDB installation failed."
            exit 1
        fi
        success "MariaDB Server installed."
    else
        info "MariaDB Server is already installed."
    fi

    if ! systemctl enable --now mariadb; then
        error "Could not start MariaDB. Check: systemctl status mariadb"
        exit 1
    fi

    success "MariaDB service is running."
}

authenticate_root() {
    if mariadb -u root -e "SELECT 1;" >/dev/null 2>&1; then
        ROOT_PASS=""
        success "MariaDB root socket authentication works."
        return 0
    fi

    echo
    read -r -s -p "Enter MariaDB root password: " ROOT_PASS
    echo

    if ! MYSQL_PWD="$ROOT_PASS" mariadb -u root -e "SELECT 1;" >/dev/null 2>&1; then
        ROOT_PASS=""
        error "MariaDB root authentication failed."
        exit 1
    fi

    success "MariaDB root authentication successful."
}

# ---------- Database operations ----------
create_database() {
    read_database || return
    if database_exists; then
        warning "Database '$DB_NAME' already exists."
        return
    fi

    if db -e "CREATE DATABASE \`$DB_NAME\`;"; then
        success "Database '$DB_NAME' created."
    else
        error "Database creation failed."
    fi
}

display_databases() {
    show_databases
}

drop_database() {
    read_database || return
    if ! database_exists; then
        error "Database '$DB_NAME' does not exist."
        return
    fi

    warning "This permanently deletes database '$DB_NAME' and all its tables and data."
    if confirm_action "Type yes to confirm dropping this database"; then
        if db -e "DROP DATABASE \`$DB_NAME\`;"; then
            success "Database '$DB_NAME' dropped."
        else
            error "Could not drop database."
        fi
    else
        info "Operation cancelled."
    fi
}

select_database() {
    require_database || return
    db -e "USE \`$DB_NAME\`; SELECT DATABASE() AS Selected_Database;"
}

# ---------- Table operations ----------
create_table() {
    require_database || return
    read_table || return

    if table_exists; then
        error "Table '$TABLE_NAME' already exists."
        return
    fi

    local count name type primary_key definition
    local -a definitions=()
    local -a column_names=()

    read -r -p "How many columns do you want? " count
    if ! [[ "$count" =~ ^[1-9][0-9]*$ ]] || (( count > 50 )); then
        error "Enter a number between 1 and 50."
        return
    fi

    echo
    echo "Common column types: INT, BIGINT, VARCHAR(100), TEXT, DATE,"
    echo "DECIMAL(10,2), DATETIME, BOOLEAN"
    echo

    for ((i=1; i<=count; i++)); do
        while true; do
            read -r -p "Column $i name: " name
            if ! valid_name "$name"; then
                error "Invalid column name."
                continue
            fi

            local duplicate=0
            for existing in "${column_names[@]}"; do
                [[ "$existing" == "$name" ]] && duplicate=1
            done
            if (( duplicate )); then
                error "Column name already used."
                continue
            fi
            break
        done

        while true; do
            read -r -p "Data type for '$name': " type
            type="${type^^}"
            # Permit common types with optional numeric size/precision.
            if [[ "$type" =~ ^(INT|INTEGER|BIGINT|SMALLINT|TINYINT|FLOAT|DOUBLE|DATE|DATETIME|TIMESTAMP|TIME|YEAR|TEXT|LONGTEXT|MEDIUMTEXT|BOOLEAN|BOOL|VARCHAR\([0-9]+\)|CHAR\([0-9]+\)|DECIMAL\([0-9]+,[0-9]+\))$ ]]; then
                break
            fi
            error "Unsupported type. Use a type from the examples above."
        done

        column_names+=("$name")
        definitions+=("\`$name\` $type")
    done

    read -r -p "Primary key column (leave blank for none): " primary_key
    if [[ -n "$primary_key" ]]; then
        local found=0
        for name in "${column_names[@]}"; do
            [[ "$name" == "$primary_key" ]] && found=1
        done
        if (( ! found )); then
            error "Primary key must be one of the columns you defined."
            return
        fi
        definitions+=("PRIMARY KEY (\`$primary_key\`)")
    fi

    definition=$(IFS=,; echo "${definitions[*]}")

    if db -e "CREATE TABLE \`$DB_NAME\`.\`$TABLE_NAME\` ($definition);"; then
        success "Table '$TABLE_NAME' created."
        show_columns
    else
        error "Table creation failed."
    fi
}

display_tables() {
    require_database || return
    show_tables
}

display_table_structure() {
    require_table || return
    show_columns
}

truncate_table() {
    require_table || return
    warning "TRUNCATE removes every record but keeps the table structure."
    if confirm_action "Type yes to truncate '$TABLE_NAME'"; then
        if db -e "TRUNCATE TABLE \`$DB_NAME\`.\`$TABLE_NAME\`;"; then
            success "Table emptied."
        else
            error "Truncate failed."
        fi
    else
        info "Operation cancelled."
    fi
}

drop_table() {
    require_table || return
    warning "This permanently deletes table '$TABLE_NAME' and all its records."
    if confirm_action "Type yes to drop this table"; then
        if db -e "DROP TABLE \`$DB_NAME\`.\`$TABLE_NAME\`;"; then
            success "Table dropped."
        else
            error "Could not drop table."
        fi
    else
        info "Operation cancelled."
    fi
}

rename_table() {
    require_table || return
    local new_name
    read -r -p "Enter new table name: " new_name

    if ! valid_name "$new_name"; then
        error "Invalid table name."
        return
    fi

    if db -e "RENAME TABLE \`$DB_NAME\`.\`$TABLE_NAME\` TO \`$DB_NAME\`.\`$new_name\`;"; then
        success "Table renamed to '$new_name'."
    else
        error "Table rename failed."
    fi
}

# ---------- Record operations ----------
insert_record() {
    require_table || return

    local columns values col val escaped
    local -a col_names=()
    local -a col_values=()

    echo "Table columns:"
    show_columns

    read -r -p "Enter column names, comma-separated (blank = all columns): " columns

    if [[ -z "$columns" ]]; then
        read -r -p "How many values will you enter? " count
        if ! [[ "$count" =~ ^[1-9][0-9]*$ ]] || (( count > 50 )); then
            error "Invalid number of values."
            return
        fi

        for ((i=1; i<=count; i++)); do
            read -r -p "Value $i: " val
            escaped=$(quote_value "$val")
            col_values+=("'$escaped'")
        done
        values=$(IFS=,; echo "${col_values[*]}")

        if db -e "INSERT INTO \`$DB_NAME\`.\`$TABLE_NAME\` VALUES ($values);"; then
            success "Record inserted."
        else
            error "Insert failed. Check the number and types of values."
        fi
        return
    fi

    IFS=',' read -r -a col_names <<< "$columns"
    for ((i=0; i<${#col_names[@]}; i++)); do
        col="${col_names[$i]//[[:space:]]/}"
        if ! valid_name "$col"; then
            error "Invalid column name: $col"
            return
        fi
        col_names[$i]="\`$col\`"
    done

    for col in "${col_names[@]}"; do
        read -r -p "Value for ${col}: " val
        escaped=$(quote_value "$val")
        col_values+=("'$escaped'")
    done

    columns=$(IFS=,; echo "${col_names[*]}")
    values=$(IFS=,; echo "${col_values[*]}")

    if db -e "INSERT INTO \`$DB_NAME\`.\`$TABLE_NAME\` ($columns) VALUES ($values);"; then
        success "Record inserted."
    else
        error "Insert failed. Check column names and data types."
    fi
}

insert_dummy_students() {
    require_database || return
    read -r -p "Student table name (default: students): " TABLE_NAME
    TABLE_NAME="${TABLE_NAME:-students}"

    if ! valid_name "$TABLE_NAME"; then
        error "Invalid table name."
        return
    fi

    if ! table_exists; then
        info "Creating a sample students table."
        if ! db -e "CREATE TABLE \`$DB_NAME\`.\`$TABLE_NAME\` (
            id INT PRIMARY KEY,
            name VARCHAR(100),
            age INT,
            course VARCHAR(100)
        );"; then
            error "Could not create sample table."
            return
        fi
    fi

    if db -e "INSERT INTO \`$DB_NAME\`.\`$TABLE_NAME\` (id,name,age,course) VALUES
        (101,'Amit',21,'Java'),
        (102,'Neha',22,'Python'),
        (103,'Rahul',20,'Linux')
        ON DUPLICATE KEY UPDATE name=VALUES(name), age=VALUES(age), course=VALUES(course);"; then
        success "Sample student records inserted or updated."
        db -e "SELECT * FROM \`$DB_NAME\`.\`$TABLE_NAME\`;"
    else
        error "Could not insert sample data. Check that the table has the expected columns."
    fi
}

display_records() {
    require_table || return
    db -e "SELECT * FROM \`$DB_NAME\`.\`$TABLE_NAME\`;"
}

search_records() {
    require_table || return

    local column value escaped
    read -r -p "Column to search: " column
    if ! valid_name "$column"; then
        error "Invalid column name."
        return
    fi

    read -r -p "Value to search for: " value
    escaped=$(quote_value "$value")

    db -e "SELECT * FROM \`$DB_NAME\`.\`$TABLE_NAME\` WHERE \`$column\`='$escaped';"
}

update_record() {
    require_table || return

    local set_col set_val where_col where_val escaped_set escaped_where
    read -r -p "Column to update: " set_col
    read -r -p "New value: " set_val
    read -r -p "Condition column (WHERE): " where_col
    read -r -p "Condition value: " where_val

    if ! valid_name "$set_col" || ! valid_name "$where_col"; then
        error "Invalid column name."
        return
    fi

    escaped_set=$(quote_value "$set_val")
    escaped_where=$(quote_value "$where_val")

    echo "Matching records before update:"
    db -e "SELECT * FROM \`$DB_NAME\`.\`$TABLE_NAME\` WHERE \`$where_col\`='$escaped_where';"

    if ! confirm_action "Apply this update"; then
        info "Operation cancelled."
        return
    fi

    if db -e "UPDATE \`$DB_NAME\`.\`$TABLE_NAME\` SET \`$set_col\`='$escaped_set' WHERE \`$where_col\`='$escaped_where';"; then
        success "Update statement executed."
    else
        error "Update failed."
    fi
}

delete_record() {
    require_table || return

    local where_col where_val escaped
    read -r -p "Condition column (WHERE): " where_col
    if ! valid_name "$where_col"; then
        error "Invalid column name."
        return
    fi

    read -r -p "Condition value: " where_val
    escaped=$(quote_value "$where_val")

    echo "Matching records:"
    db -e "SELECT * FROM \`$DB_NAME\`.\`$TABLE_NAME\` WHERE \`$where_col\`='$escaped';"

    warning "Only records matching this condition will be deleted."
    if ! confirm_action "Delete these records"; then
        info "Operation cancelled."
        return
    fi

    if db -e "DELETE FROM \`$DB_NAME\`.\`$TABLE_NAME\` WHERE \`$where_col\`='$escaped';"; then
        success "Delete statement executed."
    else
        error "Delete failed."
    fi
}

# ---------- Column operations ----------
add_column() {
    require_table || return

    local column type
    read -r -p "New column name: " column
    if ! valid_name "$column"; then
        error "Invalid column name."
        return
    fi

    read -r -p "Column type (e.g. VARCHAR(100), INT, DATE): " type
    type="${type^^}"
    if [[ ! "$type" =~ ^(INT|INTEGER|BIGINT|SMALLINT|TINYINT|FLOAT|DOUBLE|DATE|DATETIME|TIMESTAMP|TIME|YEAR|TEXT|LONGTEXT|MEDIUMTEXT|BOOLEAN|BOOL|VARCHAR\([0-9]+\)|CHAR\([0-9]+\)|DECIMAL\([0-9]+,[0-9]+\))$ ]]; then
        error "Unsupported column type."
        return
    fi

    if db -e "ALTER TABLE \`$DB_NAME\`.\`$TABLE_NAME\` ADD COLUMN \`$column\` $type;"; then
        success "Column '$column' added."
        show_columns
    else
        error "Could not add column."
    fi
}

modify_column() {
    require_table || return

    local column type
    read -r -p "Column to modify: " column
    if ! valid_name "$column"; then
        error "Invalid column name."
        return
    fi

    read -r -p "New data type: " type
    type="${type^^}"
    if [[ ! "$type" =~ ^(INT|INTEGER|BIGINT|SMALLINT|TINYINT|FLOAT|DOUBLE|DATE|DATETIME|TIMESTAMP|TIME|YEAR|TEXT|LONGTEXT|MEDIUMTEXT|BOOLEAN|BOOL|VARCHAR\([0-9]+\)|CHAR\([0-9]+\)|DECIMAL\([0-9]+,[0-9]+\))$ ]]; then
        error "Unsupported column type."
        return
    fi

    warning "Changing a column type can truncate or alter existing data."
    if confirm_action "Continue with column modification"; then
        if db -e "ALTER TABLE \`$DB_NAME\`.\`$TABLE_NAME\` MODIFY COLUMN \`$column\` $type;"; then
            success "Column modified."
            show_columns
        else
            error "Could not modify column."
        fi
    fi
}

rename_column() {
    require_table || return

    local old_name new_name type
    read -r -p "Current column name: " old_name
    read -r -p "New column name: " new_name

    if ! valid_name "$old_name" || ! valid_name "$new_name"; then
        error "Invalid column name."
        return
    fi

    read -r -p "Current column data type (e.g. INT, VARCHAR(100)): " type
    type="${type^^}"
    if [[ ! "$type" =~ ^(INT|INTEGER|BIGINT|SMALLINT|TINYINT|FLOAT|DOUBLE|DATE|DATETIME|TIMESTAMP|TIME|YEAR|TEXT|LONGTEXT|MEDIUMTEXT|BOOLEAN|BOOL|VARCHAR\([0-9]+\)|CHAR\([0-9]+\)|DECIMAL\([0-9]+,[0-9]+\))$ ]]; then
        error "Unsupported data type."
        return
    fi

    if db -e "ALTER TABLE \`$DB_NAME\`.\`$TABLE_NAME\` CHANGE COLUMN \`$old_name\` \`$new_name\` $type;"; then
        success "Column renamed."
        show_columns
    else
        error "Could not rename column. Verify the old name and data type."
    fi
}

drop_column() {
    require_table || return

    local column
    read -r -p "Column to drop: " column
    if ! valid_name "$column"; then
        error "Invalid column name."
        return
    fi

    warning "Dropping a column permanently deletes its data."
    if confirm_action "Drop column '$column'"; then
        if db -e "ALTER TABLE \`$DB_NAME\`.\`$TABLE_NAME\` DROP COLUMN \`$column\`;"; then
            success "Column dropped."
            show_columns
        else
            error "Could not drop column. It may be required by a key or constraint."
        fi
    fi
}

# ---------- Backup and restore ----------
backup_database() {
    require_database || return

    local file
    read -r -p "Backup file path (e.g. /root/${DB_NAME}_backup.sql): " file
    if [[ -z "$file" ]]; then
        error "Backup path cannot be empty."
        return
    fi

    if [[ -e "$file" ]]; then
        warning "The file already exists."
        if ! confirm_action "Overwrite '$file'"; then
            info "Backup cancelled."
            return
        fi
    fi

    if db_dump "$DB_NAME" > "$file"; then
        success "Backup created: $file"
        ls -lh "$file"
    else
        rm -f "$file"
        error "Backup failed."
    fi
}

restore_database() {
    read_database || return

    local file
    read -r -p "SQL backup file path: " file
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        error "File does not exist or cannot be read."
        return
    fi

    if ! database_exists; then
        if confirm_action "Database '$DB_NAME' does not exist. Create it"; then
            if ! db -e "CREATE DATABASE \`$DB_NAME\`;"; then
                error "Could not create database."
                return
            fi
        else
            info "Restore cancelled."
            return
        fi
    fi

    warning "Only restore SQL backup files that you trust."
    if confirm_action "Restore '$file' into database '$DB_NAME'"; then
        if db "$DB_NAME" < "$file"; then
            success "Restore completed."
        else
            error "Restore failed. Check the SQL file and database."
        fi
    fi
}

# ---------- User and permission operations ----------
create_user() {
    local username password db_name grant_choice grants escaped_password

    read -r -p "New MariaDB username: " username
    if ! valid_name "$username"; then
        error "Invalid username."
        return
    fi

    read -r -s -p "Password (letters, numbers, _ ! @ # . - only): " password
    echo
    if [[ ! "$password" =~ ^[A-Za-z0-9_!@#.-]{8,128}$ ]]; then
        error "Use 8-128 characters from the allowed set shown above."
        return
    fi

    read -r -p "Database for this user (or * for all databases): " db_name
    if [[ "$db_name" != "*" ]]; then
        if ! valid_name "$db_name"; then
            error "Invalid database name."
            return
        fi
        DB_NAME="$db_name"
        if ! database_exists; then
            error "Database '$db_name' does not exist."
            return
        fi
    fi

    echo
    echo "Permission choices:"
    echo "1. ALL PRIVILEGES"
    echo "2. SELECT only"
    echo "3. SELECT, INSERT, UPDATE, DELETE"
    echo "4. SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX"
    echo "5. Create user with no database permissions"
    read -r -p "Choose permissions [1-5]: " grant_choice

    case "$grant_choice" in
        1) grants="ALL PRIVILEGES" ;;
        2) grants="SELECT" ;;
        3) grants="SELECT, INSERT, UPDATE, DELETE" ;;
        4) grants="SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX" ;;
        5) grants="" ;;
        *) error "Invalid permission choice."; return ;;
    esac

    escaped_password=$(quote_value "$password")

    if ! db -e "CREATE USER IF NOT EXISTS '$username'@'localhost' IDENTIFIED BY '$escaped_password';"; then
        error "Could not create user."
        return
    fi

    if [[ -n "$grants" ]]; then
        if db -e "GRANT $grants ON \`$db_name\`.* TO '$username'@'localhost';"; then
            success "User '$username' created or already exists; permissions applied."
        else
            error "User exists, but permissions could not be applied."
        fi
    else
        success "User '$username' created or already exists with no database permissions added."
    fi

    warning "CREATE USER IF NOT EXISTS does not change the password of an existing user."
}

display_users() {
    db -e "SELECT User, Host FROM mysql.user ORDER BY User, Host;"
}

show_user_grants() {
    local username
    read -r -p "Username: " username
    if ! valid_name "$username"; then
        error "Invalid username."
        return
    fi

    db -e "SHOW GRANTS FOR '$username'@'localhost';"
}

grant_permissions() {
    local username db_name choice grants
    read -r -p "Username: " username
    if ! valid_name "$username"; then
        error "Invalid username."
        return
    fi

    read -r -p "Database name: " db_name
    if ! valid_name "$db_name"; then
        error "Invalid database name."
        return
    fi

    DB_NAME="$db_name"
    if ! database_exists; then
        error "Database does not exist."
        return
    fi

    echo "1. ALL PRIVILEGES"
    echo "2. SELECT"
    echo "3. SELECT, INSERT, UPDATE, DELETE"
    echo "4. SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX"
    read -r -p "Choose permissions [1-4]: " choice

    case "$choice" in
        1) grants="ALL PRIVILEGES" ;;
        2) grants="SELECT" ;;
        3) grants="SELECT, INSERT, UPDATE, DELETE" ;;
        4) grants="SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX" ;;
        *) error "Invalid choice."; return ;;
    esac

    if db -e "GRANT $grants ON \`$db_name\`.* TO '$username'@'localhost';"; then
        success "Permissions granted."
    else
        error "Could not grant permissions. Verify the user exists."
    fi
}

revoke_permissions() {
    local username db_name
    read -r -p "Username: " username
    read -r -p "Database name: " db_name

    if ! valid_name "$username" || ! valid_name "$db_name"; then
        error "Invalid username or database name."
        return
    fi

    warning "This revokes all database-level privileges on '$db_name' for '$username'."
    if confirm_action "Continue"; then
        if db -e "REVOKE ALL PRIVILEGES ON \`$db_name\`.* FROM '$username'@'localhost';"; then
            success "Database-level privileges revoked."
        else
            error "Could not revoke privileges."
        fi
    fi
}

change_user_password() {
    local username password escaped
    read -r -p "Username: " username
    if ! valid_name "$username"; then
        error "Invalid username."
        return
    fi

    read -r -s -p "New password (letters, numbers, _ ! @ # . - only): " password
    echo
    if [[ ! "$password" =~ ^[A-Za-z0-9_!@#.-]{8,128}$ ]]; then
        error "Use 8-128 characters from the allowed set shown above."
        return
    fi

    escaped=$(quote_value "$password")
    if db -e "ALTER USER '$username'@'localhost' IDENTIFIED BY '$escaped';"; then
        success "Password updated."
    else
        error "Could not change password. Check that the user exists."
    fi
}

drop_user() {
    local username
    read -r -p "Username to drop: " username
    if ! valid_name "$username"; then
        error "Invalid username."
        return
    fi

    warning "Dropping a user removes this account, not the databases it owns."
    if confirm_action "Drop user '$username'@'localhost'"; then
        if db -e "DROP USER '$username'@'localhost';"; then
            success "User dropped."
        else
            error "Could not drop user. Verify the account exists."
        fi
    fi
}

# ---------- Service operations ----------
service_status() {
    echo
    echo "MariaDB service status:"
    systemctl status mariadb --no-pager
    echo
    echo "Service enabled at boot:"
    systemctl is-enabled mariadb 2>/dev/null || true
    echo
    echo "Service active state:"
    systemctl is-active mariadb 2>/dev/null || true
}

service_action() {
    local action
    echo "1. Start MariaDB"
    echo "2. Stop MariaDB"
    echo "3. Restart MariaDB"
    echo "4. Enable MariaDB at boot"
    echo "5. Disable MariaDB at boot"
    read -r -p "Choose action [1-5]: " action

    case "$action" in
        1) systemctl start mariadb && success "MariaDB started." ;;
        2)
            warning "Stopping MariaDB interrupts database connections."
            if confirm_action "Stop MariaDB"; then
                systemctl stop mariadb && success "MariaDB stopped."
            fi
            ;;
        3) systemctl restart mariadb && success "MariaDB restarted." ;;
        4) systemctl enable mariadb && success "MariaDB enabled at boot." ;;
        5)
            if confirm_action "Disable MariaDB at boot"; then
                systemctl disable mariadb && success "MariaDB disabled at boot."
            fi
            ;;
        *) error "Invalid choice." ;;
    esac
}

# ---------- First-install wizard ----------
initial_setup() {
    [[ "$FIRST_INSTALL" -eq 1 ]] || return

    echo
    echo "=================================================="
    echo "          First-Time MariaDB Setup"
    echo "=================================================="
    echo "MariaDB has just been installed."
    echo "You can create an initial database and user now."
    echo

    if confirm_action "Create an initial database"; then
        create_database

        if [[ -n "${DB_NAME:-}" ]] && database_exists; then
            if confirm_action "Create a database user now"; then
                create_user
            fi
        fi
    else
        info "Skipping initial database and user setup."
    fi
}

# ---------- Main menu ----------
show_menu() {
    echo
    echo "=================================================="
    echo "          MariaDB Database Management"
    echo "=================================================="
    printf " Service : MariaDB\n"
    printf " Status  : %s\n" "$(systemctl is-active mariadb 2>/dev/null || echo unknown)"
    echo "=================================================="
    echo " 1.  Create database"
    echo " 2.  Display all databases"
    echo " 3.  Select / verify a database"
    echo " 4.  Drop database"
    echo "--------------------------------------------------"
    echo " 5.  Create table with custom columns"
    echo " 6.  Display tables in a database"
    echo " 7.  Display table structure"
    echo " 8.  Truncate table (delete all records)"
    echo " 9.  Drop table"
    echo "10.  Rename table"
    echo "--------------------------------------------------"
    echo "11.  Insert one record into a table"
    echo "12.  Insert dummy student data"
    echo "13.  Display table records"
    echo "14.  Search records"
    echo "15.  Update a record"
    echo "16.  Delete record(s)"
    echo "--------------------------------------------------"
    echo "17.  Add a column"
    echo "18.  Modify column data type"
    echo "19.  Rename a column"
    echo "20.  Drop a column"
    echo "--------------------------------------------------"
    echo "21.  Back up a database"
    echo "22.  Restore a database backup"
    echo "--------------------------------------------------"
    echo "23.  Create user and grant permissions"
    echo "24.  Display database users"
    echo "25.  Show user grants"
    echo "26.  Grant permissions"
    echo "27.  Revoke database permissions"
    echo "28.  Change user password"
    echo "29.  Drop user"
    echo "--------------------------------------------------"
    echo "30.  MariaDB service status"
    echo "31.  Start / stop / restart / enable service"
    echo " 0.  Exit"
    echo "=================================================="
}

main() {
    check_root
    install_mariadb
    authenticate_root
    initial_setup

    while true; do
        show_menu
        read -r -p "Enter your choice: " choice
        echo

        case "$choice" in
            1)  create_database ;;
            2)  display_databases ;;
            3)  select_database ;;
            4)  drop_database ;;
            5)  create_table ;;
            6)  display_tables ;;
            7)  display_table_structure ;;
            8)  truncate_table ;;
            9)  drop_table ;;
            10) rename_table ;;
            11) insert_record ;;
            12) insert_dummy_students ;;
            13) display_records ;;
            14) search_records ;;
            15) update_record ;;
            16) delete_record ;;
            17) add_column ;;
            18) modify_column ;;
            19) rename_column ;;
            20) drop_column ;;
            21) backup_database ;;
            22) restore_database ;;
            23) create_user ;;
            24) display_users ;;
            25) show_user_grants ;;
            26) grant_permissions ;;
            27) revoke_permissions ;;
            28) change_user_password ;;
            29) drop_user ;;
            30) service_status ;;
            31) service_action ;;
            0)
                echo "Exiting MariaDB Database Management."
                exit 0
                ;;
            *)
                error "Invalid choice. Enter a number from 0 to 31."
                ;;
        esac

        echo
        pause_screen
    done
}

main
