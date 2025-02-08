#!/bin/bash
###############################################################################
# backups.sh - Device Backup and Restore Operations for CommaUtility
#
# Version: BACKUPS_SCRIPT_VERSION="3.0.2"
# Last Modified: 2025-02-08
#
# This script manages device backup operations (SSH, persist, params,
# commautil) including creation, selective backup, restoration (local or
# network), legacy migration and removal.
###############################################################################

###############################################################################
# Global Variables
###############################################################################
readonly BACKUPS_SCRIPT_VERSION="3.0.3"
readonly BACKUPS_SCRIPT_MODIFIED="2025-02-08"

# Device backup constants
readonly BACKUP_BASE_DIR="/data/device_backup"
readonly BACKUP_METADATA_FILE="metadata.json"
readonly BACKUP_CHECKSUM_FILE="checksum.sha256"
readonly BACKUP_DIRS=("/home/comma/.ssh" "/persist/comma" "/data/params/d" "/data/commautil")

###############################################################################
# Helper Functions for Backup Metadata and Device Info
###############################################################################
get_backup_location() {
    if [ -f "$NETWORK_CONFIG" ]; then
        jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG"
    fi
}

get_backup_job() {
    if [ -f "$LAUNCH_ENV" ]; then
        grep -A1 "^### Start CommaUtility Backup" "$LAUNCH_ENV"
    fi
}

has_legacy_backup() {
    if [ -d "/data/ssh_backup" ] && [ -f "/data/ssh_backup/metadata.txt" ]; then
        return 0
    else
        return 1
    fi
}

###############################################################################
# Component Management Functions
###############################################################################
get_component_info() {
    local component="$1"
    case "$component" in
    ssh) echo "/home/comma/.ssh:600:comma" ;;
    persist) echo "/persist/comma:755:comma" ;;
    params) echo "/data/params/d:644:comma" ;;
    commautil) echo "/data/commautil:755:comma" ;;
    esac
}

set_component_permissions() {
    local component="$1"
    local target="$2"
    local info
    info=$(get_component_info "$component")
    local perms owner
    IFS=: read -r _ perms owner <<<"$info"
    chmod "$perms" "$target"
    chown "$owner:$owner" "$target"
}

###############################################################################
# Backup Status Functions
###############################################################################
display_backup_status_short() {
    print_info "│ Backup Status:"
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
        if [ "$protocol" = "smb" ]; then
            status=$(test_smb_connection "$backup_loc")
        else
            status=$(test_network_ssh "$backup_loc")
        fi
        status=${status:-"Invalid"}
        if [ "$status" = "Valid" ]; then
            echo -e "│ ├─ Network Location: ${GREEN}$label (Connected)${NC}"
        else
            echo -e "│ ├─ Network Location: ${RED}$label (Disconnected)${NC}"
        fi
        if [ -n "$backup_job" ]; then
            echo -e "│ ├─ Auto-Backup: ${GREEN}Enabled${NC}"
        else
            echo -e "│ ├─ Auto-Backup: ${YELLOW}Disabled${NC}"
        fi
    else
        echo -e "│ ├─ Network Location: ${YELLOW}Not Configured${NC}"
        echo -e "│ ├─ Auto-Backup: ${RED}Not Available${NC}"
    fi

    if [ ! -d "$BACKUP_BASE_DIR" ]; then
        echo -e "│ └─ Status: ${RED}No backup found${NC}"
        return
    fi

    local latest_backup
    latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d \
        -exec stat -c "%Y %n" {} \; 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2)

    if [ -n "$latest_backup" ] && verify_backup_integrity "$latest_backup" && [ -f "${latest_backup}/${BACKUP_METADATA_FILE}" ]; then
        local backup_timestamp backup_age_days backup_size formatted_date
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
        echo "│ ├─ Date: ${formatted_date}"
        if [ "$backup_age_days" -gt 30 ]; then
            echo -e "│ ├─ Age: ${YELLOW}${backup_age_days} days old${NC}"
        else
            echo -e "│ ├─ Age: ${GREEN}${backup_age_days} days old${NC}"
        fi
        echo "│ ├─ Size: $backup_size"
        echo "│ └─ Components: SSH, Params, Config"
    else
        echo -e "│ └─ ${RED}No valid backup found${NC}"
    fi
}

