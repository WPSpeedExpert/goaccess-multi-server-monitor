# GoAccess Multi-Server Web Analytics Monitoring

## Overview

This script provides a comprehensive solution for centralized web log monitoring across multiple servers using GoAccess, integrated with CloudPanel on Debian 12.

### Key Features

- 🌐 Centralized web analytics for multiple servers
- 🔒 Secure SSH-based log collection
- 📊 Real-time and historical web traffic analysis
- 🖥️ CloudPanel integration
- 🛡️ Enhanced security practices

### Prerequisites

- Debian 12
- CloudPanel pre-installed
- SSH access to remote servers
- Root access on the monitoring server

### Installation

#### One-line Installation Command

```bash
cd ~ && \
curl -sS https://raw.githubusercontent.com/WPSpeedExpert/goaccess-multi-server-monitor/main/goaccess_multi_server_monitor.sh -o goaccess_multi_server_monitor.sh && \
chmod +x goaccess_multi_server_monitor.sh && \
sudo ./goaccess_multi_server_monitor.sh && \
rm goaccess_multi_server_monitor.sh
```

### Pre-Installation Steps

1. Ensure CloudPanel is installed
2. Prepare SSH key-based authentication for remote servers
3. Verify firewall configurations

### Post-Installation

1. Review `/root/multi_server_goaccess_setup.txt` for detailed configuration
2. Distribute SSH public key to remote servers
3. Configure firewall rules as needed

### Security Recommendations

- Use strong, unique passwords
- Limit SSH access
- Implement fail2ban
- Regularly update and patch systems

### Troubleshooting

- Check log files in `/var/log/remote-servers/`
- Verify cron job configurations
- Inspect GoAccess service status: `systemctl status goaccess`

### Log Collection Details

- Logs are collected hourly via rsync
- Processed logs stored in `/var/log/remote-servers/`
- Reports generated in `/home/[site-user]/htdocs/[domain]/public/reports/`

### Customization

Edit the following files to customize behavior:
- `/etc/goaccess/goaccess.conf`: GoAccess configuration
- `/usr/local/bin/process-multi-server-logs.sh`: Log processing script
- Cron jobs for log collection timing

### License

[Your License Here]

### Contributing

Contributions are welcome! Please submit pull requests or open issues on the GitHub repository.

### Support

For issues or support, please [create an issue on GitHub](https://github.com/OctaHexa/goaccess-multi-server-monitor/issues)

---

*Created by OctaHexa Media LLC | Web Analytics Monitoring Solution*
