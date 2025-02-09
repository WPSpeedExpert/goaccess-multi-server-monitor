#!/bin/bash
# =========================================================================== #
# Script Name:       goaccess_multi_server_monitor.sh
# Description:       Interactive GoAccess multi-server monitoring setup
# Version:           1.3.3
# Author:            OctaHexa Media LLC
# Credits:           Nginx to GoAccess log format conversion based on 
#                    https://github.com/stockrt/nginx2goaccess
# Last Modified:     2025-02-09
# Dependencies:      Debian 12, CloudPanel
# =========================================================================== #

# Exit on error, undefined vars, and pipe failures
set -euo pipefail

# Logging function with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Error handling function
error_exit() {
    log_message "ERROR: $1"
    exit 1
}

# Derive site user from domain
derive_siteuser() {
    local domain=$1
    local main_domain=$(echo "$domain" | awk -F. '{print $(NF-1)}')
    local subdomain=$(echo "$domain" | awk -F. '{print $1}')

    if [[ "$subdomain" == "www" || "$subdomain" == "$main_domain" ]]; then
        echo "$main_domain"
    else
        echo "$main_domain-$subdomain"
    fi
}

# Check if the domain exists
check_domain_exists() {
    local domain=$1
    local site_user=$(derive_siteuser "$domain")

    # First, check if the user exists in CloudPanel
    if clpctl user:list | grep -q "$site_user"; then
        return 0 # Domain exists
    fi

    # Fallback: Check if the home directory for the siteuser exists
    if [ -d "/home/$site_user" ]; then
        return 0 # Domain exists
    fi

    return 1 # Domain does not exist
}

# Nginx to GoAccess log format conversion function
nginx2goaccess() {
    local log_format="$1"
    local conversion_table=(
        "time_local,%d:%t %^"
        "host,%v"
        "http_host,%v"
        "remote_addr,%h"
        "request_time,%T"
        "request_method,%m"
        "request_uri,%U"
        "server_protocol,%H"
        "request,%r"
        "status,%s"
        "body_bytes_sent,%b"
        "bytes_sent,%b"
        "http_referer,%R"
        "http_user_agent,%u"
        "http_x_forwarded_for,%^"
    )

    # Replace Nginx variables with GoAccess variables
    for item in "${conversion_table[@]}"; do
        nginx_var="${item%%,*}"
        goaccess_var="${item##*,}"

        # Replace ${variable} syntax
        log_format="${log_format//\${nginx_var\}/$goaccess_var}"
        # Replace $variable syntax
        log_format="${log_format//\$nginx_var/$goaccess_var}"
    done

    # Replace any remaining unhandled variables with %^
    log_format=$(echo "$log_format" | sed -E 's/\${?[a-z_]+}?/%^/g')

    echo "$log_format"
}

# Generate a secure 12-character password
generate_password() {
    < /dev/urandom tr -dc 'A-Za-z0-9' | head -c12
}