###############################################################################
# Backup Management Functions
###############################################################################
backup_device() {
    local silent_mode="${1:-normal}"
    local device_id timestamp backup_name backup_dir
    device_id=$(get_device_id)
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_name="${device_id}_${timestamp}"
    backup_dir="${BACKUP_BASE_DIR}/${backup_name}"
    local cleanup_required=false

    trap 'handle_backup_error "$backup_dir" "$cleanup_required"' ERR

    [ "$silent_mode" != "silent" ] && print_info "Creating backup in ${backup_dir}..."

    # Create temporary directory for atomic backup
    local temp_dir="${backup_dir}.tmp"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    cleanup_required=true

    # Create component directories
    for dir in ssh persist params commautil; do
        mkdir -p "${temp_dir}/${dir}"
    done

    # Initialize checksum file
    local checksum_file="${temp_dir}/${BACKUP_CHECKSUM_FILE}"
    : >"$checksum_file"

    local backup_success=true
    local stats=()

    # Backup components with error handling and checksums
    # Replace individual component backups with:
    local components=("ssh" "persist" "params" "commautil")
    local source_paths=("/home/comma/.ssh" "/persist/comma" "/data/params/d" "/data/commautil")

    for i in "${!components[@]}"; do
        local component="${components[$i]}"
        local source="${source_paths[$i]}"
        backup_component "$component" "$source" "$temp_dir" "$checksum_file" || backup_success=false
        collect_component_stats "$component" "$temp_dir" stats
    done

    if [ "$backup_success" = true ]; then
        create_backup_metadata "$temp_dir" "$backup_name" "$device_id" "${stats[@]}"

        # Atomically move the backup into place
        if [ -d "$backup_dir" ]; then
            rm -rf "${backup_dir}.old"
            mv "$backup_dir" "${backup_dir}.old"
        fi
        mv "$temp_dir" "$backup_dir"

        cleanup_required=false
        [ "$silent_mode" != "silent" ] && print_success "Backup completed successfully"
        return 0
    else
        [ "$silent_mode" != "silent" ] && print_error "Backup failed"
        return 1
    fi
}
create_backup_metadata() {
    local backup_dir="$1" backup_name="$2" device_id="$3"
    shift 3
    local stats=("$@")
    local metadata
    metadata=$(jq -n --arg backup_id "$backup_name" --arg device_id "$device_id" \
        --arg timestamp "$(date -Iseconds)" --arg script_version "$SCRIPT_VERSION" \
        --arg total_size "$(du -sh "${backup_dir}" | cut -f1)" \
        '{backup_id: $backup_id, device_id: $device_id, timestamp: $timestamp, script_version: $script_version, directories: [], total_size: $total_size}')
    if [ ${#stats[@]} -gt 0 ]; then
        local json_stats="["
        local first=true
        for stat in "${stats[@]}"; do
            if [ "$first" = true ]; then
                json_stats+="$stat"
                first=false
            else
                json_stats+=",$stat"
            fi
        done
        json_stats+="]"
        metadata=$(echo "$metadata" | jq --argjson dirs "$json_stats" '.directories = $dirs')
    fi
    echo "$metadata" >"${backup_dir}/${BACKUP_METADATA_FILE}"
    if ! jq '.' "${backup_dir}/${BACKUP_METADATA_FILE}" >/dev/null 2>&1; then
        print_error "Generated metadata file is not valid JSON"
        return 1
    fi
    return 0
}

verify_backup_integrity() {
    local backup_dir="$1"
    local metadata_file="${backup_dir}/${BACKUP_METADATA_FILE}"
    local checksum_file="${backup_dir}/${BACKUP_CHECKSUM_FILE}"

    # Verify metadata exists and is valid JSON
    if [ ! -f "$metadata_file" ] || ! jq empty "$metadata_file" 2>/dev/null; then
        print_error "Invalid or missing backup metadata"
        return 1
    fi

    # Verify all components exist and match checksums
    while IFS= read -r line; do
        local saved_hash file_path
        saved_hash=$(echo "$line" | cut -d' ' -f1)
        file_path=$(echo "$line" | cut -d' ' -f3-)
        if [ ! -f "${backup_dir}/${file_path}" ]; then
            print_error "Missing backup component: ${file_path}"
            return 1
        fi
        local current_hash
        current_hash=$(sha256sum "${backup_dir}/${file_path}" | cut -d' ' -f1)
        if [ "$saved_hash" != "$current_hash" ]; then
            print_error "Backup component corrupted: ${file_path}"
            return 1
        fi
    done <"$checksum_file"

    return 0
}

###############################################################################
# Restore Backup Functions
###############################################################################
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
    latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d \
        -exec stat -c "%Y %n" {} \; | sort -nr | head -n1 | cut -d' ' -f2)
    if [ -n "$latest_backup" ] && [ -f "${latest_backup}/${BACKUP_METADATA_FILE}" ]; then
        echo "Warning: This will restore from the most recent backup."
        read -p "Continue with restore? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            restore_from_backup_dir "$latest_backup"
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
    local location_info
    location_info=$(select_network_location "device_backup") || return 1
    if fetch_backup "$backup_dir" "$location_info"; then
        if [ -f "${backup_dir}/${BACKUP_METADATA_FILE}" ]; then
            restore_from_backup_dir "$backup_dir"
        else
            print_error "Invalid backup data received"
        fi
    else
        print_error "Failed to fetch backup from network location"
    fi
    rm -rf "$backup_dir"
    pause_for_user
}

