#!/usr/bin/env bash

###############################################################################
#                                                                             #
# Nextcloud automatic installation script                                     #
#                                                                             #
# Designed for stressed VUAs with little to no wish to copypaste a gadzillion #
# UNIX commands.                                                              #
#                                                                             #
# Copyright (c) 2020 - Bryan Pedini                                           #
#                                                                             #
###############################################################################

_parse_params() {
    VERBOSE=true
    VERSION="18.0.4"
    INSTALL_DIR="/var/www/nextcloud"
    NO_CONFIGURE_MARIADB=false
    DATABASE_NAME="nextcloud"
    DATABASE_USER="nextcloud_admin"
    for par in "$@"; do
        case "$par" in
            "-h" | "--help" | "--usage")
                _print_usage
                ;;
            "-q" | "--quiet")
                VERBOSE=false
                shift
                ;;
            "--version")
                [[ -z "$2" ]] && _print_usage "Version not specified" 1
                [[ "$2:0:1" = "-" ]] && _print_usage
                VERSION="$2"
                shift
                shift
                ;;
            "--install-dir")
                [[ -z "$2" ]] && _print_usage "Installation directory not \
specified" 1
                [[ "$2:0:1" = "-" ]] && _print_usage
                INSTALL_DIR="$2"
                shift
                shift
                ;;
            "--no-configure-mariadb")
                NO_CONFIGURE_MARIADB=true
                shift
                ;;
            "--database-name")
                [[ -z "$2" ]] && _print_usage "Database name not speficied" 1
                [[ "$2:0:1" = "-" ]] && _print_usage
                DATABASE_NAME="$2"
                shift
                shift
                ;;
            "--database-user")
                [[ -z "$2" ]] && _print_usage "Database admin user not \
specified" 1
                [[ "$2:0:1" = "-" ]] && _print_usage
                DATABASE_USER="$2"
                shift
                shift
                ;;
            *)
                _print_usage "Argument not recognized: $1" 1
        esac
    done
}

# Usage explaination printed to console
_print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "OPTIONS:"
    echo "  -h, --help, --usage     Prints this help message and exits"
    echo "  -q, --quiet             Turns off verbose logging (default: False)"
    echo "  --version               Install a custom version of Nextcloud
                            (default: $VERSION)"
    echo "  --install-dir           Specifies a custom path for installation
                            (default: \"/var/www/nextcloud\")"
    echo "  --no-configure-mariadb  Does not launch the default MariaDB server
                            configuration scriptlet (default: False)"
    echo "  --database-name         Specifies a custom database name
                            (default: \"nextcloud\")"
    echo "  --database-user         Specifies a custom database admin user
                            (default \"nextcloud_admin\")"

    if [ "$1" ]; then
        echo
        echo "Error: $1"
        if [ "$2" ]; then
            exit $2
        fi
    fi
    exit 0
}

# Update current system
_update_system() {
    [[ "$VERBOSE" = true ]] && echo "Updating current system"
    ERR=$( { apt update 1>/dev/null; } 2>&1 | grep -v "stable CLI interface" )
    [[ "$ERR" ]] && echo "Error during package cache update: $ERR"
    ERR=$( { apt -y upgrade 1>/dev/null; } 2>&1 | grep -v \
    "stable CLI interface" )
    [[ "$ERR" ]] && echo "Error during system package updates: $ERR"
}

# Ask the user for mysql `root` password and configure mysql in unattended mode
_configure_mariadb_server() {
    read -sp 'Please type a `root` password for mysql database: ' \
        MYSQL_ROOT_PASSWORD && echo ""

    [[ "$VERBOSE" = true ]] && echo "Configuring mysql in unattended mode"
    ERR=$( { apt -y install expect >/dev/null; } 2>&1 | grep -v \
    "stable CLI interface" )
    [[ "$ERR" ]] && echo "Error during package installations: $ERR"
    SECURE_MYSQL=$(expect -c "
        set timeout 10
        spawn mysql_secure_installation
        expect \"Enter current password for root (enter for none):\"
        send \"\r\"
        expect \"Set root password?\"
        send \"y\r\"
        expect \"New password:\"
        send \"$MYSQL_ROOT_PASSWORD\r\"
        expect \"Re-enter new password:\"
        send \"$MYSQL_ROOT_PASSWORD\r\"
        expect \"Remove anonymous users?\"
        send \"y\r\"
        expect \"Disallow root login remotely?\"
        send \"y\r\"
        expect \"Remove test database and access to it?\"
        send \"y\r\"
        expect \"Reload privilege tables now?\"
        send \"y\r\"
        expect eof
    ")
    ERR=$( { echo "$SECURE_MYSQL" 1>/dev/null; } 2>&1 )
    [[ "$ERR" ]] && echo "Error during mysql_initialization: $ERR"
    ERR=$( { apt -y remove --purge expect >/dev/null; } 2>&1 | \
        grep -v "stable CLI interface" )
    [[ "$ERR" ]] && echo "Error during package removals: $ERR"

    unset SECURE_MYSQL
}

# Create Nextcloud database with associated login
_configure_database() {
    [[ "$VERBOSE" = true ]] && echo "Creating Nextcloud database with \
associated login"
    MYSQL_ROOT_USER="root"
    QUERY="command=password&format=plain&scheme=rrnnnrrnrnnnrrnrnnrr"
    MYSQL_USER_PASSWORD=$(curl -s \
    "https://www.passwordrandom.com/query?$QUERY")
    SQL="CREATE DATABASE nextcloud;"
    mysql -u$MYSQL_ROOT_USER -p$MYSQL_ROOT_PASSWORD -e "$SQL"
    SQL="GRANT ALL PRIVILEGES ON nextcloud.* TO nextcloud_admin@localhost
    IDENTIFIED BY '$MYSQL_USER_PASSWORD';"
    mysql -u$MYSQL_ROOT_USER -p$MYSQL_ROOT_PASSWORD -e "$SQL"
    SQL="FLUSH PRIVILEGES;"
    mysql -u$MYSQL_ROOT_USER -p$MYSQL_ROOT_PASSWORD -e "$SQL"

    unset SQL; unset MYSQL_ROOT_USER; unset MYSQL_ROOT_PASSWORD; unset QUERY
}

# Create required folders and set correct permissions
_configure_permissions() {    
    [[ "$VERBOSE" = true ]] && echo "Creating required folders and setting \
correct permissions"
    mkdir -p "$INSTALL_DIR"/{public,data}
    chown -R www-data:www-data "$INSTALL_DIR"
}

# Configure Apache2 to run the website
_configure_apache2() {
    # Ask the user for Apache2 FQDN hostname
    read -p 'Please type the FQDN Nextcloud should run on: ' \
    HOSTNAME && echo ""

    [[ "$VERBOSE" = true ]] && echo "Configuring Apache2 to run the website"
    cat << "EOF" > /etc/apache2/sites-available/cloud.conf
<VirtualHost *:80>
    ServerName $HOSTNAME
    DocumentRoot "$INSTALL_DIR/public"

    <Directory "$INSTALL_DIR/public">
            Allow from all
            Require all granted
    </Directory>

    ErrorLog $INSTALL_DIR/error.log
    CustomLog $INSTALL_DIR/access.log combined
</VirtualHost>
EOF
    unset HOSTNAME; unset INSTALL_DIR
}

# Main program function, calls all other functions in the correct order
_main() {
    _update_system
    _configure_permissions
    [[ "$NO_CONFIGURE_MARIADB" = false ]] && _configure_mariadb_server
    _configure_database
    _download_website
    _configure_apache2
    _enable_site
}

# Program execution
_parse_params $@
_main
