#!/bin/bash
# n8n Master Script - Deploy, Manage, and Uninstall
# Complete solution for n8n lifecycle management

set -euo pipefail

# Configuration
N8N_DIR="${N8N_DIR:-$HOME/n8n}"
GLOBAL_BACKUP_DIR="${GLOBAL_BACKUP_DIR:-$HOME/n8n-backups}"
COMPOSE_PROJECT_NAME="n8n"
SCRIPT_VERSION="2.1.0"
LOG_FILE="$HOME/n8n-operations.log"

# Colors - Using printf for better compatibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Enhanced logging functions with file output
log_to_file() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
}

log_info() { 
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
    log_to_file "INFO" "$1"
}
log_warn() { 
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
    log_to_file "WARN" "$1"
}
log_error() { 
    printf "${RED}[ERROR]${NC} %s\n" "$1"
    log_to_file "ERROR" "$1"
}
log_success() { 
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
    log_to_file "SUCCESS" "$1"
}
log_debug() {
    local message="$1"
    log_to_file "DEBUG" "$message"
    if [ "${DEBUG:-false}" = "true" ]; then
        printf "${CYAN}[DEBUG]${NC} %s\n" "$message"
    fi
}

# Function entry/exit logging
log_function_start() {
    log_debug "Starting function: $1"
}
log_function_end() {
    log_debug "Completed function: $1"
}

# Check if running as root
check_not_root() {
    if [ "$EUID" -eq 0 ]; then
        log_error "This script should not be run as root"
        log_info "Please run as a regular user with sudo privileges"
        exit 1
    fi
}

# Print header
print_header() {
    clear
    printf "\n"
    printf "${CYAN}n8n Master Script v${SCRIPT_VERSION}${NC}\n"
    printf "════════════════════════════════════\n"
    printf "\n"
}

# Check if n8n is installed
is_n8n_installed() {
    [ -d "$N8N_DIR" ] && [ -f "$N8N_DIR/docker-compose.yml" ]
}

# Check if n8n is running
is_n8n_running() {
    if [ -d "$N8N_DIR" ]; then
        cd "$N8N_DIR"
        docker compose ps --services --filter "status=running" 2>/dev/null | grep -q "n8n" || return 1
    else
        return 1
    fi
}

# Get installation status
get_status() {
    if is_n8n_installed; then
        if is_n8n_running; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        echo "not_installed"
    fi
}

# Enhanced certificate generation with multiple IP addresses and SAN support
generate_ssl_certificate() {
    local cert_dir="$1"
    local key_file="$2"
    local cert_file="$3"
    
    log_info "Generating enhanced SSL certificate with multiple IP address support..."
    
    # Auto-detect all non-loopback IP addresses
    local all_ips=($(hostname -I | tr ' ' '\n' | grep -v '^127\.' | grep -v '^$'))
    log_debug "Detected IP addresses: ${all_ips[*]}"
    
    # Create temporary OpenSSL config file for SAN support
    local ssl_config=$(mktemp)
    cat > "$ssl_config" << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = State
L = City
O = Organization
CN = n8n.local

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = n8n.local
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

    # Add all detected IPs to the SAN section
    local ip_counter=2
    for ip in "${all_ips[@]}"; do
        echo "IP.$ip_counter = $ip" >> "$ssl_config"
        ((ip_counter++))
    done

    # Generate certificate with SAN extensions
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$key_file" \
        -out "$cert_file" \
        -config "$ssl_config" \
        -extensions v3_req \
        2>/dev/null
    
    # Set proper permissions
    chmod 644 "$cert_file"
    chmod 600 "$key_file"
    
    # Cleanup temporary config
    rm -f "$ssl_config"
    
    log_success "SSL certificate created with SAN support:"
    log_info "  - Domains: n8n.local, localhost"
    log_info "  - IP addresses: 127.0.0.1, ${all_ips[*]}"
    log_info "  - Valid for 10 years"
}

# Built-in backup function with comprehensive logging
create_backup() {
    log_function_start "create_backup"
    local restart_containers="${1:-restart}"
    local backup_dir="${GLOBAL_BACKUP_DIR:-$HOME/n8n-backups}"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    log_info "Starting backup process with timestamp: $timestamp"
    log_debug "Restart containers after backup: $restart_containers"
    log_debug "Backup directory: $backup_dir"
    
    printf "\n${BLUE}Creating backup...${NC}\n"
    mkdir -p "$backup_dir"
    
    # Ensure we're in n8n directory
    if [ ! -d "$N8N_DIR" ]; then
        log_error "n8n installation directory not found: $N8N_DIR"
        return 1
    fi
    
    cd "$N8N_DIR"
    log_debug "Changed to n8n directory: $(pwd)"
    
    # Check docker volumes before backup
    log_debug "Docker volumes before backup:"
    docker volume ls --format '{{.Name}}' | grep -E '(n8n|postgres)' | while read vol; do
        log_debug "  Volume: $vol"
    done
    
    # Stop containers first to ensure consistent backup
    log_info "Stopping containers for backup..."
    docker compose down
    
    # Create temp directory for backup components
    TEMP_DIR=$(mktemp -d)
    log_debug "Created temp directory: $TEMP_DIR"
    
    # Backup database volume directly (no container dependency)
    if docker volume ls --format '{{.Name}}' | grep -q "n8n_postgres_data"; then
        log_info "Backing up database volume..."
        log_debug "Running postgres volume backup command..."
        # Mount the volume and copy the data - FIX: Use consistent filename
        docker run --rm -v n8n_postgres_data:/source -v "$TEMP_DIR":/backup alpine \
            tar -czf /backup/postgres_data_${timestamp}.tar.gz -C /source .
        
        if [ -f "$TEMP_DIR/postgres_data_${timestamp}.tar.gz" ]; then
            local db_size=$(du -h "$TEMP_DIR/postgres_data_${timestamp}.tar.gz" | cut -f1)
            log_success "Database volume backup completed (${db_size})"
            log_debug "Database backup file: postgres_data_${timestamp}.tar.gz"
        else
            log_error "Database volume backup failed - file not created"
        fi
    else
        log_warn "No postgres volume found for backup"
    fi
    
    # Backup n8n data
    log_info "Backing up n8n data..."
    if [ -d "$N8N_DIR/.n8n" ]; then
        tar -czf "$TEMP_DIR/n8n_data_${timestamp}.tar.gz" -C "$N8N_DIR" .n8n
        local n8n_size=$(du -h "$TEMP_DIR/n8n_data_${timestamp}.tar.gz" | cut -f1)
        log_success "n8n data backup completed (${n8n_size})"
    else
        log_warn "No .n8n directory found to backup"
        # Create empty archive to maintain structure
        tar -czf "$TEMP_DIR/n8n_data_${timestamp}.tar.gz" -T /dev/null
    fi
    
    # Backup configs including Cloudflare IP lists
    log_info "Backing up configuration files..."
    tar -czf "$TEMP_DIR/config_${timestamp}.tar.gz" \
        docker-compose.yml nginx.conf .env certs/ .cloudflare_ips_v4 .cloudflare_ips_v6 2>/dev/null || {
        log_warn "Some config files missing, backing up available files"
        tar -czf "$TEMP_DIR/config_${timestamp}.tar.gz" --ignore-failed-read \
            docker-compose.yml nginx.conf .env certs/ .cloudflare_ips_v4 .cloudflare_ips_v6 2>/dev/null || true
    }
    
    # Backup DNS provider credentials
    log_info "Backing up DNS provider credentials..."
    mkdir -p "$TEMP_DIR/dns_credentials"
    
    # Cloudflare credentials
    if [ -f "$N8N_DIR/.cloudflare.ini" ]; then
        cp "$N8N_DIR/.cloudflare.ini" "$TEMP_DIR/dns_credentials/"
        log_debug "Backed up Cloudflare credentials"
    fi
    
    # DigitalOcean credentials  
    if [ -f "$N8N_DIR/.digitalocean.ini" ]; then
        cp "$N8N_DIR/.digitalocean.ini" "$TEMP_DIR/dns_credentials/"
        log_debug "Backed up DigitalOcean credentials"
    fi
    
    # Google Cloud credentials
    if [ -f "$N8N_DIR/.google.ini" ]; then
        cp "$N8N_DIR/.google.ini" "$TEMP_DIR/dns_credentials/"
        log_debug "Backed up Google Cloud credentials"
    fi
    
    if [ -f "$N8N_DIR/.google-cloud.json" ]; then
        cp "$N8N_DIR/.google-cloud.json" "$TEMP_DIR/dns_credentials/"
        log_debug "Backed up Google Cloud JSON key"
    fi
    
    # AWS credentials
    if [ -f "$HOME/.aws/credentials" ]; then
        mkdir -p "$TEMP_DIR/dns_credentials/.aws"
        cp "$HOME/.aws/credentials" "$TEMP_DIR/dns_credentials/.aws/"
        log_debug "Backed up AWS credentials"
    fi
    
    # Create DNS credentials archive
    if [ "$(ls -A $TEMP_DIR/dns_credentials 2>/dev/null)" ]; then
        tar -czf "$TEMP_DIR/dns_credentials_${timestamp}.tar.gz" -C "$TEMP_DIR" dns_credentials
        rm -rf "$TEMP_DIR/dns_credentials"
        log_success "DNS credentials backed up"
    else
        log_debug "No DNS credentials found to backup"
        # Create empty archive to maintain structure
        tar -czf "$TEMP_DIR/dns_credentials_${timestamp}.tar.gz" -T /dev/null
    fi
    
    # Backup fail2ban configuration
    log_info "Backing up fail2ban configuration..."
    mkdir -p "$TEMP_DIR/fail2ban_config"
    
    # Backup fail2ban jail and filter files
    if [ -f "/etc/fail2ban/jail.d/n8n.conf" ]; then
        sudo cp "/etc/fail2ban/jail.d/n8n.conf" "$TEMP_DIR/fail2ban_config/" 2>/dev/null || log_warn "Could not backup n8n jail config"
        log_debug "Backed up n8n jail configuration"
    fi
    
    if [ -f "/etc/fail2ban/filter.d/n8n-auth.conf" ]; then
        sudo cp "/etc/fail2ban/filter.d/n8n-auth.conf" "$TEMP_DIR/fail2ban_config/" 2>/dev/null || log_warn "Could not backup n8n filter config"
        log_debug "Backed up n8n filter configuration"
    fi
    
    if [ -f "/etc/fail2ban/jail.local" ]; then
        sudo cp "/etc/fail2ban/jail.local" "$TEMP_DIR/fail2ban_config/" 2>/dev/null || log_warn "Could not backup jail.local config"
        log_debug "Backed up fail2ban IP whitelist"
    fi
    
    # Create fail2ban config archive
    if [ "$(ls -A $TEMP_DIR/fail2ban_config 2>/dev/null)" ]; then
        tar -czf "$TEMP_DIR/fail2ban_config_${timestamp}.tar.gz" -C "$TEMP_DIR" fail2ban_config
        rm -rf "$TEMP_DIR/fail2ban_config"
        log_success "fail2ban configuration backed up"
    else
        log_debug "No fail2ban configuration found to backup"
        # Create empty archive to maintain structure
        tar -czf "$TEMP_DIR/fail2ban_config_${timestamp}.tar.gz" -T /dev/null
    fi
    
    # Backup UFW firewall rules
    log_info "Backing up firewall rules..."
    mkdir -p "$TEMP_DIR/firewall_config"
    
    if command -v ufw &> /dev/null; then
        # Export UFW rules
        sudo ufw status numbered > "$TEMP_DIR/firewall_config/ufw_status.txt" 2>/dev/null || log_warn "Could not export UFW status"
        sudo ufw --dry-run enable > "$TEMP_DIR/firewall_config/ufw_rules.txt" 2>/dev/null || log_warn "Could not export UFW rules"
        
        # Backup UFW config files if they exist
        if [ -d "/etc/ufw" ]; then
            sudo tar -czf "$TEMP_DIR/firewall_config/ufw_config.tar.gz" -C /etc ufw 2>/dev/null || log_warn "Could not backup UFW config files"
            log_debug "Backed up UFW configuration files"
        fi
        
        log_debug "Backed up firewall rules"
    else
        log_debug "UFW not installed, no firewall rules to backup"
    fi
    
    # Create firewall config archive
    if [ "$(ls -A $TEMP_DIR/firewall_config 2>/dev/null)" ]; then
        tar -czf "$TEMP_DIR/firewall_config_${timestamp}.tar.gz" -C "$TEMP_DIR" firewall_config
        rm -rf "$TEMP_DIR/firewall_config"
        log_success "Firewall configuration backed up"
    else
        log_debug "No firewall configuration found to backup"
        # Create empty archive to maintain structure
        tar -czf "$TEMP_DIR/firewall_config_${timestamp}.tar.gz" -T /dev/null
    fi
    
    # Backup Let's Encrypt data and configurations
    log_info "Backing up Let's Encrypt data..."
    mkdir -p "$TEMP_DIR/letsencrypt_config"
    
    # Backup Let's Encrypt account data and configurations
    if [ -d "/etc/letsencrypt" ]; then
        sudo tar -czf "$TEMP_DIR/letsencrypt_config/letsencrypt_etc.tar.gz" -C /etc letsencrypt 2>/dev/null || log_warn "Could not backup Let's Encrypt directory"
        log_debug "Backed up Let's Encrypt account data and certificates"
    fi
    
    # Backup manual DNS auth script if it exists
    if [ -f "$N8N_DIR/manual-dns-auth.sh" ]; then
        cp "$N8N_DIR/manual-dns-auth.sh" "$TEMP_DIR/letsencrypt_config/"
        log_debug "Backed up manual DNS auth script"
    fi
    
    # Create Let's Encrypt config archive
    if [ "$(ls -A $TEMP_DIR/letsencrypt_config 2>/dev/null)" ]; then
        tar -czf "$TEMP_DIR/letsencrypt_config_${timestamp}.tar.gz" -C "$TEMP_DIR" letsencrypt_config
        rm -rf "$TEMP_DIR/letsencrypt_config"
        log_success "Let's Encrypt configuration backed up"
    else
        log_debug "No Let's Encrypt configuration found to backup"
        # Create empty archive to maintain structure
        tar -czf "$TEMP_DIR/letsencrypt_config_${timestamp}.tar.gz" -T /dev/null
    fi
    
    # Log backup contents before creating combined archive
    log_debug "Backup components created:"
    ls -la "$TEMP_DIR"/ | while read line; do
        log_debug "  $line"
    done
    
    # Create combined backup
    log_info "Creating combined backup archive..."
    cd "$TEMP_DIR"
    tar -czf "$backup_dir/full_backup_${timestamp}.tar.gz" .
    
    # Verify backup was created
    if [ -f "$backup_dir/full_backup_${timestamp}.tar.gz" ]; then
        local backup_size=$(du -h "$backup_dir/full_backup_${timestamp}.tar.gz" | cut -f1)
        log_success "Combined backup archive created (${backup_size})"
        
        # List contents of final backup for verification
        log_debug "Final backup contents:"
        tar -tzf "$backup_dir/full_backup_${timestamp}.tar.gz" | while read file; do
            log_debug "  $file"
        done
    else
        log_error "Failed to create combined backup archive"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    # Cleanup temp directory
    rm -rf "$TEMP_DIR"
    log_debug "Cleaned up temp directory"
    
    # Keep only last 5 backups
    cd "$backup_dir"
    local backup_count=$(ls -1 full_backup_*.tar.gz 2>/dev/null | wc -l)
    log_debug "Total backups before cleanup: $backup_count"
    
    if [ "$backup_count" -gt 5 ]; then
        local removed_backups=$(ls -t full_backup_*.tar.gz | tail -n +6)
        echo "$removed_backups" | while read backup; do
            log_debug "Removing old backup: $backup"
        done
        ls -t full_backup_*.tar.gz | tail -n +6 | xargs -r rm
        log_info "Removed old backups, keeping latest 5"
    fi
    
    # Restart containers only if requested
    cd "$N8N_DIR"
    if [ "$restart_containers" = "restart" ]; then
        log_info "Restarting containers..."
        docker compose up -d
        log_debug "Containers restarted"
    else
        log_info "Leaving containers stopped (as requested)"
        log_debug "Containers remain stopped per request"
    fi
    
    # Validate backup contents
    log_debug "Validating backup integrity..."
    if validate_backup "$backup_dir/full_backup_${timestamp}.tar.gz"; then
        log_success "Backup validation passed"
        printf "${GREEN}Backup created: ${backup_dir}/full_backup_${timestamp}.tar.gz${NC}\n"
    else
        log_error "Backup validation failed!"
        return 1
    fi
    
    log_function_end "create_backup"
    return 0
}

# Backup validation function
validate_backup() {
    local backup_file="$1"
    log_debug "Validating backup file: $(basename "$backup_file")"
    
    # Check if backup file exists and is readable
    if [ ! -f "$backup_file" ]; then
        log_error "Backup file does not exist: $backup_file"
        return 1
    fi
    
    if [ ! -r "$backup_file" ]; then
        log_error "Backup file is not readable: $backup_file"
        return 1
    fi
    
    # Check backup file size (should be > 1KB)
    local size_bytes=$(stat -c%s "$backup_file" 2>/dev/null || echo "0")
    if [ "$size_bytes" -lt 1024 ]; then
        log_error "Backup file is too small (${size_bytes} bytes), likely corrupted"
        return 1
    fi
    
    # Test if backup is a valid tar.gz file
    if ! tar -tzf "$backup_file" >/dev/null 2>&1; then
        log_error "Backup file is not a valid tar.gz archive"
        return 1
    fi
    
    # Check required components exist in backup
    local temp_list=$(mktemp)
    tar -tzf "$backup_file" > "$temp_list"
    
    local postgres_found=false
    local n8n_found=false
    local config_found=false
    local dns_creds_found=false
    local fail2ban_found=false
    local firewall_found=false
    local letsencrypt_found=false
    
    while read -r line; do
        case "$line" in
            *postgres_data_*.tar.gz) postgres_found=true; log_debug "Found postgres data: $line" ;;
            *n8n_data_*.tar.gz) n8n_found=true; log_debug "Found n8n data: $line" ;;
            *config_*.tar.gz) config_found=true; log_debug "Found config data: $line" ;;
            *dns_credentials_*.tar.gz) dns_creds_found=true; log_debug "Found DNS credentials: $line" ;;
            *fail2ban_config_*.tar.gz) fail2ban_found=true; log_debug "Found fail2ban config: $line" ;;
            *firewall_config_*.tar.gz) firewall_found=true; log_debug "Found firewall config: $line" ;;
            *letsencrypt_config_*.tar.gz) letsencrypt_found=true; log_debug "Found Let's Encrypt config: $line" ;;
        esac
    done < "$temp_list"
    
    rm -f "$temp_list"
    
    # Verify all required components are present
    local validation_errors=0
    
    if [ "$postgres_found" = "false" ]; then
        log_warn "Missing postgres data in backup"
        validation_errors=$((validation_errors + 1))
    fi
    
    if [ "$n8n_found" = "false" ]; then
        log_warn "Missing n8n data in backup"
        validation_errors=$((validation_errors + 1))
    fi
    
    if [ "$config_found" = "false" ]; then
        log_warn "Missing config data in backup"
        validation_errors=$((validation_errors + 1))
    fi
    
    # Security components are optional but logged for information
    if [ "$dns_creds_found" = "true" ]; then
        log_debug "DNS credentials component found"
    fi
    
    if [ "$fail2ban_found" = "true" ]; then
        log_debug "fail2ban configuration component found"
    fi
    
    if [ "$firewall_found" = "true" ]; then
        log_debug "Firewall configuration component found"
    fi
    
    if [ "$letsencrypt_found" = "true" ]; then
        log_debug "Let's Encrypt configuration component found"
    fi
    
    if [ "$validation_errors" -gt 0 ]; then
        log_error "Backup validation failed: $validation_errors missing core components"
        return 1
    fi
    
    # Check individual component integrity
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    if tar -xzf "$backup_file" 2>/dev/null; then
        # Test each sub-archive (core components)
        for component in postgres_data_*.tar.gz n8n_data_*.tar.gz config_*.tar.gz; do
            if [ -f "$component" ]; then
                if tar -tzf "$component" >/dev/null 2>&1; then
                    log_debug "Component $component is valid"
                else
                    log_error "Component $component is corrupted"
                    rm -rf "$temp_dir"
                    return 1
                fi
            fi
        done
        
        # Test security components (optional, but validate if present)
        for component in dns_credentials_*.tar.gz fail2ban_config_*.tar.gz firewall_config_*.tar.gz letsencrypt_config_*.tar.gz; do
            if [ -f "$component" ]; then
                if tar -tzf "$component" >/dev/null 2>&1; then
                    log_debug "Security component $component is valid"
                else
                    log_warn "Security component $component is corrupted, but backup can still be restored"
                fi
            fi
        done
    else
        log_error "Failed to extract backup for validation"
        rm -rf "$temp_dir"
        return 1
    fi
    
    rm -rf "$temp_dir"
    log_debug "Backup validation completed successfully"
    return 0
}

