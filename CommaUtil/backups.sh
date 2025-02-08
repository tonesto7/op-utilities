#!/bin/bash

###############################################################################
# Global Variables
###############################################################################
readonly BACKUPS_SCRIPT_VERSION="3.0.1"
readonly BACKUPS_SCRIPT_MODIFIED="2025-02-08"

# Device Backup Related Constants
readonly BACKUP_BASE_DIR="/data/device_backup"
readonly BACKUP_METADATA_FILE="metadata.json"
readonly MAX_BACKUP_COUNT=1
readonly BACKUP_DIRS=(
    "/home/comma/.ssh"
    "/persist/comma"
    "/data/params/d"
    "/data/commautil"
)

get_backup_location() {
    local backup_loc
    if [ -f "$NETWORK_CONFIG" ]; then
        backup_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG")
    fi
    echo "$backup_loc"
}

get_backup_job() {
    local backup_job
    if [ -f "$LAUNCH_ENV" ]; then # Changed from LAUNCH_ENV_FILE to LAUNCH_ENV
        backup_job=$(grep -A1 "^### Start CommaUtility Backup" "$LAUNCH_ENV")
    fi
    echo "$backup_job"
}

has_legacy_backup() {
    if [ -d "/data/ssh_backup" ] && [ -f "/data/ssh_backup/metadata.txt" ]; then
        return 0
    else
        return 1
    fi
}

###############################################################################
# Backup Status Functions
###############################################################################

display_backup_status_short() {
    print_info "│ Backup Status:"

    # Check network location configuration safely
    local backup_loc backup_job
    if [ -f "$NETWORK_CONFIG" ]; then
        backup_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG" 2>/dev/null)
    fi

    if [ -f "$LAUNCH_ENV" ]; then
        backup_job=$(grep -A1 "^### Start CommaUtility Backup" "$LAUNCH_ENV" 2>/dev/null)
    fi

    if [ -n "$backup_loc" ]; then
        local label protocol status
        label=$(echo "$backup_loc" | jq -r '.label // "Unknown"')
        protocol=$(echo "$backup_loc" | jq -r '.protocol // "Unknown"')

        status=$(if [ "$protocol" = "smb" ]; then
            test_smb_connection "$backup_loc"
        else
            test_ssh_connection "$backup_loc"
        fi)
        status=${status:-"Invalid"}

        if [ "$status" = "Valid" ]; then
            echo -e "│ ├─ Network: ${GREEN}$label (Connected)${NC}"
        else
            echo -e "│ ├─ Network: ${RED}$label (Disconnected)${NC}"
        fi

        if [ -n "$backup_job" ]; then
            echo -e "│ ├─ Auto-Backup: ${GREEN}Enabled${NC}"
        else
            echo -e "│ ├─ Auto-Backup: ${YELLOW}Disabled${NC}"
        fi
    else
        echo -e "│ ├─ Network: ${YELLOW}Not Configured${NC}"
        echo -e "│ ├─ Auto-Backup: ${RED}Not Available${NC}"
    fi

    # Find backup
    if [ ! -d "$BACKUP_BASE_DIR" ]; then
        echo -e "│ └─ ${RED}No backup found${NC}"
        return
    fi

    local latest_backup
    latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -c "%Y %n" {} \; 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2)

    if [ -n "$latest_backup" ] && [ -f "${latest_backup}/${BACKUP_METADATA_FILE}" ]; then
        local backup_timestamp backup_age_days backup_size

        # Safely parse the timestamp with error checking
        if backup_timestamp=$(jq -r '.timestamp' "${latest_backup}/${BACKUP_METADATA_FILE}" 2>/dev/null) &&
            [ -n "$backup_timestamp" ] && [ "$backup_timestamp" != "null" ]; then
            backup_age_days=$((($(date +%s) - $(date -d "$backup_timestamp" +%s)) / 86400))
            formatted_date=$(date -d "$backup_timestamp" "+%Y-%m-%d %H:%M" 2>/dev/null)
        else
            backup_timestamp=$(stat -c %y "$latest_backup")
            backup_age_days=0
            formatted_date=$(date -d "$backup_timestamp" "+%Y-%m-%d %H:%M" 2>/dev/null)
        fi

        backup_size=$(du -sh "$latest_backup" | cut -f1)

        # Get component counts with safe defaults
        local ssh_files=0 params_files=0 commautil_files=0

        # Use grep to count actual files in the backup directories instead of relying on metadata
        if [ -d "${latest_backup}/ssh" ]; then
            ssh_files=$(tar -tzf "${latest_backup}/ssh/backup.tar.gz" 2>/dev/null | wc -l)
        fi
        if [ -d "${latest_backup}/params" ]; then
            params_files=$(tar -tzf "${latest_backup}/params/backup.tar.gz" 2>/dev/null | wc -l)
        fi
        if [ -d "${latest_backup}/commautil" ]; then
            commautil_files=$(tar -tzf "${latest_backup}/commautil/backup.tar.gz" 2>/dev/null | wc -l)
        fi

        echo "│ ├─ Date: ${formatted_date}"
        if [ "$backup_age_days" -gt 30 ]; then
            echo -e "│ ├─ Age: ${YELLOW}${backup_age_days} days old${NC}"
        else
            echo -e "│ ├─ Age: ${GREEN}${backup_age_days} days old${NC}"
        fi
        echo "│ ├─ Size: $backup_size"
        echo "│ └─ Contents: SSH($ssh_files), Params($params_files), Config($commautil_files) files"
    else
        echo -e "│ └─ ${RED}No backup found${NC}"
    fi
}

