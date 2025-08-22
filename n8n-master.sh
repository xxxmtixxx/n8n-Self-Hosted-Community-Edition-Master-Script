#!/bin/bash
# n8n Master Script - Deploy, Manage, and Uninstall
# Complete solution for n8n lifecycle management

set -euo pipefail

# Configuration
N8N_DIR="${N8N_DIR:-$HOME/n8n}"
GLOBAL_BACKUP_DIR="${GLOBAL_BACKUP_DIR:-$HOME/n8n-backups}"
COMPOSE_PROJECT_NAME="n8n"
SCRIPT_VERSION="2.0.0"
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
    
    # Backup configs
    log_info "Backing up configuration files..."
    tar -czf "$TEMP_DIR/config_${timestamp}.tar.gz" \
        docker-compose.yml nginx.conf .env certs/ 2>/dev/null || {
        log_warn "Some config files missing, backing up available files"
        tar -czf "$TEMP_DIR/config_${timestamp}.tar.gz" --ignore-failed-read \
            docker-compose.yml nginx.conf .env certs/ 2>/dev/null || true
    }
    
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
    
    while read -r line; do
        case "$line" in
            *postgres_data_*.tar.gz) postgres_found=true; log_debug "Found postgres data: $line" ;;
            *n8n_data_*.tar.gz) n8n_found=true; log_debug "Found n8n data: $line" ;;
            *config_*.tar.gz) config_found=true; log_debug "Found config data: $line" ;;
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
    
    if [ "$validation_errors" -gt 0 ]; then
        log_error "Backup validation failed: $validation_errors missing components"
        return 1
    fi
    
    # Check individual component integrity
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    if tar -xzf "$backup_file" 2>/dev/null; then
        # Test each sub-archive
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
        printf "10) Renew SSL Certificate\n"
        printf "11) Manage Environment Variables\n"
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
            10) renew_certificate ;;
            11) manage_env_vars ;;
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
}

# Renew certificate
renew_certificate() {
    log_info "Renewing self-signed certificate..."
    cd "$N8N_DIR"
    
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout certs/n8n.key.new \
        -out certs/n8n.crt.new \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=n8n.local" \
        2>/dev/null
    
    mv certs/n8n.key certs/n8n.key.old
    mv certs/n8n.crt certs/n8n.crt.old
    mv certs/n8n.key.new certs/n8n.key
    mv certs/n8n.crt.new certs/n8n.crt
    
    chmod 644 certs/n8n.crt
    chmod 600 certs/n8n.key
    
    docker compose restart nginx
    printf "${GREEN}Certificate renewed for another 10 years${NC}\n"
    sleep 2
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
    
    printf "q) Quit\n"
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
    
    # Install required packages
    if ! command -v docker &> /dev/null || ! command -v jq &> /dev/null; then
        log_info "Installing required packages..."
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl gnupg jq openssl
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
            
            # Clean up temp directory will be done later
            # rm -rf "$TEMP_DIR"
        else
            log_info "Proceeding with fresh installation"
        fi
    fi
    
    # Generate certificates
    if [ ! -f "$N8N_DIR/certs/n8n.crt" ]; then
        log_info "Creating self-signed certificate..."
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$N8N_DIR/certs/n8n.key" \
            -out "$N8N_DIR/certs/n8n.crt" \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=n8n.local" \
            2>/dev/null
        log_info "Self-signed certificate created (valid for 10 years)"
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
    
    # Create nginx configuration
    log_info "Creating nginx configuration..."
    cat > "$N8N_DIR/nginx.conf" << 'EOF'
events {
    worker_connections 1024;
}

http {
    upstream n8n {
        server n8n:5678;
    }

    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate /etc/nginx/certs/n8n.crt;
        ssl_certificate_key /etc/nginx/certs/n8n.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        client_max_body_size 100M;

        location / {
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
    
    # Create cron script first
    mkdir -p "$N8N_DIR/scripts"
    cat > "$N8N_DIR/scripts/cron-tasks.sh" <<'EOF'
#!/bin/bash
# Automated maintenance tasks for n8n

N8N_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$N8N_DIR/logs/cron.log"

mkdir -p "$(dirname "$LOG_FILE")"

echo "[$(date)] Running maintenance tasks..." >> "$LOG_FILE"

# Daily backup (keep last 7 days)
create_backup >> "$LOG_FILE" 2>&1

# Certificate check (renew if expires in 30 days)
CERT_FILE="$N8N_DIR/certs/n8n.crt"
if [ -f "$CERT_FILE" ]; then
    EXPIRES_IN=$(( ($(date -d "$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
    if [ "$EXPIRES_IN" -lt 30 ]; then
        echo "[$(date)] Certificate expires in $EXPIRES_IN days, renewing..." >> "$LOG_FILE"
        renew_certificate >> "$LOG_FILE" 2>&1
    fi
fi

# Log rotation
find "$N8N_DIR/logs" -name "*.log" -size +100M -exec gzip {} \;
find "$N8N_DIR/logs" -name "*.log.gz" -mtime +30 -delete

echo "[$(date)] Maintenance tasks complete" >> "$LOG_FILE"
EOF
    
    chmod +x "$N8N_DIR/scripts/cron-tasks.sh"
    
    # Add to crontab - using the same method as gold standard
    CRONLINE="0 3 * * * $N8N_DIR/scripts/cron-tasks.sh"
    if ! crontab -l 2>/dev/null | grep -qF "$CRONLINE"; then
        (crontab -l 2>/dev/null || true; echo "$CRONLINE") | crontab -
    fi
    
    log_info "Cron jobs configured"
    
    
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
                q|Q)
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
