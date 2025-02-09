#!/bin/bash
# =========================================================================== #
# Script Name:       goaccess_multi_server_monitor.sh
# Description:       Interactive GoAccess multi-server monitoring setup
# Version:           1.4.0
# Author:            OctaHexa Media LLC
# Last Modified:     2025-02-09
# Dependencies:      Debian 12, CloudPanel
# =========================================================================== #

#===============================================
# 1. SCRIPT CONFIGURATION
#===============================================
# Exit on error, undefined vars, and pipe failures
set -euo pipefail

#===============================================
# 2. UTILITY FUNCTIONS
#===============================================

# 2.1. Logging Functions
#---------------------------------------
# Logging function with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Error handling function
error_exit() {
    log_message "ERROR: $1"
    exit 1
}

# 2.2. Password Generation
#---------------------------------------
# Generate a secure 12-character password
generate_password() {
    < /dev/urandom tr -dc 'A-Za-z0-9' | head -c12
}

# 2.3. Log Format Conversion
#---------------------------------------
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
        log_format="${log_format//\$\{$nginx_var\}/$goaccess_var}"
        # Replace $variable syntax
        log_format="${log_format//\$$nginx_var/$goaccess_var}"
    done

    # Replace any remaining unhandled variables with %^
    log_format=$(echo "$log_format" | sed -E 's/\$\{?[a-z_]+\}?/%^/g')

    echo "$log_format"
}

#===============================================
# 3. DOMAIN MANAGEMENT
#===============================================