# Built-in restore function with comprehensive logging
restore_backup() {
    log_function_start "restore_backup"
    local backup_dir="${GLOBAL_BACKUP_DIR:-$HOME/n8n-backups}"
    
    log_info "Starting restore process"
    log_debug "Backup directory: $backup_dir"
    
    printf "\n${BLUE}Available backups:${NC}\n"
    
    # Get list of backup files
    local backup_files=($(ls -t "$backup_dir"/full_backup_*.tar.gz 2>/dev/null))
    
    log_debug "Found ${#backup_files[@]} backup files"
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        printf "No backups found\n"
        log_error "No backup files found in $backup_dir"
        sleep 2
        return 1
    fi
    
    printf "\n"
    # Display backups with numbers
    for i in "${!backup_files[@]}"; do
        backup_file="${backup_files[$i]}"
        filename=$(basename "$backup_file")
        timestamp=$(echo "$filename" | sed 's/full_backup_//;s/.tar.gz//')
        size=$(du -h "$backup_file" | cut -f1)
        printf "%d) %s (Size: %s)\n" $((i+1)) "$timestamp" "$size"
        log_debug "Backup option $((i+1)): $filename ($size)"
    done
    printf "%d) Cancel\n" $((${#backup_files[@]}+1))
    printf "\n"
    
    read -p "Select backup to restore (1-$((${#backup_files[@]}+1))): " RESTORE_CHOICE
    
    log_debug "User selected option: $RESTORE_CHOICE"
    
    # Validate choice
    if [[ ! "$RESTORE_CHOICE" =~ ^[0-9]+$ ]]; then
        log_error "Invalid selection: not a number"
        sleep 2
        return 1
    fi
    
    # Cancel option
    if [ "$RESTORE_CHOICE" -eq $((${#backup_files[@]}+1)) ]; then
        log_info "User cancelled restore operation"
        return 0
    fi
    
    # Check valid range
    if [ "$RESTORE_CHOICE" -lt 1 ] || [ "$RESTORE_CHOICE" -gt ${#backup_files[@]} ]; then
        log_error "Invalid selection: out of range (1-${#backup_files[@]})"
        sleep 2
        return 1
    fi
    
    # Get selected backup file
    backup_file="${backup_files[$((RESTORE_CHOICE-1))]}"
    log_info "Selected backup file: $(basename "$backup_file")"
    
    # Validate backup before proceeding
    log_info "Validating backup integrity..."
    if ! validate_backup "$backup_file"; then
        log_error "Backup validation failed! Cannot proceed with restore."
        sleep 3
        return 1
    fi
    log_success "Backup validation passed"
    
    printf "\n${YELLOW}This will restore data from backup. Current data will be lost!${NC}\n"
    printf "Continue? (yes/no): "
    read confirm
    
    log_debug "User confirmation: $confirm"
    [ "$confirm" != "yes" ] && {
        log_info "User cancelled restore operation"
        return 0
    }
    
    # Ensure we're in n8n directory
    if [ ! -d "$N8N_DIR" ]; then
        log_error "n8n installation directory not found: $N8N_DIR"
        return 1
    fi
    
    # Extract backup
    TEMP_DIR=$(mktemp -d)
    log_debug "Created temp directory: $TEMP_DIR"
    
    cd "$TEMP_DIR"
    log_info "Extracting backup archive..."
    tar -xzf "$backup_file"
    
    # List extracted contents for debugging
    log_debug "Extracted backup contents:"
    ls -la "$TEMP_DIR"/ | while read line; do
        log_debug "  $line"
    done
    
    # Stop services
    cd "$N8N_DIR"
    log_info "Stopping containers for restore..."
    docker compose down
    
    # Restore configuration files (nginx, docker-compose, env, certificates)
    log_info "Restoring configuration files..."
    local config_file=$(ls "$TEMP_DIR"/config_*.tar.gz 2>/dev/null | head -1)
    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
        log_debug "Found config file: $(basename "$config_file")"
        cd "$TEMP_DIR"
        tar -xzf "$(basename "$config_file")"
        
        # Restore environment configuration
        if [ -f ".env" ]; then
            cp ".env" "$N8N_DIR/.env"
            log_success "Restored environment configuration"
        else
            log_warn "No .env file found in backup"
        fi
        
        # Restore docker-compose.yml
        if [ -f "docker-compose.yml" ]; then
            cp "docker-compose.yml" "$N8N_DIR/docker-compose.yml"
            log_success "Restored docker-compose.yml configuration"
        else
            log_warn "No docker-compose.yml found in backup"
        fi
        
        # Restore nginx configuration
        if [ -f "nginx.conf" ]; then
            cp "nginx.conf" "$N8N_DIR/nginx.conf"
            log_success "Restored nginx configuration"
        else
            log_warn "No nginx.conf found in backup"
        fi
        
        # Restore SSL certificates
        if [ -d "certs" ]; then
            mkdir -p "$N8N_DIR/certs"
            cp -r certs/* "$N8N_DIR/certs/" 2>/dev/null || true
            chmod 600 "$N8N_DIR/certs/n8n.key" 2>/dev/null || true
            log_success "Restored SSL certificates"
        else
            log_warn "No certificates found in backup"
        fi
        
        # Restore Cloudflare IP lists if present
        if [ -f ".cloudflare_ips_v4" ] || [ -f ".cloudflare_ips_v6" ]; then
            cp .cloudflare_ips_v* "$N8N_DIR/" 2>/dev/null || true
            log_success "Restored Cloudflare IP lists"
        fi
        
        cd "$N8N_DIR"
    else
        log_warn "No configuration backup found - certificates and config may be missing"
    fi
    
    # Restore n8n data
    log_info "Restoring n8n data..."
    log_debug "Removing existing .n8n directory"
    rm -rf .n8n
    
    # Find and extract n8n data
    local n8n_data_file=$(ls "$TEMP_DIR"/n8n_data_*.tar.gz 2>/dev/null | head -1)
    if [ -n "$n8n_data_file" ]; then
        log_debug "Found n8n data file: $(basename "$n8n_data_file")"
        tar -xzf "$n8n_data_file" -C "$N8N_DIR"
        log_success "n8n data restored"
    else
        log_warn "No n8n data file found in backup"
    fi
    
    # Preserve the config file to maintain encryption key continuity
    # This is critical for maintaining user setup state and encrypted data access
    if [ -f ".n8n/config" ]; then
        chmod 600 ".n8n/config"
        log_debug "Preserving config file to maintain encryption key and user state (permissions: 600)"
    else
        log_warn "No config file found in restored data - may need initial setup"
    fi
    
    # Restore database volume directly
    local postgres_data_file=$(ls "$TEMP_DIR"/postgres_data_*.tar.gz 2>/dev/null | head -1)
    if [ -n "$postgres_data_file" ]; then
        log_info "Restoring database volume..."
        log_debug "Found postgres data file: $(basename "$postgres_data_file")"
        
        # Remove existing volume and recreate
        log_debug "Removing existing postgres volume"
        docker volume rm n8n_postgres_data 2>/dev/null || true
        
        log_debug "Creating new postgres volume"
        docker volume create n8n_postgres_data
        
        # Restore data to volume - FIX: Use specific file instead of wildcard
        log_debug "Restoring data to postgres volume from: $(basename "$postgres_data_file")"
        docker run --rm -v n8n_postgres_data:/target -v "$TEMP_DIR":/backup alpine \
            tar -xzf "/backup/$(basename "$postgres_data_file")" -C /target
        
        if [ $? -eq 0 ]; then
            log_success "Database volume restored successfully"
        else
            log_error "Failed to restore database volume"
        fi
    elif [ -f "$TEMP_DIR"/postgres_*.sql ]; then
        # Fallback for old backup format
        log_info "Restoring database from SQL dump (old format)..."
        log_debug "Found SQL dump file in backup"
        
        docker compose up -d postgres
        sleep 10
        
        # Get container name dynamically
        POSTGRES_CONTAINER=$(docker compose ps --format '{{.Names}}' | grep postgres)
        log_debug "Postgres container: $POSTGRES_CONTAINER"
        
        docker exec "$POSTGRES_CONTAINER" psql -U n8n -d postgres -c "DROP DATABASE IF EXISTS n8n;"
        docker exec "$POSTGRES_CONTAINER" psql -U n8n -d postgres -c "CREATE DATABASE n8n;"
        docker exec -i "$POSTGRES_CONTAINER" psql -U n8n -d n8n < "$TEMP_DIR"/postgres_*.sql
        docker compose down
        
        log_success "Database restored from SQL dump"
    else
        log_error "No database backup found in archive!"
        log_debug "Looking for files matching: postgres_data_*.tar.gz or postgres_*.sql"
        ls -la "$TEMP_DIR"/ | grep -i postgres | while read line; do
            log_debug "  Found postgres file: $line"
        done
    fi
    
    # Restore security components using helper function
    restore_security_components "$TEMP_DIR" "$N8N_DIR"
    
    # Start all services
    log_info "Starting all services..."
    docker compose up -d
    
    # Wait a moment and check service status
    sleep 5
    log_debug "Service status after restore:"
    docker compose ps --format '{{.Names}} {{.Status}}' | while read line; do
        log_debug "  $line"
    done
    
    rm -rf "$TEMP_DIR"
    log_debug "Cleaned up temp directory"
    
    printf "${GREEN}Restore complete!${NC}\n"
    log_function_end "restore_backup"
    sleep 2
    return 0
}

# Helper function to restore security components from backup
restore_security_components() {
    log_function_start "restore_security_components"
    local temp_dir="$1"
    local n8n_dir="$2"
    
    log_info "Restoring security components..."
    
    # Restore DNS provider credentials
    log_info "Restoring DNS provider credentials..."
    local dns_creds_file=$(ls "$temp_dir"/dns_credentials_*.tar.gz 2>/dev/null | head -1)
    if [ -n "$dns_creds_file" ]; then
        log_debug "Found DNS credentials file: $(basename "$dns_creds_file")"
        cd "$temp_dir"
        tar -xzf "$(basename "$dns_creds_file")" 2>/dev/null
        
        # Restore DNS provider credential files
        if [ -d "dns_credentials" ]; then
            # Cloudflare
            if [ -f "dns_credentials/.cloudflare.ini" ]; then
                cp "dns_credentials/.cloudflare.ini" "$n8n_dir/.cloudflare.ini"
                chmod 600 "$n8n_dir/.cloudflare.ini"
                log_debug "Restored Cloudflare credentials"
            fi
            
            # DigitalOcean
            if [ -f "dns_credentials/.digitalocean.ini" ]; then
                cp "dns_credentials/.digitalocean.ini" "$n8n_dir/.digitalocean.ini"
                chmod 600 "$n8n_dir/.digitalocean.ini"
                log_debug "Restored DigitalOcean credentials"
            fi
            
            # Google Cloud
            if [ -f "dns_credentials/.google.ini" ]; then
                cp "dns_credentials/.google.ini" "$n8n_dir/.google.ini"
                chmod 600 "$n8n_dir/.google.ini"
                log_debug "Restored Google Cloud credentials"
            fi
            
            if [ -f "dns_credentials/.google-cloud.json" ]; then
                cp "dns_credentials/.google-cloud.json" "$n8n_dir/.google-cloud.json"
                chmod 600 "$n8n_dir/.google-cloud.json"
                log_debug "Restored Google Cloud JSON key"
            fi
            
            # AWS credentials
            if [ -d "dns_credentials/.aws" ]; then
                mkdir -p "$HOME/.aws"
                cp "dns_credentials/.aws/credentials" "$HOME/.aws/credentials"
                chmod 600 "$HOME/.aws/credentials"
                log_debug "Restored AWS credentials"
            fi
            
            log_success "DNS provider credentials restored"
        fi
    else
        log_debug "No DNS credentials found in backup"
    fi
    
    # Restore fail2ban configuration
    log_info "Restoring fail2ban configuration..."
    local fail2ban_file=$(ls "$temp_dir"/fail2ban_config_*.tar.gz 2>/dev/null | head -1)
    if [ -n "$fail2ban_file" ]; then
        log_debug "Found fail2ban config file: $(basename "$fail2ban_file")"
        cd "$temp_dir"
        tar -xzf "$(basename "$fail2ban_file")" 2>/dev/null
        
        if [ -d "fail2ban_config" ]; then
            # Restore fail2ban jail configuration
            if [ -f "fail2ban_config/n8n.conf" ]; then
                sudo cp "fail2ban_config/n8n.conf" "/etc/fail2ban/jail.d/n8n.conf" 2>/dev/null || log_warn "Could not restore n8n jail config"
                log_debug "Restored n8n jail configuration"
            fi
            
            # Restore fail2ban filter configuration
            if [ -f "fail2ban_config/n8n-auth.conf" ]; then
                sudo cp "fail2ban_config/n8n-auth.conf" "/etc/fail2ban/filter.d/n8n-auth.conf" 2>/dev/null || log_warn "Could not restore n8n filter config"
                log_debug "Restored n8n filter configuration"
            fi
            
            # Restore fail2ban IP whitelist
            if [ -f "fail2ban_config/jail.local" ]; then
                sudo cp "fail2ban_config/jail.local" "/etc/fail2ban/jail.local" 2>/dev/null || log_warn "Could not restore jail.local config"
                log_debug "Restored fail2ban IP whitelist"
            fi
            
            # Restart fail2ban if configurations were restored
            if command -v fail2ban-client &> /dev/null; then
                sudo systemctl restart fail2ban 2>/dev/null || log_warn "Could not restart fail2ban"
                log_success "fail2ban configuration restored and restarted"
            fi
        fi
    else
        log_debug "No fail2ban configuration found in backup"
    fi
    
    # Restore firewall configuration
    log_info "Restoring firewall configuration..."
    local firewall_file=$(ls "$temp_dir"/firewall_config_*.tar.gz 2>/dev/null | head -1)
    if [ -n "$firewall_file" ]; then
        log_debug "Found firewall config file: $(basename "$firewall_file")"
        cd "$temp_dir"
        tar -xzf "$(basename "$firewall_file")" 2>/dev/null
        
        if [ -d "firewall_config" ] && command -v ufw &> /dev/null; then
            # Restore UFW configuration files with enhanced error handling
            if [ -f "firewall_config/ufw_config.tar.gz" ]; then
                log_debug "Attempting to restore UFW configuration files..."
                if sudo tar -xzf "firewall_config/ufw_config.tar.gz" -C /etc 2>/dev/null; then
                    log_debug "UFW configuration files restored successfully"
                    
                    # Validate restored configuration
                    if [ -f "/etc/ufw/ufw.conf" ]; then
                        log_debug "UFW configuration validated"
                    else
                        log_warn "UFW configuration may be incomplete - /etc/ufw/ufw.conf not found"
                    fi
                else
                    log_warn "Could not restore UFW config files - may be incompatible with current system"
                fi
            fi
            
            # Re-enable UFW if it was active (with improved error handling)
            if [ -f "firewall_config/ufw_status.txt" ] && grep -q "Status: active" "firewall_config/ufw_status.txt"; then
                log_debug "UFW was active in backup, attempting to re-enable..."
                
                # Try to reload UFW rules first
                if sudo ufw --force reload 2>/dev/null; then
                    log_debug "UFW rules reloaded successfully"
                elif sudo ufw --force enable 2>/dev/null; then
                    log_debug "UFW enabled successfully"
                else
                    log_warn "Could not re-enable UFW - may need manual configuration"
                    log_info "To manually restore firewall:"
                    log_info "  1. Check UFW status: sudo ufw status"
                    log_info "  2. Enable UFW: sudo ufw --force enable"
                    log_info "  3. Review rules: sudo ufw status numbered"
                fi
                
                # Verify UFW status after restoration
                if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
                    log_success "Firewall configuration restored and enabled"
                else
                    log_warn "Firewall restoration completed but UFW is not active"
                fi
            else
                log_debug "UFW was not active in backup, leaving disabled"
            fi
        elif [ -d "firewall_config" ]; then
            log_warn "UFW not installed on this system - firewall rules from backup cannot be restored"
            log_info "To restore firewall protection, install UFW: sudo apt-get install ufw"
        fi
    else
        log_debug "No firewall configuration found in backup"
    fi
    
    # Restore Let's Encrypt configuration
    log_info "Restoring Let's Encrypt configuration..."
    local letsencrypt_file=$(ls "$temp_dir"/letsencrypt_config_*.tar.gz 2>/dev/null | head -1)
    if [ -n "$letsencrypt_file" ]; then
        log_debug "Found Let's Encrypt config file: $(basename "$letsencrypt_file")"
        cd "$temp_dir"
        tar -xzf "$(basename "$letsencrypt_file")" 2>/dev/null
        
        if [ -d "letsencrypt_config" ]; then
            # Restore Let's Encrypt directory
            if [ -f "letsencrypt_config/letsencrypt_etc.tar.gz" ]; then
                sudo tar -xzf "letsencrypt_config/letsencrypt_etc.tar.gz" -C /etc 2>/dev/null || log_warn "Could not restore Let's Encrypt directory"
                log_debug "Restored Let's Encrypt account data and certificates"
            fi
            
            # Restore manual DNS auth script
            if [ -f "letsencrypt_config/manual-dns-auth.sh" ]; then
                cp "letsencrypt_config/manual-dns-auth.sh" "$n8n_dir/manual-dns-auth.sh"
                chmod +x "$n8n_dir/manual-dns-auth.sh"
                log_debug "Restored manual DNS auth script"
            fi
            
            log_success "Let's Encrypt configuration restored"
        fi
    else
        log_debug "No Let's Encrypt configuration found in backup"
    fi
    
    log_function_end "restore_security_components"
    return 0
}


# Built-in management menu
show_management_menu() {
    while true; do
        clear
        printf "\n${BLUE}n8n Management Menu${NC}\n"
        printf "====================\n\n"
        printf "1) View Status\n"
        printf "2) View Logs\n"
        printf "3) Restart Services\n"
        printf "4) Recreate Services\n"
        printf "5) Create Backup\n"
        printf "6) Restore Backup\n"
        printf "7) Update n8n\n"
        printf "8) Health Check\n"
        printf "9) Show Version\n"
        printf "10) Manage Environment Variables\n"
        printf "11) Security & SSL Settings\n"
        printf "0) Back to Main Menu\n\n"
        printf "Select option: "
        
        read choice
        
        case $choice in
            1) view_status ;;
            2) view_logs ;;
            3) restart_services ;;
            4) recreate_services ;;
            5) create_backup ;;
            6) restore_backup ;;
            7) update_n8n ;;
            8) health_check ;;
            9) show_version ;;
            10) manage_env_vars ;;
            11) security_settings_menu ;;
            0) return ;;
            *) printf "${RED}Invalid option${NC}\n"; sleep 1 ;;
        esac
    done
}

# View status
view_status() {
    printf "\n${BLUE}Service Status:${NC}\n"
    cd "$N8N_DIR"
    docker compose ps 2>/dev/null || docker compose ps
    printf "\nPress Enter to continue..."
    read
}

# View logs
view_logs() {
    printf "\n${BLUE}Select service:${NC}\n"
    printf "1) n8n\n"
    printf "2) PostgreSQL\n"
    printf "3) Nginx\n"
    printf "4) All services\n"
    printf "Select: "
    read service_choice
    
    cd "$N8N_DIR"
    case $service_choice in
        1) docker compose logs -f n8n ;;
        2) docker compose logs -f postgres ;;
        3) docker compose logs -f nginx ;;
        4) docker compose logs -f ;;
    esac
}

# Restart services
restart_services() {
    printf "\n${YELLOW}Restarting services...${NC}\n"
    cd "$N8N_DIR"
    docker compose restart
    printf "\n${GREEN}Services restarted${NC}\n"
    sleep 2
}

# Recreate services
recreate_services() {
    printf "\n${YELLOW}Recreating services...${NC}\n"
    cd "$N8N_DIR"
    docker compose down
    docker compose up -d
    printf "\n${GREEN}Services recreated${NC}\n"
    sleep 2
}

# Update n8n
update_n8n() {
    printf "\n${YELLOW}Updating n8n...${NC}\n"
    
    # Create backup first
    create_backup
    
    # Ensure we're in the correct directory
    cd "$N8N_DIR"
    
    # Pull latest images
    docker compose pull
    
    # Restart services
    docker compose up -d
    
    printf "${GREEN}n8n updated!${NC}\n"
    show_version
    sleep 2
}

# Health check
health_check() {
    printf "\n${BLUE}Health Check:${NC}\n"
    printf "====================\n"
    
    cd "$N8N_DIR"
    
    # Check containers
    printf "\nContainer Status:\n"
    for container in $(docker compose ps --format '{{.Names}}'); do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            STATUS=$(docker inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "running")
            if [[ "$STATUS" == "healthy" ]] || [[ "$STATUS" == "running" ]]; then
                printf "  %s: ${GREEN}✓ %s${NC}\n" "${container##*-}" "$STATUS"
            else
                printf "  %s: ${RED}✗ %s${NC}\n" "${container##*-}" "$STATUS"
            fi
        else
            printf "  %s: ${RED}✗ not running${NC}\n" "${container##*-}"
        fi
    done
    
    # Check services
    printf "\nService Endpoints:\n"
    if curl -sk https://localhost/nginx-health >/dev/null 2>&1; then
        printf "  Nginx: ${GREEN}✓ responding${NC}\n"
    else
        printf "  Nginx: ${RED}✗ not responding${NC}\n"
    fi
    
    POSTGRES_CONTAINER=$(docker compose ps --format '{{.Names}}' | grep postgres)
    if [ -n "$POSTGRES_CONTAINER" ] && docker exec "$POSTGRES_CONTAINER" pg_isready -U n8n >/dev/null 2>&1; then
        printf "  PostgreSQL: ${GREEN}✓ ready${NC}\n"
    else
        printf "  PostgreSQL: ${RED}✗ not ready${NC}\n"
    fi
    
    if curl -k -s https://localhost/healthz > /dev/null 2>&1; then
        printf "  n8n API: ${GREEN}✓ accessible${NC}\n"
    else
        printf "  n8n API: ${RED}✗ not accessible${NC}\n"
    fi
    
    printf "\nPress Enter to continue..."
    read
}

# Show version
show_version() {
    cd "$N8N_DIR"
    N8N_CONTAINER=$(docker compose ps --format '{{.Names}}' | grep n8n | head -1)
    printf "\nn8n version: "
    if [ -n "$N8N_CONTAINER" ]; then
        docker exec "$N8N_CONTAINER" n8n --version 2>/dev/null || echo "not running"
    else
        echo "not running"
    fi
    printf "\nPress Enter to continue..."
    read
}

# Renew certificate
renew_certificate() {
    log_info "Renewing SSL certificate..."
    cd "$N8N_DIR"
    
    # Check certificate type from .env
    local cert_type=$(grep "^CERTIFICATE_TYPE=" .env 2>/dev/null | cut -d'=' -f2 || echo "self-signed")
    
    if [ "$cert_type" = "letsencrypt" ]; then
        renew_letsencrypt_certificate
    else
        # Generate new self-signed certificate with enhanced features (IP addresses + SAN)
        generate_ssl_certificate "$N8N_DIR/certs" certs/n8n.key.new certs/n8n.crt.new
        
        mv certs/n8n.key certs/n8n.key.old
        mv certs/n8n.crt certs/n8n.crt.old
        mv certs/n8n.key.new certs/n8n.key
        mv certs/n8n.crt.new certs/n8n.crt
        
        docker compose restart nginx
        printf "${GREEN}Self-signed certificate renewed for another 10 years${NC}\n"
    fi
    sleep 2
}

# Configure firewall rules
configure_firewall() {
    log_function_start "configure_firewall"
    log_info "Configuring firewall rules..."
    
    # Check if UFW is installed
    if ! command -v ufw &> /dev/null; then
        log_info "Installing UFW (Uncomplicated Firewall)..."
        sudo apt-get update && sudo apt-get install -y ufw
    fi
    
    # Configure UFW rules
    log_info "Setting up firewall rules..."
    
    # Default policies
    sudo ufw default deny incoming || log_warn "Could not set default deny incoming"
    sudo ufw default allow outgoing || log_warn "Could not set default allow outgoing"
    
    # Allow SSH (port 22)
    sudo ufw allow 22/tcp comment 'SSH' || log_warn "Could not add SSH rule"
    
    # Allow HTTPS (port 443) for n8n
    sudo ufw allow 443/tcp comment 'n8n HTTPS' || log_warn "Could not add HTTPS rule"
    
    # Note: UFW automatically handles established/related connections with stateful firewall
    # No need for explicit 'established' rule
    
    # Enable UFW if not already enabled
    if sudo ufw status | grep -q "Status: inactive"; then
        log_info "Enabling firewall..."
        sudo ufw --force enable
        log_success "Firewall enabled with secure rules"
    else
        log_info "Firewall already active, rules updated"
        sudo ufw reload
    fi
    
    log_function_end "configure_firewall"
}

# Firewall status
firewall_status() {
    printf "\n${BLUE}Firewall Status:${NC}\n"
    printf "==================\n"
    
    if command -v ufw &> /dev/null; then
        sudo ufw status verbose
    else
        printf "${YELLOW}UFW is not installed${NC}\n"
    fi
    
    printf "\nPress Enter to continue..."
    read
}

# Configure fail2ban
configure_fail2ban() {
    log_function_start "configure_fail2ban"
    log_info "Configuring fail2ban for intrusion prevention..."
    
    # Install fail2ban if not present
    if ! command -v fail2ban-client &> /dev/null; then
        log_info "Installing fail2ban..."
        sudo apt-get update && sudo apt-get install -y fail2ban
    fi
    
    # Create n8n jail configuration
    log_info "Creating fail2ban jail for n8n..."
    sudo tee /etc/fail2ban/jail.d/n8n.conf > /dev/null << 'EOF'
[n8n-auth]
enabled = true
port = 443
protocol = tcp
filter = n8n-auth
logpath = $N8N_DIR/logs/access.log
maxretry = 5
findtime = 600
bantime = 3600

[nginx-limit-req]
enabled = true
port = 443
protocol = tcp
filter = nginx-limit-req
logpath = $N8N_DIR/logs/error.log
maxretry = 10
findtime = 60
bantime = 600
EOF

    # Create n8n filter
    sudo tee /etc/fail2ban/filter.d/n8n-auth.conf > /dev/null << 'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST) .*/rest/login.*" 401 .*$
            ^<HOST> .* "(GET|POST) .*/api/.*" 401 .*$
ignoreregex =
EOF

    # Restart fail2ban
    sudo systemctl restart fail2ban
    sudo systemctl enable fail2ban
    
    log_success "fail2ban configured for n8n protection"
    log_function_end "configure_fail2ban"
}

# Validate IP address format
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# Unban IP address
unban_ip() {
    printf "\n${BLUE}Unban IP Address${NC}\n"
    printf "=================\n\n"
    
    # Show currently banned IPs first
    printf "Currently banned IPs:\n"
    printf "----------------------\n"
    local jails=($(sudo fail2ban-client status | grep "Jail list" | cut -d: -f2 | tr -d ' \t' | tr ',' ' '))
    local found_banned=false
    
    for jail in "${jails[@]}"; do
        local banned_ips=$(sudo fail2ban-client status "$jail" | grep "Banned IP list" | cut -d: -f2 | xargs)
        if [ -n "$banned_ips" ] && [ "$banned_ips" != "" ]; then
            printf "%s: %s\n" "$jail" "$banned_ips"
            found_banned=true
        fi
    done
    
    if [ "$found_banned" = false ]; then
        printf "No IPs currently banned\n"
        printf "\nPress Enter to continue..."
        read
        return 0
    fi
    
    printf "\nEnter IP address to unban: "
    read ip_to_unban
    
    # Validate IP format
    if ! validate_ip "$ip_to_unban"; then
        log_error "Invalid IP address format: $ip_to_unban"
        sleep 2
        return 1
    fi
    
    printf "\nUnban options:\n"
    printf "1) Unban from ALL jails\n"
    printf "2) Select specific jail\n"
    printf "0) Cancel\n\n"
    printf "Select option: "
    read unban_choice
    
    case $unban_choice in
        1)
            log_info "Unbanning $ip_to_unban from ALL jails..."
            sudo fail2ban-client unban "$ip_to_unban"
            if [ $? -eq 0 ]; then
                log_success "IP $ip_to_unban unbanned from all jails"
            else
                log_error "Failed to unban IP $ip_to_unban"
            fi
            ;;
        2)
            printf "\nSelect jail to unban from:\n"
            local jail_count=1
            for jail in "${jails[@]}"; do
                printf "%d) %s\n" "$jail_count" "$jail"
                ((jail_count++))
            done
            printf "0) Cancel\n\n"
            printf "Select jail: "
            read jail_choice
            
            if [[ "$jail_choice" =~ ^[0-9]+$ ]] && [ "$jail_choice" -gt 0 ] && [ "$jail_choice" -le ${#jails[@]} ]; then
                local selected_jail="${jails[$((jail_choice-1))]}"
                log_info "Unbanning $ip_to_unban from $selected_jail jail..."
                sudo fail2ban-client set "$selected_jail" unbanip "$ip_to_unban"
                if [ $? -eq 0 ]; then
                    log_success "IP $ip_to_unban unbanned from $selected_jail jail"
                else
                    log_error "Failed to unban IP $ip_to_unban from $selected_jail"
                fi
            else
                log_info "Operation cancelled"
            fi
            ;;
        0)
            log_info "Operation cancelled"
            ;;
        *)
            log_error "Invalid option"
            ;;
    esac
    
    printf "\nPress Enter to continue..."
    read
}

# Add IP to whitelist (ignore list)
add_to_whitelist() {
    printf "\n${BLUE}Add IP to Whitelist${NC}\n"
    printf "====================\n\n"
    
    printf "Enter IP address to whitelist: "
    read ip_to_whitelist
    
    # Validate IP format
    if ! validate_ip "$ip_to_whitelist"; then
        log_error "Invalid IP address format: $ip_to_whitelist"
        sleep 2
        return 1
    fi
    
    printf "Enter description (optional): "
    read description
    
    # Add to fail2ban default ignore list
    local ignore_file="/etc/fail2ban/jail.local"
    
    # Create jail.local if it doesn't exist
    if [ ! -f "$ignore_file" ]; then
        sudo tee "$ignore_file" > /dev/null << 'EOF'
[DEFAULT]
# Whitelisted IPs added by n8n-master script
ignoreip = 127.0.0.1/8 ::1
EOF
    fi
    
    # Check if IP is already whitelisted
    if sudo grep -q "$ip_to_whitelist" "$ignore_file"; then
        log_warn "IP $ip_to_whitelist is already whitelisted"
        sleep 2
        return 0
    fi
    
    # Add IP to ignore list
    log_info "Adding $ip_to_whitelist to whitelist..."
    
    # Create a backup
    sudo cp "$ignore_file" "$ignore_file.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Add the IP to the ignoreip line
    if [ -n "$description" ]; then
        sudo sed -i "/ignoreip = /s/$/ $ip_to_whitelist # $description/" "$ignore_file"
    else
        sudo sed -i "/ignoreip = /s/$/ $ip_to_whitelist/" "$ignore_file"
    fi
    
    # Restart fail2ban to apply changes
    sudo systemctl restart fail2ban
    if [ $? -eq 0 ]; then
        log_success "IP $ip_to_whitelist added to whitelist and fail2ban restarted"
    else
        log_error "Failed to restart fail2ban"
    fi
    
    printf "\nPress Enter to continue..."
    read
}

# View whitelist
view_whitelist() {
    printf "\n${BLUE}Whitelisted IPs${NC}\n"
    printf "===============\n\n"
    
    local ignore_file="/etc/fail2ban/jail.local"
    
    if [ -f "$ignore_file" ]; then
        local ignore_line=$(sudo grep "^ignoreip" "$ignore_file" 2>/dev/null)
        if [ -n "$ignore_line" ]; then
            printf "Current whitelist:\n"
            printf "%s\n" "$ignore_line"
        else
            printf "No custom whitelist found\n"
        fi
    else
        printf "No whitelist configuration found\n"
        printf "Default: 127.0.0.1/8 ::1 (localhost only)\n"
    fi
    
    printf "\nPress Enter to continue..."
    read
}

# fail2ban IP Management Menu
manage_fail2ban_ips() {
    while true; do
        clear
        printf "\n${BLUE}fail2ban IP Management${NC}\n"
        printf "======================\n\n"
        
        printf "1) View All Banned IPs\n"
        printf "2) Unban Specific IP\n"
        printf "3) Add IP to Whitelist\n"
        printf "4) View Whitelist\n"
        printf "5) Unban All IPs from All Jails\n"
        printf "0) Back to Security Menu\n\n"
        printf "Select option: "
        read ip_choice
        
        case $ip_choice in
            1)
                printf "\n${BLUE}Currently Banned IPs${NC}\n"
                printf "=====================\n\n"
                local jails=($(sudo fail2ban-client status | grep "Jail list" | cut -d: -f2 | tr -d ' \t' | tr ',' ' '))
                local found_any=false
                
                for jail in "${jails[@]}"; do
                    local banned_count=$(sudo fail2ban-client status "$jail" | grep "Currently banned" | awk '{print $4}')
                    local banned_ips=$(sudo fail2ban-client status "$jail" | grep "Banned IP list" | cut -d: -f2 | xargs)
                    
                    printf "%s jail:\n" "$jail"
                    printf "  Currently banned: %s\n" "$banned_count"
                    if [ -n "$banned_ips" ] && [ "$banned_ips" != "" ]; then
                        printf "  IPs: %s\n" "$banned_ips"
                        found_any=true
                    else
                        printf "  IPs: None\n"
                    fi
                    printf "\n"
                done
                
                if [ "$found_any" = false ]; then
                    printf "${GREEN}No IPs are currently banned${NC}\n"
                fi
                
                printf "\nPress Enter to continue..."
                read
                ;;
            2)
                unban_ip
                ;;
            3)
                add_to_whitelist
                ;;
            4)
                view_whitelist
                ;;
            5)
                printf "\n${YELLOW}Unban ALL IPs from ALL jails?${NC}\n"
                printf "This will remove all current bans.\n"
                printf "Continue? (yes/no): "
                read confirm_unban_all
                
                if [ "$confirm_unban_all" = "yes" ]; then
                    log_info "Unbanning all IPs from all jails..."
                    local jails=($(sudo fail2ban-client status | grep "Jail list" | cut -d: -f2 | tr -d ' \t' | tr ',' ' '))
                    
                    for jail in "${jails[@]}"; do
                        sudo fail2ban-client unban --all "$jail" 2>/dev/null || true
                    done
                    
                    log_success "All IPs unbanned from all jails"
                else
                    log_info "Operation cancelled"
                fi
                
                printf "\nPress Enter to continue..."
                read
                ;;
            0)
                return
                ;;
            *)
                log_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# fail2ban status
fail2ban_status() {
    printf "\n${BLUE}fail2ban Status:${NC}\n"
    printf "==================\n"
    
    if command -v fail2ban-client &> /dev/null; then
        printf "\nOverall Status:\n"
        sudo fail2ban-client status
        
        printf "\nn8n Jail Status:\n"
        sudo fail2ban-client status n8n-auth 2>/dev/null || printf "n8n jail not configured\n"
        
        printf "\nNginx Rate Limit Jail Status:\n"
        sudo fail2ban-client status nginx-limit-req 2>/dev/null || printf "Nginx jail not configured\n"
        
        printf "\nSSH Jail Status:\n"
        sudo fail2ban-client status sshd 2>/dev/null || printf "SSH jail not configured\n"
        
        printf "\n${CYAN}Options:${NC}\n"
        printf "1) Manage Banned IPs\n"
        printf "2) Back to Security Menu\n\n"
        printf "Select option: "
        read status_choice
        
        case $status_choice in
            1)
                manage_fail2ban_ips
                ;;
            2)
                return
                ;;
            *)
                printf "\nPress Enter to continue..."
                read
                ;;
        esac
    else
        printf "${YELLOW}fail2ban is not installed${NC}\n"
        printf "\nPress Enter to continue..."
        read
    fi
}

