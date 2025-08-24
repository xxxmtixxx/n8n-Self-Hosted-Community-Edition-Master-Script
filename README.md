# n8n Self-Hosted Master Script - Complete Lifecycle Management

A comprehensive master script for deploying, managing, and maintaining n8n with PostgreSQL, Nginx, and automated features. This all-in-one solution handles installation, updates, backups, uninstallation, and complete environment management with no external port exposure required.

## 🚀 Features

### Core Features
- **All-in-One Script**: Single master script for deployment, management, and uninstallation (no separate files)
- **Smart Installation**: Auto-detects installation state and offers appropriate options
- **Data Preservation**: Choose which backup to restore when multiple are available
- **Complete Environment Management**: Add/update/remove variables with automatic docker-compose.yml updates and service recreation
- **Automated Backups**: Daily backups with configurable retention (default: 5 backups)
- **Comprehensive Logging**: All operations logged to `~/n8n-operations.log` with timestamps
- **Health Monitoring**: Comprehensive health checks for all services
- **Resource Monitoring**: View real-time container resource usage
- **Version Management**: Easy updates with automatic backup creation
- **Systemd Integration**: Auto-start on boot with proper service management
- **Docker Compose v2**: Full compatibility with latest Docker Compose
- **Interactive Menus**: User-friendly command-line interface with built-in management functions
- **Direct Commands**: Script automation support with command-line arguments

### 🔒 Enhanced Security Features (v2.1.0)
- **Let's Encrypt Support**: Toggle between self-signed and Let's Encrypt certificates with DNS-01 challenge
- **Firewall Protection**: UFW firewall with secure default rules (ports 22, 443 only)
- **Rate Limiting**: Nginx-based rate limiting to prevent abuse and DDoS attacks
- **Intrusion Prevention**: fail2ban configured for blocking malicious IPs
- **Automatic Security Updates**: Configurable OS and package security updates
- **Enhanced SSL/TLS**: Strong ciphers, TLS 1.2/1.3 only, security headers
- **Security Hardening**: Automated application of all security best practices

## 📋 Requirements

- Ubuntu 22.04/24.04 LTS or Debian-based system
- Minimum specifications:
  - 2GB RAM
  - 10GB available storage
  - Network connectivity