restore_from_backup_dir() {
    local backup_dir="$1"
    echo "The following components will be restored:"
    echo "----------------------------------------"
    if [ -f "${backup_dir}/${BACKUP_METADATA_FILE}" ]; then
        jq -r '.directories[] | "- \(.type) (\(.files) files, \(.size) bytes)"' "${backup_dir}/${BACKUP_METADATA_FILE}"
    fi
    echo "----------------------------------------"
    read -p "Continue with restore? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # Add integrity check before restore
        if ! verify_backup_integrity "$backup_dir"; then
            print_error "Backup verification failed"
            return 1
        fi

        mount_rw
        # For each component, extract its backup archive.
        local components=("ssh" "persist" "params" "commautil")
        local restore_paths=("/home/comma/.ssh" "/persist/comma" "/data/params/d" "/data/commautil")
        for i in "${!components[@]}"; do
            local comp="${components[$i]}"
            local target="${restore_paths[$i]}"
            if [ -f "${backup_dir}/${comp}/backup.tar.gz" ]; then
                print_info "Restoring ${comp}..."
                mkdir -p "$(dirname "$target")"
                # For SSH, use the new optimized restore logic.
                if [ "$comp" = "ssh" ]; then
                    restore_ssh_component
                else
                    tar xzf "${backup_dir}/${comp}/backup.tar.gz" -C "$(dirname "$target")"
                    set_component_permissions "$comp" "$target"
                fi
            fi
        done
        print_success "Restore completed"
    else
        print_info "Restore cancelled"
    fi
    pause_for_user
}

###############################################################################
# New SSH Restore Logic (Optimized)
###############################################################################
restore_ssh_component() {
    local latest_backup
    latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d \
        -exec stat -c "%Y %n" {} \; | sort -nr | head -n1 | cut -d' ' -f2)
    if [ -z "$latest_backup" ] || [ ! -f "${latest_backup}/ssh/backup.tar.gz" ]; then
        print_error "No valid SSH backup found."
        return 1
    fi
    if ! tar tzf "${latest_backup}/ssh/backup.tar.gz" >/dev/null 2>&1; then
        print_error "SSH backup archive appears to be corrupted."
        return 1
    fi
    if [ -f "${latest_backup}/${BACKUP_METADATA_FILE}" ]; then
        local backup_info
        backup_info=$(jq -r '.directories[] | select(.type=="ssh") | "Backup Date: \(.timestamp), Files: \(.files), Size: \(.size)"' \
            "${latest_backup}/${BACKUP_METADATA_FILE}")
        print_info "SSH Backup Info: $backup_info"
    fi
    read -p "Proceed with restoring SSH backup? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "SSH restore cancelled."
        return 1
    fi
    remove_ssh_contents
    mkdir -p /home/comma/.ssh
    tar xzf "${latest_backup}/ssh/backup.tar.gz" -C /home/comma/.ssh
    [ -f "/home/comma/.ssh/github" ] && chmod 600 /home/comma/.ssh/github
    [ -f "/home/comma/.ssh/github.pub" ] && chmod 644 /home/comma/.ssh/github.pub
    [ -f "/home/comma/.ssh/config" ] && chmod 644 /home/comma/.ssh/config
    chown -R comma:comma /home/comma/.ssh
    copy_ssh_config_and_keys
    restart_ssh_agent
    print_success "SSH files restored successfully."
    return 0
}