# Setup Let's Encrypt with DNS-01 challenge
setup_letsencrypt() {
    log_function_start "setup_letsencrypt"
    
    printf "\n${BLUE}Let's Encrypt Setup with DNS-01 Challenge${NC}\n"
    printf "==========================================\n\n"
    
    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        log_info "Installing certbot and DNS plugins..."
        sudo apt-get update
        sudo apt-get install -y certbot \
            python3-certbot-dns-cloudflare \
            python3-certbot-dns-route53 \
            python3-certbot-dns-digitalocean \
            python3-certbot-dns-google
    fi
    
    printf "Select your DNS provider:\n"
    printf "1) Cloudflare (API - Automated)\n"
    printf "2) AWS Route53 (API - Automated)\n"
    printf "3) DigitalOcean (API - Automated)\n"
    printf "4) Google Cloud DNS (API - Automated)\n"
    printf "5) Manual DNS (Any provider - GoDaddy, Namecheap, etc.)\n"
    printf "0) Cancel\n\n"
    printf "Select option: "
    read dns_provider
    
    case $dns_provider in
        1)
            setup_letsencrypt_cloudflare
            ;;
        2)
            setup_letsencrypt_route53
            ;;
        3)
            setup_letsencrypt_digitalocean
            ;;
        4)
            setup_letsencrypt_google
            ;;
        5)
            setup_letsencrypt_manual
            ;;
        0)
            return
            ;;
        *)
            log_error "Invalid option"
            sleep 1
            ;;
    esac
    
    log_function_end "setup_letsencrypt"
}

# Validate Cloudflare API token
validate_cloudflare_token() {
    local token="$1"
    local domain="$2"
    
    # Extract base domain (e.g., example.com from sub.example.com)
    local base_domain=$(echo "$domain" | awk -F'.' '{print $(NF-1)"."$NF}')
    
    log_info "Validating Cloudflare API token..."
    
    # Test token validity
    local response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    if echo "$response" | grep -q '"success":true'; then
        log_success "Token is valid"
        
        # Check if we can access the zone
        local zone_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$base_domain" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json")
        
        if echo "$zone_response" | grep -q '"success":true' && echo "$zone_response" | grep -q "$base_domain"; then
            log_success "Token has access to domain: $base_domain"
            return 0
        else
            log_error "Token does not have access to domain: $base_domain"
            log_info "Make sure the token has 'Zone:DNS:Edit' permission for this domain"
            return 1
        fi
    else
        log_error "Invalid Cloudflare API token"
        local error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$error_msg" ]; then
            log_error "Error: $error_msg"
        fi
        return 1
    fi
}

# Setup Let's Encrypt with Cloudflare
setup_letsencrypt_cloudflare() {
    printf "\n${BLUE}Cloudflare DNS Setup${NC}\n"
    printf "=====================\n\n"
    
    printf "${YELLOW}Creating a Cloudflare API Token:${NC}\n"
    printf "1. Go to: https://dash.cloudflare.com/profile/api-tokens\n"
    printf "2. Click 'Create Token'\n"
    printf "3. Use template: 'Edit zone DNS'\n"
    printf "4. Configure permissions:\n"
    printf "   - Zone Resources: Include → Specific zone → Your domain\n"
    printf "   - Zone:DNS:Edit permission\n"
    printf "5. Click 'Continue to summary' → 'Create Token'\n"
    printf "6. Copy the ENTIRE token (it's long!)\n\n"
    
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        printf "Enter your Cloudflare API token (attempt $attempt/$max_attempts): "
        read -s cf_token
        echo
        
        printf "Enter your domain name (e.g., n8n.example.com): "
        read domain_name
        
        # Validate token before proceeding
        if validate_cloudflare_token "$cf_token" "$domain_name"; then
            break
        else
            if [ $attempt -lt $max_attempts ]; then
                printf "\n${YELLOW}Token validation failed. Please check:${NC}\n"
                printf "- You copied the ENTIRE token\n"
                printf "- Token has 'Zone:DNS:Edit' permission\n"
                printf "- Token is for the correct domain\n\n"
                printf "Try again? (y/n): "
                read retry
                if [ "$retry" != "y" ]; then
                    return 1
                fi
            else
                log_error "Maximum attempts reached. Please verify your token and try again."
                return 1
            fi
        fi
        ((attempt++))
    done
    
    # Save credentials securely
    cat > "$N8N_DIR/.cloudflare.ini" << EOF
dns_cloudflare_api_token = $cf_token
EOF
    chmod 600 "$N8N_DIR/.cloudflare.ini"
    
    # Update .env with certificate settings
    update_letsencrypt_env "letsencrypt" "$domain_name" "cloudflare"
    
    # Request certificate
    log_info "Requesting Let's Encrypt certificate via Cloudflare..."
    sudo certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$N8N_DIR/.cloudflare.ini" \
        -d "$domain_name" \
        --non-interactive \
        --agree-tos \
        --email "admin@$domain_name" \
        --cert-path "$N8N_DIR/certs" \
        --key-path "$N8N_DIR/certs"
    
    if [ $? -eq 0 ]; then
        copy_letsencrypt_certificates "$domain_name"
        log_success "Let's Encrypt certificate obtained successfully!"
        
        # Restart nginx
        cd "$N8N_DIR"
        docker compose restart nginx
    else
        log_error "Failed to obtain Let's Encrypt certificate"
        printf "\n${YELLOW}Common issues:${NC}\n"
        printf "- DNS propagation may take a few minutes\n"
        printf "- Ensure the domain points to Cloudflare nameservers\n"
        printf "- Check /var/log/letsencrypt/letsencrypt.log for details\n\n"
        return 1
    fi
}

# Setup Let's Encrypt with AWS Route53
setup_letsencrypt_route53() {
    printf "\n${BLUE}AWS Route53 DNS Setup${NC}\n"
    printf "======================\n\n"
    
    printf "You'll need AWS credentials with Route53 permissions.\n"
    printf "The credentials can be obtained from AWS IAM console.\n\n"
    
    # Check for existing AWS credentials
    if [ -f "$HOME/.aws/credentials" ]; then
        printf "${YELLOW}Found existing AWS credentials.${NC}\n"
        printf "Use existing credentials? (y/n): "
        read use_existing
        if [ "$use_existing" != "y" ]; then
            printf "\nEnter AWS Access Key ID: "
            read aws_access_key
            printf "Enter AWS Secret Access Key: "
            read -s aws_secret_key
            echo
            
            # Create AWS credentials file
            mkdir -p "$HOME/.aws"
            cat > "$HOME/.aws/credentials" << EOF
[default]
aws_access_key_id = $aws_access_key
aws_secret_access_key = $aws_secret_key
EOF
            chmod 600 "$HOME/.aws/credentials"
        fi
    else
        printf "Enter AWS Access Key ID: "
        read aws_access_key
        printf "Enter AWS Secret Access Key: "
        read -s aws_secret_key
        echo
        
        # Optional: AWS Session Token for temporary credentials
        printf "Enter AWS Session Token (optional, press Enter to skip): "
        read -s aws_session_token
        echo
        
        # Create AWS credentials file
        mkdir -p "$HOME/.aws"
        cat > "$HOME/.aws/credentials" << EOF
[default]
aws_access_key_id = $aws_access_key
aws_secret_access_key = $aws_secret_key
EOF
        
        if [ -n "$aws_session_token" ]; then
            echo "aws_session_token = $aws_session_token" >> "$HOME/.aws/credentials"
        fi
        
        chmod 600 "$HOME/.aws/credentials"
    fi
    
    printf "\nEnter your domain name (e.g., n8n.example.com): "
    read domain_name
    
    # Update .env with certificate settings
    update_letsencrypt_env "letsencrypt" "$domain_name" "route53"
    
    # Request certificate
    log_info "Requesting Let's Encrypt certificate via Route53..."
    sudo certbot certonly \
        --dns-route53 \
        -d "$domain_name" \
        --non-interactive \
        --agree-tos \
        --email "admin@$domain_name"
    
    if [ $? -eq 0 ]; then
        copy_letsencrypt_certificates "$domain_name"
        log_success "Let's Encrypt certificate obtained successfully!"
        
        # Restart nginx
        cd "$N8N_DIR"
        docker compose restart nginx
    else
        log_error "Failed to obtain Let's Encrypt certificate"
        log_info "Please verify your AWS credentials and Route53 permissions"
        return 1
    fi
}

# Setup Let's Encrypt with DigitalOcean
setup_letsencrypt_digitalocean() {
    printf "\n${BLUE}DigitalOcean DNS Setup${NC}\n"
    printf "=======================\n\n"
    
    printf "You'll need a DigitalOcean API token with DNS write permissions.\n"
    printf "Get your token from: https://cloud.digitalocean.com/account/api/tokens\n\n"
    
    printf "Enter your DigitalOcean API token: "
    read -s do_token
    echo
    
    # Save credentials securely
    cat > "$N8N_DIR/.digitalocean.ini" << EOF
dns_digitalocean_token = $do_token
EOF
    chmod 600 "$N8N_DIR/.digitalocean.ini"
    
    printf "Enter your domain name (e.g., n8n.example.com): "
    read domain_name
    
    # Update .env with certificate settings
    update_letsencrypt_env "letsencrypt" "$domain_name" "digitalocean"
    
    # Request certificate
    log_info "Requesting Let's Encrypt certificate via DigitalOcean..."
    sudo certbot certonly \
        --dns-digitalocean \
        --dns-digitalocean-credentials "$N8N_DIR/.digitalocean.ini" \
        -d "$domain_name" \
        --non-interactive \
        --agree-tos \
        --email "admin@$domain_name"
    
    if [ $? -eq 0 ]; then
        copy_letsencrypt_certificates "$domain_name"
        log_success "Let's Encrypt certificate obtained successfully!"
        
        # Restart nginx
        cd "$N8N_DIR"
        docker compose restart nginx
    else
        log_error "Failed to obtain Let's Encrypt certificate"
        log_info "Please verify your DigitalOcean API token and DNS settings"
        return 1
    fi
}

# Setup Let's Encrypt with Google Cloud DNS
setup_letsencrypt_google() {
    printf "\n${BLUE}Google Cloud DNS Setup${NC}\n"
    printf "=======================\n\n"
    
    printf "You'll need a Google Cloud service account with DNS Admin permissions.\n"
    printf "Download the JSON key file from Google Cloud Console.\n\n"
    
    printf "Enter the path to your Google Cloud service account JSON file: "
    read json_path
    
    # Validate JSON file exists
    if [ ! -f "$json_path" ]; then
        log_error "JSON file not found: $json_path"
        return 1
    fi
    
    # Copy JSON to n8n directory for consistency
    cp "$json_path" "$N8N_DIR/.google-cloud.json"
    chmod 600 "$N8N_DIR/.google-cloud.json"
    
    printf "Enter your Google Cloud Project ID: "
    read project_id
    
    # Create credentials file for certbot
    cat > "$N8N_DIR/.google.ini" << EOF
dns_google_credentials = $N8N_DIR/.google-cloud.json
dns_google_project = $project_id
EOF
    chmod 600 "$N8N_DIR/.google.ini"
    
    printf "Enter your domain name (e.g., n8n.example.com): "
    read domain_name
    
    # Update .env with certificate settings
    update_letsencrypt_env "letsencrypt" "$domain_name" "google"
    echo "GOOGLE_CLOUD_PROJECT=$project_id" >> "$N8N_DIR/.env"
    
    # Request certificate
    log_info "Requesting Let's Encrypt certificate via Google Cloud DNS..."
    sudo certbot certonly \
        --dns-google \
        --dns-google-credentials "$N8N_DIR/.google.ini" \
        -d "$domain_name" \
        --non-interactive \
        --agree-tos \
        --email "admin@$domain_name"
    
    if [ $? -eq 0 ]; then
        copy_letsencrypt_certificates "$domain_name"
        log_success "Let's Encrypt certificate obtained successfully!"
        
        # Restart nginx
        cd "$N8N_DIR"
        docker compose restart nginx
    else
        log_error "Failed to obtain Let's Encrypt certificate"
        log_info "Please verify your Google Cloud credentials and DNS permissions"
        return 1
    fi
}

