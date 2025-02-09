#!/bin/bash
# =========================================================================== #
# Script Name:       goaccess_multi_server_monitor.sh
# Description:       Interactive GoAccess multi-server monitoring setup
# Version:           1.2.1
# Author:            OctaHexa Media LLC
# Last Modified:     2025-02-05
# Dependencies:      Debian 12, CloudPanel
# =========================================================================== #

# Exit on error, undefined vars, and pipe failures
set -euo pipefail

# Logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Generate a secure 12-character password
generate_password() {
    < /dev/urandom tr -dc 'A-Za-z0-9' | head -c12
}

# Validate domain name
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_message "Invalid domain name: $domain"
        return 1
    fi
}

# Main installation function
main_installation() {
    # Clear screen and display header
    clear
    echo "========================================="
    echo "   GoAccess Multi-Server Monitoring     "
    echo "========================================="
    echo ""

    # Domain configuration
    while true; do
        read -p "Enter domain for GoAccess monitoring (e.g., stats.yourdomain.com): " GOACCESS_DOMAIN
        if validate_domain "$GOACCESS_DOMAIN"; then
            break
        else
            echo "Please enter a valid domain name."
        fi
    done

    # Generate site user and password
    SITE_USER=$(echo "$GOACCESS_DOMAIN" | awk -F. '{print $1}')
    SITE_USER_PASSWORD=$(generate_password)

    # Server configuration
    REMOTE_SERVERS=()
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
        echo "Installation cancelled."
        return 1
    fi

    # Proceed with installation
    log_message "Starting GoAccess Multi-Server Monitoring installation..."

    # Add the rest of the installation steps here
    # (This is a placeholder - add your full installation logic)
    
    # Create credentials file
    cat > /root/goaccess_monitor_credentials.txt << END_CREDENTIALS
GoAccess Multi-Server Monitoring Credentials
============================================
Domain: $GOACCESS_DOMAIN
Site User: $SITE_USER
Site User Password: $SITE_USER_PASSWORD

Monitored Servers:
$(printf '- %s\n' "${REMOTE_SERVERS[@]}")

Access URL: https://$GOACCESS_DOMAIN
END_CREDENTIALS

    # Output important information
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
    echo "3. SSH Key Management:"
    echo "   - Monitoring SSH Key: /home/web-monitor/.ssh/id_ed25519"
    echo "   - Distribute this key to remote servers using: ssh-copy-id"
    echo ""
    echo "4. Log Locations:"
    echo "   - Remote Server Logs: /var/log/remote-servers/"
    echo "   - GoAccess Reports: /home/$SITE_USER/htdocs/$GOACCESS_DOMAIN/public/reports/"
    echo ""
    echo "5. Configuration Files:"
    echo "   - GoAccess Config: /etc/goaccess/goaccess.conf"
    echo "   - Server List: /etc/goaccess/monitored_servers"
    echo ""
    echo "SECURITY REMINDER: Protect your SSH keys and credentials!"
    echo ""

    return 0
}

# Main script execution
main() {
    # Ensure script is run as root
    if [ "$EUID" -ne 0 ]; then
        log_message "Please run as root"
        exit 1
    }

    # Check CloudPanel installation
    if ! command -v clpctl &> /dev/null; then
        log_message "CloudPanel is not installed. This script requires a pre-installed CloudPanel."
        exit 1
    fi

    # Run main installation
    if main_installation; then
        echo "Installation completed successfully."
    else
        echo "Installation cancelled or failed."
        exit 1
    fi
}

# Execute main function
main