###############################################################################
# Backup Management Functions
###############################################################################

# Create a backup of devices SSH, SSH Keys, params, and commautil
# Returns:
# - 0: Success
# - 1: Failure
backup_device() {
    local silent_mode="${1:-normal}"
    local device_id=$(get_device_id)
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="${device_id}_${timestamp}"
    local backup_dir="${BACKUP_BASE_DIR}/${backup_name}"

    # Only show progress message if not in silent mode
    [ "$silent_mode" != "silent" ] && print_info "Creating backup in ${backup_dir}..."

    # Remove any existing backup
    if [ -d "$BACKUP_BASE_DIR" ] && [ -n "$(ls -A "$BACKUP_BASE_DIR")" ]; then
        echo "An existing backup was found."
        read -p "Replace existing backup? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Backup cancelled."
            return 1
        fi
        rm -rf "${BACKUP_BASE_DIR:?}"/*
    fi

    # Create backup directory structure
    mkdir -p "${backup_dir}/ssh"
    mkdir -p "${backup_dir}/persist"
    mkdir -p "${backup_dir}/params"
    mkdir -p "${backup_dir}/commautil"

    # Track backup success
    local backup_success=true

    # Track component stats for metadata
    local stats=()
    local component_stats

    # Backup SSH files
    if [ -d "/home/comma/.ssh" ]; then
        mkdir -p "${backup_dir}/ssh"
        tar czf "${backup_dir}/ssh/backup.tar.gz" -C "/home/comma/.ssh" . || backup_success=false
        if [ "$backup_success" = true ]; then
            local file_count
            # Count all files in .ssh directory, excluding . and ..
            file_count=$(find "/home/comma/.ssh" -type f | wc -l)
            component_stats=$(jq -n \
                --arg type "ssh" \
                --arg files "$file_count" \
                --arg size "$(du -b "${backup_dir}/ssh/backup.tar.gz" | cut -f1)" \
                '{type: $type, files: $files, size: $size}')
            stats+=("$component_stats")
        fi
    fi

    # Backup persist files
    if [ -d "/persist/comma" ]; then
        tar czf "${backup_dir}/persist/backup.tar.gz" -C "/persist" comma || backup_success=false
        if [ "$backup_success" = true ]; then
            local file_count=$(find "/persist/comma" -type f | wc -l)
            local size=$(du -b "${backup_dir}/persist/backup.tar.gz" | cut -f1)
            component_stats=$(jq -n --arg type "persist" --arg files "$file_count" --arg size "$size" \
                '{type: $type, files: $files, size: $size}')
            stats+=("$component_stats")
        fi
    fi

    # Backup params
    if [ -d "/data/params/d" ]; then
        tar czf "${backup_dir}/params/backup.tar.gz" -C "/data/params" d || backup_success=false
        if [ "$backup_success" = true ]; then
            local file_count=$(find "/data/params/d" -type f | wc -l)
            local size=$(du -b "${backup_dir}/params/backup.tar.gz" | cut -f1)
            component_stats=$(jq -n --arg type "params" --arg files "$file_count" --arg size "$size" \
                '{type: $type, files: $files, size: $size}')
            stats+=("$component_stats")
        fi
    fi

    # Backup commautil
    if [ -d "/data/commautil" ]; then
        tar czf "${backup_dir}/commautil/backup.tar.gz" -C "/data" commautil || backup_success=false
        if [ "$backup_success" = true ]; then
            local file_count=$(find "/data/commautil" -type f | wc -l)
            local size=$(du -b "${backup_dir}/commautil/backup.tar.gz" | cut -f1)
            component_stats=$(jq -n --arg type "commautil" --arg files "$file_count" --arg size "$size" \
                '{type: $type, files: $files, size: $size}')
            stats+=("$component_stats")
        fi
    fi

    if [ "$backup_success" = true ]; then
        # Create metadata
        create_backup_metadata "$backup_dir" "$backup_name" "$device_id" "${stats[@]}"

        if [ "$silent_mode" = "silent" ]; then
            # In silent mode, just output JSON and don't interact with user
            echo "{\"status\":\"success\",\"backup_path\":\"$backup_dir\"}"
        else
            print_success "Backup completed successfully"
            echo "Backup location: $backup_dir"

            # Only offer network sync in interactive mode
            local backup_loc
            backup_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG")

            if [ -n "$backup_loc" ] && [ "$backup_loc" != "null" ]; then
                read -p "Would you like to sync this backup to the configured network location? (y/N): " sync_choice
                if [[ "$sync_choice" =~ ^[Yy]$ ]]; then
                    local location_id
                    location_id=$(echo "$backup_loc" | jq -r '.location_id')
                    if [ -n "$location_id" ] && [ "$location_id" != "null" ]; then
                        sync_backup_to_network "$backup_dir" "$location_id"
                    else
                        print_error "Invalid network location configuration"
                    fi
                fi
            fi

            pause_for_user
        fi
        return 0
    else
        if [ "$silent_mode" = "silent" ]; then
            echo "{\"status\":\"error\",\"message\":\"Backup failed\"}"
        else
            print_error "Backup failed"
            pause_for_user
        fi
        # Clean up failed backup
        rm -rf "$backup_dir"
        return 1
    fi
}

# Restore SSH files from backup with verification
restore_backup() {
    clear
    echo "+----------------------------------------------+"
    echo "│            Restore from Backup               │"
    echo "+----------------------------------------------+"
    echo "│ Restore Source:"
    echo "│ 1. Local device backup"
    echo "│ 2. Network location"
    echo "│ Q. Cancel"
    echo "+----------------------------------------------+"

    read -p "Select restore source: " source_choice

    case $source_choice in
    1) restore_from_local ;;
    2) restore_from_network ;;
    [qQ]) return ;;
    *)
        print_error "Invalid selection"
        pause_for_user
        ;;
    esac
}

restore_from_local() {
    if [ ! -d "$BACKUP_BASE_DIR" ] || [ -z "$(ls -A "$BACKUP_BASE_DIR")" ]; then
        print_error "No local backup found."
        pause_for_user
        return 1
    fi

    local latest_backup
    latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -c "%Y %n" {} \; | sort -nr | head -n1 | cut -d' ' -f2)

    if [ -n "$latest_backup" ] && [ -f "${latest_backup}/${BACKUP_METADATA_FILE}" ]; then
        echo "Warning: This will restore from the most recent backup."
        read -p "Continue with restore? (y/N): " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            restore_from_backup "$latest_backup"
        else
            print_info "Restore cancelled."
        fi
    else
        print_error "No valid backup found."
    fi
    pause_for_user
}

restore_from_network() {
    local backup_dir="/tmp/network_restore"
    mkdir -p "$backup_dir"

    # Get network location
    local location_info
    location_info=$(select_network_location "device_backup") || return 1

    # Fetch the backup
    if fetch_backup "$backup_dir" "$location_info"; then
        if [ -f "${backup_dir}/${BACKUP_METADATA_FILE}" ]; then
            restore_from_backup "$backup_dir"
        else
            print_error "Invalid backup data received"
        fi
    else
        print_error "Failed to fetch backup from network location"
    fi
    rm -rf "$backup_dir"
    pause_for_user
}

create_backup_metadata() {
    local backup_dir="$1"
    local backup_name="$2"
    local device_id="$3"
    shift 3
    local stats=("$@")

    # Ensure proper JSON array formatting for stats
    local stats_json
    if [ ${#stats[@]} -gt 0 ]; then
        stats_json=$(printf '%s,' "${stats[@]}" | sed 's/,$//')
    else
        stats_json='[]'
    fi

    # Create metadata with properly formatted JSON
    cat >"${backup_dir}/${BACKUP_METADATA_FILE}" <<EOF
{
    "backup_id": "${backup_name}",
    "device_id": "${device_id}",
    "timestamp": "$(date -Iseconds)",
    "script_version": "${SCRIPT_VERSION}",
    "agnos_version": "$(cat /VERSION 2>/dev/null)",
    "directories": [
        ${stats_json}
    ],
    "total_size": "$(du -sh "${backup_dir}" | cut -f1)"
}
EOF

    # Verify the JSON is valid
    if ! jq '.' "${backup_dir}/${BACKUP_METADATA_FILE}" >/dev/null 2>&1; then
        print_error "Generated metadata file is not valid JSON"
        return 1
    fi
}

restore_from_backup() {
    local backup_dir="$1"
    local metadata
    metadata=$(cat "${backup_dir}/${BACKUP_METADATA_FILE}")

    echo "The following components will be restored:"
    echo "----------------------------------------"
    echo "$metadata" | jq -r '.directories[] | "- \(.type) (\(.files) files, \(.size) bytes)"'
    echo "----------------------------------------"
    read -p "Continue with restore? (y/N): " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mount_rw

        # Restore each component
        local components=("ssh" "persist" "params" "commautil")
        local restore_paths=(
            "/home/comma/.ssh"
            "/persist/comma"
            "/data/params/d"
            "/data/commautil"
        )

        for i in "${!components[@]}"; do
            local component="${components[$i]}"
            local restore_path="${restore_paths[$i]}"

            if [ -f "${backup_dir}/${component}/backup.tar.gz" ]; then
                print_info "Restoring ${component}..."
                # Create parent directory if it doesn't exist
                mkdir -p "$(dirname "$restore_path")"
                # Extract backup
                tar xzf "${backup_dir}/${component}/backup.tar.gz" -C "$(dirname "$restore_path")"
                # Fix permissions
                chown -R comma:comma "$restore_path"

                # Special handling for SSH files
                if [ "$component" = "ssh" ]; then
                    # Fix SSH permissions
                    chmod 600 "$restore_path/github"
                    chmod 644 "$restore_path/github.pub"
                    chmod 644 "$restore_path/config"

                    # Copy to persistent storage
                    copy_ssh_config_and_keys

                    # Restart SSH agent
                    restart_ssh_agent
                fi
            fi
        done

        print_success "Restore completed"
    else
        print_info "Restore cancelled"
    fi
    pause_for_user
}

perform_automated_backup() {
    local network_id="$1"

    if [ -z "$network_id" ]; then
        print_error "Missing network ID for automated backup"
        exit 1
    fi

    # Check if device is onroad
    if [ -f "/data/params/d/IsOnroad" ] && grep -q "^1" "/data/params/d/IsOnroad"; then
        print_error "Cannot perform backup while device is onroad"
        exit 1
    fi

    # Verify network location exists
    local network_config="/data/commautil/network_locations.json"
    if [ ! -f "$network_config" ]; then
        print_error "Network configuration not found"
        exit 1
    fi

    # Verify network ID exists
    local location
    location=$(jq --arg id "$network_id" '.smb[] + .ssh[] | select(.location_id == $id)' "$network_config")
    if [ -z "$location" ]; then
        print_error "Network location with ID $network_id not found"
        exit 1
    fi

    # Perform backup
    local backup_result
    backup_result=$(backup_device "silent")
    if [ $? -ne 0 ]; then
        print_error "Backup failed"
        exit 1
    fi

    # Extract backup path from result
    local backup_path
    backup_path=$(echo "$backup_result" | jq -r '.backup_path')

    # Sync to network
    if ! sync_backup_to_network "$backup_path" "$network_id"; then
        print_error "Network sync failed"
        exit 1
    fi

    exit 0
}

migrate_legacy_backup() {
    clear
    print_info "Old backup format detected at /data/ssh_backup"
    echo "This script now uses a new backup format that includes additional device data."
    echo "Would you like to:"
    echo "1. Create new backup and remove old backup data"
    echo "2. Create new backup and keep old backup data"
    echo "3. Skip migration for now"

    read -p "Enter choice (1-3): " choice

    case $choice in
    1 | 2)
        print_info "Creating new format backup..."
        if backup_device; then
            if [ "$choice" = "1" ]; then
                print_info "Removing old backup data..."
                rm -rf "/data/ssh_backup"
                print_success "Old backup data removed"
            else
                print_info "Old backup data preserved at /data/ssh_backup"
            fi
            print_success "Migration completed successfully"
        else
            print_error "Backup failed - keeping old backup data"
        fi
        ;;
    3)
        print_info "Migration skipped. You can migrate later using the backup menu."
        ;;
    *)
        print_error "Invalid choice"
        ;;
    esac
    pause_for_user
}

remove_legacy_backup() {
    clear
    print_info "Old backup format detected at /data/ssh_backup"
    echo "This script now uses a new backup format that includes additional device data."
    echo "Would you like to remove the old backup data?"
    read -p "Enter y or n: " remove_choice
    if [ "$remove_choice" = "y" ]; then
        rm -rf "/data/ssh_backup"
        print_success "Old backup data removed"
    else
        print_info "Old backup data preserved at /data/ssh_backup"
    fi
    pause_for_user
}

backup_menu() {
    local backup_loc backup_job has_legacy_backup
    backup_loc=$(get_backup_location)
    backup_job=$(get_backup_job)
    has_legacy_backup=$(has_legacy_backup)
    protocol=$(echo "$backup_loc" | jq -r '.protocol')
    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "│            Device Backup Manager             │"
        echo "+----------------------------------------------+"
        display_backup_status_short
        echo "│ "
        echo "│ Available Options:"
        echo "│ 1.  Create New Backup"
        echo "│ 2.  Restore from Backup"
        echo "│ 3.  Configure Network Location"

        if [ -n "$backup_loc" ]; then
            echo "│ 4.  Configure Auto-Backup"
            echo "│ 5.  Test Network Connection"
            echo "│ 6.  Network Location Settings"
            echo "│ 7.  Sync Backup to Network"
        fi

        if [ "$has_legacy_backup" = "true" ]; then
            echo "│ M. Migrate Legacy Backup"
        fi

        echo "│ Q|B. Back to Main Menu"
        echo "+----------------------------------------------+"

        read -p "Enter your choice: " choice
        case $choice in
        1) backup_device ;;
        2) restore_backup ;;
        3) configure_network_location "device_backup" ;;
        4) manage_auto_backup_jobs ;;
        5)
            if [ -n "$backup_loc" ]; then
                test_network_connection "$backup_loc"
                pause_for_user
            fi
            ;;
        6) manage_network_locations_menu ;;
        7)
            if [ -n "$backup_loc" ] && [ -n "$latest_backup" ]; then
                local location_id=$(echo "$backup_loc" | jq -r .location_id)
                sync_backup_to_network "$latest_backup" "$location_id"
            else
                print_error "No backup available to sync or no network location configured"
                pause_for_user
            fi
            ;;
        [mM])
            if [ "$has_legacy_backup" = "true" ]; then
                migrate_legacy_backup
            else
                print_error "No legacy backup detected"
                pause_for_user
            fi
            ;;
        [mM])
            if [ "$has_legacy_backup" = "true" ]; then
                migrate_legacy_backup
            else
                print_error "No legacy backup detected"
                pause_for_user
            fi
            ;;
        [qQ | bB]) break ;;
        *) print_error "Invalid choice." ;;
        esac
    done
}

view_backup_details() {
    clear
    echo "+----------------------------------------------------+"
    echo "│               Available Backups                     │"
    echo "+----------------------------------------------------+"

    # List available backups
    local backups=()
    local i=1
    while IFS= read -r backup_dir; do
        if [ -f "${backup_dir}/${BACKUP_METADATA_FILE}" ]; then
            backups+=("$backup_dir")
            local metadata timestamp device_id size components
            metadata=$(cat "${backup_dir}/${BACKUP_METADATA_FILE}")
            timestamp=$(echo "$metadata" | jq -r '.timestamp')
            device_id=$(echo "$metadata" | jq -r '.device_id')
            size=$(du -sh "$backup_dir" | cut -f1)

            echo "Backup #$i:"
            echo "├─ Date: $(date -d "$timestamp" "+%Y-%m-%d %H:%M")"
            echo "├─ Device ID: $device_id"
            echo "├─ Size: $size"
            echo "├─ Components:"
            echo "$metadata" | jq -r '.directories[] | "│  └─ \(.type): \(.files) files (\(.size) bytes)"'
            echo "│"
            ((i++))
        fi
    done < <(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)

    if [ ${#backups[@]} -eq 0 ]; then
        echo "No backups found"
    fi

    pause_for_user
}

remove_backup() {
    local backup_dir="$1"
    local network_only="${2:-false}"
    local silent_mode="${3:-normal}"

    if [ ! -d "$backup_dir" ]; then
        [ "$silent_mode" != "silent" ] && print_error "Backup directory not found: $backup_dir"
        return 1
    fi

    # Get network location info if exists
    local network_loc location_id
    if [ -f "$NETWORK_CONFIG" ]; then
        network_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG")
        location_id=$(echo "$network_loc" | jq -r '.location_id')
    fi

    # Remove from network if configured
    if [ -n "$network_loc" ] && [ -n "$location_id" ]; then
        [ "$silent_mode" != "silent" ] && print_info "Removing backup from network location..."
        remove_backup_from_network "$backup_dir" "$location_id"
    fi

    # Remove local backup unless network_only is true
    if [ "$network_only" = "false" ]; then
        [ "$silent_mode" != "silent" ] && print_info "Removing local backup..."
        rm -rf "$backup_dir"
        [ "$silent_mode" != "silent" ] && print_success "Backup removed successfully"
    fi

    return 0
}

remove_backup_from_network() {
    local backup_dir="$1"
    local location_id="$2"

    local location
    location=$(jq -r --arg id "$location_id" '.locations[] | select(.location_id == $id)' "$NETWORK_CONFIG")
    if [ -z "$location" ] || [ "$location" = "null" ]; then
        print_error "Network location not found"
        return 1
    fi

    local device_id=$(get_device_id)
    local backup_name=$(basename "$backup_dir")
    local remote_path

    # Build remote path
    local base_path
    base_path=$(echo "$location" | jq -r '.path')
    remote_path="${base_path%/}/${device_id}/backups/${backup_name}"

    local protocol
    protocol=$(echo "$location" | jq -r '.protocol')

    case "$protocol" in
    smb)
        local server share username password
        server=$(echo "$location" | jq -r .server)
        share=$(echo "$location" | jq -r .share)
        username=$(echo "$location" | jq -r .username)
        password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")

        smbclient "//${server}/${share}" -U "${username}%${password}" \
            -c "deltree \"$remote_path\"" >/dev/null 2>&1
        ;;
    ssh)
        local server port username auth_type
        server=$(echo "$location" | jq -r .server)
        port=$(echo "$location" | jq -r .port)
        username=$(echo "$location" | jq -r .username)
        auth_type=$(echo "$location" | jq -r .auth_type)

        if [ "$auth_type" = "password" ]; then
            local password
            password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")
            sshpass -p "$password" ssh -p "$port" "$username@$server" "rm -rf '$remote_path'"
        else
            local key_path
            key_path=$(echo "$location" | jq -r .key_path)
            ssh -p "$port" -i "$key_path" "$username@$server" "rm -rf '$remote_path'"
        fi
        ;;
    esac
}

remove_all_backups() {
    local network_only="${1:-false}"
    local silent_mode="${2:-normal}"

    if [ "$silent_mode" != "silent" ]; then
        echo "WARNING: This will remove all backups"
        if [ "$network_only" = "true" ]; then
            echo "from the network location only."
        else
            echo "both locally and from the network location."
        fi
        read -p "Are you sure you want to continue? (y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return 1
    fi

    local backups=()
    while IFS= read -r backup_dir; do
        backups+=("$backup_dir")
    done < <(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d)

    for backup_dir in "${backups[@]}"; do
        remove_backup "$backup_dir" "$network_only" "$silent_mode"
    done

    [ "$silent_mode" != "silent" ] && print_success "All backups removed successfully"
    return 0
}

select_backup_for_removal() {
    clear
    echo "+----------------------------------------------------+"
    echo "│               Select Backup to Remove               │"
    echo "+----------------------------------------------------+"

    # List available backups
    local backups=()
    local i=1
    while IFS= read -r backup_dir; do
        if [ -f "${backup_dir}/${BACKUP_METADATA_FILE}" ]; then
            backups+=("$backup_dir")
            local timestamp size
            timestamp=$(jq -r .timestamp "${backup_dir}/${BACKUP_METADATA_FILE}")
            size=$(du -sh "$backup_dir" | cut -f1)
            echo "$i) $(date -d "$timestamp" "+%Y-%m-%d %H:%M") - Size: $size"
            ((i++))
        fi
    done < <(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)

    if [ ${#backups[@]} -eq 0 ]; then
        print_error "No backups found"
        pause_for_user
        return 1
    fi

    echo "Q) Cancel"
    echo "+----------------------------------------------------+"
    read -p "Select backup to remove: " choice

    case $choice in
    [qQ]) return 1 ;;
    *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#backups[@]}" ]; then
            local selected_backup="${backups[$((choice - 1))]}"
            echo "Selected: $selected_backup"

            echo "Remove from:"
            echo "1. Local device only"
            echo "2. Network location only"
            echo "3. Both local and network"
            echo "Q. Cancel"
            read -p "Select option: " remove_choice

            case $remove_choice in
            1) remove_backup "$selected_backup" "false" ;;
            2) remove_backup "$selected_backup" "true" ;;
            3) remove_backup "$selected_backup" "false" ;;
            [qQ]) return 1 ;;
            *) print_error "Invalid choice" ;;
            esac
        else
            print_error "Invalid selection"
            pause_for_user
            return 1
        fi
        ;;
    esac
}