# Setup Let's Encrypt with Manual DNS
setup_letsencrypt_manual() {
    printf "\n${YELLOW}Manual DNS Challenge Setup${NC}\n"
    printf "============================\n\n"
    
    printf "This option allows you to use Let's Encrypt with any DNS provider.\n"
    printf "You will need to manually add a TXT record to your DNS.\n\n"
    
    printf "Enter your domain name (e.g., n8n.example.com): "
    read domain_name
    
    printf "Enter your email address for Let's Encrypt notifications: "
    read email_address
    
    # Update .env with certificate settings
    update_letsencrypt_env "letsencrypt" "$domain_name" "manual"
    
    # Start manual challenge
    log_info "Starting manual DNS challenge...\n"
    
    # Create a temporary script to handle the manual challenge
    cat > "$N8N_DIR/manual-dns-auth.sh" << 'EOF'
#!/bin/bash
echo ""
echo "==============================================="
echo "Please add the following TXT record to your DNS:"
echo "==============================================="
echo ""
echo "Record Type: TXT"
echo "Name: _acme-challenge.$CERTBOT_DOMAIN"
echo "Value: $CERTBOT_VALIDATION"
echo "TTL: 60 (or lowest available)"
echo ""
echo "Instructions for common providers:"
echo "  GoDaddy: DNS > Manage Zones > Add > TXT"
echo "  Namecheap: Advanced DNS > Add New Record > TXT"
echo "  Cloudflare: DNS > Add Record > TXT"
echo "  Route53: Create Record > TXT"
echo ""
echo "==============================================="
echo ""
read -p "Press Enter once you've added the DNS record..."

# Optional: Check DNS propagation
echo "Checking DNS propagation (this may take a moment)..."
for i in {1..30}; do
    if host -t TXT _acme-challenge.$CERTBOT_DOMAIN | grep -q "$CERTBOT_VALIDATION"; then
        echo "DNS record found! Proceeding..."
        break
    fi
    echo -n "."
    sleep 2
done
echo ""
EOF
    
    chmod +x "$N8N_DIR/manual-dns-auth.sh"
    
    # Request certificate with manual DNS challenge
    sudo certbot certonly \
        --manual \
        --preferred-challenges dns \
        --manual-auth-hook "$N8N_DIR/manual-dns-auth.sh" \
        -d "$domain_name" \
        --non-interactive \
        --agree-tos \
        --email "$email_address"
    
    if [ $? -eq 0 ]; then
        copy_letsencrypt_certificates "$domain_name"
        log_success "Let's Encrypt certificate obtained successfully!"
        
        printf "\n${YELLOW}Important: For renewals, you'll need to update the TXT record.${NC}\n"
        printf "The system will notify you 7 days before expiry.\n\n"
        
        # Restart nginx
        cd "$N8N_DIR"
        docker compose restart nginx
        
        sleep 3
    else
        log_error "Failed to obtain Let's Encrypt certificate"
        return 1
    fi
}

# Helper function to update Let's Encrypt environment variables
update_letsencrypt_env() {
    local cert_type="$1"
    local domain="$2"
    local provider="$3"
    
    if ! grep -q "^CERTIFICATE_TYPE=" "$N8N_DIR/.env"; then
        echo "CERTIFICATE_TYPE=$cert_type" >> "$N8N_DIR/.env"
        echo "LETSENCRYPT_DOMAIN=$domain" >> "$N8N_DIR/.env"
        echo "LETSENCRYPT_DNS_PROVIDER=$provider" >> "$N8N_DIR/.env"
    else
        sed -i "s/^CERTIFICATE_TYPE=.*/CERTIFICATE_TYPE=$cert_type/" "$N8N_DIR/.env"
        if grep -q "^LETSENCRYPT_DOMAIN=" "$N8N_DIR/.env"; then
            sed -i "s/^LETSENCRYPT_DOMAIN=.*/LETSENCRYPT_DOMAIN=$domain/" "$N8N_DIR/.env"
        else
            echo "LETSENCRYPT_DOMAIN=$domain" >> "$N8N_DIR/.env"
        fi
        if grep -q "^LETSENCRYPT_DNS_PROVIDER=" "$N8N_DIR/.env"; then
            sed -i "s/^LETSENCRYPT_DNS_PROVIDER=.*/LETSENCRYPT_DNS_PROVIDER=$provider/" "$N8N_DIR/.env"
        else
            echo "LETSENCRYPT_DNS_PROVIDER=$provider" >> "$N8N_DIR/.env"
        fi
    fi
}

# Helper function to copy Let's Encrypt certificates
copy_letsencrypt_certificates() {
    local domain="$1"
    
    sudo cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$N8N_DIR/certs/n8n.crt"
    sudo cp "/etc/letsencrypt/live/$domain/privkey.pem" "$N8N_DIR/certs/n8n.key"
    sudo chown $USER:$USER "$N8N_DIR/certs/"*
    chmod 644 "$N8N_DIR/certs/n8n.crt"
    chmod 600 "$N8N_DIR/certs/n8n.key"
}

# Update Let's Encrypt domain
update_letsencrypt_domain() {
    printf "\n${BLUE}Update Let's Encrypt Domain${NC}\n"
    printf "============================\n\n"
    
    local current_domain=$(grep "^LETSENCRYPT_DOMAIN=" "$N8N_DIR/.env" | cut -d'=' -f2)
    local current_provider=$(grep "^LETSENCRYPT_DNS_PROVIDER=" "$N8N_DIR/.env" | cut -d'=' -f2)
    
    printf "Current domain: ${YELLOW}%s${NC}\n" "$current_domain"
    printf "Current provider: ${YELLOW}%s${NC}\n\n" "$current_provider"
    
    printf "What would you like to update?\n"
    printf "1) Change domain name only\n"
    printf "2) Change DNS provider only\n"
    printf "3) Change both domain and provider\n"
    printf "0) Cancel\n\n"
    printf "Select option: "
    read update_choice
    
    case $update_choice in
        1)
            printf "\nEnter new domain name (e.g., n8n.newdomain.com): "
            read new_domain
            
            # Update domain and re-request certificate
            sed -i "s/^LETSENCRYPT_DOMAIN=.*/LETSENCRYPT_DOMAIN=$new_domain/" "$N8N_DIR/.env"
            
            log_info "Requesting certificate for new domain..."
            case "$current_provider" in
                "cloudflare")
                    setup_letsencrypt_cloudflare
                    ;;
                "route53")
                    setup_letsencrypt_route53
                    ;;
                "digitalocean")
                    setup_letsencrypt_digitalocean
                    ;;
                "google")
                    setup_letsencrypt_google
                    ;;
                "manual")
                    setup_letsencrypt_manual
                    ;;
                *)
                    log_error "Unknown provider: $current_provider"
                    ;;
            esac
            ;;
        2)
            printf "\nChanging DNS provider. Please select new provider:\n"
            setup_letsencrypt
            ;;
        3)
            printf "\nChanging both domain and provider.\n"
            setup_letsencrypt
            ;;
        0)
            return
            ;;
        *)
            log_error "Invalid option"
            sleep 1
            ;;
    esac
}

# Renew Let's Encrypt certificate
renew_letsencrypt_certificate() {
    log_info "Renewing Let's Encrypt certificate..."
    
    local domain=$(grep "^LETSENCRYPT_DOMAIN=" "$N8N_DIR/.env" | cut -d'=' -f2)
    local provider=$(grep "^LETSENCRYPT_DNS_PROVIDER=" "$N8N_DIR/.env" | cut -d'=' -f2)
    
    if [ -z "$domain" ]; then
        log_error "No Let's Encrypt domain configured"
        return 1
    fi
    
    log_info "Renewing certificate for $domain using $provider provider..."
    
    case "$provider" in
        "cloudflare")
            # Cloudflare automated renewal
            if [ ! -f "$N8N_DIR/.cloudflare.ini" ]; then
                log_error "Cloudflare credentials not found. Please reconfigure."
                return 1
            fi
            sudo certbot renew --cert-name "$domain" --quiet
            ;;
        "route53")
            # AWS Route53 automated renewal
            if [ ! -f "$HOME/.aws/credentials" ]; then
                log_error "AWS credentials not found. Please reconfigure."
                return 1
            fi
            sudo certbot renew --cert-name "$domain" --quiet
            ;;
        "digitalocean")
            # DigitalOcean automated renewal
            if [ ! -f "$N8N_DIR/.digitalocean.ini" ]; then
                log_error "DigitalOcean credentials not found. Please reconfigure."
                return 1
            fi
            sudo certbot renew --cert-name "$domain" --quiet
            ;;
        "google")
            # Google Cloud DNS automated renewal
            if [ ! -f "$N8N_DIR/.google.ini" ]; then
                log_error "Google Cloud credentials not found. Please reconfigure."
                return 1
            fi
            sudo certbot renew --cert-name "$domain" --quiet
            ;;
        "manual")
            printf "\n${YELLOW}Manual DNS renewal required!${NC}\n"
            printf "You need to update the DNS TXT record for renewal.\n\n"
            
            # Run manual renewal
            sudo certbot certonly \
                --manual \
                --preferred-challenges dns \
                --manual-auth-hook "$N8N_DIR/manual-dns-auth.sh" \
                -d "$domain" \
                --force-renewal \
                --non-interactive \
                --agree-tos
            ;;
        *)
            log_error "Unknown DNS provider: $provider"
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        copy_letsencrypt_certificates "$domain"
        
        cd "$N8N_DIR"
        docker compose restart nginx
        
        log_success "Let's Encrypt certificate renewed successfully"
    else
        log_error "Failed to renew Let's Encrypt certificate"
        return 1
    fi
}

# Configure automated security updates
configure_auto_updates() {
    log_function_start "configure_auto_updates"
    
    printf "\n${BLUE}Automated Security Updates Configuration${NC}\n"
    printf "=========================================\n\n"
    
    # Install unattended-upgrades if not present
    if ! dpkg -l | grep -q unattended-upgrades; then
        log_info "Installing unattended-upgrades..."
        sudo apt-get update
        sudo apt-get install -y unattended-upgrades apt-listchanges
    fi
    
    printf "Configure automatic updates for:\n"
    printf "1) Security updates only (recommended)\n"
    printf "2) All updates\n"
    printf "3) Security updates + n8n auto-update\n"
    printf "4) Disable automatic updates\n"
    printf "0) Cancel\n\n"
    printf "Select option: "
    read update_choice
    
    case $update_choice in
        1)
            # Configure for security updates only
            sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null << 'EOF'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
            
            # Enable automatic updates
            sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
            
            log_success "Configured for automatic security updates only"
            
            # Update .env
            if ! grep -q "^AUTO_UPDATES_ENABLED=" "$N8N_DIR/.env"; then
                echo "AUTO_UPDATES_ENABLED=security" >> "$N8N_DIR/.env"
            else
                sed -i "s/^AUTO_UPDATES_ENABLED=.*/AUTO_UPDATES_ENABLED=security/" "$N8N_DIR/.env"
            fi
            ;;
        2)
            # Configure for all updates
            sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null << 'EOF'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}:${distro_codename}-updates";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
            
            sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
            
            log_success "Configured for all automatic updates"
            
            # Update .env
            if ! grep -q "^AUTO_UPDATES_ENABLED=" "$N8N_DIR/.env"; then
                echo "AUTO_UPDATES_ENABLED=all" >> "$N8N_DIR/.env"
            else
                sed -i "s/^AUTO_UPDATES_ENABLED=.*/AUTO_UPDATES_ENABLED=all/" "$N8N_DIR/.env"
            fi
            ;;
        3)
            # Configure security updates + n8n auto-update
            # First configure security updates
            sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null << 'EOF'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
            
            sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
            
            # Enable n8n auto-update in .env
            if ! grep -q "^AUTO_UPDATE_N8N=" "$N8N_DIR/.env"; then
                echo "AUTO_UPDATE_N8N=true" >> "$N8N_DIR/.env"
                echo "AUTO_UPDATES_ENABLED=security+n8n" >> "$N8N_DIR/.env"
            else
                sed -i "s/^AUTO_UPDATE_N8N=.*/AUTO_UPDATE_N8N=true/" "$N8N_DIR/.env"
                sed -i "s/^AUTO_UPDATES_ENABLED=.*/AUTO_UPDATES_ENABLED=security+n8n/" "$N8N_DIR/.env"
            fi
            
            log_success "Configured for security updates + n8n auto-updates"
            log_info "n8n will be automatically updated weekly with backup"
            ;;
        4)
            # Disable automatic updates
            sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
            
            log_warn "Automatic updates disabled"
            
            # Update .env
            if ! grep -q "^AUTO_UPDATES_ENABLED=" "$N8N_DIR/.env"; then
                echo "AUTO_UPDATES_ENABLED=disabled" >> "$N8N_DIR/.env"
                echo "AUTO_UPDATE_N8N=false" >> "$N8N_DIR/.env"
            else
                sed -i "s/^AUTO_UPDATES_ENABLED=.*/AUTO_UPDATES_ENABLED=disabled/" "$N8N_DIR/.env"
                sed -i "s/^AUTO_UPDATE_N8N=.*/AUTO_UPDATE_N8N=false/" "$N8N_DIR/.env"
            fi
            ;;
        0)
            return
            ;;
        *)
            log_error "Invalid option"
            sleep 1
            ;;
    esac
    
    printf "\nPress Enter to continue..."
    read
    
    log_function_end "configure_auto_updates"
}


# Security Settings Menu (Combined with SSL)
security_settings_menu() {
    while true; do
        clear
        printf "\n${BLUE}Security & SSL Settings${NC}\n"
        printf "========================\n\n"
        
        # Check certificate type
        local cert_type=$(grep "^CERTIFICATE_TYPE=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "self-signed")
        printf "Certificate: ${YELLOW}%s${NC}" "$cert_type"
        if [ "$cert_type" = "letsencrypt" ]; then
            local domain=$(grep "^LETSENCRYPT_DOMAIN=" "$N8N_DIR/.env" | cut -d'=' -f2)
            printf " (%s)" "$domain"
        fi
        printf "\n"
        
        # Check status of security features
        printf "Firewall: "
        if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
            printf "${GREEN}Enabled${NC}"
        else
            printf "${RED}Disabled${NC}"
        fi
        
        printf " | fail2ban: "
        if systemctl is-active --quiet fail2ban; then
            printf "${GREEN}Enabled${NC}"
        else
            printf "${RED}Disabled${NC}"
        fi
        
        printf " | Updates: "
        local auto_updates=$(grep "^AUTO_UPDATES_ENABLED=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "disabled")
        if [ "$auto_updates" != "disabled" ]; then
            printf "${GREEN}%s${NC}" "$auto_updates"
        else
            printf "${RED}Disabled${NC}"
        fi
        printf "\n\n"
        
        printf "${BOLD}SSL Certificate Management:${NC}\n"
        printf "1) View Certificate Details\n"
        printf "2) Renew Current Certificate\n"
        printf "3) Switch to Let's Encrypt (DNS-01)\n"
        printf "4) Switch to Self-Signed\n"
        if [ "$cert_type" = "letsencrypt" ]; then
            printf "5) Update Let's Encrypt Domain\n"
        fi
        printf "\n${BOLD}Security Configuration:${NC}\n"
        printf "6) Configure Firewall\n"
        printf "7) View Firewall Status\n"
        printf "8) Configure fail2ban\n"
        printf "9) View fail2ban Status\n"
        printf "10) Configure Automated Updates\n"
        printf "\n${BOLD}Production Security:${NC}\n"
        printf "11) Configure Cloudflare Protection\n"
        printf "12) Cloudflare IP Whitelist Management\n"
        printf "13) Run Security Audit\n"
        printf "14) Configure Security Monitoring\n"
        printf "\n${BOLD}Quick Actions:${NC}\n"
        printf "15) Apply All Security Hardening\n"
        printf "\n0) Back to Management Menu\n\n"
        printf "Select option: "
        read sec_choice
        
        case $sec_choice in
            1)
                printf "\n${BLUE}Certificate Details:${NC}\n"
                printf "====================\n"
                openssl x509 -in "$N8N_DIR/certs/n8n.crt" -noout -text | head -20
                printf "\nPress Enter to continue..."
                read
                ;;
            2)
                renew_certificate
                ;;
            3)
                setup_letsencrypt
                ;;
            4)
                printf "\nSwitching to self-signed certificate...\n"
                sed -i "s/^CERTIFICATE_TYPE=.*/CERTIFICATE_TYPE=self-signed/" "$N8N_DIR/.env"
                cd "$N8N_DIR"
                generate_ssl_certificate "$N8N_DIR/certs" "$N8N_DIR/certs/n8n.key" "$N8N_DIR/certs/n8n.crt"
                docker compose restart nginx
                log_success "Switched to self-signed certificate"
                sleep 2
                ;;
            5)
                if [ "$cert_type" = "letsencrypt" ]; then
                    update_letsencrypt_domain
                else
                    log_error "Invalid option"
                    sleep 1
                fi
                ;;
            6)
                configure_firewall
                printf "\nPress Enter to continue..."
                read
                ;;
            7)
                firewall_status
                ;;
            8)
                configure_fail2ban
                printf "\nPress Enter to continue..."
                read
                ;;
            9)
                fail2ban_status
                ;;
            10)
                configure_auto_updates
                ;;
            11)
                configure_cloudflare_protection
                ;;
            12)
                cloudflare_ip_whitelist_menu
                ;;
            13)
                run_security_audit
                ;;
            14)
                configure_security_monitoring
                ;;
            15)
                printf "\n${YELLOW}Applying all security hardening measures...${NC}\n"
                configure_firewall
                configure_fail2ban
                configure_auto_updates
                log_success "All security measures applied"
                printf "\nPress Enter to continue..."
                read
                ;;
            0)
                return
                ;;
            *)
                log_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# Extract root domain from subdomain
extract_root_domain() {
    local domain="$1"
    
    # Handle common cases
    case "$domain" in
        # Two-part TLDs (co.uk, com.au, etc.)
        *.co.uk|*.com.au|*.co.nz|*.co.za|*.com.br)
            echo "$domain" | awk -F. '{print $(NF-2)"."$(NF-1)"."$NF}'
            ;;
        # Three-part domains (regular .com, .net, .org, etc.)
        *.*)
            echo "$domain" | awk -F. '{print $(NF-1)"."$NF}'
            ;;
        # Already a root domain
        *)
            echo "$domain"
            ;;
    esac
}