- Regular user account with sudo privileges (don't run as root)

## 🎯 Quick Start

### 1. Download the Master Script
```bash
wget https://raw.githubusercontent.com/xxxmtixxx/n8n-Self-Hosted-Master-Script/main/n8n-master.sh
# or create it manually:
nano n8n-master.sh
# Then paste the script content and save (Ctrl+X, Y, Enter)
```

### 2. Make it Executable
```bash
chmod +x n8n-master.sh
```

### 3. Run the Script
```bash
./n8n-master.sh
```

The script will detect if n8n is installed and show appropriate options:
- **Not Installed**: Deploy n8n (with automatic backup detection)
- **Running**: Manage, Stop, or Uninstall
- **Stopped**: Start, Manage, or Uninstall

**Important**: If Docker was just installed, you'll need to log out and back in before running the script again.

## 🔧 Master Script Commands

### Interactive Mode (Recommended)
```bash
./n8n-master.sh
```
The script automatically detects installation state and shows appropriate menu options.

### Direct Commands
```bash
./n8n-master.sh deploy      # Install n8n (with backup detection)
./n8n-master.sh uninstall   # Remove n8n (with data preservation options)
```

## 📊 Management Features (Built into Master Script)

All management functions are now built directly into the master script. Once installed, access them through:

### Interactive Management Menu
```bash
./n8n-master.sh
# Select option 1: Manage n8n
```

### Management Menu Options
1. **View Status** - Service status and container health
2. **View Logs** - n8n, PostgreSQL, Nginx, or all services
3. **Restart Services** - Quick restart without recreation
4. **Recreate Services** - Full container recreation (required for env changes)
5. **Create Backup** - Manual backup creation
6. **Restore Backup** - Restore from available backups
7. **Update n8n** - Update to latest version with automatic backup
8. **Health Check** - Comprehensive system health analysis
9. **Show Version** - Display current n8n version
10. **Manage Environment Variables** - Add/update/remove variables with automatic service recreation
11. **Security & SSL Settings** - Complete security and certificate management:
    - SSL certificate management (Let's Encrypt/self-signed)
    - Firewall configuration
    - fail2ban setup
    - Automated updates
    - Security hardening

## 🔐 Environment Variable Management

The script includes comprehensive environment variable management with automatic docker-compose.yml integration:

### Interactive Environment Management
```bash
./n8n-master.sh
# Select: 1) Manage n8n
# Select: 11) Manage Environment Variables
```

### Environment Variable Menu Options
1. **View current values** - Lists all variables (sensitive values masked)
2. **Add new variable** - Add variable to both .env and docker-compose.yml
3. **Update variable** - Modify existing variable value
4. **Remove variable** - Remove variable (system variables protected)

### Automatic Service Recreation
After adding, updating, or removing variables, the script now prompts:
```
Recreate services now to apply changes? (y/n):
```
- **'y'**: Automatically recreates services to apply changes immediately
- **'n'**: Shows reminder to recreate services manually later

### Add API Keys Example
```bash
# Through interactive menu:
./n8n-master.sh → 1) Manage n8n → 11) Manage Environment Variables → 2) Add new variable

# Example variables to add:
OPENAI_API_KEY = "sk-..."
ANTHROPIC_API_KEY = "sk-ant-..."
PERPLEXITY_API_KEY = "pplx-..."
SLACK_WEBHOOK_URL = "https://hooks.slack.com/..."
```

### Access in n8n Workflows
Use the Expression syntax:
- `{{ $env.OPENAI_API_KEY }}`
- `{{ $env.PERPLEXITY_API_KEY }}`
- `{{ $env.MY_CUSTOM_VAR }}`

### Protected System Variables
The following variables cannot be removed (protection built-in):
- `POSTGRES_*` (Database configuration)
- `N8N_BASIC_AUTH_*` (Authentication)
- `N8N_HOST`, `N8N_PORT`, `N8N_PROTOCOL` (Core settings)
- `WEBHOOK_URL`, `GENERIC_TIMEZONE`
- `N8N_ENCRYPTION_KEY` (Security)
- `DB_*` (Database connection)

## 🌐 Access Methods

After deployment, access n8n using any of these methods. The SSL certificate includes all network IP addresses for seamless access:

### 1. Local Access (On the Server)
```
https://localhost
https://127.0.0.1
```

### 2. SSH Tunnel (Recommended for Remote Access)
```bash
ssh -L 8443:localhost:443 username@server-ip
```
Then visit: `https://localhost:8443`

### 3. Internal Network Access (All Network Interfaces)
```
https://YOUR_SERVER_IP
```
Examples: 
- `https://192.168.1.200` (LAN IP)
- `https://10.0.1.100` (VPN or secondary network)
- All detected network interfaces are included in the certificate

**Note**: Port 443 is only exposed internally. For internet access, use SSH tunneling or configure additional security measures.

**Authentication**:
n8n uses email/password authentication. You'll create your credentials during the initial n8n setup when you first access the interface.

## 📁 File Locations

| Component | Location |
|-----------|----------|
| Master Script | `~/n8n-master.sh` |
| Project Directory | `~/n8n/` |
| n8n Data | `~/n8n/.n8n/` |
| Backups | `~/n8n/backups/` |
| Certificates | `~/n8n/certs/` |
| Environment Config | `~/n8n/.env` |
| Docker Compose | `~/n8n/docker-compose.yml` |
| Nginx Config | `~/n8n/nginx.conf` |
| Cron Tasks | `~/n8n/scripts/cron-tasks.sh` |
| Logs | `~/n8n/logs/` |
| Operations Log | `~/n8n-operations.log` |

## 🔄 Backup & Restore

### Automatic Backups
- Run daily at 3 AM via cron
- Keep last 5 backups by default
- Include database, workflows, and configurations
- Log rotation for files over 100MB
- Automatic certificate renewal check (30 days before expiry)

### Manual Backup
Through management menu:
```bash
./n8n-master.sh → 1) Manage n8n → 5) Create Backup
```
Creates a timestamped backup: `full_backup_YYYYMMDD_HHMMSS.tar.gz`

### Restore Process
Through management menu:
```bash
./n8n-master.sh → 1) Manage n8n → 6) Restore Backup
```
- Lists available backups with sizes
- Select the backup file to restore
- Confirm restoration (current data will be lost)

### Unified Backup System
The script now uses a unified backup format for:
- Manual backups (management menu)
- Uninstall with backup option
- Automatic daily backups

### Backup Contents
**Core Components:**
- PostgreSQL database dump
- n8n workflows and credentials
- All configuration files (docker-compose.yml, nginx.conf, .env)
- SSL certificates
- Environment variables

**Security Features (v2.1.0+):**
- DNS provider credentials (Cloudflare, AWS Route53, DigitalOcean, Google Cloud)
- fail2ban configuration (jails, filters, IP whitelists)
- UFW firewall rules and configuration
- Let's Encrypt account data and certificate configurations
- Manual DNS authentication scripts

**Complete System Restoration:**
- All security settings are automatically restored during backup restoration
- Firewall rules are re-enabled if they were active (with compatibility checks)
- fail2ban service is restarted with restored configurations
- DNS provider credentials are restored with proper permissions
- Let's Encrypt renewal automation continues seamlessly

**Cross-Environment Compatibility (v2.1.0+):**
- **Hostname/IP Migration**: Automatic detection and adaptation to new network environments
- **Certificate Intelligence**: Self-signed certificates regenerated with new IP addresses, Let's Encrypt certificates preserved
- **Firewall Resilience**: Enhanced error handling for UFW rule compatibility across different systems
- **Manual Recovery**: Clear instructions provided when automatic restoration needs assistance

## 🆙 Updating n8n

Updates are handled safely with automatic backups:
```bash
./n8n-master.sh → 1) Manage n8n → 7) Update n8n
```

This will:
1. Create a full backup automatically
2. Pull the latest n8n image
3. Restart services with new version
4. Display the new version number

## 📋 Comprehensive Logging

All operations are now logged to `~/n8n-operations.log` with timestamps:

### Log Contents
- Installation and uninstallation operations
- Backup and restore operations
- Environment variable changes
- Service restarts and recreations
- Error messages and debug information

### View Operations Log
```bash
tail -f ~/n8n-operations.log
# or
less ~/n8n-operations.log
```

### Log Format
```
[2024-12-20 15:30:45] [INFO] n8n Master Script v2.0.0 started
[2024-12-20 15:31:12] [SUCCESS] Backup created: backups/full_backup_20241220_153112.tar.gz
[2024-12-20 15:32:05] [INFO] Environment variable OPENAI_API_KEY added successfully
```

## 🗑️ Uninstallation

The uninstall process provides two options to handle your data:

### Option 1: Uninstall - with Backup (Recommended)
```bash
./n8n-master.sh → 3) Uninstall n8n → 1) Uninstall - with Backup
```

This:
- Creates a full backup before uninstalling
- Stops and removes containers
- Removes systemd service and cron jobs
- Removes installation directory
- Preserves Docker volumes for future use

### Option 2: Uninstall - No backup
```bash
./n8n-master.sh → 3) Uninstall n8n → 2) Uninstall - No backup
# Type 'yes' to confirm complete deletion
```

This removes:
- All Docker containers and volumes
- Installation directory
- Systemd service and cron jobs
- All data (workflows, database, backups)

### Reinstallation with Backup
When reinstalling after backing up:
1. Run `./n8n-master.sh`
2. Select "Deploy n8n"
3. Choose from available backups (shows timestamp and size)
4. All workflows and settings will be restored automatically

#### Cross-System Migration & VM Rebuild
The backup system now supports **complete cross-system migration** with automatic adaptation to different environments:

**Migration Process:**
1. **Copy backup** to new system (different hostname/IP/VM)
2. **Run installation** with backup selection
3. **Automatic adaptation** handles environment differences

**What Gets Automatically Adapted:**
- ✅ **SSL Certificates**: Self-signed certificates regenerated with new IP addresses
- ✅ **Domain Certificates**: Let's Encrypt certificates work unchanged (domain-based)
- ✅ **Firewall Rules**: UFW configuration restored with compatibility checks
- ✅ **Security Services**: fail2ban and all configurations restored seamlessly
- ✅ **DNS Credentials**: All provider credentials restored for certificate renewal

**Migration Scenarios Supported:**
- Same datacenter, different server
- Different cloud provider (AWS → GCP → DigitalOcean)
- Different IP ranges/subnets
- Different hostnames
- Different Linux distributions (Ubuntu/Debian variants)

## 🔄 Migration Scenarios Reference

| Migration Type | SSL Certificates | Firewall Rules | Security Services | Manual Steps Required |
|---|---|---|---|---|
| **Same IP/Hostname** | ✅ No changes needed | ✅ Direct restore | ✅ Direct restore | None |
| **Different IP, Same Hostname** | 🔄 Self-signed regenerated<br/>✅ Let's Encrypt preserved | ✅ Automatic adaptation | ✅ Direct restore | None |
| **Different Hostname** | 🔄 Self-signed regenerated<br/>✅ Let's Encrypt preserved | ✅ Automatic adaptation | ✅ Direct restore | None |
| **Different Cloud Provider** | 🔄 Self-signed regenerated<br/>✅ Let's Encrypt preserved | ⚠️ UFW validation + fallback | ✅ Direct restore | Possible UFW manual config |
| **Different Linux Distribution** | 🔄 Self-signed regenerated<br/>✅ Let's Encrypt preserved | ⚠️ Path validation + fallback | ✅ Direct restore | Possible package installation |

**Legend:**
- ✅ **Automatic**: No intervention required
- 🔄 **Adapted**: Automatically updated for new environment  
- ⚠️ **Validated**: Checked with fallback if incompatible

**Certificate Behavior Details:**
- **Self-Signed**: Always regenerated with new system's IP addresses and hostname
- **Let's Encrypt**: Domain-based certificates work unchanged on any system
- **Backup Protection**: Original certificates backed up before regeneration

## 🔧 Advanced Features

### Health Check
Comprehensive health monitoring:
```bash
./n8n-master.sh → 1) Manage n8n → 8) Health Check
```

Shows:
- Container health status (healthy/running/not running)
- Service endpoint availability (Nginx, PostgreSQL, n8n API)
- Disk usage with percentage
- Memory usage with percentage
- Backup count and total size

### Certificate Management
SSL certificates are automatically managed with enhanced features:
- Self-signed certificates valid for 10 years
- **Multiple IP address support** - includes all network interfaces automatically
- **SAN (Subject Alternative Names)** - covers n8n.local, localhost, and all detected IPs
- Automatic renewal check via cron (30 days before expiry)
- Manual renewal option in management menu (maintains enhanced features)

### Service Recreation
Important for environment variable changes:
```bash
./n8n-master.sh → 1) Manage n8n → 4) Recreate Services
```
Required after:
- Adding/updating/removing environment variables
- Configuration changes that affect containers

## 🐛 Troubleshooting

### View Service Logs
```bash
./n8n-master.sh → 1) Manage n8n → 2) View Logs
```
Options:
- n8n service logs
- PostgreSQL logs
- Nginx logs  
- All services

### Check System Health
```bash
./n8n-master.sh → 1) Manage n8n → 8) Health Check
```

### Check Operations Log
```bash
tail -50 ~/n8n-operations.log
```

### Environment Variables Not Working
1. Verify variable was added:
   ```bash
   ./n8n-master.sh → 1) Manage n8n → 11) Manage Environment Variables → 1) View current values
   ```

2. **Important**: Recreate services after adding variables:
   ```bash
   ./n8n-master.sh → 1) Manage n8n → 4) Recreate Services
   ```
   Or use the automatic recreation prompt when adding variables.

### Container Won't Start
```bash
# Check service status
./n8n-master.sh → 1) Manage n8n → 1) View Status

# Check logs for errors  
./n8n-master.sh → 1) Manage n8n → 2) View Logs

# Try recreating services
./n8n-master.sh → 1) Manage n8n → 4) Recreate Services
```

### Locked Out by fail2ban
```bash
# If you're accidentally banned by fail2ban:

# Option 1: Unban your specific IP
./n8n-master.sh → Manage n8n → Security & SSL Settings → View fail2ban Status → Manage Banned IPs → Unban Specific IP

# Option 2: Add your IP to permanent whitelist  
./n8n-master.sh → Manage n8n → Security & SSL Settings → View fail2ban Status → Manage Banned IPs → Add IP to Whitelist

# Option 3: Emergency clear all bans (if you can't access via SSH)
# From another system or console: sudo fail2ban-client unban --all
```

### Docker Permission Issues
If you see "permission denied" errors:
```bash
# Ensure user is in docker group
sudo usermod -aG docker $USER
# Log out and back in, then try again
```

### SSL Certificate Issues
```bash
# Check certificate validity
openssl x509 -in ~/n8n/certs/n8n.crt -noout -dates

# Manually renew certificate
./n8n-master.sh → 1) Manage n8n → 10) Renew SSL Certificate
```

### Migration & Cross-System Issues
Problems after restoring backup to different system:

#### SSL Certificate Not Working on New IP/Hostname
```bash
# Check if certificate matches current system
openssl x509 -in ~/n8n/certs/n8n.crt -text -noout | grep -A5 "Subject Alternative Name"

# Compare with current system IPs
hostname -I

# If IPs don't match, regenerate certificate:
rm ~/n8n/certs/n8n.crt ~/n8n/certs/n8n.key
./n8n-master.sh → 1) Manage n8n → 4) Recreate Services
```

#### Firewall Rules Not Working
```bash
# Check UFW status after restoration
sudo ufw status verbose

# If UFW failed to enable during restoration:
sudo ufw --force enable

# If rules are missing, reconfigure manually:
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 443/tcp comment 'n8n HTTPS'
sudo ufw --force enable
```

#### fail2ban Not Starting
```bash
# Check fail2ban status
sudo systemctl status fail2ban

# If fail2ban config is incompatible:
sudo systemctl restart fail2ban

# Verify n8n jail is active:
sudo fail2ban-client status n8n-auth
```

#### DNS Provider Credentials Missing
```bash
# Check if credentials were restored
ls -la ~/n8n/.*.ini ~/n8n/.google-cloud.json ~/.aws/credentials 2>/dev/null

# If missing, reconfigure Let's Encrypt:
./n8n-master.sh → 1) Manage n8n → Security & SSL Settings → Configure Let's Encrypt
```

### Database Connection Issues
```bash
# Test database connectivity through health check
./n8n-master.sh → 1) Manage n8n → 8) Health Check

# View PostgreSQL logs
./n8n-master.sh → 1) Manage n8n → 2) View Logs → 2) PostgreSQL
```

## 🔒 Security Notes

1. **Self-Signed Certificate**: Browser warnings are normal. Certificates include all network IP addresses for seamless access. Add exception to proceed.
2. **Local Network Only**: No external ports exposed by default
3. **Sensitive Data**: 
   - `.env` file has 600 permissions
   - Passwords are auto-generated and secure
   - Backups contain sensitive data - store securely
   - Sensitive environment variables are masked in display

## 📝 Common Use Cases

### API Integration Setup
```bash
# Add API keys through interactive menu
./n8n-master.sh → 1) Manage n8n → 11) Manage Environment Variables → 2) Add new variable

# Example variables:
OPENAI_API_KEY = "sk-..."
SLACK_TOKEN = "xoxb-..."
GITHUB_TOKEN = "ghp_..."

# Select 'y' when prompted to recreate services
```

### Production Environment
```bash
# Add production settings
./n8n-master.sh → 1) Manage n8n → 11) Manage Environment Variables → 2) Add new variable

# Add variables:
N8N_METRICS = "true"
N8N_LOG_LEVEL = "warn"

# Select 'y' to recreate services automatically
```

### Regular Maintenance
```bash
# Weekly health check
./n8n-master.sh → 1) Manage n8n → 8) Health Check

# Check for updates
./n8n-master.sh → 1) Manage n8n → 7) Update n8n

# Review logs
tail -100 ~/n8n-operations.log
```

## 🆕 Recent Improvements

### Version 2.1.0 - Security Enhancements
- **Let's Encrypt Integration**: Support for free SSL certificates with DNS-01 challenge
- **Firewall Management**: Automated UFW configuration with secure defaults
- **Rate Limiting**: Comprehensive rate limiting to prevent abuse
- **Intrusion Prevention**: fail2ban integration with automatic IP blocking
- **Automatic Updates**: Configurable security and application updates
- **Security Hardening**: One-click application of all security best practices
- **Enhanced Monitoring**: Security status in health checks and logs

### Version 2.0.0 - Core Improvements
- **Unified Architecture**: Single master script with all functions built-in
- **Enhanced SSL Certificates**: Multiple IP address support with SAN extensions
- **Comprehensive Logging**: All operations logged with timestamps
- **Automatic Service Recreation**: Environment variable management with prompts
- **Backup Unification**: Consistent backup format across all operations
- **Enhanced Error Handling**: Better error messages and recovery suggestions
- **Deprecation Compliance**: Latest n8n environment variables
- **Docker Compose Integration**: Proper environment variable management

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## 📄 License

This deployment script is provided as-is for use with n8n. n8n itself is licensed under the [Sustainable Use License](https://github.com/n8n-io/n8n/blob/master/LICENSE.md).

## 🔒 Security Configuration

### SSL Certificate Management

The script now supports both self-signed certificates and Let's Encrypt with DNS-01 challenge:

#### Switching to Let's Encrypt
```bash
./n8n-master.sh → Manage n8n → Security & SSL Settings → Switch to Let's Encrypt
```

**Supported DNS Providers**:
- **Cloudflare** - Automated with API token
- **AWS Route53** - Automated with IAM credentials
- **DigitalOcean** - Automated with API token
- **Google Cloud DNS** - Automated with service account
- **Manual DNS** - Works with any provider (GoDaddy, Namecheap, etc.)

**Benefits of DNS-01 Challenge**:
- No need to open port 80
- Works behind firewalls/NAT
- Wildcard certificate support
- More secure than HTTP-01

#### Provider Setup Instructions:

**Cloudflare**:
1. Get API token: https://dash.cloudflare.com/profile/api-tokens
2. Create token with "Zone:DNS:Edit" permissions
3. Enter token when prompted

**AWS Route53**:
1. Create IAM user with Route53 permissions
2. Generate Access Key ID and Secret Access Key
3. Enter credentials when prompted
4. Optional: Support for session tokens (temporary credentials)

**DigitalOcean**:
1. Get API token: https://cloud.digitalocean.com/account/api/tokens
2. Generate token with write scope
3. Enter token when prompted

**Google Cloud DNS**:
1. Create service account in GCP Console
2. Grant "DNS Administrator" role
3. Download JSON key file
4. Provide path to JSON file when prompted

**Manual DNS (Any Provider)**:
1. Script shows exact TXT record to add
2. Add record in your DNS provider's control panel
3. Press Enter to verify and complete
4. Works with GoDaddy, Namecheap, or any DNS provider

### Firewall Configuration

UFW (Uncomplicated Firewall) is automatically configured during installation:

**Default Rules**:
- Allow SSH (port 22)
- Allow HTTPS (port 443)
- Deny all other incoming
- Allow all outgoing

**Management**:
```bash
./n8n-master.sh → Manage n8n → Security & SSL Settings → Configure Firewall
```

### Rate Limiting

Nginx rate limiting is automatically configured to prevent abuse:

**Limits by Endpoint**:
- Authentication: 5 requests/minute
- API endpoints: 30 requests/second (burst: 20)
- Webhooks: 50 requests/second (burst: 50)
- General: 10 requests/second (burst: 20)
- Connection limit: 100 per IP

### fail2ban Configuration

Automatically blocks IPs after repeated failed attempts:

**Jail Configuration**:
- **n8n-auth**: 5 failed logins = 1 hour ban
- **nginx-limit-req**: 10 rate limit hits/minute = 10 minute ban
- **sshd**: SSH brute force protection (default fail2ban jail)

**Management**:
```bash
./n8n-master.sh → Manage n8n → Security & SSL Settings → View fail2ban Status
```

### fail2ban IP Management

Advanced IP management capabilities for handling false positives and security threats:

**Access IP Management:**
```bash
./n8n-master.sh → Manage n8n → Security & SSL Settings → View fail2ban Status → Manage Banned IPs
```

**Features:**
1. **View All Banned IPs** - Monitor current threats across all jails
2. **Unban Specific IP** - Remove false positive bans
   - Unban from all jails at once
   - Unban from specific jail only
3. **Add IP to Whitelist** - Permanently trust specific IPs
   - Supports descriptions for documentation
   - Automatically restarts fail2ban to apply changes
4. **View Whitelist** - Show all currently trusted IPs
5. **Emergency Unban All** - Clear all bans from all jails (with confirmation)

**Common Use Cases:**
- **False Positive**: Use "Unban Specific IP" to restore legitimate access
- **Trusted Admin IP**: Use "Add to Whitelist" for your office/home IP
- **System Reset**: Use "Emergency Unban All" to clear all bans after issues
- **Security Monitoring**: Use "View All Banned IPs" to monitor threats

**Advanced Features:**
- **IP Validation**: Automatic validation of IP address format
- **Safety Checks**: Clear error messages for invalid entries
- **Confirmations**: Prompts for destructive actions
- **Backup System**: Automatic backup of configuration files before changes
- **Professional Interface**: Clean status displays and intuitive navigation

### Automatic Security Updates

Configurable automatic update options:

1. **Security updates only** (default)
2. **All system updates**
3. **Security updates + n8n auto-update**
4. **Disabled**

**Configure**:
```bash
./n8n-master.sh → Manage n8n → Security & SSL Settings → Configure Automated Updates
```

**n8n Auto-Updates**:
- Weekly schedule (Sundays)
- Automatic backup before update
- Rollback capability on failure

### Security Hardening

Apply all security measures at once:
```bash
./n8n-master.sh → Manage n8n → Security & SSL Settings → Apply All Security Hardening
```

This enables:
- Firewall with secure rules
- fail2ban with default jails
- Automatic security updates
- Rate limiting
- Security headers

## ⚠️ Disclaimer

This script now includes enterprise-grade security features suitable for production use. The enhanced security measures include:
- ✅ Proper SSL certificates (Let's Encrypt with DNS-01)
- ✅ Configured firewall rules (UFW)
- ✅ Rate limiting implementation
- ✅ fail2ban enabled
- ✅ Automatic security updates

For internet-facing deployments, consider additional measures:
- Use a reverse proxy/CDN (Cloudflare)
- Implement application-level authentication
- Regular security audits
- Monitoring and alerting

---

**Version**: 2.1.0  
**Last Updated**: December 2024  
**Tested On**: Ubuntu 22.04/24.04 LTS, Debian 11/12  
**Security Level**: Production-Ready with Enhanced Security
