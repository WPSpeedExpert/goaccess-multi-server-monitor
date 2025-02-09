#!/bin/bash
# =========================================================================== #
# Script Name:       goaccess_multi_server_monitor.sh
# Description:       Interactive GoAccess multi-server monitoring setup
# Version:           1.4.4
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

# 3.3. Site User Generation
#---------------------------------------
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
    local site_home="/home/${site_user}"

    cat > /usr/local/bin/update-server-monitoring.sh << 'EOF'
#!/bin/bash

# Update server monitoring configuration
if [ -f /etc/goaccess/monitored_servers ]; then
    while IFS= read -r server; do
        # Skip empty lines and comments
        [[ -z "$server" || "$server" =~ ^[[:space:]]*# ]] && continue

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
            read -p "Enter domain for GoAccess monitoring (e.g., stats.octahexa.com): " GOACCESS_DOMAIN
            if validate_domain "$GOACCESS_DOMAIN"; then
                break
            else
                echo "Please enter a valid domain name."
            fi
        done

        # Generate site user and password using correct naming convention
        local SITE_USER=$(derive_siteuser "$GOACCESS_DOMAIN")
        local SITE_USER_PASSWORD=$(generate_password)

        # 7.3. Domain Existence Check
        #---------------------------------------
        log_message "Checking if domain already exists..."
        if check_domain_exists "$GOACCESS_DOMAIN"; then
            echo "Domain '$GOACCESS_DOMAIN' already exists."
            echo "Options:"
            echo "1. Delete existing site and continue"
            echo "2. Abort installation"

            while true; do
                read -p "Choose an option (1/2): " DOMAIN_CHOICE
                case $DOMAIN_CHOICE in
                    1)
                        log_message "Deleting existing site for domain '$GOACCESS_DOMAIN'..."
                        if ! clpctl site:delete --domainName="$GOACCESS_DOMAIN" --force; then
                            error_exit "Failed to delete existing domain. Exiting."
                        fi
                        # Wait for cleanup
                        sleep 5
                        # Verify deletion
                        if check_domain_exists "$GOACCESS_DOMAIN"; then
                            error_exit "Failed to delete domain. Please remove manually and try again."
                        fi
                        log_message "Domain deleted successfully."
                        break
                        ;;
                    2)
                        log_message "Installation aborted by user - domain exists"
                        exit 0
                        ;;
                    *) echo "Please enter 1 or 2." ;;
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
        echo "Server Configuration:"
        echo "Enter remote servers to monitor (leave blank to finish)"
        echo "Format: user@hostname"
        echo "--------------------"

        while true; do
            read -p "Enter server (or leave blank to finish): " SERVER
            if [[ -z "$SERVER" ]]; then
                if [ ${#REMOTE_SERVERS[@]} -eq 0 ]; then
                    echo "At least one server must be configured."
                    continue
                fi
                break
            fi

            if [[ $SERVER =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+$ ]]; then
                REMOTE_SERVERS+=("$SERVER")
                echo "Server added: $SERVER"
            else
                echo "Invalid server format. Please use format: user@hostname"
            fi
        done

        echo ""
        echo "Configured Servers:"
        echo "--------------------"
        for server in "${REMOTE_SERVERS[@]}"; do
            echo "- $server"
        done
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

            # Create update script for server monitoring
            create_update_script "$SITE_USER"

        # 7.10. Documentation Generation
        #---------------------------------------
        cat > /root/goaccess_monitor_credentials.txt << EOF
    GoAccess Multi-Server Monitoring Credentials
    ============================================
    Domain: $GOACCESS_DOMAIN
    Site User: $SITE_USER (Derived from domain name)
    Site User Password: $SITE_USER_PASSWORD
    Log Format: $LOG_FORMAT_NAME

    Monitored Servers:
    $(printf '- %s\n' "${REMOTE_SERVERS[@]}")

    SETUP INSTRUCTIONS:
    1. SSH Setup (Manual Steps Required):
       SSH setup should be done manually by the administrator:
       - Log in as the site user: su - ${SITE_USER}
       - Generate and manage SSH keys for server monitoring
       - Configure SSH access between servers

    2. Monitoring Configuration:
       - Server list: /etc/goaccess/monitored_servers
       - Update configuration: Run /usr/local/bin/update-server-monitoring.sh

    SECURITY NOTES:
    - Ensure proper SSH key management
    - Use key-based authentication
    - Implement appropriate access controls

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
        echo "Options:"
        echo "1. Reconfigure existing installation"
        echo "2. Remove and reinstall"
        echo "3. Abort installation"

        while true; do
            read -p "Choose an option (1/2/3): " INSTALL_CHOICE
            case $INSTALL_CHOICE in
                1)
                    log_message "Proceeding with reconfiguration..."
                    break
                    ;;
                2)
                    log_message "Removing existing GoAccess installation..."
                    systemctl stop goaccess || true
                    systemctl disable goaccess || true
                    rm -f /etc/systemd/system/goaccess.service
                    apt-get remove -y goaccess
                    apt-get purge -y goaccess
                    rm -rf /etc/goaccess
                    systemctl daemon-reload
                    log_message "GoAccess removed. Proceeding with fresh installation..."
                    break
                    ;;
                3)
                    log_message "Installation aborted by user."
                    exit 0
                    ;;
                *) echo "Please enter 1, 2, or 3." ;;
            esac
        done
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