# Validate Cloudflare API token
validate_cloudflare_token() {
    local token="$1"
    
    printf "Testing API connectivity..."
    
    # Test basic API connectivity first
    printf " connectivity"
    local connectivity_test=$(curl -s --max-time 10 --connect-timeout 5 \
        -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Accept: application/json" 2>&1)
    
    local curl_exit_code=$?
    if [ $curl_exit_code -ne 0 ]; then
        printf " ${RED}FAILED${NC}\n"
        case $curl_exit_code in
            28) log_error "Connection timeout - check your internet connection" ;;
            6) log_error "Could not resolve api.cloudflare.com - check DNS settings" ;;
            7) log_error "Failed to connect to api.cloudflare.com - check firewall/proxy" ;;
            35) log_error "SSL/TLS certificate error - check system time and certificates" ;;
            *) log_error "Network error (exit code: $curl_exit_code)" ;;
        esac
        printf "\n${YELLOW}Troubleshooting steps:${NC}\n"
        printf "1. Check internet connectivity: ping -c 3 8.8.8.8\n"
        printf "2. Test DNS resolution: nslookup api.cloudflare.com\n"
        printf "3. Check system time: date\n"
        printf "4. Test HTTPS access: curl -I https://www.cloudflare.com\n"
        printf "\nSkip validation and continue anyway? (y/n): "
        read skip_validation
        if [ "$skip_validation" = "y" ] || [ "$skip_validation" = "Y" ]; then
            printf "${YELLOW}Skipping validation - some features may not work correctly${NC}\n"
            return 0
        else
            return 1
        fi
    fi
    printf " ${GREEN}OK${NC}"
    
    # Test token validity
    printf " • token"
    local test_response=$(curl -s --max-time 15 --connect-timeout 5 \
        -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    curl_exit_code=$?
    if [ $curl_exit_code -ne 0 ]; then
        printf " ${RED}TIMEOUT${NC}\n"
        log_error "API request timed out - network or server issues"
        printf "\nSkip validation and continue anyway? (y/n): "
        read skip_validation
        if [ "$skip_validation" = "y" ] || [ "$skip_validation" = "Y" ]; then
            printf "${YELLOW}Skipping validation - some features may not work correctly${NC}\n"
            return 0
        else
            return 1
        fi
    fi
    
    if echo "$test_response" | grep -q '"success":true'; then
        printf " ${GREEN}VALID${NC}"
    else
        printf " ${RED}INVALID${NC}\n"
        log_error "API token validation failed"
        printf "${RED}Error details:${NC} %s\n" "$test_response"
        printf "\n${YELLOW}Common issues:${NC}\n"
        printf "• Token has expired\n"
        printf "• Token was revoked or deleted\n" 
        printf "• Token format is incorrect\n"
        return 1
    fi
    
    # Test zone read permissions
    printf " • permissions"
    local zones_response=$(curl -s --max-time 15 --connect-timeout 5 \
        -X GET "https://api.cloudflare.com/client/v4/zones?per_page=1" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    curl_exit_code=$?
    if [ $curl_exit_code -ne 0 ]; then
        printf " ${RED}TIMEOUT${NC}\n"
        log_error "Zone permissions test timed out"
        printf "\nContinue without full permission verification? (y/n): "
        read skip_perms
        if [ "$skip_perms" = "y" ] || [ "$skip_perms" = "Y" ]; then
            printf "${YELLOW}Continuing with limited validation${NC}\n"
            return 0
        else
            return 1
        fi
    fi
    
    if echo "$zones_response" | grep -q '"success":true'; then
        printf " ${GREEN}OK${NC}\n"
        log_debug "Zone read permission confirmed"
        return 0
    else
        printf " ${RED}INSUFFICIENT${NC}\n"
        log_error "Token lacks Zone:Zone:Read permission"
        printf "${RED}API Response:${NC} %s\n" "$zones_response"
        printf "\n${YELLOW}Required token permissions:${NC}\n"
        printf "• Zone:Zone:Read\n"
        printf "• Zone:Zone Settings:Edit\n"
        printf "• Zone:DNS:Edit\n"
        printf "\n${BLUE}Create a new token at:${NC} https://dash.cloudflare.com/profile/api-tokens\n"
        return 1
    fi
}

# Configure DNS proxy on existing record
configure_dns_proxy() {
    local zone_id="$1"
    local cf_token="$2"
    local record_id="$3"
    local record_type="$4"
    local record_content="$5"
    local domain="$6"
    
    printf "Enabling Cloudflare proxy on existing %s record...\n" "$record_type"
    
    local update_response=$(curl -s --max-time 15 \
        -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json" \
        --data '{
            "proxied": true
        }')
    
    if echo "$update_response" | grep -q '"success":true'; then
        log_success "Cloudflare proxy enabled on %s record" "$record_type"
        printf "✓ %s → %s (proxied)\n" "$domain" "$record_content"
    else
        log_error "Failed to enable proxy"
        printf "${RED}Error:${NC} %s\n" "$update_response"
        return 1
    fi
}

# Configure A record
configure_dns_a_record() {
    local zone_id="$1"
    local cf_token="$2"
    local record_id="$3"
    local domain="$4"
    
    # Get current server IP
    printf "Getting current server IP...\n"
    local server_ip=$(curl -s --max-time 10 ipv4.icanhazip.com || curl -s --max-time 10 ipinfo.io/ip)
    if [ -z "$server_ip" ]; then
        log_error "Could not determine server IP address"
        printf "Enter server IP manually: "
        read server_ip
        if [ -z "$server_ip" ]; then
            return 1
        fi
    fi
    printf "Server IP: ${GREEN}%s${NC}\n" "$server_ip"
    
    local method="POST"
    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records"
    
    if [ -n "$record_id" ]; then
        method="PATCH"
        url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id"
        printf "Updating existing record to A record...\n"
    else
        printf "Creating new A record...\n"
    fi
    
    local dns_response=$(curl -s --max-time 15 \
        -X "$method" "$url" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json" \
        --data '{
            "type": "A",
            "name": "'$domain'",
            "content": "'$server_ip'",
            "ttl": 1,
            "proxied": true,
            "comment": "n8n server with Cloudflare protection"
        }')
    
    if echo "$dns_response" | grep -q '"success":true'; then
        log_success "A record configured with Cloudflare proxy"
        printf "✓ %s → %s (proxied)\n" "$domain" "$server_ip"
    else
        log_error "Failed to configure A record"
        printf "${RED}Error:${NC} %s\n" "$dns_response"
        return 1
    fi
}

# Configure CNAME record
configure_dns_cname_record() {
    local zone_id="$1"
    local cf_token="$2"
    local record_id="$3"
    local domain="$4"
    
    printf "Enter the target hostname for CNAME (e.g., whycanti.synology.me): "
    read cname_target
    
    if [ -z "$cname_target" ]; then
        log_error "CNAME target cannot be empty"
        return 1
    fi
    
    # Validate CNAME target
    printf "Validating CNAME target %s...\n" "$cname_target"
    if ! nslookup "$cname_target" >/dev/null 2>&1; then
        printf "${YELLOW}Warning:${NC} Could not resolve %s\n" "$cname_target"
        printf "Continue anyway? (y/n): "
        read continue_anyway
        if [ "$continue_anyway" != "y" ] && [ "$continue_anyway" != "Y" ]; then
            return 1
        fi
    else
        printf "✓ Target resolves correctly\n"
    fi
    
    local method="POST"
    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records"
    
    if [ -n "$record_id" ]; then
        method="PATCH"
        url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id"
        printf "Updating existing record to CNAME...\n"
    else
        printf "Creating new CNAME record...\n"
    fi
    
    local dns_response=$(curl -s --max-time 15 \
        -X "$method" "$url" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json" \
        --data '{
            "type": "CNAME",
            "name": "'$domain'",
            "content": "'$cname_target'",
            "ttl": 1,
            "proxied": true,
            "comment": "n8n CNAME with Cloudflare protection"
        }')
    
    if echo "$dns_response" | grep -q '"success":true'; then
        log_success "CNAME record configured with Cloudflare proxy"
        printf "✓ %s → %s (proxied)\n" "$domain" "$cname_target"
        printf "\n${GREEN}Benefits of your CNAME setup:${NC}\n"
        printf "• Automatic IP updates when %s changes\n" "$cname_target"
        printf "• No manual DNS management required\n"
        printf "• Perfect for dynamic IP addresses\n"
    else
        log_error "Failed to configure CNAME record"
        printf "${RED}Error:${NC} %s\n" "$dns_response"
        return 1
    fi
}

# Configure Cloudflare Protection
configure_cloudflare_protection() {
    log_function_start "configure_cloudflare_protection"
    
    printf "\n${BLUE}Cloudflare Protection Setup${NC}\n"
    printf "==========================\n\n"
    
    # Check if domain is configured
    local domain=$(grep "^LETSENCRYPT_DOMAIN=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2)
    if [ -z "$domain" ]; then
        printf "${YELLOW}Cloudflare protection requires a domain name.${NC}\n"
        printf "Please configure Let's Encrypt first to set up your domain.\n\n"
        printf "Would you like to configure Let's Encrypt now? (y/n): "
        read setup_le
        if [ "$setup_le" = "y" ] || [ "$setup_le" = "Y" ]; then
            setup_letsencrypt
            domain=$(grep "^LETSENCRYPT_DOMAIN=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2)
            [ -z "$domain" ] && return 1
        else
            return 1
        fi
    fi
    
    printf "Domain: ${GREEN}%s${NC}\n\n" "$domain"
    
    # Check for existing Cloudflare credentials
    local cf_token
    if [ -f "$N8N_DIR/.cloudflare.ini" ]; then
        cf_token=$(grep "dns_cloudflare_api_token" "$N8N_DIR/.cloudflare.ini" | cut -d'=' -f2 | xargs)
        printf "${GREEN}Found existing Cloudflare credentials.${NC}\n"
    else
        printf "Cloudflare API token required for protection setup.\n\n"
        printf "${YELLOW}Creating a Cloudflare API Token:${NC}\n"
        printf "1. Go to: https://dash.cloudflare.com/profile/api-tokens\n"
        printf "2. Click 'Create Token'\n"
        printf "3. Use 'Custom token' template\n"
        printf "4. Set permissions:\n"
        printf "   - Zone:Zone Settings:Edit\n"
        printf "   - Zone:Zone:Read\n"
        printf "   - Zone:DNS:Edit\n"
        printf "5. Set zone resources to include your domain\n"
        printf "6. Create and copy the token\n\n"
        
        printf "Enter your Cloudflare API token: "
        read -s cf_token
        printf "\n"
        
        # Save token
        cat > "$N8N_DIR/.cloudflare.ini" << EOF
dns_cloudflare_api_token = $cf_token
EOF
        chmod 600 "$N8N_DIR/.cloudflare.ini"
    fi
    
    # Validate API token first
    printf "Validating Cloudflare API token...\n"
    if ! validate_cloudflare_token "$cf_token"; then
        printf "\n${YELLOW}Please check your API token and try again.${NC}\n"
        printf "Press Enter to continue..."
        read
        return 1
    fi
    
    # Extract root domain for zone lookup
    local root_domain=$(extract_root_domain "$domain")
    printf "Full domain: ${CYAN}%s${NC}\n" "$domain"
    printf "Root domain: ${CYAN}%s${NC}\n" "$root_domain"
    
    # Get Zone ID using root domain  
    printf "Getting Cloudflare zone information for %s..." "$root_domain"
    local zone_response=$(curl -s --max-time 15 --connect-timeout 5 \
        -X GET "https://api.cloudflare.com/client/v4/zones?name=$root_domain" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json")
    
    local curl_exit_code=$?
    if [ $curl_exit_code -ne 0 ]; then
        printf " ${RED}TIMEOUT${NC}\n"
        log_error "Zone lookup timed out (exit code: $curl_exit_code)"
        printf "\nTry again or enter zone ID manually? (retry/manual/quit): "
        read retry_choice
        case $retry_choice in
            "retry"|"r")
                printf "Retrying zone lookup...\n"
                return 1
                ;;
            "manual"|"m")
                printf "Enter your zone ID manually: "
                read manual_zone_id
                if [ -n "$manual_zone_id" ]; then
                    zone_id="$manual_zone_id"
                    printf " ${GREEN}OK${NC}\n"
                else
                    return 1
                fi
                ;;
            *)
                return 1
                ;;
        esac
    else
        printf " ${GREEN}OK${NC}\n"
        log_debug "Zone API response: $zone_response"
        
        # Extract zone ID from response
        local zone_id=$(echo "$zone_response" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
    fi
    
    if [ -z "$zone_id" ]; then
        log_error "Could not find Cloudflare zone for domain: $root_domain"
        printf "\n${RED}Debugging information:${NC}\n"
        printf "• Searched for zone: %s\n" "$root_domain"
        printf "• API Response: %s\n" "$zone_response"
        
        # Check if API response contains any zones
        local zone_count=$(echo "$zone_response" | grep -o '"name":"[^"]*' | wc -l)
        if [ $zone_count -gt 0 ]; then
            printf "\n${YELLOW}Available zones in your account:${NC}\n"
            echo "$zone_response" | grep -o '"name":"[^"]*' | cut -d'"' -f4 | while read zone_name; do
                printf "• %s\n" "$zone_name"
            done
            printf "\nPlease ensure '%s' matches one of the zones above.\n" "$root_domain"
        else
            printf "\n${YELLOW}No zones found in your Cloudflare account.${NC}\n"
            printf "Please ensure:\n"
            printf "1. Domain '%s' is added to your Cloudflare account\n" "$root_domain"
            printf "2. API token has Zone:Zone:Read permission\n"
            printf "3. Token scope includes the zone\n"
        fi
        
        printf "\n${BLUE}Manual zone ID entry:${NC}\n"
        printf "If you know your zone ID, enter it manually: "
        read manual_zone_id
        
        if [ -n "$manual_zone_id" ]; then
            zone_id="$manual_zone_id"
            printf "Using manual zone ID: ${GREEN}%s${NC}\n" "$zone_id"
        else
            return 1
        fi
    fi
    
    printf "Zone ID: ${GREEN}%s${NC}\n\n" "$zone_id"
    
    # Check existing DNS records first
    printf "Checking existing DNS records for %s...\n" "$domain"
    local existing_records=$(curl -s --max-time 10 \
        -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?name=$domain" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json")
    
    local existing_type=$(echo "$existing_records" | grep -o '"type":"[^"]*' | head -1 | cut -d'"' -f4)
    local existing_content=$(echo "$existing_records" | grep -o '"content":"[^"]*' | head -1 | cut -d'"' -f4)
    local existing_proxied=$(echo "$existing_records" | grep -o '"proxied":[^,]*' | head -1 | cut -d':' -f2)
    local record_id=$(echo "$existing_records" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
    
    if [ -n "$existing_type" ]; then
        printf "\n${BLUE}Current DNS Configuration:${NC}\n"
        printf "Record Type: ${YELLOW}%s${NC}\n" "$existing_type"
        printf "Points to: ${YELLOW}%s${NC}\n" "$existing_content"
        printf "Cloudflare Proxy: ${YELLOW}%s${NC}\n" "$existing_proxied"
        printf "\n"
        
        # Provide smart recommendations
        if [[ "$existing_content" == *".synology.me" ]] || [[ "$existing_content" == *".duckdns.org" ]] || [[ "$existing_content" == *".no-ip.com" ]]; then
            printf "${GREEN}✓ Detected dynamic IP setup${NC}\n"
            printf "Your current CNAME setup is ideal for dynamic IPs.\n\n"
            
            printf "Options:\n"
            printf "1) Keep CNAME and enable Cloudflare proxy (recommended)\n"
            printf "2) Switch to A record with current server IP\n"
            printf "3) Cancel and keep current settings\n"
            printf "\nSelect option (1-3): "
        else
            printf "Current setup uses %s record.\n\n" "$existing_type"
            printf "Options:\n"
            printf "1) Keep current record type and enable Cloudflare proxy\n"
            printf "2) Switch to A record with current server IP\n"
            printf "3) Switch to CNAME (for dynamic IP setups)\n"
            printf "4) Cancel and keep current settings\n"
            printf "\nSelect option (1-4): "
        fi
        
        read dns_choice
        
        case $dns_choice in
            1)
                # Enable proxy on existing record
                configure_dns_proxy "$zone_id" "$cf_token" "$record_id" "$existing_type" "$existing_content" "$domain"
                ;;
            2)
                # Switch to A record
                configure_dns_a_record "$zone_id" "$cf_token" "$record_id" "$domain"
                ;;
            3)
                if [[ "$existing_content" == *".synology.me" ]] || [[ "$existing_content" == *".duckdns.org" ]]; then
                    # Cancel option for dynamic IP setups
                    printf "Keeping current settings unchanged.\n"
                    return 0
                else
                    # CNAME option for static setups
                    configure_dns_cname_record "$zone_id" "$cf_token" "$record_id" "$domain"
                fi
                ;;
            4|*)
                if [[ "$existing_content" != *".synology.me" ]]; then
                    printf "Keeping current settings unchanged.\n"
                    return 0
                else
                    configure_dns_cname_record "$zone_id" "$cf_token" "$record_id" "$domain"
                fi
                ;;
        esac
    else
        printf "${YELLOW}No existing DNS record found for %s${NC}\n\n" "$domain"
        printf "Choose DNS record type:\n"
        printf "1) A record - Points to server IP address (best for static IPs)\n"
        printf "2) CNAME record - Points to hostname (best for dynamic IPs)\n"
        printf "\nSelect option (1-2): "
        read dns_choice
        
        case $dns_choice in
            1)
                configure_dns_a_record "$zone_id" "$cf_token" "" "$domain"
                ;;
            2)
                configure_dns_cname_record "$zone_id" "$cf_token" "" "$domain"
                ;;
            *)
                log_error "Invalid option"
                return 1
                ;;
        esac
    fi
    
    # Configure security rules
    printf "\nConfiguring Cloudflare security rules...\n"
    
    # Rate limiting rule for authentication endpoints
    local rate_limit_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/rate_limits" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json" \
        --data '{
            "match": {
                "request": {
                    "url": "*'$domain'/rest/login*"
                }
            },
            "threshold": 5,
            "period": 60,
            "action": {
                "mode": "ban",
                "timeout": 3600,
                "response": {
                    "content_type": "application/json",
                    "body": "{\"error\": \"Rate limit exceeded\"}"
                }
            },
            "description": "n8n login rate limiting"
        }')
    
    # Bot protection
    printf "Enabling bot protection...\n"
    local bot_response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/settings/bot_management" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json" \
        --data '{"value": {"enable_js": true, "sb_im": "block", "sb_ml": "challenge"}}')
    
    # SSL settings
    printf "Configuring SSL settings...\n"
    local ssl_response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/settings/ssl" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json" \
        --data '{"value": "full"}')
    
    # Save configuration
    echo "CLOUDFLARE_ZONE_ID=$zone_id" >> "$N8N_DIR/.env"
    echo "CLOUDFLARE_PROTECTION_ENABLED=true" >> "$N8N_DIR/.env"
    
    printf "\n${GREEN}Cloudflare protection configured successfully!${NC}\n\n"
    printf "Features enabled:\n"
    printf "✓ DNS proxy (orange cloud) for DDoS protection\n"
    printf "✓ Rate limiting on login endpoints (5 requests/minute)\n"
    printf "✓ Bot protection with JavaScript challenges\n"
    printf "✓ SSL/TLS encryption (Full mode)\n\n"
    
    printf "Additional recommendations:\n"
    printf "• Enable 'Under Attack Mode' during active threats\n"
    printf "• Configure geographic restrictions if needed\n"
    printf "• Set up Cloudflare Access for additional authentication\n\n"
    
    log_function_end "configure_cloudflare_protection"
    printf "Press Enter to continue..."
    read
}

# Whitelist Cloudflare IPs in UFW
whitelist_cloudflare_ips() {
    log_function_start "whitelist_cloudflare_ips"
    
    printf "\n${BLUE}Cloudflare IP Whitelist Configuration${NC}\n"
    printf "=====================================\n\n"
    
    # Check if UFW is installed and enabled
    if ! command -v ufw &> /dev/null; then
        log_error "UFW is not installed. Please install UFW first."
        printf "Run: sudo apt-get install ufw\n"
        sleep 3
        return 1
    fi
    
    # Check current status
    if sudo ufw status | grep -q "443.*ALLOW.*Anywhere" && ! sudo ufw status | grep -q "Cloudflare"; then
        printf "${YELLOW}Warning: Port 443 is currently open to all IPs${NC}\n"
        printf "This will be restricted to Cloudflare IPs only.\n\n"
    fi
    
    # Detect SSH connection source if possible
    local ssh_client_ip=""
    if [ -n "$SSH_CLIENT" ]; then
        ssh_client_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
        log_debug "Detected SSH connection from: $ssh_client_ip"
    fi
    
    printf "This will:\n"
    printf "• Fetch current Cloudflare IP ranges\n"
    printf "• Remove existing port 443 rules\n"
    printf "• Add rules allowing only Cloudflare IPs to port 443\n"
    printf "• Preserve internal network access (localhost, private IPs)\n"
    if [ -n "$ssh_client_ip" ]; then
        printf "• Preserve SSH access for your connection (%s)\n" "$ssh_client_ip"
    fi
    printf "• Keep all other firewall rules intact\n\n"
    
    printf "${CYAN}Note:${NC} SSH (port 22) access is never affected by this change.\n"
    printf "${CYAN}Note:${NC} Internal network HTTPS access is preserved for management.\n\n"
    
    printf "Continue? (y/n): "
    read confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "Cloudflare IP whitelist cancelled"
        return 0
    fi
    
    # Backup current UFW rules
    log_info "Backing up current firewall rules..."
    sudo ufw status numbered > "$N8N_DIR/ufw_backup_$(date +%Y%m%d_%H%M%S).txt"
    
    # Fetch Cloudflare IP ranges
    printf "\nFetching Cloudflare IP ranges...\n"
    local cf_ipv4_url="https://www.cloudflare.com/ips-v4"
    local cf_ipv6_url="https://www.cloudflare.com/ips-v6"
    
    # Download IP lists
    local ipv4_list=$(curl -s --max-time 10 "$cf_ipv4_url")
    local ipv6_list=$(curl -s --max-time 10 "$cf_ipv6_url")
    
    if [ -z "$ipv4_list" ]; then
        log_error "Failed to fetch Cloudflare IPv4 addresses"
        return 1
    fi
    
    # Save IP lists for reference
    echo "$ipv4_list" > "$N8N_DIR/.cloudflare_ips_v4"
    echo "$ipv6_list" > "$N8N_DIR/.cloudflare_ips_v6"
    
    # Count IPs
    local ipv4_count=$(echo "$ipv4_list" | wc -l)
    local ipv6_count=$(echo "$ipv6_list" | wc -l)
    printf "Found ${GREEN}%d${NC} IPv4 ranges and ${GREEN}%d${NC} IPv6 ranges\n\n" "$ipv4_count" "$ipv6_count"
    
    # Remove existing port 443 rules (both generic and Cloudflare-specific)
    printf "Removing existing port 443 rules...\n"
    while sudo ufw status numbered | grep -q "443/tcp"; do
        local rule_num=$(sudo ufw status numbered | grep "443/tcp" | head -1 | sed 's/\[\([0-9]*\)\].*/\1/')
        if [ -n "$rule_num" ]; then
            sudo ufw --force delete "$rule_num" 2>/dev/null || true
        else
            break
        fi
    done
    
    # Add internal network access first (preserve local access)
    printf "Adding internal network access rules...\n"
    sudo ufw allow from 127.0.0.0/8 to any port 443 proto tcp comment "Internal localhost" 2>/dev/null
    sudo ufw allow from 10.0.0.0/8 to any port 443 proto tcp comment "Internal private 10.x" 2>/dev/null
    sudo ufw allow from 172.16.0.0/12 to any port 443 proto tcp comment "Internal private 172.x" 2>/dev/null
    sudo ufw allow from 192.168.0.0/16 to any port 443 proto tcp comment "Internal private 192.168.x" 2>/dev/null
    printf " ${GREEN}✓${NC} (Internal networks preserved)\n"
    
    # Add Cloudflare IPv4 rules
    printf "Adding Cloudflare IPv4 rules...\n"
    local added_count=0
    while IFS= read -r ip; do
        if [ -n "$ip" ]; then
            sudo ufw allow from "$ip" to any port 443 proto tcp comment "Cloudflare IPv4" 2>/dev/null
            ((added_count++))
            printf "."
        fi
    done <<< "$ipv4_list"
    printf " ${GREEN}✓${NC} (%d rules)\n" "$added_count"
    
    # Add Cloudflare IPv6 rules if IPv6 is enabled
    if [ "$ipv6_count" -gt 0 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = "0" ]; then
        printf "Adding Cloudflare IPv6 rules...\n"
        added_count=0
        while IFS= read -r ip; do
            if [ -n "$ip" ]; then
                sudo ufw allow from "$ip" to any port 443 proto tcp comment "Cloudflare IPv6" 2>/dev/null
                ((added_count++))
                printf "."
            fi
        done <<< "$ipv6_list"
        printf " ${GREEN}✓${NC} (%d rules)\n" "$added_count"
    fi
    
    # Reload UFW
    printf "\nReloading firewall...\n"
    sudo ufw reload
    
    # Save whitelist status
    if ! grep -q "^CLOUDFLARE_IP_WHITELIST=" "$N8N_DIR/.env"; then
        echo "CLOUDFLARE_IP_WHITELIST=enabled" >> "$N8N_DIR/.env"
    else
        sed -i "s/^CLOUDFLARE_IP_WHITELIST=.*/CLOUDFLARE_IP_WHITELIST=enabled/" "$N8N_DIR/.env"
    fi
    
    if ! grep -q "^CLOUDFLARE_IP_WHITELIST_DATE=" "$N8N_DIR/.env"; then
        echo "CLOUDFLARE_IP_WHITELIST_DATE=$(date +%Y-%m-%d)" >> "$N8N_DIR/.env"
    else
        sed -i "s/^CLOUDFLARE_IP_WHITELIST_DATE=.*/CLOUDFLARE_IP_WHITELIST_DATE=$(date +%Y-%m-%d)/" "$N8N_DIR/.env"
    fi
    
    printf "\n${GREEN}Cloudflare IP whitelist enabled successfully!${NC}\n\n"
    printf "Port 443 is now restricted to Cloudflare IPs only.\n"
    printf "Your server is protected while maintaining Cloudflare proxy access.\n"
    printf "\n${CYAN}Access Methods:${NC}\n"
    printf "• External: https://your.domain.com (via Cloudflare)\n"
    printf "• Internal: https://localhost or https://LAN_IP (direct access)\n"
    printf "• SSH: Port 22 remains unaffected\n"
    printf "\n${YELLOW}Recovery:${NC} If locked out, disable with option 2 in this menu.\n"
    
    printf "\nPress Enter to continue..."
    read
    
    log_function_end "whitelist_cloudflare_ips"
}