###############################################################################
# Selective Backup Functions
###############################################################################
create_selective_backup() {
    clear
    echo "+----------------------------------------------+"
    echo "│           Create Selective Backup            │"
    echo "+----------------------------------------------+"
    echo "Select components to backup:"
    echo "1. SSH Files"
    echo "2. Params"
    echo "3. CommaUtil Settings"
    echo "4. All Components"
    echo "Q. Cancel"
    local components=()
    read -p "Enter choices (e.g., 123 for all): " choices
    [[ "$choices" =~ [qQ] ]] && return
    local device_id timestamp backup_name backup_dir
    device_id=$(get_device_id)
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_name="${device_id}_${timestamp}"
    backup_dir="${BACKUP_BASE_DIR}/${backup_name}"
    mkdir -p "$backup_dir"
    local success=true
    # Initialize checksum file
    local checksum_file="${backup_dir}/${BACKUP_CHECKSUM_FILE}"
    : >"$checksum_file"

    if [[ "$choices" == "4" ]] || [[ "$choices" =~ [1] ]]; then
        print_info "Backing up SSH files..."
        backup_component "ssh" "/home/comma/.ssh" "$backup_dir" "$checksum_file" || success=false
    fi

    if [[ "$choices" == "4" ]] || [[ "$choices" =~ [2] ]]; then
        print_info "Backing up Params..."
        backup_component params "$backup_dir" || success=false
    fi
    if [[ "$choices" == "4" ]] || [[ "$choices" =~ [3] ]]; then
        print_info "Backing up CommaUtil settings..."
        backup_component commautil "$backup_dir" || success=false
    fi
    if [ "$success" = true ]; then
        create_backup_metadata "$backup_dir" "$backup_name" "$device_id"
        print_success "Selective backup completed successfully"
    else
        print_error "Selective backup failed"
        rm -rf "$backup_dir"
        return 1
    fi
}

handle_backup_error() {
    local backup_dir="$1"
    local cleanup_required="$2"

    print_error "Backup operation failed"
    if [ "$cleanup_required" = true ]; then
        print_info "Cleaning up incomplete backup..."
        rm -rf "${backup_dir}" "${backup_dir}.tmp"
    fi
}

backup_component() {
    local component="$1"
    local source_dir="$2"
    local backup_dir="$3"
    local checksum_file="$4"

    [ ! -d "$source_dir" ] && return 0

    local archive_path="${backup_dir}/${component}/backup.tar.gz"
    if ! tar czf "$archive_path" -C "$(dirname "$source_dir")" "$(basename "$source_dir")"; then
        print_error "Failed to backup ${component}"
        return 1
    fi

    # Generate and store checksum
    sha256sum "$archive_path" | tee -a "$checksum_file"
    return 0
}

