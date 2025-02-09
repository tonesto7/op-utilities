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
readonly BACKUPS_SCRIPT_VERSION="3.0.1"
readonly BACKUPS_SCRIPT_MODIFIED="2025-02-08"

readonly BACKUP_BASE_DIR="/data/device_backup"
readonly BACKUP_METADATA_FILE="metadata.json"
readonly BACKUP_CHECKSUM_FILE="checksum.sha256"

###############################################################################
# Backup Operations
###############################################################################

backup_ssh_to_network() {
    local location_id="$1"
    local location

    if [ -z "$location_id" ]; then
        # No location specified, try to select one
        if ! verify_network_config; then
            print_info "No network locations configured."
            read -p "Would you like to configure a network location now? (y/N): " setup_choice
            if [[ "$setup_choice" =~ ^[Yy]$ ]]; then
                manage_network_locations_menu
                location_id=$(select_network_location_id)
            else
                return 1
            fi
        else
            location_id=$(select_network_location_id)
        fi
    fi

    # Get location details
    location=$(get_network_location_by_id "$location_id")
    if [ $? -ne 0 ]; then
        print_error "Failed to get network location details"
        return 1
    fi

    # Ensure we have a local backup first
    if ! check_ssh_backup; then
        print_info "Creating local backup first..."
        backup_ssh
    fi

    print_info "Backing up SSH files to network location..."

    local protocol
    protocol=$(echo "$location" | jq -r .protocol)

    case "$protocol" in
    "smb")
        backup_ssh_to_smb "$location"
        ;;
    "ssh")
        backup_ssh_to_ssh "$location"
        ;;
    *)
        print_error "Unsupported protocol: $protocol"
        return 1
        ;;
    esac
}

backup_ssh_to_smb() {
    local location="$1"
    local server share username path
    server=$(echo "$location" | jq -r .server)
    share=$(echo "$location" | jq -r .share)
    username=$(echo "$location" | jq -r .username)
    path=$(echo "$location" | jq -r .path)
    local cred_file=$(echo "$location" | jq -r .credential_file)
    local password

    password=$(decrypt_credentials "$cred_file")
    if [ -z "$password" ]; then
        print_error "Failed to decrypt network credentials"
        return 1
    fi

    local remote_path="$path/ssh_backup"
    local tmp_archive="/tmp/ssh_backup.tar.gz"

    # Create temporary archive
    tar -czf "$tmp_archive" -C "$CONFIG_DIR/backups" ssh

    # Upload to SMB share
    if ! smbclient "//${server}/${share}" -U "${username}%${password}" -c "mkdir ${remote_path}; put ${tmp_archive} ${remote_path}/ssh_backup.tar.gz"; then
        print_error "Failed to upload backup to SMB share"
        rm -f "$tmp_archive"
        return 1
    fi

    rm -f "$tmp_archive"
    print_success "SSH backup uploaded to network location"
    return 0
}

backup_ssh_to_ssh() {
    local location="$1"
    local server port username path auth_type
    server=$(echo "$location" | jq -r .server)
    port=$(echo "$location" | jq -r .port)
    username=$(echo "$location" | jq -r .username)
    path=$(echo "$location" | jq -r .path)
    auth_type=$(echo "$location" | jq -r .auth_type)

    local tmp_archive="/tmp/ssh_backup.tar.gz"
    tar -czf "$tmp_archive" -C "$CONFIG_DIR/backups" ssh

    if [ "$auth_type" = "password" ]; then
        local password
        password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")
        sshpass -p "$password" scp -P "$port" "$tmp_archive" "${username}@${server}:${path}/ssh_backup.tar.gz"
    else
        local key_path
        key_path=$(echo "$location" | jq -r .key_path)
        scp -i "$key_path" -P "$port" "$tmp_archive" "${username}@${server}:${path}/ssh_backup.tar.gz"
    fi

    rm -f "$tmp_archive"
    print_success "SSH backup uploaded to network location"
    return 0
}