# 3.1. Domain Validation
#---------------------------------------
# Validate domain name
validate_domain() {
    local domain=$1
    if [[ ! $domain =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_message "Invalid domain name: $domain"
        return 1
    fi
}

# 3.2. Domain Existence Check
#---------------------------------------
# Check if the domain exists in CloudPanel
check_domain_exists() {
    local domain=$1
    local exists=0

    # Try using clpctl to list sites and grep for the domain
    if clpctl site:list 2>/dev/null | grep -q "$domain"; then
        exists=1
    fi

    # Check nginx configuration as backup
    if [ -f "/etc/nginx/sites-enabled/$domain.conf" ]; then
        exists=1
    fi

    return $exists
}

#===============================================
# 4. GOACCESS SETUP
#===============================================

# 4.1. Installation
#---------------------------------------
# Install GoAccess from official repository
install_goaccess() {
    log_message "Installing GoAccess..."

    # Add GoAccess official repository
    echo "deb https://deb.goaccess.io/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/goaccess.list
    wget -O - https://deb.goaccess.io/gnugpg.key | gpg --dearmor | tee /etc/apt/trusted.gpg.d/goaccess.gpg > /dev/null

    # Update and install
    apt-get update
    apt-get install -y goaccess

    # Create required directories
    mkdir -p /var/log/goaccess /var/lib/goaccess /var/log/remote-servers

    # Set proper permissions
    chown -R www-data:www-data /var/log/goaccess /var/lib/goaccess
}

# 4.2. Service Configuration
#---------------------------------------
# Create and configure GoAccess systemd service
setup_goaccess_service() {
    local domain=$1
    local site_user=$2

    # Create systemd service file
    cat > /etc/systemd/system/goaccess.service << EOF
[Unit]
Description=GoAccess real-time web log analyzer
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
ExecStart=/usr/bin/goaccess --config-file=/etc/goaccess/goaccess.conf --no-global-config
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and enable/start service
    systemctl daemon-reload
    systemctl enable goaccess
    systemctl start goaccess

    # Verify service is running
    if ! systemctl is-active --quiet goaccess; then
        error_exit "Failed to start GoAccess service"
    fi
}

#===============================================
# 5. SERVER MONITORING SETUP
#===============================================

# 5.1. Update Script Creation
#---------------------------------------
# Create server monitoring update script
create_update_script() {
    local site_user=$1

    cat > /usr/local/bin/update-server-monitoring.sh << 'EOF'
#!/bin/bash

# Update server monitoring configuration
if [ -f /etc/goaccess/monitored_servers ]; then
    while IFS= read -r server; do
        # Skip empty lines and comments
        [[ -z "$server" || "$server" =~ ^[[:space:]]*# ]] && continue

        # Ensure SSH directory exists
        ssh-keyscan -H "$(echo "$server" | cut -d@ -f2)" >> /home/web-monitor/.ssh/known_hosts 2>/dev/null

        echo "Configuring monitoring for $server..."
    done < /etc/goaccess/monitored_servers
fi

# Restart GoAccess service
systemctl restart goaccess
EOF

    chmod +x /usr/local/bin/update-server-monitoring.sh
}

#===============================================
# 6. SSH KEY MANAGEMENT
#===============================================

# 6.1. SSH Key Setup
#---------------------------------------
# Setup SSH keys for web-monitor user
setup_ssh_keys() {
    local site_user=$1

    # Create SSH directory if it doesn't exist
    mkdir -p /home/web-monitor/.ssh

    # Generate SSH key if it doesn't exist
    if [ ! -f /home/web-monitor/.ssh/id_ed25519 ]; then
        ssh-keygen -t ed25519 -f /home/web-monitor/.ssh/id_ed25519 -N ""
    fi

    # Set proper permissions
    chmod 700 /home/web-monitor/.ssh
    chmod 600 /home/web-monitor/.ssh/id_ed25519*
    chown -R web-monitor:web-monitor /home/web-monitor/.ssh
}

#===============================================
# 7. MAIN INSTALLATION FUNCTION
#===============================================

main_installation() {
    # Ensure function fails on any error
    set -e

    # 7.1. Initial Setup
    #---------------------------------------
    clear
    echo "========================================="
    echo "   GoAccess Multi-Server Monitoring     "
    echo "========================================="
    echo ""

    # 7.2. Domain Configuration
    #---------------------------------------
    local GOACCESS_DOMAIN
    while true; do
        read -p "Enter domain for GoAccess monitoring (e.g., stats.yourdomain.com): " GOACCESS_DOMAIN
        if validate_domain "$GOACCESS_DOMAIN"; then
            break
        else
            echo "Please enter a valid domain name."
        fi
    done

    # Generate site user and password
    local SITE_USER=$(echo "$GOACCESS_DOMAIN" | awk -F. '{print $1}')
    local SITE_USER_PASSWORD=$(generate_password)

    # 7.3. Domain Existence Check
    #---------------------------------------
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
                    # Wait a moment for cleanup
                    sleep 2
                    break
                    ;;
                [Nn]*|"")
                    log_message "Installation aborted - domain already exists"
                    return 1
                    ;;
                *) echo "Please answer y or n." ;;
            esac
        done
    fi

    # 7.4. Log Format Configuration
    #---------------------------------------
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

    # 7.5. Server Configuration
    #---------------------------------------
    local REMOTE_SERVERS=()
    read -p "Enter the first remote server to monitor (format: user@hostname): " SERVER

    # Basic validation of server entry
    if [[ $SERVER =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+$ ]]; then
        REMOTE_SERVERS+=("$SERVER")
    else
        echo "Invalid server format. Skipping server addition."
    fi

    echo ""
    echo "Server Configuration:"
    echo "--------------------"
    echo "To add more servers after installation:"
    echo "1. Edit /etc/goaccess/monitored_servers"
    echo "2. Run /usr/local/bin/update-server-monitoring.sh"
    echo ""

    # 7.6. Configuration Summary
    #---------------------------------------
    echo "Configuration Summary:"
    echo "--------------------"
    echo "Monitoring Domain: $GOACCESS_DOMAIN"
    echo "Site User: $SITE_USER"
    echo "Log Format: $LOG_FORMAT_NAME"
    echo "Initial Server to Monitor:"
    for server in "${REMOTE_SERVERS[@]}"; do
        echo "- $server"
    done

    read -p "Confirm installation? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_message "Installation cancelled by user."
        return 1
    fi

    # 7.7. Installation Process
    #---------------------------------------
    log_message "Starting GoAccess Multi-Server Monitoring installation..."

    # Install GoAccess if not already installed
    if ! command -v goaccess &> /dev/null; then
        install_goaccess
    fi

    # Create web-monitor user if it doesn't exist
    if ! id -u web-monitor >/dev/null 2>&1; then
        useradd -m -s /bin/bash web-monitor
    fi

    # Setup SSH keys for web-monitor user
    setup_ssh_keys "web-monitor"

    # Create CloudPanel site
    log_message "Creating CloudPanel site for GoAccess..."
    clpctl site:add:reverse-proxy \
        --domainName="$GOACCESS_DOMAIN" \
        --reverseProxyUrl="http://localhost:7890" \
        --siteUser="$SITE_USER" \
        --siteUserPassword="$SITE_USER_PASSWORD" \
        || error_exit "Failed to create CloudPanel site"

        # 7.8. SSL Certificate Installation
    #---------------------------------------
    log_message "Installing SSL Certificate for GoAccess domain..."
    clpctl lets-encrypt:install:certificate --domainName="$GOACCESS_DOMAIN" \
        || log_message "WARNING: SSL Certificate installation failed"

    # 7.9. GoAccess Configuration
    #---------------------------------------
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

    # Store list of monitored servers
    echo "${REMOTE_SERVERS[@]}" > /etc/goaccess/monitored_servers

    # Create update script
    create_update_script "$SITE_USER"

    # 7.10. Documentation Generation
    #---------------------------------------
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
/home/web-monitor/.ssh/id_ed25519

Generate SSH Key (if not exists):
ssh-keygen -t ed25519 -f /home/web-monitor/.ssh/id_ed25519 -N ""

MODIFY MONITORING CONFIGURATION:
1. Add/Remove Servers:
   - Edit server list in /etc/goaccess/monitored_servers
   - Run /usr/local/bin/update-server-monitoring.sh

2. Manually Add a Server:
   a) Copy SSH public key to new server:
      ssh-copy-id -i /home/web-monitor/.ssh/id_ed25519.pub user@newserver.example.com

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

    # 7.11. Final Setup and Verification
    #---------------------------------------
    log_message "Setting up GoAccess service..."
    setup_goaccess_service "$GOACCESS_DOMAIN" "$SITE_USER"

    # Final verification
    log_message "Verifying installation..."
    if ! systemctl is-active --quiet goaccess; then
        log_message "WARNING: GoAccess service is not running. Attempting to start..."
        systemctl start goaccess
    fi

    # Verify website accessibility
    if ! curl -s -o /dev/null -w "%{http_code}" "https://$GOACCESS_DOMAIN" | grep -q "200\|301\|302"; then
        log_message "WARNING: Website is not responding correctly. Please check the configuration."
    fi

    return 0
}

#===============================================
# 8. MAIN SCRIPT EXECUTION
#===============================================

main() {
    # 8.1. Initial Checks
    #---------------------------------------
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

    # 8.2. Installation Check
    #---------------------------------------
    # Check if GoAccess is already installed
    if command -v goaccess &> /dev/null; then
        echo "GoAccess is already installed."
        read -p "Do you want to reconfigure the existing installation? (y/N): " RECONFIGURE
        if [[ ! "$RECONFIGURE" =~ ^[Yy]$ ]]; then
            echo "Installation cancelled. GoAccess is already set up."
            exit 0
        fi
    fi

    # 8.3. Run Installation
    #---------------------------------------
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
