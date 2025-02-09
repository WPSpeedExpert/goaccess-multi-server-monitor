#!/bin/bash
# =========================================================================== #
# Script Name:       goaccess_multi_server_monitor.sh
# Description:       Interactive GoAccess multi-server monitoring setup
# Version:           1.3.4
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
    local site_user
    if [[ "$domain" =~ ^www\. ]]; then
        site_user=${domain:4} # Remove 'www.' prefix
    else
        site_user=$domain
    fi
    echo "${site_user%%.*}" # Extract site_user before the first period
}

# Check if the domain exists
check_domain_exists() {
    local domain=$1
    local site_user=$(derive_siteuser "$domain")

    # First, check if the user exists in CloudPanel
    if clpctl user:list | grep -q "${site_user}"; then
        return 0 # Domain exists
    fi

    # Fallback: Check if the home directory for the siteuser exists
    if [ -d "/home/${site_user}" ]; then
        return 0 # Domain exists
    fi

    return 1 # Domain does not exist
}

# Nginx to GoAccess log format conversion function
# Original script: https://github.com/stockrt/nginx2goaccess
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

# Main installation function
main_installation() {
    # Ensure function fails on any error
    set -e

    # Clear screen and display header
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

    # Generate site user and password
    local SITE_USER=$(derive_siteuser "$GOACCESS_DOMAIN")
    local SITE_USER_PASSWORD=$(generate_password)

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

    # Check if domain already exists
    log_message "Checking if domain already exists..."
    if check_domain_exists "$GOACCESS_DOMAIN"; then
        echo "Domain '$GOACCESS_DOMAIN' already exists."
        while true; do
            read -p "Do you want to delete and recreate the site? (y/N): " DELETE_EXISTING
            case $DELETE_EXISTING in
                [Yy]*)
                    log_message "Deleting existing site for domain '$GOACCESS_DOMAIN'..."
                    if ! clpctl site:delete --domainName="$GOACCESS_DOMAIN" --force; then
                        error_exit "Failed to delete existing domain. Exiting."
                    fi
                    break
                    ;;
                [Nn]*|"")
                    log_message "Aborting site creation for existing domain '$GOACCESS_DOMAIN'."
                    exit 1
                    ;;
                *) echo "Please answer y or n." ;;
            esac
        done
    fi

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
Log Format: $LOG_FORMAT_NAME

Monitored Servers:
$(printf '- %s\n' "${REMOTE_SERVERS[@]}")

SSH KEY LOCATION:
/home/${SITE_USER}/.ssh/id_ed25519

Generate SSH Key (if not exists):
ssh-keygen -t ed25519 -f /home/${SITE_USER}/.ssh/id_ed25519 -N ""

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

    # Final success message
    log_message "GoAccess Multi-Server Monitoring installation completed successfully!"
    
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
    if command -v goaccess &> /dev/null; then
        echo "GoAccess is already installed."
        read -p "Do you want to reconfigure the existing installation? (y/N): " RECONFIGURE
        if [[ ! "$RECONFIGURE" =~ ^[Yy]$ ]]; then
            echo "Installation cancelled. GoAccess is already set up."
            exit 0
        fi
        # If user chooses to reconfigure, continue with the script
    fi

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