restore_ssh_from_network() {
    local location_id="$1"
    local location

    if [ -z "$location_id" ]; then
        if ! verify_network_config; then
            print_info "No network locations configured."
            read -p "Would you like to configure a network location now? (y/N): " setup_choice
            if [[ "$setup_choice" =~ ^[Yy]$ ]]; then
                manage_network_locations_menu
                location_id=$(select_network_location_id)
            else
                return 1
            fi
        else
            location_id=$(select_network_location_id)
        fi
    fi

    location=$(get_network_location_by_id "$location_id")
    if [ $? -ne 0 ]; then
        print_error "Failed to get network location details"
        return 1
    fi

    print_info "Restoring SSH files from network location..."

    local protocol
    protocol=$(echo "$location" | jq -r .protocol)

    case "$protocol" in
    "smb")
        restore_ssh_from_smb "$location"
        ;;
    "ssh")
        restore_ssh_from_ssh "$location"
        ;;
    *)
        print_error "Unsupported protocol: $protocol"
        return 1
        ;;
    esac
}

restore_ssh_from_smb() {
    local location="$1"
    local server share username path
    server=$(echo "$location" | jq -r .server)
    share=$(echo "$location" | jq -r .share)
    username=$(echo "$location" | jq -r .username)
    path=$(echo "$location" | jq -r .path)
    local cred_file=$(echo "$location" | jq -r .credential_file)
    local password

    password=$(decrypt_credentials "$cred_file")
    if [ -z "$password" ]; then
        print_error "Failed to decrypt network credentials"
        return 1
    fi

    local remote_path="$path/ssh_backup"
    local tmp_archive="/tmp/ssh_backup.tar.gz"

    # Download from SMB share
    if ! smbclient "//${server}/${share}" -U "${username}%${password}" -c "get ${remote_path}/ssh_backup.tar.gz ${tmp_archive}"; then
        print_error "Failed to download backup from SMB share"
        return 1
    fi

    # Extract archive
    rm -rf "$CONFIG_DIR/backups/ssh"
    tar -xzf "$tmp_archive" -C "$CONFIG_DIR/backups"
    rm -f "$tmp_archive"

    # Now restore from local backup
    restore_ssh

    print_success "SSH backup restored from network location"
    return 0
}

restore_ssh_from_ssh() {
    local location="$1"
    local server port username path auth_type
    server=$(echo "$location" | jq -r .server)
    port=$(echo "$location" | jq -r .port)
    username=$(echo "$location" | jq -r .username)
    path=$(echo "$location" | jq -r .path)
    auth_type=$(echo "$location" | jq -r .auth_type)

    local tmp_archive="/tmp/ssh_backup.tar.gz"

    if [ "$auth_type" = "password" ]; then
        local password
        password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")
        sshpass -p "$password" scp -P "$port" "${username}@${server}:${path}/ssh_backup.tar.gz" "$tmp_archive"
    else
        local key_path
        key_path=$(echo "$location" | jq -r .key_path)
        scp -i "$key_path" -P "$port" "${username}@${server}:${path}/ssh_backup.tar.gz" "$tmp_archive"
    fi

    # Extract archive
    rm -rf "$CONFIG_DIR/backups/ssh"
    tar -xzf "$tmp_archive" -C "$CONFIG_DIR/backups"
    rm -f "$tmp_archive"

    # Now restore from local backup
    restore_ssh

    print_success "SSH backup restored from network location"
    return 0
}

configure_network_ssh_backup() {
    clear
    print_info "Configuring network backup location..."
    manage_network_locations_menu

    if verify_network_config; then
        read -p "Would you like to configure this as your preferred backup location? (Y/n): " configure_pref
        if [[ ! "$configure_pref" =~ ^[Nn]$ ]]; then
            configure_preferred_backup_location

            if [ -n "$(get_preferred_location "ssh_backup")" ] && check_ssh_backup; then
                read -p "Would you like to sync your local backup to the network now? (Y/n): " sync_now
                if [[ ! "$sync_now" =~ ^[Nn]$ ]]; then
                    backup_ssh_to_network
                fi
            fi
        fi
    fi
}

###############################################################################
# SSH Preferred Location Functions
###############################################################################

get_preferred_ssh_location() {
    local location_type="$1" # e.g., "ssh_backup"
    if [ -f "$CONFIG_DIR/preferred_locations.json" ]; then
        jq -r --arg type "$location_type" '.[$type] // empty' "$CONFIG_DIR/preferred_locations.json"
    fi
}