# Validate domain name
validate_domain() {
    local domain=$1
    if [[ ! $domain =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_message "Invalid domain name: $domain"
        return 1
    fi
}

# Check and optionally reinstall GoAccess
check_goaccess_installation() {
    if command -v goaccess &> /dev/null; then
        echo "GoAccess is already installed."
        read -p "Do you want to reinstall GoAccess? (y/N): " REINSTALL
        if [[ "$REINSTALL" =~ ^[Yy]$ ]]; then
            log_message "Reinstalling GoAccess..."
            apt-get remove --purge -y goaccess || true
            apt-get install -y goaccess || error_exit "Failed to reinstall GoAccess."
            log_message "GoAccess reinstalled successfully."
        else
            log_message "Skipping GoAccess reinstallation."
        fi
    else
        log_message "Installing GoAccess..."
        apt-get install -y goaccess || error_exit "Failed to install GoAccess."
        log_message "GoAccess installed successfully."
    fi
}

# Main installation function
main_installation() {
    set -e  # Ensure function fails on any error

    clear
    echo "========================================="
    echo "   GoAccess Multi-Server Monitoring     "
    echo "========================================="
    echo ""

    # Domain configuration
    local GOACCESS_DOMAIN
    while true; do
        read -p "Enter domain for GoAccess monitoring (e.g., stats.octahexa.com): " GOACCESS_DOMAIN
        if validate_domain "$GOACCESS_DOMAIN"; then
            break
        else
            echo "Please enter a valid domain name."
        fi
    done

    # Derive siteuser from domain
    local SITE_USER=$(derive_siteuser "$GOACCESS_DOMAIN")
    local SITE_USER_PASSWORD=$(generate_password)

    # Check if the domain already exists
    if check_domain_exists "$GOACCESS_DOMAIN"; then
        log_message "Domain $GOACCESS_DOMAIN already exists."
        echo "Options:"
        echo "1) Stop the installation"
        echo "2) Delete the domain and recreate it"
        read -p "Enter your choice (1-2): " DOMAIN_ACTION

        case $DOMAIN_ACTION in
            1)
                log_message "Installation stopped by user."
                exit 0
                ;;
            2)
                log_message "Deleting existing domain $GOACCESS_DOMAIN..."
                clpctl site:delete --domainName="$GOACCESS_DOMAIN" --force || error_exit "Failed to delete domain $GOACCESS_DOMAIN."
                log_message "Domain $GOACCESS_DOMAIN deleted successfully."
                ;;
            *)
                error_exit "Invalid choice. Exiting installation."
                ;;
        esac
    fi

    # Log format configuration
    echo ""
    echo "Log Format Configuration:"
    echo "1. Standard Nginx Log Format"
    echo "2. Cloudflare Nginx Log Format"
    echo "3. Enter custom Nginx log format"
    read -p "Choose an option (1-3, default: 1): " LOG_FORMAT_CHOICE

    case ${LOG_FORMAT_CHOICE:-1} in
        1)
            GOACCESS_LOG_FORMAT="%h - %^ [%d:%t %^] \"%r\" %s %b \"%R\" \"%u\" \"%v\""
            LOG_FORMAT_NAME="Standard"
            ;;
        2)
            GOACCESS_LOG_FORMAT="%v - %^ [%d:%t %^] \"%r\" %s %b \"%R\" \"%u\" \"%v\""
            LOG_FORMAT_NAME="Cloudflare"
            ;;
        3)
            read -p "Enter your Nginx log format (e.g., '\$remote_addr - \$remote_user [\$time_local] \"\$request\" \$status \$body_bytes_sent'): " CUSTOM_LOG_FORMAT
            GOACCESS_LOG_FORMAT=$(nginx2goaccess "$CUSTOM_LOG_FORMAT")
            LOG_FORMAT_NAME="Custom"
            echo "Converted GoAccess Log Format: $GOACCESS_LOG_FORMAT"
            ;;
        *)
            GOACCESS_LOG_FORMAT="%h - %^ [%d:%t %^] \"%r\" %s %b \"%R\" \"%u\" \"%v\""
            LOG_FORMAT_NAME="Standard"
            ;;
    esac

    echo "Selected Log Format: $LOG_FORMAT_NAME"

    # Server configuration
    local REMOTE_SERVERS=()
    while true; do
        read -p "Enter a remote CloudPanel server to monitor (format: user@hostname, or leave blank to stop): " SERVER
        if [[ -z "$SERVER" ]]; then
            break
        fi
        REMOTE_SERVERS+=("$SERVER")
    done

    if [[ ${#REMOTE_SERVERS[@]} -eq 0 ]]; then
        error_exit "No servers were configured. Exiting installation."
    fi

    echo ""
    echo "Configuration Summary:"
    echo "--------------------"
    echo "Monitoring Domain: $GOACCESS_DOMAIN"
    echo "Site User: $SITE_USER"
    echo "Log Format: $LOG_FORMAT_NAME"
    echo "Servers to Monitor:"
    for server in "${REMOTE_SERVERS[@]}"; do
        echo "- $server"
    done

    read -p "Confirm installation? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_message "Installation cancelled by user."
        return 1
    fi

    # Check and install GoAccess
    check_goaccess_installation

    # Proceed to create the site
    log_message "Creating CloudPanel site for GoAccess..."
    clpctl site:add:reverse-proxy \
        --domainName="$GOACCESS_DOMAIN" \
        --reverseProxyUrl="http://localhost:7890" \
        --siteUser="$SITE_USER" \
        --siteUserPassword="$SITE_USER_PASSWORD" \
        || error_exit "Failed to create CloudPanel site"

    # Install SSL Certificate
    log_message "Installing SSL Certificate for GoAccess domain..."
    clpctl lets-encrypt:install:certificate --domainName="$GOACCESS_DOMAIN" \
        || log_message "WARNING: SSL Certificate installation failed"

    # Create GoAccess configuration with selected log format
    mkdir -p /etc/goaccess
    cat > /etc/goaccess/goaccess.conf << EOF
# GoAccess Configuration with ${LOG_FORMAT_NAME} Log Format

# Time and Date Formats
time-format %T
date-format %d/%b/%Y

# Log Format
log-format $GOACCESS_LOG_FORMAT

# General Options
port 7890
real-time-html true
ws-url wss://${GOACCESS_DOMAIN}
output /home/${SITE_USER}/htdocs/${GOACCESS_DOMAIN}/public/index.html
debug-file /var/log/goaccess/debug.log

# Log Processing Options
keep-last 30
load-from-disk true

# Persistent Storage
db-path /var/lib/goaccess/
restore true
persist true

# UI Customization
html-report-title "Web Server Analytics"
no-html-last-updated true
EOF

    # Create credentials file with instructions
    cat > /root/goaccess_monitor_credentials.txt << EOF
GoAccess Multi-Server Monitoring Credentials
============================================
Domain: $GOACCESS_DOMAIN
Site User: $SITE_USER
Site User Password: $SITE_USER_PASSWORD

Monitored Servers:
$(printf '- %s\n' "${REMOTE_SERVERS[@]}")

SSH KEY LOCATION:
/home/${SITE_USER}/.ssh/id_ed25519

MODIFY MONITORING CONFIGURATION:
1. Add/Remove Servers:
   - Edit server list in /etc/goaccess/monitored_servers
   - Run /usr/local/bin/update-server-monitoring.sh

2. Manually Add a Server:
   a) Copy SSH public key to new server:
      ssh-copy-id -i /home/${SITE_USER}/.ssh/id_ed25519.pub user@newserver.example.com

   b) Add server to monitoring configuration:
      echo "user@newserver.example.com" >> /etc/goaccess/monitored_servers
      /usr/local/bin/update-server-monitoring.sh

3. Remove a Server:
   a) Remove server from /etc/goaccess/monitored_servers
   b) Run /usr/local/bin/update-server-monitoring.sh

