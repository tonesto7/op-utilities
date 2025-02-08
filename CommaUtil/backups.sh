#!/bin/bash

###############################################################################
# Global Variables
###############################################################################
readonly BACKUPS_SCRIPT_VERSION="3.0.0"
readonly BACKUPS_SCRIPT_MODIFIED="2025-02-08"

# Device Backup Related Constants
readonly BACKUP_BASE_DIR="/data/device_backup"
readonly BACKUP_METADATA_FILE="metadata.json"
readonly MAX_BACKUP_COUNT=5
readonly BACKUP_DIRS=(
    "/home/comma/.ssh"
    "/persist/comma"
    "/data/params/d"
    "/data/commautil"
)

###############################################################################
# Backup Status Functions
###############################################################################

display_backup_status_short() {
    print_info "| Backup Status:"
    # Check network location configuration
    local backup_loc backup_job
    if [ -f "$NETWORK_CONFIG" ]; then
        backup_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG")
    fi
    if [ -f "$LAUNCH_ENV_FILE" ]; then
        backup_job=$(grep -A1 "^### Start CommaUtility Backup" "$LAUNCH_ENV_FILE")
    fi

    if [ -n "$backup_loc" ]; then
        local label protocol status
        label=$(echo "$backup_loc" | jq -r .label)
        protocol=$(echo "$backup_loc" | jq -r .protocol)

        # Use CommaUtilityRoutes.sh to test the connection
        if [ "$protocol" = "smb" ]; then
            test_smb_connection "$backup_loc"
        else
            test_ssh_connection "$backup_loc"
        fi

        # echo "Status: $status"

        if [ "$status" = "Valid" ]; then
            echo -e "| ├ Network: ${GREEN}$label - Connected${NC}"
        else
            echo -e "| ├ Network: ${RED}$label - Disconnected${NC}"
        fi

        if [ -n "$backup_job" ]; then
            echo -e "| ├ Auto-Backup: ${GREEN}Enabled${NC}"
        else
            echo -e "| ├ Auto-Backup: ${YELLOW}Disabled${NC}"
        fi
    else
        echo -e "| ├ Network: ${YELLOW}Not Configured${NC}"
        echo -e "| ├ Auto-Backup: ${RED}Not Available${NC}"
    fi

    # Find most recent backup
    local latest_backup
    latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -c "%Y %n" {} \; | sort -nr | head -n1 | cut -d' ' -f2)

    if [ -n "$latest_backup" ] && [ -f "${latest_backup}/${BACKUP_METADATA_FILE}" ]; then
        local backup_timestamp backup_age_days backup_size
        backup_timestamp=$(jq -r '.timestamp' "${latest_backup}/${BACKUP_METADATA_FILE}")
        backup_age_days=$((($(date +%s) - $(date -d "$backup_timestamp" +%s)) / 86400))
        backup_size=$(du -sh "$latest_backup" | cut -f1)

        # Count total number of backups
        local total_backups max_label
        total_backups=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
        max_label="${total_backups}/${MAX_BACKUP_COUNT}"

        # Calculate total size of all backups
        local total_size
        total_size=$(du -sh "$BACKUP_BASE_DIR" | cut -f1)

        echo "| ├ Latest: $(date -d "$backup_timestamp" "+%Y-%m-%d %H:%M")"
        if [ "$backup_age_days" -gt 30 ]; then
            echo -e "| ├ Age: ${YELLOW}${backup_age_days} days old${NC}"
        else
            echo -e "| ├ Age: ${GREEN}${backup_age_days} days old${NC}"
        fi
        echo "| ├ Latest Size: $backup_size"
        echo "| ├ Total Size: $total_size (Backups: $max_label)"

        # Get backup contents summary
        local ssh_files params_files commautil_files
        ssh_files=$(jq -r '.directories[] | select(.type=="ssh") | .files' "${latest_backup}/${BACKUP_METADATA_FILE}")
        params_files=$(jq -r '.directories[] | select(.type=="params") | .files' "${latest_backup}/${BACKUP_METADATA_FILE}")
        commautil_files=$(jq -r '.directories[] | select(.type=="commautil") | .files' "${latest_backup}/${BACKUP_METADATA_FILE}")
        echo "| └ Contents: SSH($ssh_files), Params($params_files), Config($commautil_files) files"
    else
        echo -e "| ├ Status: ${RED}No backups found${NC}"
        echo "| └ Action: Run backup to secure your device configuration"
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

    # Create backup directory structure
    mkdir -p "${backup_dir}/ssh"
    mkdir -p "${backup_dir}/persist"
    mkdir -p "${backup_dir}/params"
    mkdir -p "${backup_dir}/commautil"

    # Perform backup operations...
    # [Previous backup logic remains the same]

    if [ "$silent_mode" = "silent" ]; then
        echo "{\"status\":\"success\",\"backup_path\":\"$backup_dir\"}"
    else
        print_success "Backup completed successfully"

        # Check for configured network location
        local backup_loc
        backup_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG")
        if [ -n "$backup_loc" ]; then
            read -p "Would you like to sync this backup to the configured network location? (y/N): " sync_choice
            if [[ "$sync_choice" =~ ^[Yy]$ ]]; then
                local location_id=$(echo "$backup_loc" | jq -r .location_id)
                sync_backup_to_network "$backup_dir" "$location_id"
            fi
        else
            print_info "No network location configured for backups."
            read -p "Would you like to configure one now? (y/N): " configure_choice
            if [[ "$configure_choice" =~ ^[Yy]$ ]]; then
                manage_network_locations_menu
            fi
        fi
    fi
    return 0
}