# Remove Cloudflare IP whitelist
remove_cloudflare_whitelist() {
    log_function_start "remove_cloudflare_whitelist"
    
    printf "\n${BLUE}Remove Cloudflare IP Whitelist${NC}\n"
    printf "===============================\n\n"
    
    # Check if whitelist is active
    if ! sudo ufw status | grep -q "Cloudflare"; then
        printf "${YELLOW}No Cloudflare IP whitelist rules found.${NC}\n"
        printf "\nPress Enter to continue..."
        read
        return 0
    fi
    
    printf "This will:\n"
    printf "• Remove all Cloudflare-specific firewall rules\n"
    printf "• Open port 443 to all IPs (standard configuration)\n"
    printf "• Keep all other firewall rules intact\n\n"
    
    printf "${YELLOW}Warning: Port 443 will be accessible from any IP address.${NC}\n\n"
    
    printf "Continue? (y/n): "
    read confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "Removal cancelled"
        return 0
    fi
    
    # Backup current rules
    log_info "Backing up current firewall rules..."
    sudo ufw status numbered > "$N8N_DIR/ufw_backup_before_removal_$(date +%Y%m%d_%H%M%S).txt"
    
    # Remove Cloudflare-specific rules and internal network rules
    printf "\nRemoving Cloudflare IP rules and internal network rules...\n"
    local removed_count=0
    
    while sudo ufw status numbered | grep -qE "(Cloudflare|Internal)"; do
        local rule_num=$(sudo ufw status numbered | grep -E "(Cloudflare|Internal)" | head -1 | sed 's/\[\([0-9]*\)\].*/\1/')
        if [ -n "$rule_num" ]; then
            sudo ufw --force delete "$rule_num" 2>/dev/null
            ((removed_count++))
            printf "."
        else
            break
        fi
    done
    
    printf " ${GREEN}✓${NC} (Removed %d rules)\n" "$removed_count"
    
    # Add standard port 443 rule
    printf "Adding standard port 443 rule...\n"
    sudo ufw allow 443/tcp comment "n8n HTTPS"
    
    # Reload UFW
    printf "Reloading firewall...\n"
    sudo ufw reload
    
    # Update status in .env
    sed -i '/^CLOUDFLARE_IP_WHITELIST=/d' "$N8N_DIR/.env" 2>/dev/null || true
    sed -i '/^CLOUDFLARE_IP_WHITELIST_DATE=/d' "$N8N_DIR/.env" 2>/dev/null || true
    
    printf "\n${GREEN}Cloudflare IP whitelist removed successfully!${NC}\n\n"
    printf "Port 443 is now open to all IPs (standard configuration).\n"
    printf "Consider re-enabling the whitelist for enhanced security.\n"
    
    printf "\nPress Enter to continue..."
    read
    
    log_function_end "remove_cloudflare_whitelist"
}

# Update Cloudflare IP whitelist
update_cloudflare_ips() {
    log_function_start "update_cloudflare_ips"
    
    printf "\n${BLUE}Update Cloudflare IP List${NC}\n"
    printf "=========================\n\n"
    
    # Check if whitelist is active
    if ! sudo ufw status | grep -q "Cloudflare"; then
        printf "${YELLOW}Cloudflare IP whitelist is not currently active.${NC}\n"
        printf "Enable it first from the menu.\n"
        printf "\nPress Enter to continue..."
        read
        return 0
    fi
    
    printf "This will:\n"
    printf "• Fetch the latest Cloudflare IP ranges\n"
    printf "• Update firewall rules with any changes\n"
    printf "• Maintain uninterrupted service\n\n"
    
    printf "Continue? (y/n): "
    read confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        return 0
    fi
    
    # Re-apply whitelist (this will fetch fresh IPs)
    whitelist_cloudflare_ips
    
    log_function_end "update_cloudflare_ips"
}

# Show Cloudflare whitelist status
show_cloudflare_whitelist_status() {
    printf "\n${BLUE}Cloudflare IP Whitelist Status${NC}\n"
    printf "===============================\n\n"
    
    # Check if whitelist is enabled
    local whitelist_status=$(grep "^CLOUDFLARE_IP_WHITELIST=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2)
    local whitelist_date=$(grep "^CLOUDFLARE_IP_WHITELIST_DATE=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2)
    
    if [ "$whitelist_status" = "enabled" ]; then
        printf "Status: ${GREEN}ENABLED${NC}\n"
        if [ -n "$whitelist_date" ]; then
            printf "Last updated: %s\n" "$whitelist_date"
        fi
    else
        printf "Status: ${YELLOW}DISABLED${NC}\n"
    fi
    
    # Count Cloudflare rules in UFW
    local cf_rule_count=$(sudo ufw status numbered | grep -c "Cloudflare" || echo "0")
    printf "Active Cloudflare rules: ${CYAN}%d${NC}\n" "$cf_rule_count"
    
    # Check port 443 accessibility
    printf "\nPort 443 Configuration:\n"
    if sudo ufw status | grep -q "443.*ALLOW.*Anywhere" && ! sudo ufw status | grep -q "Cloudflare.*443"; then
        printf "• ${YELLOW}Open to all IPs${NC} (standard configuration)\n"
    elif [ "$cf_rule_count" -gt 0 ]; then
        printf "• ${GREEN}Restricted to Cloudflare IPs only${NC}\n"
        
        # Show IP list files
        if [ -f "$N8N_DIR/.cloudflare_ips_v4" ]; then
            local ipv4_count=$(wc -l < "$N8N_DIR/.cloudflare_ips_v4")
            printf "• IPv4 ranges: %d\n" "$ipv4_count"
        fi
        if [ -f "$N8N_DIR/.cloudflare_ips_v6" ]; then
            local ipv6_count=$(wc -l < "$N8N_DIR/.cloudflare_ips_v6")
            printf "• IPv6 ranges: %d\n" "$ipv6_count"
        fi
    else
        printf "• ${RED}No rules found${NC}\n"
    fi
    
    # Test connectivity suggestion
    printf "\n${CYAN}Test Commands:${NC}\n"
    printf "• Check DNS: dig +short your.domain.com\n"
    printf "• Verify proxy: curl -I https://your.domain.com\n"
    printf "• UFW details: sudo ufw status numbered | grep 443\n"
    
    printf "\nPress Enter to continue..."
    read
}

# Cloudflare IP whitelist menu
cloudflare_ip_whitelist_menu() {
    while true; do
        print_header
        printf "${BLUE}Cloudflare IP Whitelist Management${NC}\n"
        printf "===================================\n\n"
        
        # Show current status
        local whitelist_status=$(grep "^CLOUDFLARE_IP_WHITELIST=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2)
        if [ "$whitelist_status" = "enabled" ]; then
            printf "Current Status: ${GREEN}Whitelist Enabled${NC}\n\n"
        else
            printf "Current Status: ${YELLOW}Whitelist Disabled${NC}\n\n"
        fi
        
        printf "1) Enable Cloudflare IP whitelist (restrict port 443)\n"
        printf "2) Remove Cloudflare IP whitelist (open port 443)\n"
        printf "3) Update Cloudflare IP list\n"
        printf "4) Show whitelist status\n"
        printf "0) Back to Security Menu\n\n"
        
        read -p "Select option: " choice
        
        case $choice in
            1) whitelist_cloudflare_ips ;;
            2) remove_cloudflare_whitelist ;;
            3) update_cloudflare_ips ;;
            4) show_cloudflare_whitelist_status ;;
            0) return ;;
            *) log_error "Invalid option" ;;
        esac
    done
}

# Run Security Audit
run_security_audit() {
    log_function_start "run_security_audit"
    
    printf "\n${BLUE}Security Audit Report${NC}\n"
    printf "====================\n\n"
    
    local issues=0
    local warnings=0
    
    # Check SSL certificate
    printf "${BOLD}SSL Certificate Status:${NC}\n"
    if [ -f "$N8N_DIR/certs/n8n.crt" ]; then
        local cert_expiry=$(openssl x509 -in "$N8N_DIR/certs/n8n.crt" -noout -enddate | cut -d= -f2)
        local cert_days=$(( ($(date -d "$cert_expiry" +%s) - $(date +%s)) / 86400 ))
        
        if [ $cert_days -lt 7 ]; then
            printf "❌ Certificate expires in ${RED}%d days${NC} (%s)\n" "$cert_days" "$cert_expiry"
            ((issues++))
        elif [ $cert_days -lt 30 ]; then
            printf "⚠️  Certificate expires in ${YELLOW}%d days${NC} (%s)\n" "$cert_days" "$cert_expiry"
            ((warnings++))
        else
            printf "✅ Certificate valid for ${GREEN}%d days${NC}\n" "$cert_days"
        fi
        
        # Check certificate algorithm
        local cert_algo=$(openssl x509 -in "$N8N_DIR/certs/n8n.crt" -noout -text | grep "Signature Algorithm" | head -1 | awk '{print $3}')
        if [[ "$cert_algo" == *"sha1"* ]]; then
            printf "❌ Certificate uses weak ${RED}SHA-1${NC} algorithm\n"
            ((issues++))
        else
            printf "✅ Certificate uses strong signature algorithm\n"
        fi
    else
        printf "❌ ${RED}No SSL certificate found${NC}\n"
        ((issues++))
    fi
    
    # Check firewall status
    printf "\n${BOLD}Firewall Configuration:${NC}\n"
    if command -v ufw &> /dev/null; then
        if sudo ufw status | grep -q "Status: active"; then
            printf "✅ UFW firewall is enabled\n"
            
            # Check for proper rules
            local ssh_rule=$(sudo ufw status | grep -E "(22|ssh)" | wc -l)
            local https_rule=$(sudo ufw status | grep -E "(443|https)" | wc -l)
            
            if [ $ssh_rule -eq 0 ]; then
                printf "⚠️  ${YELLOW}No SSH rule found${NC} (may lock you out)\n"
                ((warnings++))
            fi
            
            if [ $https_rule -eq 0 ]; then
                printf "❌ ${RED}No HTTPS rule found${NC} (n8n may be inaccessible)\n"
                ((issues++))
            fi
        else
            printf "❌ ${RED}UFW firewall is disabled${NC}\n"
            ((issues++))
        fi
    else
        printf "❌ ${RED}UFW firewall not installed${NC}\n"
        ((issues++))
    fi
    
    # Check fail2ban status
    printf "\n${BOLD}Intrusion Prevention:${NC}\n"
    if command -v fail2ban-client &> /dev/null; then
        if systemctl is-active --quiet fail2ban; then
            printf "✅ fail2ban is active\n"
            
            # Check n8n jail
            if sudo fail2ban-client status | grep -q "n8n-auth"; then
                printf "✅ n8n authentication jail is configured\n"
                
                # Check banned IPs
                local banned_count=$(sudo fail2ban-client status n8n-auth | grep "Currently banned" | awk '{print $4}' || echo "0")
                if [ $banned_count -gt 0 ]; then
                    printf "ℹ️  Currently blocking ${YELLOW}%s${NC} IP(s)\n" "$banned_count"
                fi
            else
                printf "⚠️  ${YELLOW}n8n jail not configured${NC}\n"
                ((warnings++))
            fi
        else
            printf "❌ ${RED}fail2ban is not running${NC}\n"
            ((issues++))
        fi
    else
        printf "❌ ${RED}fail2ban not installed${NC}\n"
        ((issues++))
    fi
    
    # Check service status
    printf "\n${BOLD}Service Status:${NC}\n"
    cd "$N8N_DIR"
    local services=("nginx" "postgres" "n8n")
    for service in "${services[@]}"; do
        local status=$(docker compose ps --format '{{.Service}} {{.Status}}' | grep "^$service " | awk '{print $2}')
        if [[ "$status" == *"Up"* ]]; then
            printf "✅ %s is running\n" "$service"
        else
            printf "❌ ${RED}%s is not running${NC}\n" "$service"
            ((issues++))
        fi
    done
    
    # Check for weak configurations
    printf "\n${BOLD}Configuration Security:${NC}\n"
    
    # Check for default passwords
    if grep -q "admin:admin" "$N8N_DIR/.env" 2>/dev/null; then
        printf "❌ ${RED}Default admin credentials detected${NC}\n"
        ((issues++))
    else
        printf "✅ Custom admin credentials configured\n"
    fi
    
    # Check encryption key
    if grep -q "^N8N_ENCRYPTION_KEY=" "$N8N_DIR/.env" 2>/dev/null; then
        printf "✅ Encryption key is configured\n"
    else
        printf "⚠️  ${YELLOW}No encryption key found${NC}\n"
        ((warnings++))
    fi
    
    # Check for exposed ports
    printf "\n${BOLD}Network Exposure:${NC}\n"
    local open_ports=$(netstat -tuln 2>/dev/null | grep LISTEN | grep -E ":80|:443|:5432|:5678" | wc -l)
    if [ $open_ports -gt 0 ]; then
        printf "ℹ️  Found %d listening ports (review for necessity)\n" "$open_ports"
        netstat -tuln 2>/dev/null | grep LISTEN | grep -E ":80|:443|:5432|:5678" | while read line; do
            printf "   %s\n" "$line"
        done
    fi
    
    # Summary
    printf "\n${BOLD}Security Audit Summary:${NC}\n"
    printf "======================\n"
    
    if [ $issues -eq 0 ] && [ $warnings -eq 0 ]; then
        printf "${GREEN}🛡️  Excellent security posture!${NC}\n"
        printf "No issues or warnings found.\n"
    elif [ $issues -eq 0 ]; then
        printf "${YELLOW}⚠️  Good security with %d warning(s)${NC}\n" "$warnings"
        printf "Consider addressing warnings for optimal security.\n"
    else
        printf "${RED}🚨 Security issues require attention${NC}\n"
        printf "Found: %d critical issues, %d warnings\n" "$issues" "$warnings"
        printf "\nRecommended actions:\n"
        printf "1. Address all critical issues immediately\n"
        printf "2. Review and resolve warnings\n"
        printf "3. Run audit again after fixes\n"
    fi
    
    log_function_end "run_security_audit"
    printf "\nPress Enter to continue..."
    read
}

# Configure Security Monitoring
configure_security_monitoring() {
    log_function_start "configure_security_monitoring"
    
    printf "\n${BLUE}Security Monitoring Setup${NC}\n"
    printf "=========================\n\n"
    
    printf "Configure notification methods for security events:\n\n"
    
    printf "1) Email notifications\n"
    printf "2) Webhook notifications (Slack, Discord, etc.)\n"
    printf "3) Log-based monitoring only\n"
    printf "0) Cancel\n\n"
    printf "Select option: "
    read monitor_choice
    
    case $monitor_choice in
        1)
            configure_email_monitoring
            ;;
        2)
            configure_webhook_monitoring
            ;;
        3)
            configure_log_monitoring
            ;;
        0)
            return
            ;;
        *)
            log_error "Invalid option"
            return 1
            ;;
    esac
    
    log_function_end "configure_security_monitoring"
}