set_preferred_ssh_location() {
    local location_type="$1"
    local location_id="$2"
    local config_file="$CONFIG_DIR/preferred_locations.json"

    # Create or update the preferred locations file
    if [ ! -f "$config_file" ]; then
        echo "{}" >"$config_file"
    fi

    # Update the preferred location
    jq --arg type "$location_type" --arg id "$location_id" \
        '.[$type] = $id' "$config_file" >"${config_file}.tmp" &&
        mv "${config_file}.tmp" "$config_file"
}

clear_preferred_ssh_location() {
    local location_type="$1"
    local config_file="$CONFIG_DIR/preferred_locations.json"

    if [ -f "$config_file" ]; then
        jq --arg type "$location_type" 'del(.[$type])' "$config_file" >"${config_file}.tmp" &&
            mv "${config_file}.tmp" "$config_file"
    fi
}

configure_preferred_ssh_backup_location() {
    clear
    echo "┌───────────────────────────────────────────────"
    echo "│         Configure Preferred SSH Backup        "
    echo "└───────────────────────────────────────────────"

    local current_preferred
    current_preferred=$(get_preferred_ssh_location "ssh_backup")

    if [ -n "$current_preferred" ]; then
        local current_label
        current_label=$(get_location_label "$current_preferred")
        echo "│ Current preferred location: $current_label"
    else
        echo "│ No preferred location set"
    fi

    echo "│"
    echo "│ Options:"
    echo "│ 1. Select new preferred location"
    echo "│ 2. Clear preferred location"
    echo "│ 3. Configure new network location"
    echo "│ Q. Cancel"

    read -p "Enter choice: " pref_choice

    case $pref_choice in
    1)
        local location_id
        if location_id=$(select_network_location_id); then
            set_preferred_ssh_location "ssh_backup" "$location_id"
            print_success "Preferred location updated"
        fi
        ;;
    2)
        clear_preferred_ssh_location "ssh_backup"
        print_success "Preferred location cleared"
        ;;
    3)
        manage_network_locations_menu
        configure_preferred_ssh_backup_location # Recurse to allow selection after configuration
        ;;
    [qQ])
        return
        ;;
    *)
        print_error "Invalid choice"
        ;;
    esac
    pause_for_user
}

check_network_ssh_backup_exists() {
    local location_id="$1"
    local location
    location=$(get_network_location_by_id "$location_id")
    if [ $? -ne 0 ]; then
        return 1
    fi

    local protocol
    protocol=$(echo "$location" | jq -r .protocol)

    case "$protocol" in
    "smb")
        check_smb_backup_exists "$location"
        return $?
        ;;
    "ssh")
        check_ssh_backup_exists "$location"
        return $?
        ;;
    *)
        return 1
        ;;
    esac
}

get_network_ssh_backup_date() {
    local location_id="$1"
    local location
    location=$(get_network_location_by_id "$location_id")
    if [ $? -ne 0 ]; then
        return 1
    fi

    local protocol
    protocol=$(echo "$location" | jq -r .protocol)

    case "$protocol" in
    "smb")
        get_smb_ssh_backup_date "$location"
        ;;
    "ssh")
        get_ssh_ssh_backup_date "$location"
        ;;
    *)
        echo ""
        ;;
    esac
}

handle_ssh_backup_menu_choice() {
    local choice="$1"
    local has_local_backup="$2"
    local has_network_location="$3"
    local has_network_backup="$4"

    if [ "$has_local_backup" = true ]; then
        case $choice in
        1) backup_ssh ;;
        2) restore_ssh ;;
        3)
            if [ "$has_network_location" = true ]; then
                if [ "$has_network_backup" = true ]; then
                    backup_ssh_to_network
                else
                    # Initial network sync
                    configure_preferred_ssh_backup_location
                    local preferred_location_id=$(get_preferred_ssh_location "ssh_backup")
                    if [ -n "$preferred_location_id" ]; then
                        backup_ssh_to_network "$preferred_location_id"
                    fi
                fi
            else
                configure_network_ssh_backup
            fi
            ;;
        4)
            if [ "$has_network_backup" = true ]; then
                restore_ssh_from_network
            else
                configure_preferred_ssh_backup_location
            fi
            ;;
        5) configure_preferred_ssh_backup_location ;;
        esac
    else
        case $choice in
        1) backup_ssh ;;
        2)
            if [ "$has_network_location" = true ] && [ "$has_network_backup" = true ]; then
                restore_ssh_from_network
            fi
            ;;
        esac
    fi
}
