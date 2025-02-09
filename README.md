# GoAccess Multi-Server Web Analytics Monitoring

## Overview

Centralized web log monitoring solution for multiple servers using GoAccess, seamlessly integrated with CloudPanel on Debian 12.

### Features

- 🌐 Centralized web analytics for multiple servers
- 🔒 Secure, interactive SSH-based log collection
- 📊 Real-time and historical web traffic analysis
- 🖥️ CloudPanel integration
- 🛡️ Enhanced security practices

### Prerequisites

- Debian 12 server
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

### Installation Process

1. Run the installation script
2. Interactively enter:
   - GoAccess monitoring domain
   - Remote servers to monitor
3. Confirm installation details
4. Automatic setup completes

### Post-Installation

#### Credentials and Access

- Credentials stored in: `/root/goaccess_monitor_credentials.txt`
- Web Analytics Access URL provided during installation

### Server Monitoring Management

#### Adding New Servers

1. Edit `/etc/goaccess/monitored_servers`
2. Add server in `user@hostname` format
3. Run update script:
   ```bash
   /usr/local/bin/update-server-monitoring.sh
   ```

#### SSH Key Distribution

1. Locate monitoring SSH key:
   ```bash
   /home/web-monitor/.ssh/id_ed25519
   ```

2. Distribute to a new server:
   ```bash
   ssh-copy-id -i /home/web-monitor/.ssh/id_ed25519.pub user@newserver.example.com
   ```

### Key Locations

- Remote Server Logs: `/var/log/remote-servers/`
- GoAccess Reports: `/home/[site-user]/htdocs/[domain]/public/reports/`
- Configuration: `/etc/goaccess/`

### Security Recommendations

- Protect SSH private key
- Use key-based authentication
- Limit SSH access
- Regularly update and patch systems

### Troubleshooting

- Check log files: `/var/log/remote-servers/`
- Verify cron jobs
- Check GoAccess service: `systemctl status goaccess`

### Customization

Modify these files to customize behavior:
- `/etc/goaccess/goaccess.conf`: GoAccess configuration
- `/usr/local/bin/process-multi-server-logs.sh`: Log processing
- Cron jobs for log collection timing

### License

This project is licensed under the GNU General Public License v3.0 (GPL-3.0). 

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

A full copy of the license is available in the `LICENSE` file in the repository. 

Key points of the GPL-3.0:
- You are free to use, modify, and distribute the software
- Any modifications or derivative works must also be licensed under GPL-3.0
- You must include the original copyright notice
- Source code must be made available for any distributed versions

### Contributing

Contributions welcome! Submit pull requests or open issues on the GitHub repository.

### Support

For issues or support, [create an issue on GitHub](https://github.com/WPSpeedExpert/goaccess-multi-server-monitor/issues)

---

*Created by OctaHexa Media LLC | Comprehensive Web Analytics Monitoring*
