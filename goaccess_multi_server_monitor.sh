#!/bin/bash
# =========================================================================== #
# Script Name:       goaccess_multi_server_monitor.sh
# Description:       Interactive GoAccess multi-server monitoring setup
# Version:           1.2.4
# Author:            OctaHexa Media LLC
# Last Modified:     2025-02-05
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

    # Server configuration
    local REMOTE_SERVERS=()
    while true; do
        read -p "Enter a remote server to monitor (format: user@hostname, or press ENTER to finish): " SERVER
        if [ -z "$SERVER" ]; then
            break
        fi
        
        # Basic validation of server entry
        if [[ $SERVER =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+$ ]]; then
            REMOTE_SERVERS+=("$SERVER")
        else
            echo "Invalid server format. Use user@hostname."
        fi
    done

    # Confirm configuration
    echo ""
    echo "Configuration Summary:"
    echo "--------------------"
    echo "Monitoring Domain: $GOACCESS_DOMAIN"
    echo "Site User: $SITE_USER"
    echo "Remote Servers to Monitor:"
    for server in "${REMOTE_SERVERS[@]}"; do
        echo "- $server"
    done
    
    read -p "Confirm installation? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_message "Installation cancelled by user."
        return 1
    fi

    # Proceed with installation
    log_message "Starting GoAccess Multi-Server Monitoring installation..."

    # Create CloudPanel site as reverse proxy
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
/home/web-monitor/.ssh/id_ed25519

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

    # Secure the credentials file
    chmod 600 /root/goaccess_monitor_credentials.txt

    # Create server management script
    cat > /usr/local/bin/update-server-monitoring.sh << 'EOFSCRIPT'
#!/bin/bash
set -euo pipefail

# Ensure script runs with web-monitor user permissions
if [[ "$EUID" -eq 0 ]]; then
    echo "This script should be run as web-monitor, not root."
    exit 1
fi

# Read servers from configuration file
MONITORED_SERVERS=$(cat /etc/goaccess/monitored_servers)

# Update log collection scripts
for server in $MONITORED_SERVERS; do
    server_name=$(echo "$server" | cut -d'@' -f2 | cut -d'.' -f1)
    
    # Create/Update log collection script
    cat > "/usr/local/bin/collect-logs-${server_name}.sh" << EOF
#!/bin/bash
set -euo pipefail
rsync -avz -e "ssh -i /home/web-monitor/.ssh/id_ed25519" \
    "${server}:/var/log/nginx/access.log" \
    "/var/log/remote-servers/${server_name}/access.log"
EOF
    
    chmod +x "/usr/local/bin/collect-logs-${server_name}.sh"
done

echo "Server monitoring configuration updated."
EOFSCRIPT

    # Create and configure web-monitor user if not exists
    if ! id web-monitor &>/dev/null; then
        log_message "Creating web-monitor user..."
        useradd -m -s /bin/bash web-monitor || error_exit "Failed to create web-monitor user"
    fi

    # Generate SSH key for web-monitor
    log_message "Generating SSH key for web-monitor..."
    sudo -u web-monitor ssh-keygen -t ed25519 -f /home/web-monitor/.ssh/id_ed25519 -N "" \
        || error_exit "Failed to generate SSH key"

    chmod +x /usr/local/bin/update-server-monitoring.sh
    chown web-monitor:web-monitor /usr/local/bin/update-server-monitoring.sh

    # Create initial servers configuration file
    mkdir -p /etc/goaccess
    printf '%s\n' "${REMOTE_SERVERS[@]}" > /etc/goaccess/monitored_servers
    chown web-monitor:web-monitor /etc/goaccess/monitored_servers

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
    echo "   - Monitoring SSH Key: /home/web-monitor/.ssh/id_ed25519"
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