SECURITY NOTES:
- Protect the SSH private key
- Use key-based authentication
- Limit SSH access

Access Web Analytics:
https://$GOACCESS_DOMAIN
EOF

    # Print important installation information
    echo ""
    echo "========================================="
    echo "   IMPORTANT INSTALLATION INFORMATION   "
    echo "========================================="
    echo ""
    echo "1. Credentials and Access:"
    echo "   - Credentials file: /root/goaccess_monitor_credentials.txt"
    echo "   - Access URL: https://$GOACCESS_DOMAIN"
    echo ""
    echo "2. Server Monitoring Management:"
    echo "   - Add/Remove Servers: Edit /etc/goaccess/monitored_servers"
    echo "   - Update Monitoring: /usr/local/bin/update-server-monitoring.sh"
    echo ""
    echo "3. SSL Certificate:"
    echo "   - Domain: $GOACCESS_DOMAIN"
    echo "   - Installed via Let's Encrypt"
    echo ""
    echo "4. SSH Key Management:"
    echo "   - Monitoring SSH Key: /home/${SITE_USER}/.ssh/id_ed25519"
    echo "   - Distribute this key to remote servers using: ssh-copy-id"
    echo ""
    echo "5. Log Locations:"
    echo "   - Remote Server Logs: /var/log/remote-servers/"
    echo "   - GoAccess Reports: /home/$SITE_USER/htdocs/$GOACCESS_DOMAIN/public/reports/"
    echo ""
    echo "6. Configuration Files:"
    echo "   - GoAccess Config: /etc/goaccess/goaccess.conf"
    echo "   - Server List: /etc/goaccess/monitored_servers"
    echo ""
    echo "SECURITY REMINDER: Protect your SSH keys and credentials!"
    echo ""

    # Final success message
    log_message "GoAccess Multi-Server Monitoring installation completed successfully!"
    echo "Access the monitoring dashboard at: https://$GOACCESS_DOMAIN"
    return 0
}

# Main script execution
main() {
    # Ensure script is run as root
    if [ "$EUID" -ne 0 ]; then
        log_message "Please run as root"
        exit 1
    fi

    # Check CloudPanel installation
    if ! command -v clpctl &> /dev/null; then
        log_message "CloudPanel is not installed. This script requires a pre-installed CloudPanel."
        exit 1
    fi

    # Check if GoAccess is already installed
    check_goaccess_installation

    # Run main installation with error handling
    if main_installation; then
        log_message "Installation completed successfully."
        exit 0
    else
        log_message "Installation failed or was cancelled."
        exit 1
    fi
}

# Execute main function
main