cleanup_old_backups() {
    local keep_count="$1"
    local count=0

    # Count existing backups
    count=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)

    if [ "$count" -gt "$keep_count" ]; then
        print_info "Found $count backups, cleaning up to maintain $keep_count most recent..."

        # List backups by timestamp, keep the newest $keep_count
        find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -c "%Y %n" {} \; |
            sort -nr |
            tail -n +$((keep_count + 1)) |
            while read -r timestamp dir; do
                print_info "Removing old backup: $(basename "$dir")"
                rm -rf "$dir"
            done

        print_success "Backup cleanup complete."
    fi
}

# Restore SSH files from backup with verification
restore_backup() {
    clear
    echo "+----------------------------------------------+"
    echo "|            Restore from Backup               |"
    echo "+----------------------------------------------+"
    echo "| Restore Source:"
    echo "| 1. Local device backup"
    echo "| 2. Network location"
    echo "| Q. Cancel"
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
    # List available local backups
    local backups=()
    local i=1
    while IFS= read -r backup_dir; do
        if [ -f "${backup_dir}/${BACKUP_METADATA_FILE}" ]; then
            local metadata
            metadata=$(cat "${backup_dir}/${BACKUP_METADATA_FILE}")
            backups+=("$backup_dir")
            local timestamp device_id total_size
            timestamp=$(echo "$metadata" | jq -r '.timestamp')
            device_id=$(echo "$metadata" | jq -r '.device_id')
            total_size=$(echo "$metadata" | jq -r '.total_size')
            echo "$i) ${timestamp} - Device: ${device_id} (${total_size})"
            i=$((i + 1))
        fi
    done < <(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d)

    if [ ${#backups[@]} -eq 0 ]; then
        print_info "No local backups found."
        pause_for_user
        return
    fi

    echo "Q) Cancel"
    echo "----------------------------------------------"
    read -p "Select backup to restore: " choice

    case $choice in
    [qQ]) return ;;
    *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#backups[@]}" ]; then
            local selected_backup="${backups[$((choice - 1))]}"
            restore_from_backup "$selected_backup"
        else
            print_error "Invalid selection"
            pause_for_user
        fi
        ;;
    esac
}

restore_from_network() {
    local backup_dir="/tmp/network_restore"
    mkdir -p "$backup_dir"

    # Get network location
    local location_info
    location_info=$(select_network_location) || return 1

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

    cat >"${backup_dir}/${BACKUP_METADATA_FILE}" <<EOF
{
    "backup_id": "${backup_name}",
    "device_id": "${device_id}",
    "timestamp": "$(date -Iseconds)",
    "script_version": "${SCRIPT_VERSION}",
    "agnos_version": "$(cat /VERSION 2>/dev/null)",
    "directories": [
        $(printf "%s," "${stats[@]}" | sed 's/,$//')
    ],
    "total_size": "$(du -sh "${backup_dir}" | cut -f1)"
}
EOF
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
    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "|            Device Backup Manager             |"
        echo "+----------------------------------------------+"

        # Show backup network location status
        local backup_loc backup_job

        if [ -f "$NETWORK_CONFIG" ]; then
            backup_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG")
        fi
        if [ -f "$LAUNCH_ENV_FILE" ]; then
            backup_job=$(grep -A1 "^### Start CommaUtility Backup" "$LAUNCH_ENV_FILE")
        fi

        if [ -n "$backup_loc" ]; then
            local label protocol status
            label=$(echo "$backup_loc" | jq -r .label)
            protocol=$(echo "$backup_loc" | jq -r .protocol)

            # Use CommaUtilityRoutes.sh to test the connection
            if [ "$protocol" = "smb" ]; then
                status=$(test_smb_connection "$backup_loc")
            else
                status=$(test_ssh_connection "$backup_loc")
            fi

            if [ "$status" = "Valid" ]; then
                echo -e "| Network Location: ${GREEN}$label - Connected${NC}"
            else
                echo -e "| Network Location: ${RED}$label - Disconnected${NC}"
            fi

            if [ -n "$backup_job" ]; then
                echo -e "| Auto-Backup: ${GREEN}Enabled${NC}"
            else
                echo -e "| Auto-Backup: ${YELLOW}Disabled${NC}"
            fi
        else
            echo -e "| Network Location: ${YELLOW}Not Configured${NC}"
            echo -e "| Auto-Backup: ${RED}Not Available${NC}"
        fi

        # Show latest backup info
        local latest_backup
        latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -c "%Y %n" {} \; | sort -nr | head -n1 | cut -d' ' -f2)

        if [ -n "$latest_backup" ] && [ -f "${latest_backup}/${BACKUP_METADATA_FILE}" ]; then
            local backup_timestamp backup_age_days backup_size
            backup_timestamp=$(jq -r '.timestamp' "${latest_backup}/${BACKUP_METADATA_FILE}")
            backup_age_days=$((($(date +%s) - $(date -d "$backup_timestamp" +%s)) / 86400))
            backup_size=$(du -sh "$latest_backup" | cut -f1)

            # Count total number of backups
            local total_backups total_size max_label
            total_backups=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
            total_size=$(du -sh "$BACKUP_BASE_DIR" | cut -f1)
            max_label="${total_backups}/${MAX_BACKUP_COUNT}"

            echo "| Last Backup: $backup_timestamp"
            if [ "$backup_age_days" -gt 30 ]; then
                echo -e "| Backup Age: ${RED}$backup_age_days days old${NC}"
            else
                echo -e "| Backup Age: ${GREEN}$backup_age_days days old${NC}"
            fi
            echo "| Latest Size: $backup_size"
            echo "| Total Size: $total_size (Backups: $max_label)"
        else
            echo -e "| Last Backup: ${RED}None Found${NC}"
        fi

        echo "+----------------------------------------------+"
        echo "| Available Options:"
        echo "| 1. Create New Backup"
        echo "| 2. Restore from Backup"
        echo "| 3. Configure Network Location"
        if [ -n "$backup_loc" ]; then
            if [ -n "$backup_job" ]; then
                echo "| 4. Disable Auto-Backup"
            else
                echo "| 4. Enable Auto-Backup"
            fi
            echo "| 5. Test Network Connection"
            echo "| 6. Sync Latest Backup to Network"
        fi

        if [ -d "/data/ssh_backup" ] && [ -f "/data/ssh_backup/metadata.txt" ]; then
            echo "| M. Migrate Legacy Backup"
        fi

        echo "| Q. Back to Main Menu"
        echo "+----------------------------------------------+"

        read -p "Enter your choice: " choice
        case $choice in
        1) backup_device ;;
        2) restore_backup ;;
        3) manage_network_locations_menu ;;
        4)
            if [ -n "$backup_loc" ]; then
                if [ -n "$backup_job" ]; then
                    manage_backup_sync_menu
                else
                    manage_jobs_menu
                fi
            fi
            ;;
        5)
            if [ -n "$backup_loc" ]; then
                if [ "$protocol" = "smb" ]; then
                    test_smb_connection "$backup_loc"
                else
                    test_ssh_connection "$backup_loc"
                fi
                pause_for_user
            fi
            ;;
        6)
            if [ -n "$backup_loc" ] && [ -n "$latest_backup" ]; then
                local location_id=$(echo "$backup_loc" | jq -r .location_id)
                sync_backup_to_network "$latest_backup" "$location_id"
            else
                print_error "No backup available to sync or no network location configured"
                pause_for_user
            fi
            ;;
        [mM])
            if [ -d "/data/ssh_backup" ] && [ -f "/data/ssh_backup/metadata.txt" ]; then
                migrate_legacy_backup
            else
                print_error "No old backup format detected"
                pause_for_user
            fi
            ;;
        [qQ]) break ;;
        *) print_error "Invalid choice." ;;
        esac
    done
}