###############################################################################
# Automated Backup Function
###############################################################################
perform_automated_backup() {
    local network_id="$1"
    [ -z "$network_id" ] && {
        print_error "Missing network ID for automated backup"
        exit 1
    }
    if [ -f "/data/params/d/IsOnroad" ] && grep -q "^1" "/data/params/d/IsOnroad"; then
        print_error "Cannot perform backup while device is onroad"
        exit 1
    fi
    local network_config="/data/commautil/network_locations.json"
    [ ! -f "$network_config" ] && {
        print_error "Network configuration not found"
        exit 1
    }
    local location
    location=$(jq --arg id "$network_id" '.smb[] + .ssh[] | select(.location_id == $id)' "$network_config")
    [ -z "$location" ] && {
        print_error "Network location with ID $network_id not found"
        exit 1
    }
    local backup_result
    backup_result=$(backup_device "silent")
    [ $? -ne 0 ] && {
        print_error "Backup failed"
        exit 1
    }
    local backup_path
    backup_path=$(echo "$backup_result" | jq -r '.backup_path')
    if ! sync_backup_to_network "$backup_path" "$network_id"; then
        print_error "Network sync failed"
        exit 1
    fi
    exit 0
}

###############################################################################
# Legacy Backup Migration Functions
###############################################################################
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
            [ "$choice" = "1" ] && {
                print_info "Removing old backup data..."
                rm -rf "/data/ssh_backup"
                print_success "Old backup data removed"
            } ||
                print_info "Old backup data preserved at /data/ssh_backup"
            print_success "Migration completed successfully"
        else
            print_error "Backup failed - keeping old backup data"
        fi
        ;;
    3) print_info "Migration skipped. You can migrate later using the backup menu." ;;
    *) print_error "Invalid choice" ;;
    esac
    pause_for_user
}

remove_legacy_backup() {
    clear
    print_info "Old backup format detected at /data/ssh_backup"
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

###############################################################################
# Backup Menu
###############################################################################
backup_menu() {
    local backup_loc backup_job legacy_detected
    backup_loc=$(get_backup_location)
    backup_job=$(get_backup_job)
    has_legacy_backup && legacy_detected=true || legacy_detected=false
    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "│         Device Backup/Restore Manager        │"
        echo "+----------------------------------------------+"
        display_backup_status_short
        echo "│ "
        echo "│ Available Options:"
        echo "│ 1.  Create New Backup"
        echo "│ 2.  Create Selective Backup"
        echo "│ 3.  Restore from Backup"
        echo "│ 4.  Configure Network Location"
        if [ -n "$backup_loc" ]; then
            echo "│ 5.  Configure Auto-Backup"
            echo "│ 6.  Test Network Connection"
            echo "│ 7.  Network Location Settings"
            echo "│ 8.  Sync Backup to Network"
        fi
        if [ "$legacy_detected" = true ]; then
            echo "│ M.  Migrate Legacy Backup"
        fi
        echo "│ Q|B. Back to Main Menu"
        echo "+----------------------------------------------+"
        read -p "Enter your choice: " choice
        case $choice in
        1) backup_device ;;
        2) create_selective_backup ;;
        3) restore_components_menu ;;
        4) configure_network_location "device_backup" ;;
        5) manage_auto_backup_jobs ;;
        6)
            [ -n "$backup_loc" ] && {
                test_network_connection "$backup_loc"
                pause_for_user
            }
            ;;
        7) manage_network_locations_menu ;;
        8)
            if [ -n "$backup_loc" ]; then
                local location_id
                location_id=$(echo "$backup_loc" | jq -r .location_id)
                if [ -n "$location_id" ]; then
                    local latest_backup
                    latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d \
                        -exec stat -c "%Y %n" {} \; | sort -nr | head -n1 | cut -d' ' -f2)
                    [ -n "$latest_backup" ] && sync_backup_to_network "$latest_backup" "$location_id" || print_error "No backup available to sync"
                else
                    print_error "No network location configured"
                fi
            else
                print_error "No backup available to sync or no network location configured"
                pause_for_user
            fi
            ;;
        [mM])
            [ "$legacy_detected" = true ] && migrate_legacy_backup || {
                print_error "No legacy backup detected"
                pause_for_user
            }
            ;;
        [qQ | bB]) break ;;
        *)
            print_error "Invalid choice."
            pause_for_user
            ;;
        esac
    done
}