# Configure Email Monitoring
configure_email_monitoring() {
    printf "\n${BLUE}Email Monitoring Setup${NC}\n"
    printf "======================\n\n"
    
    printf "Enter SMTP server (e.g., smtp.gmail.com): "
    read smtp_server
    
    printf "Enter SMTP port (usually 587 for TLS): "
    read smtp_port
    
    printf "Enter email address for notifications: "
    read notification_email
    
    printf "Enter sender email address: "
    read sender_email
    
    printf "Enter sender email password (will be hidden): "
    read -s sender_password
    printf "\n"
    
    # Save monitoring configuration
    cat >> "$N8N_DIR/.env" << EOF
MONITORING_ENABLED=true
MONITORING_TYPE=email
SMTP_SERVER=$smtp_server
SMTP_PORT=$smtp_port
NOTIFICATION_EMAIL=$notification_email
SENDER_EMAIL=$sender_email
SENDER_PASSWORD=$sender_password
EOF
    
    # Create monitoring script
    cat > "$N8N_DIR/scripts/security_monitor.sh" << 'EOF'
#!/bin/bash

# Security monitoring script
LOG_FILE="$HOME/n8n-operations.log"
ALERT_LOG="/tmp/n8n_security_alerts.log"

# Source environment variables
source "$HOME/n8n/.env"

send_email_alert() {
    local subject="$1"
    local body="$2"
    
    python3 -c "
import smtplib
from email.mime.text import MimeText
from email.mime.multipart import MimeMultipart
import os

smtp_server = os.environ.get('SMTP_SERVER')
smtp_port = int(os.environ.get('SMTP_PORT', 587))
sender_email = os.environ.get('SENDER_EMAIL')
sender_password = os.environ.get('SENDER_PASSWORD')
notification_email = os.environ.get('NOTIFICATION_EMAIL')

msg = MimeMultipart()
msg['From'] = sender_email
msg['To'] = notification_email
msg['Subject'] = '$subject'
msg.attach(MimeText('$body', 'plain'))

try:
    server = smtplib.SMTP(smtp_server, smtp_port)
    server.starttls()
    server.login(sender_email, sender_password)
    server.send_message(msg)
    server.quit()
    print('Alert sent successfully')
except Exception as e:
    print(f'Failed to send alert: {e}')
"
}

# Check for failed logins
failed_logins=$(grep -c "401.*rest/login" "$LOG_FILE" 2>/dev/null || echo "0")
if [ $failed_logins -gt 10 ]; then
    echo "$(date): High number of failed logins detected ($failed_logins)" >> "$ALERT_LOG"
    send_email_alert "n8n Security Alert: Failed Logins" "Detected $failed_logins failed login attempts. Please review security logs."
fi

# Check certificate expiry
if [ -f "$HOME/n8n/certs/n8n.crt" ]; then
    cert_days=$(( ($(date -d "$(openssl x509 -in "$HOME/n8n/certs/n8n.crt" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
    if [ $cert_days -lt 7 ]; then
        echo "$(date): SSL certificate expires in $cert_days days" >> "$ALERT_LOG"
        send_email_alert "n8n Security Alert: Certificate Expiry" "SSL certificate expires in $cert_days days. Please renew immediately."
    fi
fi

# Check for service failures
if ! docker compose -f "$HOME/n8n/docker-compose.yml" ps | grep -q "Up"; then
    echo "$(date): Service failure detected" >> "$ALERT_LOG"
    send_email_alert "n8n Security Alert: Service Down" "One or more n8n services are not running. Please check system status."
fi
EOF

    chmod +x "$N8N_DIR/scripts/security_monitor.sh"
    
    # Add to cron
    (crontab -l 2>/dev/null | grep -v "security_monitor.sh"; echo "*/15 * * * * $N8N_DIR/scripts/security_monitor.sh") | crontab -
    
    log_success "Email monitoring configured"
    printf "Security alerts will be sent to: ${GREEN}%s${NC}\n" "$notification_email"
    printf "Monitoring runs every 15 minutes\n"
    printf "\nPress Enter to continue..."
    read
}

# Configure Webhook Monitoring
configure_webhook_monitoring() {
    printf "\n${BLUE}Webhook Monitoring Setup${NC}\n"
    printf "========================\n\n"
    
    printf "Enter webhook URL (Slack, Discord, or custom): "
    read webhook_url
    
    printf "Enter webhook type (slack/discord/custom): "
    read webhook_type
    
    # Save monitoring configuration
    cat >> "$N8N_DIR/.env" << EOF
MONITORING_ENABLED=true
MONITORING_TYPE=webhook
WEBHOOK_URL=$webhook_url
WEBHOOK_TYPE=$webhook_type
EOF
    
    # Create webhook monitoring script
    cat > "$N8N_DIR/scripts/webhook_monitor.sh" << 'EOF'
#!/bin/bash

# Webhook monitoring script
LOG_FILE="$HOME/n8n-operations.log"
ALERT_LOG="/tmp/n8n_security_alerts.log"

# Source environment variables
source "$HOME/n8n/.env"

send_webhook_alert() {
    local message="$1"
    local webhook_url="$WEBHOOK_URL"
    local webhook_type="$WEBHOOK_TYPE"
    
    case $webhook_type in
        "slack")
            curl -X POST -H 'Content-type: application/json' \
                --data "{\"text\":\"🚨 n8n Security Alert: $message\"}" \
                "$webhook_url"
            ;;
        "discord")
            curl -X POST -H 'Content-Type: application/json' \
                --data "{\"content\":\"🚨 **n8n Security Alert**: $message\"}" \
                "$webhook_url"
            ;;
        "custom")
            curl -X POST -H 'Content-Type: application/json' \
                --data "{\"alert\":\"n8n Security Alert\",\"message\":\"$message\",\"timestamp\":\"$(date)\"}" \
                "$webhook_url"
            ;;
    esac
}

# Monitor security events (same checks as email version)
failed_logins=$(grep -c "401.*rest/login" "$LOG_FILE" 2>/dev/null || echo "0")
if [ $failed_logins -gt 10 ]; then
    echo "$(date): High number of failed logins detected ($failed_logins)" >> "$ALERT_LOG"
    send_webhook_alert "High number of failed logins detected ($failed_logins)"
fi

# Check certificate expiry
if [ -f "$HOME/n8n/certs/n8n.crt" ]; then
    cert_days=$(( ($(date -d "$(openssl x509 -in "$HOME/n8n/certs/n8n.crt" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
    if [ $cert_days -lt 7 ]; then
        echo "$(date): SSL certificate expires in $cert_days days" >> "$ALERT_LOG"
        send_webhook_alert "SSL certificate expires in $cert_days days"
    fi
fi

# Check for service failures
if ! docker compose -f "$HOME/n8n/docker-compose.yml" ps | grep -q "Up"; then
    echo "$(date): Service failure detected" >> "$ALERT_LOG"
    send_webhook_alert "One or more n8n services are not running"
fi
EOF

    chmod +x "$N8N_DIR/scripts/webhook_monitor.sh"
    
    # Add to cron
    (crontab -l 2>/dev/null | grep -v "webhook_monitor.sh"; echo "*/15 * * * * $N8N_DIR/scripts/webhook_monitor.sh") | crontab -
    
    log_success "Webhook monitoring configured"
    printf "Security alerts will be sent to: ${GREEN}%s${NC}\n" "$webhook_url"
    printf "Monitoring runs every 15 minutes\n"
    printf "\nPress Enter to continue..."
    read
}

# Configure Log Monitoring
configure_log_monitoring() {
    printf "\n${BLUE}Log-based Monitoring Setup${NC}\n"
    printf "===========================\n\n"
    
    # Save monitoring configuration
    cat >> "$N8N_DIR/.env" << EOF
MONITORING_ENABLED=true
MONITORING_TYPE=log
EOF
    
    # Enhance log monitoring
    cat > "$N8N_DIR/scripts/log_monitor.sh" << 'EOF'
#!/bin/bash

# Enhanced log monitoring script
LOG_FILE="$HOME/n8n-operations.log"
SECURITY_LOG="$HOME/n8n-security.log"

# Create security-specific log
mkdir -p "$(dirname "$SECURITY_LOG")"

# Analyze recent activity
echo "=== Security Log Entry: $(date) ===" >> "$SECURITY_LOG"

# Failed login attempts
failed_logins=$(grep "401.*rest/login" "$LOG_FILE" 2>/dev/null | tail -10)
if [ -n "$failed_logins" ]; then
    echo "Recent failed logins:" >> "$SECURITY_LOG"
    echo "$failed_logins" >> "$SECURITY_LOG"
fi

# Certificate status
if [ -f "$HOME/n8n/certs/n8n.crt" ]; then
    cert_days=$(( ($(date -d "$(openssl x509 -in "$HOME/n8n/certs/n8n.crt" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
    echo "Certificate expires in $cert_days days" >> "$SECURITY_LOG"
fi

# fail2ban status
if command -v fail2ban-client &> /dev/null; then
    banned_count=$(sudo fail2ban-client status n8n-auth 2>/dev/null | grep "Currently banned" | awk '{print $4}' || echo "0")
    echo "Currently banned IPs: $banned_count" >> "$SECURITY_LOG"
fi

# Service status
echo "Service status:" >> "$SECURITY_LOG"
docker compose -f "$HOME/n8n/docker-compose.yml" ps --format 'table' >> "$SECURITY_LOG" 2>/dev/null

echo "" >> "$SECURITY_LOG"
EOF

    chmod +x "$N8N_DIR/scripts/log_monitor.sh"
    
    # Add to cron for hourly logging
    (crontab -l 2>/dev/null | grep -v "log_monitor.sh"; echo "0 * * * * $N8N_DIR/scripts/log_monitor.sh") | crontab -
    
    log_success "Log-based monitoring configured"
    printf "Security logs will be written to: ${GREEN}%s${NC}\n" "$HOME/n8n-security.log"
    printf "Monitoring runs every hour\n"
    printf "\nView security logs with: ${CYAN}tail -f ~/n8n-security.log${NC}\n"
    printf "\nPress Enter to continue..."
    read
}

# Manage environment variables
manage_env_vars() {
    cd "$N8N_DIR"
    
    while true; do
        clear
        printf "\n${BLUE}Environment Variables Management${NC}\n"
        printf "================================\n\n"
        printf "1) View current values\n"
        printf "2) Add new variable\n"
        printf "3) Update variable\n"
        printf "4) Remove variable\n"
        printf "0) Back to main menu\n\n"
        printf "Select: "
        read env_choice
        
        case $env_choice in
            1)
                printf "\n${BLUE}Current environment variables:${NC}\n"
                printf "====================================\n"
                # Show all variables but mask sensitive ones
                while IFS='=' read -r key value; do
                    if [[ "$key" =~ ^[A-Z] ]]; then
                        if [[ "$key" =~ (PASSWORD|KEY|SECRET|TOKEN) ]]; then
                            printf "%s=%s\n" "$key" "[HIDDEN]"
                        else
                            printf "%s=%s\n" "$key" "$value"
                        fi
                    fi
                done < .env
                printf "\nPress Enter to continue..."
                read
                ;;
            2)
                printf "\nVariable name: "
                read var_name
                
                # Validate variable name
                if [[ ! "$var_name" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
                    log_error "Invalid variable name. Use uppercase letters, numbers, and underscores only."
                    sleep 2
                    continue
                fi
                
                printf "Variable value: "
                read var_value
                
                if grep -q "^${var_name}=" .env; then
                    log_warn "Variable $var_name already exists. Use 'update' to modify it."
                    sleep 2
                else
                    # Backup .env file
                    cp .env .env.backup
                    
                    # Add to .env file
                    echo "${var_name}=${var_value}" >> .env
                    
                    # Update docker-compose.yml
                    # Create a backup
                    cp docker-compose.yml docker-compose.yml.backup
                    
                    # Add to n8n service environment section
                    if ! grep -q "${var_name}=" docker-compose.yml; then
                        # Find the last environment variable line in the n8n service and add after it
                        sed -i "/- DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}/a\\      - ${var_name}=\${${var_name}}" docker-compose.yml
                    fi
                    
                    log_success "Variable added successfully"
                    printf "\nRecreate services now to apply changes? (y/n): "
                    read recreate_choice
                    if [[ "$recreate_choice" =~ ^[Yy]$ ]]; then
                        recreate_services
                    else
                        log_warn "Run 'Recreate Services' option for changes to take effect"
                        sleep 2
                    fi
                fi
                ;;
            3)
                printf "\nVariable name to update: "
                read var_name
                
                if ! grep -q "^${var_name}=" .env; then
                    log_error "Variable $var_name not found"
                    sleep 2
                else
                    current_value=$(grep "^${var_name}=" .env | cut -d'=' -f2-)
                    if [[ "$var_name" =~ (PASSWORD|KEY|SECRET|TOKEN) ]]; then
                        printf "Current value: [HIDDEN]\n"
                    else
                        printf "Current value: %s\n" "$current_value"
                    fi
                    printf "New value: "
                    read var_value
                    
                    # Backup .env file
                    cp .env .env.backup
                    
                    # Update the value
                    sed -i "s|^${var_name}=.*|${var_name}=${var_value}|" .env
                    
                    log_success "Variable updated successfully"
                    printf "\nRecreate services now to apply changes? (y/n): "
                    read recreate_choice
                    if [[ "$recreate_choice" =~ ^[Yy]$ ]]; then
                        recreate_services
                    else
                        log_warn "Run 'Recreate Services' option for changes to take effect"
                        sleep 2
                    fi
                fi
                ;;
            4)
                printf "\nVariable name to remove: "
                read var_name
                
                # Protect system variables
                if echo "$var_name" | grep -qE '^(POSTGRES_|N8N_BASIC_AUTH_|N8N_HOST|N8N_PORT|N8N_PROTOCOL|WEBHOOK_URL|GENERIC_TIMEZONE|N8N_ENCRYPTION_KEY|N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS|N8N_RUNNERS_ENABLED|DB_)'; then
                    log_error "Cannot remove system variable: $var_name"
                    sleep 2
                else
                    if ! grep -q "^${var_name}=" .env; then
                        log_error "Variable $var_name not found"
                        sleep 2
                    else
                        # Backup files
                        cp .env .env.backup
                        cp docker-compose.yml docker-compose.yml.backup
                        
                        # Remove from .env file
                        sed -i "/^${var_name}=/d" .env
                        
                        # Remove from docker-compose.yml
                        sed -i "/- ${var_name}=\${${var_name}}/d" docker-compose.yml
                        
                        log_success "Variable removed successfully"
                        printf "\nRecreate services now to apply changes? (y/n): "
                        read recreate_choice
                        if [[ "$recreate_choice" =~ ^[Yy]$ ]]; then
                            recreate_services
                        else
                            log_warn "Run 'Recreate Services' option for changes to take effect"
                            sleep 2
                        fi
                    fi
                fi
                ;;
            0)
                return
                ;;
            *)
                log_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# Main menu
show_main_menu() {
    local status=$(get_status)
    
    print_header
    
    case $status in
        "not_installed")
            printf "${YELLOW}Status:${NC} Not installed\n\n"
            printf "1) ${GREEN}Deploy n8n${NC} - Install or restore from backup\n"
            ;;
        "running")
            printf "${GREEN}Status:${NC} Running ✓\n\n"
            printf "1) ${CYAN}Manage n8n${NC} - Access management menu\n"
            printf "2) ${YELLOW}Stop n8n${NC} - Stop all services\n"
            printf "3) ${RED}Uninstall n8n${NC} - Remove installation\n"
            ;;
        "stopped")
            printf "${YELLOW}Status:${NC} Stopped\n\n"
            printf "1) ${GREEN}Start n8n${NC} - Start all services\n"
            printf "2) ${CYAN}Manage n8n${NC} - Access management menu\n"
            printf "3) ${RED}Uninstall n8n${NC} - Remove installation\n"
            ;;
    esac
    
    printf "0) Quit\n"
    printf "\n"
    printf "Select option: "
}

# Deploy n8n (installation logic from original script)
deploy_n8n() {
    log_function_start "deploy_n8n"
    log_info "Starting n8n deployment..."
    log_debug "N8N_DIR: $N8N_DIR"
    log_debug "GLOBAL_BACKUP_DIR: $GLOBAL_BACKUP_DIR"
    
    # Check requirements
    log_info "Checking requirements..."
    
    # Install required packages including security tools
    log_info "Installing required packages and security tools..."
    if ! command -v docker &> /dev/null || ! command -v jq &> /dev/null || ! command -v ufw &> /dev/null || ! command -v fail2ban-client &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl gnupg jq openssl ufw fail2ban unattended-upgrades apt-listchanges
    fi
    
    # Install Docker if needed
    if ! command -v docker &> /dev/null; then
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker $USER
        rm get-docker.sh
        log_warn "You need to log out and back in for Docker permissions"
        log_info "Then run this script again"
        exit 0
    else
        log_info "Docker already installed: $(docker --version)"
    fi
    
    # Create directories
    log_info "Creating project structure..."
    mkdir -p "$N8N_DIR"/{.n8n,certs,scripts,logs}
    mkdir -p "$GLOBAL_BACKUP_DIR"
    cd "$N8N_DIR"
    
    # Check for available backups
    local backup_files=($(ls -t "$GLOBAL_BACKUP_DIR"/full_backup_*.tar.gz 2>/dev/null))
    if [ ${#backup_files[@]} -gt 0 ]; then
        log_warn "Found ${#backup_files[@]} existing n8n backup(s):"
        printf "\n"
        
        # Show all backup files with details
        for i in "${!backup_files[@]}"; do
            backup_file="${backup_files[$i]}"
            filename=$(basename "$backup_file")
            timestamp=$(echo "$filename" | sed 's/full_backup_//;s/.tar.gz//')
            size=$(du -h "$backup_file" | cut -f1)
            printf "%d) %s (Size: %s)\n" $((i+1)) "$timestamp" "$size"
        done
        printf "%d) Skip - Fresh installation\n" $((${#backup_files[@]}+1))
        printf "\n"
        
        read -p "Select backup to restore (1-$((${#backup_files[@]}+1))): " RESTORE_CHOICE
        
        if [[ "$RESTORE_CHOICE" =~ ^[0-9]+$ ]] && [ "$RESTORE_CHOICE" -ge 1 ] && [ "$RESTORE_CHOICE" -le ${#backup_files[@]} ]; then
            RESTORE_BACKUP="${backup_files[$((RESTORE_CHOICE-1))]}"
            log_info "Will restore from backup: $(basename "$RESTORE_BACKUP")"
            
            # Extract backup to temporary location for inspection
            TEMP_DIR=$(mktemp -d)
            cd "$TEMP_DIR"
            tar -xzf "$RESTORE_BACKUP"
            
            # Restore configuration files
            if [ -f "config_"*.tar.gz ]; then
                tar -xzf config_*.tar.gz
                if [ -f ".env" ]; then
                    cp ".env" "$N8N_DIR/.env"
                    log_info "Restored environment configuration from backup"
                fi
                if [ -f "docker-compose.yml" ]; then
                    cp "docker-compose.yml" "$N8N_DIR/docker-compose.yml"
                    log_info "Restored docker-compose.yml configuration"
                fi
                if [ -f "nginx.conf" ]; then
                    cp "nginx.conf" "$N8N_DIR/nginx.conf"
                    log_info "Restored nginx configuration"
                fi
                if [ -d "certs" ]; then
                    cp -r "certs"/* "$N8N_DIR/certs/" 2>/dev/null || true
                    log_info "Restored SSL certificates"
                fi
            fi
            
            # Restore n8n data
            if [ -f "n8n_data_"*.tar.gz ]; then
                tar -xzf n8n_data_*.tar.gz
                if [ -d ".n8n" ]; then
                    cp -r ".n8n"/* "$N8N_DIR/.n8n/" 2>/dev/null || true
                    log_info "Restored n8n data from backup"
                fi
            fi
            
            # Set flag for database restoration
            local postgres_data_file=$(ls "postgres_data_"*.tar.gz 2>/dev/null | head -1)
            if [ -n "$postgres_data_file" ] && [ -f "$postgres_data_file" ]; then
                RESTORE_DATABASE_VOLUME="$TEMP_DIR/$postgres_data_file"
                log_info "Database volume backup found - will restore before containers start"
                log_debug "Database restoration file: $postgres_data_file"
            elif [ -f "postgres_"*.sql ]; then
                RESTORE_DATABASE_SQL="$TEMP_DIR/postgres_"*.sql
                log_info "Database SQL backup found - will restore after containers start"
            fi
            
            # Restore security components from backup during installation
            restore_security_components "$TEMP_DIR" "$N8N_DIR"
            
            # Clean up temp directory will be done later
            # rm -rf "$TEMP_DIR"
        else
            log_info "Proceeding with fresh installation"
        fi
    fi
    
    # Handle certificates after restoration
    if [ ! -f "$N8N_DIR/certs/n8n.crt" ]; then
        # No certificates in backup - generate fresh ones
        generate_ssl_certificate "$N8N_DIR/certs" "$N8N_DIR/certs/n8n.key" "$N8N_DIR/certs/n8n.crt"
    elif [ -n "${RESTORE_BACKUP:-}" ]; then
        # Certificates were restored from backup - check if they need updating
        log_info "Checking restored certificates for hostname/IP compatibility..."
        
        # Check if certificate type is self-signed (not Let's Encrypt)
        local cert_type=$(grep "^CERTIFICATE_TYPE=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2)
        if [ "$cert_type" != "letsencrypt" ]; then
            # Self-signed certificate - check for IP mismatch
            local current_ips=($(hostname -I | tr ' ' '\n' | grep -v '^127\.' | grep -v '^$'))
            local cert_ips=$(openssl x509 -in "$N8N_DIR/certs/n8n.crt" -text -noout 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | grep -oE 'IP:[0-9.]+' | cut -d: -f2 || true)
            
            local ip_mismatch=false
            if [ -n "$cert_ips" ]; then
                # Check if any current IPs are missing from certificate
                for current_ip in "${current_ips[@]}"; do
                    if ! echo "$cert_ips" | grep -q "$current_ip"; then
                        ip_mismatch=true
                        log_warn "Current IP $current_ip not found in restored certificate"
                        break
                    fi
                done
            else
                # Certificate has no IP SANs, but we have IPs - regenerate
                ip_mismatch=true
                log_warn "Restored certificate has no IP addresses in SAN extensions"
            fi
            
            if [ "$ip_mismatch" = "true" ]; then
                log_info "IP address mismatch detected - regenerating self-signed certificate with current IP addresses"
                # Backup old certificate
                cp "$N8N_DIR/certs/n8n.crt" "$N8N_DIR/certs/n8n.crt.backup.$(date +%Y%m%d_%H%M%S)"
                cp "$N8N_DIR/certs/n8n.key" "$N8N_DIR/certs/n8n.key.backup.$(date +%Y%m%d_%H%M%S)"
                
                # Generate new certificate with current IPs
                generate_ssl_certificate "$N8N_DIR/certs" "$N8N_DIR/certs/n8n.key" "$N8N_DIR/certs/n8n.crt"
                log_success "Certificate regenerated with current IP addresses: ${current_ips[*]}"
            else
                log_success "Restored certificate is compatible with current hostname/IP"
            fi
        else
            log_info "Let's Encrypt certificate restored - domain-based, no IP dependency"
        fi
    fi
    
    # Create environment file if not restored
    if [ ! -f "$N8N_DIR/.env" ]; then
        log_info "Creating environment configuration..."
        
        # Get timezone
        TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
        
        # Generate credentials
        N8N_BASIC_AUTH_USER="admin"
        read -s -p "Enter password for n8n admin user: " N8N_BASIC_AUTH_PASSWORD
        echo
        read -s -p "Confirm password: " PASSWORD_CONFIRM
        echo
        
        if [ "$N8N_BASIC_AUTH_PASSWORD" != "$PASSWORD_CONFIRM" ]; then
            log_error "Passwords do not match"
            exit 1
        fi
        
        # Generate encryption key
        N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
        
        # Create .env file
        cat > "$N8N_DIR/.env" << EOF
# n8n Configuration
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
N8N_HOST=0.0.0.0
N8N_PORT=5678
N8N_PROTOCOL=https
WEBHOOK_URL=https://localhost/
GENERIC_TIMEZONE=$TIMEZONE
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
N8N_RUNNERS_ENABLED=true

# Database Configuration
POSTGRES_USER=n8n
POSTGRES_PASSWORD=$(openssl rand -base64 32)
POSTGRES_DB=n8n
EOF
        chmod 600 "$N8N_DIR/.env"
    fi
    
    # Create docker-compose.yml if not restored
    if [ ! -f "$N8N_DIR/docker-compose.yml" ]; then
        log_info "Creating docker-compose.yml..."
        cat > "$N8N_DIR/docker-compose.yml" << 'EOF'

services:
  postgres:
    image: postgres:15
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: unless-stopped
    environment:
      - N8N_BASIC_AUTH_ACTIVE=${N8N_BASIC_AUTH_ACTIVE}
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=${N8N_PORT}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - WEBHOOK_URL=${WEBHOOK_URL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}
      - N8N_RUNNERS_ENABLED=${N8N_RUNNERS_ENABLED}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - ./.n8n:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3

  nginx:
    image: nginx:stable
    restart: unless-stopped
    ports:
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
      - ./logs:/var/log/nginx
    depends_on:
      - n8n
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  postgres_data:

networks:
  default:
    name: n8n_network
EOF
fi
    
    # Create nginx configuration with rate limiting
    log_info "Creating nginx configuration with security features..."
    cat > "$N8N_DIR/nginx.conf" << 'EOF'
events {
    worker_connections 1024;
}

http {
    # Rate limiting zones
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=api:10m rate=30r/s;
    limit_req_zone $binary_remote_addr zone=auth:10m rate=5r/m;
    limit_conn_zone $binary_remote_addr zone=addr:10m;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # Logging with enhanced format for fail2ban
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;
    
    upstream n8n {
        server n8n:5678;
    }

    server {
        listen 443 ssl http2;
        server_name _;

        ssl_certificate /etc/nginx/certs/n8n.crt;
        ssl_certificate_key /etc/nginx/certs/n8n.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
        ssl_prefer_server_ciphers off;
        ssl_session_timeout 1d;
        ssl_session_cache shared:SSL:50m;
        ssl_stapling on;
        ssl_stapling_verify on;

        client_max_body_size 100M;
        
        # Connection limiting
        limit_conn addr 100;
        
        # Health check endpoint (no rate limiting)
        location /nginx-health {
            access_log off;
            return 200 "healthy";
            add_header Content-Type text/plain;
        }
        
        # Authentication endpoints (strict rate limiting)
        location ~ ^/(rest/login|api/v1/auth) {
            limit_req zone=auth burst=2 nodelay;
            limit_req_status 429;
            
            proxy_pass http://n8n;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_buffering off;
            proxy_read_timeout 3600s;
        }
        
        # API endpoints (moderate rate limiting)
        location ~ ^/api/ {
            limit_req zone=api burst=20 nodelay;
            limit_req_status 429;
            
            proxy_pass http://n8n;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_buffering off;
            proxy_read_timeout 3600s;
        }
        
        # Webhook endpoints (higher rate limit for webhooks)
        location ~ ^/webhook/ {
            limit_req zone=api burst=50 nodelay;
            limit_req_status 429;
            
            proxy_pass http://n8n;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_buffering off;
            proxy_read_timeout 3600s;
        }

        # Default location (general rate limiting)
        location / {
            limit_req zone=general burst=20 nodelay;
            limit_req_status 429;
            
            proxy_pass http://n8n;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_buffering off;
            proxy_read_timeout 3600s;
        }
    }
}
EOF
    
    # Create systemd service
    log_info "Creating systemd service..."
    sudo tee /etc/systemd/system/n8n.service > /dev/null << EOF
[Unit]
Description=n8n workflow automation
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$N8N_DIR
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable n8n.service
    log_info "Systemd service created and enabled"
    
    # Setup cron jobs
    log_info "Setting up automated tasks..."
    
    # Create enhanced cron script with security updates
    mkdir -p "$N8N_DIR/scripts"
    cat > "$N8N_DIR/scripts/cron-tasks.sh" <<'EOF'
#!/bin/bash
# Automated maintenance and security tasks for n8n

N8N_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$N8N_DIR/logs/cron.log"
SCRIPT_DIR="$(dirname "$0")"

mkdir -p "$(dirname "$LOG_FILE")"

echo "[$(date)] Running maintenance tasks..." >> "$LOG_FILE"

# Source the main script for functions (create a minimal backup function)
create_backup() {
    cd "$N8N_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="${GLOBAL_BACKUP_DIR:-$HOME/n8n-backups}"
    mkdir -p "$backup_dir"
    
    # Stop containers for consistent backup
    docker compose down
    
    # Create backup
    TEMP_DIR=$(mktemp -d)
    
    # Backup database
    if docker volume ls --format '{{.Name}}' | grep -q "n8n_postgres_data"; then
        docker run --rm -v n8n_postgres_data:/source -v "$TEMP_DIR":/backup alpine \
            tar -czf /backup/postgres_data_${timestamp}.tar.gz -C /source .
    fi
    
    # Backup n8n data
    if [ -d "$N8N_DIR/.n8n" ]; then
        tar -czf "$TEMP_DIR/n8n_data_${timestamp}.tar.gz" -C "$N8N_DIR" .n8n
    fi
    
    # Backup configs
    tar -czf "$TEMP_DIR/config_${timestamp}.tar.gz" \
        docker-compose.yml nginx.conf .env certs/ 2>/dev/null || true
    
    # Create combined backup
    cd "$TEMP_DIR"
    tar -czf "$backup_dir/full_backup_${timestamp}.tar.gz" .
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    
    # Keep only last 5 backups
    cd "$backup_dir"
    ls -t full_backup_*.tar.gz | tail -n +6 | xargs -r rm
    
    # Restart containers
    cd "$N8N_DIR"
    docker compose up -d
    
    echo "Backup created: $backup_dir/full_backup_${timestamp}.tar.gz"
}

# Daily backup
echo "[$(date)] Starting daily backup..." >> "$LOG_FILE"
create_backup >> "$LOG_FILE" 2>&1

# Certificate check and renewal
CERT_TYPE=$(grep "^CERTIFICATE_TYPE=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "self-signed")
DNS_PROVIDER=$(grep "^LETSENCRYPT_DNS_PROVIDER=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "")
CERT_FILE="$N8N_DIR/certs/n8n.crt"

if [ "$CERT_TYPE" = "letsencrypt" ]; then
    # Check certificate expiry
    if [ -f "$CERT_FILE" ]; then
        EXPIRES_IN=$(( ($(date -d "$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
        
        if [ "$DNS_PROVIDER" = "manual" ]; then
            # Manual DNS provider - log reminder
            if [ "$EXPIRES_IN" -lt 7 ]; then
                echo "[$(date)] WARNING: Let's Encrypt certificate expires in $EXPIRES_IN days!" >> "$LOG_FILE"
                echo "[$(date)] Manual DNS renewal required. Run: ./n8n-master.sh → Manage → SSL Settings → Renew" >> "$LOG_FILE"
            elif [ "$EXPIRES_IN" -lt 30 ]; then
                echo "[$(date)] INFO: Let's Encrypt certificate expires in $EXPIRES_IN days" >> "$LOG_FILE"
                echo "[$(date)] Consider scheduling manual renewal soon" >> "$LOG_FILE"
            fi
        else
            # Automated renewal for API-based providers
            echo "[$(date)] Checking Let's Encrypt certificate (expires in $EXPIRES_IN days)..." >> "$LOG_FILE"
            if [ "$EXPIRES_IN" -lt 30 ]; then
                certbot renew --quiet --deploy-hook "cd $N8N_DIR && docker compose restart nginx" >> "$LOG_FILE" 2>&1
            fi
        fi
    fi
elif [ -f "$CERT_FILE" ]; then
    # Self-signed certificate check
    EXPIRES_IN=$(( ($(date -d "$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
    if [ "$EXPIRES_IN" -lt 30 ]; then
        echo "[$(date)] Certificate expires in $EXPIRES_IN days, renewing..." >> "$LOG_FILE"
        cd "$N8N_DIR"
        # Generate new self-signed certificate
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout certs/n8n.key -out certs/n8n.crt \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=n8n.local" \
            2>/dev/null
        docker compose restart nginx
    fi
fi

# Check for n8n updates if enabled
AUTO_UPDATE_N8N=$(grep "^AUTO_UPDATE_N8N=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "false")
if [ "$AUTO_UPDATE_N8N" = "true" ]; then
    # Check if it's Sunday (weekly update)
    if [ "$(date +%u)" = "7" ]; then
        echo "[$(date)] Checking for n8n updates..." >> "$LOG_FILE"
        
        # Create backup before update
        echo "[$(date)] Creating pre-update backup..." >> "$LOG_FILE"
        create_backup >> "$LOG_FILE" 2>&1
        
        # Update n8n
        cd "$N8N_DIR"
        docker compose pull n8n >> "$LOG_FILE" 2>&1
        docker compose up -d n8n >> "$LOG_FILE" 2>&1
        
        echo "[$(date)] n8n update complete" >> "$LOG_FILE"
    fi
fi

# Security updates check (runs daily)
AUTO_UPDATES=$(grep "^AUTO_UPDATES_ENABLED=" "$N8N_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "disabled")
if [ "$AUTO_UPDATES" != "disabled" ]; then
    echo "[$(date)] Running security updates check..." >> "$LOG_FILE"
    
    # Update package lists
    sudo apt-get update >> "$LOG_FILE" 2>&1
    
    if [ "$AUTO_UPDATES" = "security" ] || [ "$AUTO_UPDATES" = "security+n8n" ]; then
        # Security updates only
        sudo unattended-upgrade -d >> "$LOG_FILE" 2>&1
    elif [ "$AUTO_UPDATES" = "all" ]; then
        # All updates
        sudo apt-get upgrade -y >> "$LOG_FILE" 2>&1
    fi
fi

# Log rotation
find "$N8N_DIR/logs" -name "*.log" -size +100M -exec gzip {} \;
find "$N8N_DIR/logs" -name "*.log.gz" -mtime +30 -delete

# Check fail2ban status
if systemctl is-active --quiet fail2ban; then
    echo "[$(date)] fail2ban is active" >> "$LOG_FILE"
    # Log any banned IPs
    sudo fail2ban-client status n8n-auth 2>/dev/null | grep "Banned IP" >> "$LOG_FILE" || true
fi

echo "[$(date)] Maintenance tasks complete" >> "$LOG_FILE"
EOF
    
    chmod +x "$N8N_DIR/scripts/cron-tasks.sh"
    
    # Add to crontab - using the same method as gold standard
    CRONLINE="0 3 * * * $N8N_DIR/scripts/cron-tasks.sh"
    if ! crontab -l 2>/dev/null | grep -qF "$CRONLINE"; then
        (crontab -l 2>/dev/null || true; echo "$CRONLINE") | crontab -
    fi
    
    log_info "Cron jobs configured"
    
    
    # Configure initial security settings
    log_info "Applying security configurations..."
    
    # Configure firewall
    configure_firewall
    
    # Configure fail2ban
    configure_fail2ban
    
    # Enable default security updates
    if ! grep -q "^AUTO_UPDATES_ENABLED=" "$N8N_DIR/.env"; then
        echo "AUTO_UPDATES_ENABLED=security" >> "$N8N_DIR/.env"
        echo "AUTO_UPDATE_N8N=false" >> "$N8N_DIR/.env"
        
        # Configure unattended-upgrades for security only by default
        sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null << 'EOFA'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOFA
        
        sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'EOFB'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOFB
        
        log_success "Security updates enabled by default"
    fi
    
    # Start services
    log_info "Starting n8n services..."
    
    cd "$N8N_DIR"
    
    # Check for existing volumes
    if docker volume ls --format '{{.Name}}' | grep -q "n8n_postgres_data"; then
        log_warn "Found existing PostgreSQL data volume: n8n_postgres_data"
        log_info "Your previous database will be reused automatically"
    fi
    
    # Restore database volume BEFORE starting containers (if backup exists)
    if [ -n "${RESTORE_DATABASE_VOLUME:-}" ] && [ -f "$RESTORE_DATABASE_VOLUME" ]; then
        BACKUP_SIZE=$(du -h "$RESTORE_DATABASE_VOLUME" | cut -f1)
        log_info "Found database volume backup (${BACKUP_SIZE})"
        log_info "Restoring PostgreSQL volume before starting containers..."
        
        # Remove existing volume and recreate
        docker volume rm n8n_postgres_data 2>/dev/null || true
        docker volume create n8n_postgres_data
        
        # Restore data to volume - use specific filename instead of wildcard
        POSTGRES_FILE=$(basename "$RESTORE_DATABASE_VOLUME")
        log_debug "Restoring database from: $POSTGRES_FILE"
        docker run --rm -v n8n_postgres_data:/target -v "$(dirname "$RESTORE_DATABASE_VOLUME")":/backup alpine \
            tar -xzf "/backup/$POSTGRES_FILE" -C /target
        
        log_success "Database volume restored successfully"
        
        # Clean up temp directory
        if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
            rm -rf "$TEMP_DIR"
        fi
    fi
    
    # Pull and start services
    docker compose pull
    docker compose up -d
    
    # Wait for services to be ready
    log_info "Waiting for services to be ready..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if docker compose ps | grep -q "healthy"; then
            break
        fi
        printf "."
        sleep 2
        ((attempt++))
    done
    printf "\n"
    
    # Fallback for old SQL format backups (after containers are running)
    if [ -n "${RESTORE_DATABASE_SQL:-}" ] && [ -f "$RESTORE_DATABASE_SQL" ]; then
        BACKUP_SIZE=$(du -h "$RESTORE_DATABASE_SQL" | cut -f1)
        log_info "Found database SQL backup (${BACKUP_SIZE}) - using legacy restore method"
        log_info "Waiting for PostgreSQL to be ready..."
        
        # Wait for PostgreSQL to be ready
        local wait_attempts=0
        while [ $wait_attempts -lt 10 ]; do
            if docker compose exec -T postgres pg_isready -U n8n >/dev/null 2>&1; then
                break
            fi
            sleep 2
            ((wait_attempts++))
        done
        
        # Restore using SQL
        if docker compose exec -T postgres psql -U n8n -c "SELECT 1" >/dev/null 2>&1; then
            docker compose exec -T postgres psql -U n8n -d postgres -c "DROP DATABASE IF EXISTS n8n;"
            docker compose exec -T postgres psql -U n8n -d postgres -c "CREATE DATABASE n8n;"
            docker compose exec -i postgres psql -U n8n -d n8n < "$RESTORE_DATABASE_SQL"
            log_success "Database restored from SQL backup"
        else
            log_error "PostgreSQL not ready - manual restore required"
            log_info "Backup available at: $RESTORE_DATABASE_SQL"
        fi
        
        # Clean up temp directory
        if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
            rm -rf "$TEMP_DIR"
        fi
    fi
    
    # Show status
    printf "\n"
    docker compose ps
    printf "\n"
    
    # Show completion message
    show_deployment_complete
    
    # Show security status
    printf "\n${GREEN}Security Features Enabled:${NC}\n"
    printf "─────────────────────────────────────────────────────────────\n"
    printf "✓ Firewall configured (UFW) - Ports 22, 443 only\n"
    printf "✓ Rate limiting active - Protection against abuse\n"
    printf "✓ fail2ban configured - Intrusion prevention\n"
    printf "✓ Automatic security updates enabled\n"
    printf "✓ Enhanced SSL with strong ciphers\n"
    printf "\nAccess Security Settings: ./n8n-master.sh → Manage → Security Settings\n"
    
    log_function_end "deploy_n8n"
}

# Uninstall n8n
uninstall_n8n() {
    log_function_start "uninstall_n8n"
    print_header
    log_info "Starting n8n uninstall process"
    log_debug "N8N_DIR: $N8N_DIR"
    log_debug "GLOBAL_BACKUP_DIR: $GLOBAL_BACKUP_DIR"
    
    log_info "This will remove:"
    printf "  - Docker containers (n8n, postgres, nginx)\n"
    printf "  - Systemd service\n"
    printf "  - Cron jobs\n"
    printf "  - Installation directory: $N8N_DIR\n"
    printf "\n"
    
    # Ask about data preservation
    printf "${YELLOW}Choose uninstall type:${NC}\n"
    printf "1) Create backup and uninstall (backup all data then remove everything)\n"
    printf "2) Uninstall without backup (remove everything immediately)\n"
    printf "3) Cancel\n"
    printf "\nSelect option (1-3): "
    read UNINSTALL_TYPE
    
    case $UNINSTALL_TYPE in
        1)
            REMOVE_VOLUMES="-v"
            PRESERVE_DATA="yes"
            log_info "Will create backup before removing everything"
            ;;
        2)
            REMOVE_VOLUMES="-v"
            PRESERVE_DATA="no"
            log_warn "Will remove ALL data including workflows and databases!"
            printf "\n"
            printf "Are you SURE you want to delete all data? Type 'yes' to confirm: "
            read CONFIRM
            if [ "$CONFIRM" != "yes" ]; then
                log_info "Uninstall cancelled"
                return
            fi
            ;;
        3)
            log_info "Uninstall cancelled"
            return
            ;;
        *)
            log_error "Invalid option"
            return
            ;;
    esac
    
    printf "\n"
    log_info "Starting uninstall process..."
    
    # Handle data preservation using unified backup method
    if [ "$PRESERVE_DATA" = "yes" ]; then
        log_info "Creating standard backup before uninstall..."
        
        # Use the built-in backup function without restarting containers
        if create_backup no-restart; then
            # Find the most recent backup
            LATEST_BACKUP=$(ls -t "$GLOBAL_BACKUP_DIR"/full_backup_*.tar.gz 2>/dev/null | head -n1)
            if [ -f "$LATEST_BACKUP" ]; then
                BACKUP_SIZE=$(du -h "$LATEST_BACKUP" | cut -f1)
                log_success "Standard backup created successfully (${BACKUP_SIZE})"
                log_info "Backup location: $LATEST_BACKUP"
                PRESERVE_BACKUP="$LATEST_BACKUP"
            else
                log_error "Backup creation failed - backup file not found"
                printf "\n${RED}Backup creation failed!${NC}\n"
                printf "Continue with uninstall anyway? (yes/no): "
                read CONTINUE_UNINSTALL
                if [ "$CONTINUE_UNINSTALL" != "yes" ]; then
                    log_info "Uninstall cancelled - your data is safe"
                    return
                fi
            fi
        else
            log_error "Failed to create backup"
            printf "\n${RED}Backup creation failed!${NC}\n"
            printf "Continue with uninstall anyway? (yes/no): "
            read CONTINUE_UNINSTALL
            if [ "$CONTINUE_UNINSTALL" != "yes" ]; then
                log_info "Uninstall cancelled - your data is safe"
                return
            fi
        fi
        
        # Note about volume removal
        log_info "Docker volumes will be removed during uninstall"
        
        printf "\n"
        if [ -n "${PRESERVE_BACKUP:-}" ]; then
            log_warn "Data preserved in standard backup: $(basename "$PRESERVE_BACKUP")"
        fi
        log_info "Docker volumes removed (data preserved in backup)"
        log_info "All backups available at: $GLOBAL_BACKUP_DIR"
    fi
    
    # Stop and remove containers (backup function already stopped them)
    if [ -d "$N8N_DIR" ]; then
        log_info "Removing Docker containers..."
        cd "$N8N_DIR"
        if [ -f "docker-compose.yml" ]; then
            docker compose down $REMOVE_VOLUMES 2>/dev/null || true
        fi
    fi
    
    # Remove systemd service
    if [ -f "/etc/systemd/system/n8n.service" ]; then
        log_info "Removing systemd service..."
        sudo systemctl stop n8n.service 2>/dev/null || true
        sudo systemctl disable n8n.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/n8n.service
        sudo systemctl daemon-reload
    fi
    
    # Remove cron jobs
    log_info "Removing cron jobs..."
    crontab -l 2>/dev/null | grep -v "$N8N_DIR" | crontab - || true
    
    # Remove installation directory
    log_info "Removing installation directory..."
    rm -rf "$N8N_DIR"
    
    # Clean up Docker resources if not preserving
    if [ "$PRESERVE_DATA" = "no" ]; then
        log_info "Cleaning up Docker resources..."
        
        # Remove volumes
        docker volume ls --format '{{.Name}}' | grep -E '^n8n' | xargs -r docker volume rm 2>/dev/null || true
        
        # Remove network
        docker network rm n8n_network 2>/dev/null || true
        
        # Offer to prune images
        printf "\n"
        printf "Remove unused Docker images to free space? (y/n): "
        read PRUNE
        if [ "$PRUNE" = "y" ]; then
            docker image prune -a -f
        fi
    fi
    
    # Summary
    printf "\n"
    printf "${GREEN}════════════════════════════════════════${NC}\n"
    printf "${GREEN}n8n has been uninstalled successfully!${NC}\n"
    printf "${GREEN}════════════════════════════════════════${NC}\n"
    
    if [ "$PRESERVE_DATA" = "yes" ]; then
        printf "\n"
        printf "Data preserved:\n"
        if [ -n "${PRESERVE_BACKUP:-}" ]; then
            printf "  - Standard backup: $(basename "$PRESERVE_BACKUP")\n"
        fi
        printf "  - All backups: $GLOBAL_BACKUP_DIR\n"
        printf "\n"
        printf "All data removed from system (preserved in backup).\n"
    else
        printf "\n"
        printf "All data has been removed.\n"
    fi
    
    printf "\n"
    printf "To reinstall n8n, run this script again.\n"
    printf "\n"
    printf "Press Enter to exit..."
    read
    log_function_end "uninstall_n8n"
}

# Start n8n
start_n8n() {
    log_info "Starting n8n services..."
    cd "$N8N_DIR"
    docker compose up -d
    sleep 3
    docker compose ps
    log_success "n8n services started"
    printf "\nPress Enter to continue..."
    read
}

# Stop n8n
stop_n8n() {
    log_info "Stopping n8n services..."
    cd "$N8N_DIR"
    docker compose down
    log_success "n8n services stopped"
    printf "\nPress Enter to continue..."
    read
}

# Show deployment complete message with proper color codes
show_deployment_complete() {
    local admin_pass=$(grep N8N_BASIC_AUTH_PASSWORD "$N8N_DIR/.env" | cut -d'=' -f2)
    local ip_addr=$(hostname -I | awk '{print $1}')
    
    # Check if data was restored
    if [ -n "${RESTORE_BACKUP:-}" ]; then
        printf "\n"
        log_info "Restored from backup: $(basename "$RESTORE_BACKUP")"
        log_info "1. Access n8n with your restored admin password"
        log_info "2. All workflows should be intact from the backup"
        log_info "3. Additional backups available via './n8n-master.sh restore'"
    fi
    
    printf "\n"
    printf "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║           n8n Installation Complete! 🎉                    ║${NC}\n"
    printf "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
    
    printf "${GREEN}Access Methods:${NC}\n"
    printf "─────────────────────────────────────────────────────────────\n"
    printf "1. ${BLUE}Local Access:${NC}\n"
    printf "   https://localhost\n"
    printf "\n"
    printf "2. ${BLUE}SSH Tunnel:${NC}\n"
    printf "   ssh -L 8443:localhost:443 %s@%s\n" "$USER" "$ip_addr"
    printf "   Then visit: https://localhost:8443\n"
    printf "\n"
    printf "3. ${BLUE}Internal Network:${NC}\n"
    printf "   https://%s (if firewall allows)\n" "$ip_addr"
    printf "   https://n8n.local (if DNS configured)\n"
    printf "\n"
    
    printf "${GREEN}Credentials:${NC}\n"
    printf "─────────────────────────────────────────────────────────────\n"
    printf "Username: ${YELLOW}admin${NC}\n"
    printf "Password: ${YELLOW}%s${NC}\n" "$admin_pass"
    printf "\n"
    
    printf "${GREEN}Management:${NC}\n"
    printf "─────────────────────────────────────────────────────────────\n"
    printf "Master script: ${BLUE}./n8n-master.sh${NC}\n"
    printf "\n"
    printf "Quick commands:\n"
    printf "  ${BLUE}./n8n-master.sh manage${NC}   - Interactive management menu\n"
    printf "  ${BLUE}./n8n-master.sh backup${NC}   - Create backup\n"
    printf "  ${BLUE}./n8n-master.sh restore${NC}  - Restore from backup\n"
    printf "  ${BLUE}./n8n-master.sh status${NC}   - Show service status\n"
    printf "  ${BLUE}./n8n-master.sh logs${NC}     - View logs\n"
    printf "  ${BLUE}./n8n-master.sh health${NC}   - Check system health\n"
    printf "\n"
    
    printf "${GREEN}File Locations:${NC}\n"
    printf "─────────────────────────────────────────────────────────────\n"
    printf "Project:      %s\n" "$N8N_DIR"
    printf "Data:         %s/.n8n\n" "$N8N_DIR"
    printf "Backups:      %s\n" "$GLOBAL_BACKUP_DIR"
    printf "Certificates: %s/certs\n" "$N8N_DIR"
    printf "Configs:      %s/{docker-compose.yml,nginx.conf,.env}\n" "$N8N_DIR"
    printf "\n"
    
    printf "${GREEN}Features Configured:${NC}\n"
    printf "─────────────────────────────────────────────────────────────\n"
    printf "✓ Self-signed SSL certificate (10-year validity)\n"
    printf "✓ Automated daily backups (3 AM)\n"
    printf "✓ Certificate monitoring and renewal\n"
    printf "✓ Systemd service (auto-start on boot)\n"
    printf "✓ Health monitoring\n"
    printf "✓ Log rotation\n"
    printf "✓ Environment variable management\n"
    printf "✓ LAN accessible (port 443)\n"
    printf "✓ Firewall protection (UFW)\n"
    printf "✓ Rate limiting & DDoS protection\n"
    printf "✓ Intrusion prevention (fail2ban)\n"
    printf "✓ Automatic security updates\n"
    printf "\n"
    
    printf "${YELLOW}⚠️  Browser Warning:${NC}\n"
    printf "You'll see a certificate warning on first access - this is\n"
    printf "normal for self-signed certificates. Click \"Advanced\" and\n"
    printf "\"Proceed\" to continue.\n"
    printf "\n"
    
    printf "${GREEN}Next Steps:${NC}\n"
    printf "1. Access n8n and complete the setup wizard\n"
    printf "2. Configure your workflows\n"
    printf "3. Use management menu: ${BLUE}./n8n-master.sh manage${NC}\n"
    printf "\n"
    printf "For help: ${BLUE}./n8n-master.sh${NC}\n"
}

# Main script logic
main() {
    # Initialize logging
    log_info "n8n Master Script v${SCRIPT_VERSION} started"
    log_debug "Script arguments: $*"
    log_debug "Working directory: $(pwd)"
    log_debug "User: $(whoami)"
    log_debug "Log file: $LOG_FILE"
    
    check_not_root
    
    # If command line argument provided
    if [ $# -gt 0 ]; then
        case "$1" in
            deploy)
                if is_n8n_installed; then
                    log_error "n8n is already installed at $N8N_DIR"
                    log_info "Use the uninstall option first if you want to reinstall"
                    exit 1
                fi
                deploy_n8n
                ;;
            uninstall)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                uninstall_n8n
                ;;
            manage)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                show_management_menu
                ;;
            backup)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                create_backup
                ;;
            restore)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                restore_backup
                ;;
            status)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                view_status
                ;;
            logs)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                view_logs
                ;;
            health)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                health_check
                ;;
            version)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                show_version
                ;;
            start)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                start_n8n
                ;;
            stop)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                stop_n8n
                ;;
            restart)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                restart_services
                ;;
            update)
                if ! is_n8n_installed; then
                    log_error "n8n is not installed"
                    exit 1
                fi
                update_n8n
                ;;
            *)
                log_error "Unknown command: $1"
                printf "Usage: $0 [deploy|uninstall|manage|backup|restore|status|logs|health|version|start|stop|restart|update]\n"
                exit 1
                ;;
        esac
    else
        # Interactive menu
        while true; do
            show_main_menu
            read choice
            
            case "$choice" in
                1)
                    case $(get_status) in
                        "not_installed") deploy_n8n ;;
                        "running") show_management_menu ;;
                        "stopped") start_n8n ;;
                    esac
                    ;;
                2)
                    case $(get_status) in
                        "running") stop_n8n ;;
                        "stopped") show_management_menu ;;
                    esac
                    ;;
                3)
                    if [ "$(get_status)" != "not_installed" ]; then
                        uninstall_n8n
                    fi
                    ;;
                0)
                    printf "\nGoodbye!\n"
                    exit 0
                    ;;
                *)
                    log_error "Invalid option"
                    sleep 1
                    ;;
            esac
        done
    fi
}

# Run main function
main "$@"