restore_components_menu() {
    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "│           Restore Components                 │"
        echo "+----------------------------------------------+"
        echo "│ 1. Restore SSH Files"
        echo "│ 2. Restore Params"
        echo "│ 3. Restore CommaUtil Settings"
        echo "│ 4. Restore Everything"
        echo "│ Q. Back"
        read -p "Select component to restore: " choice
        case $choice in
        1) restore_ssh_component ;;
        2)
            # For simplicity, extract params backup if available
            if [ -f "${latest_backup}/params/backup.tar.gz" ]; then
                tar xzf "${latest_backup}/params/backup.tar.gz" -C "/data/params"
                chown -R comma:comma "/data/params/d"
            else
                print_error "Params backup not found"
            fi
            ;;
        3)
            if [ -f "${latest_backup}/commautil/backup.tar.gz" ]; then
                tar xzf "${latest_backup}/commautil/backup.tar.gz" -C "/data"
                chown -R comma:comma "/data/commautil"
            else
                print_error "CommaUtil backup not found"
            fi
            ;;
        4) restore_backup ;;
        [qQ]) break ;;
        *) print_error "Invalid choice" ;;
        esac
        pause_for_user
    done
}

view_backup_details() {
    clear
    echo "+----------------------------------------------------+"
    echo "│               Available Backups                     │"
    echo "+----------------------------------------------------+"
    local backups=() i=1
    while IFS= read -r backup_dir; do
        if [ -f "${backup_dir}/${BACKUP_METADATA_FILE}" ]; then
            backups+=("$backup_dir")
            local metadata timestamp device_id size
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
            echo ""
            ((i++))
        fi
    done < <(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)
    [ ${#backups[@]} -eq 0 ] && echo "No backups found"
    pause_for_user
}

remove_backup() {
    local backup_dir="$1" network_only="${2:-false}" silent_mode="${3:-normal}"
    [ ! -d "$backup_dir" ] && {
        [ "$silent_mode" != "silent" ] && print_error "Backup directory not found: $backup_dir"
        return 1
    }
    local network_loc location_id
    if [ -f "$NETWORK_CONFIG" ]; then
        network_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG")
        location_id=$(echo "$network_loc" | jq -r '.location_id')
    fi
    if [ -n "$network_loc" ] && [ -n "$location_id" ]; then
        [ "$silent_mode" != "silent" ] && print_info "Removing backup from network location..."
        remove_backup_from_network "$backup_dir" "$location_id"
    fi
    [ "$network_only" = "false" ] && {
        [ "$silent_mode" != "silent" ] && print_info "Removing local backup..."
        rm -rf "$backup_dir"
        [ "$silent_mode" != "silent" ] && print_success "Backup removed successfully"
    }
    return 0
}

remove_backup_from_network() {
    local backup_dir="$1" location_id="$2"
    local location
    location=$(jq -r --arg id "$location_id" '.locations[] | select(.location_id == $id)' "$NETWORK_CONFIG")
    [ -z "$location" ] || [ "$location" = "null" ] && {
        print_error "Network location not found"
        return 1
    }
    local device_id backup_name remote_path
    device_id=$(get_device_id)
    backup_name=$(basename "$backup_dir")
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
        local server port username auth_type key_path
        server=$(echo "$location" | jq -r .server)
        port=$(echo "$location" | jq -r .port)
        username=$(echo "$location" | jq -r .username)
        auth_type=$(echo "$location" | jq -r .auth_type)
        if [ "$auth_type" = "password" ]; then
            local password
            password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")
            sshpass -p "$password" ssh -p "$port" "$username@$server" "rm -rf '$remote_path'"
        else
            key_path=$(echo "$location" | jq -r .key_path)
            ssh -p "$port" -i "$key_path" "$username@$server" "rm -rf '$remote_path'"
        fi
        ;;
    esac
}

remove_all_backups() {
    local network_only="${1:-false}" silent_mode="${2:-normal}"
    [ "$silent_mode" != "silent" ] && {
        echo "WARNING: This will remove all backups"
        echo "from the network location only." [ "$network_only" = "true" ] && echo "from the network location only." || echo "both locally and from the network location."
        read -p "Are you sure you want to continue? (y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return 1
    }
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
    local backups=() i=1
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
    [ ${#backups[@]} -eq 0 ] && {
        print_error "No backups found"
        pause_for_user
        return 1
    }
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
