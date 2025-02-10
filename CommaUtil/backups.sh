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
readonly BACKUPS_SCRIPT_VERSION="3.0.0"
readonly BACKUPS_SCRIPT_MODIFIED="2025-02-10"

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
                location_id=$(select_network_location_id "ssh_backup")
            else
                return 1
            fi
        else
            location_id=$(select_network_location_id "ssh_backup")
        fi
    fi

    # Get location details
    location=$(get_network_location_by_id "$location_id")
    if [ $? -ne 0 ]; then
        print_error "Failed to get network location details"
        pause_for_user
        return 1
    fi

    # Ensure we have a local backup first
    if ! check_ssh_backup; then
        print_info "Creating local backup first..."
        backup_ssh
        pause_for_user
    fi

    print_info "Backing up SSH files to network location..."

    local protocol
    protocol=$(echo "$location" | jq -r .protocol)

    case "$protocol" in
    "smb")
        backup_ssh_to_smb "$location"
        pause_for_user
        ;;
    "ssh")
        backup_ssh_to_ssh "$location"
        pause_for_user
        ;;
    *)
        print_error "Unsupported protocol: $protocol"
        pause_for_user
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

    # Get dongle-specific backup path
    local remote_path=$(get_network_backup_path "$path/ssh_backup")
    local tmp_archive="/tmp/ssh_backup.tar.gz"
    local tmp_metadata="/tmp/metadata.txt"

    # Create temporary archive
    tar -czf "$tmp_archive" -C "$CONFIG_DIR/backups" ssh

    # Copy metadata file to temp
    cp "$SSH_BACKUP_DIR/metadata.txt" "$tmp_metadata"

    # Create each level of the directory structure
    local current_path=""
    for dir in ${remote_path//\// }; do
        current_path="${current_path}/${dir}"
        smbclient "//${server}/${share}" -U "${username}%${password}" -c "mkdir \"${current_path}\"" 2>/dev/null || true
    done

    # Create the ssh_backup directory
    smbclient "//${server}/${share}" -U "${username}%${password}" -c "mkdir \"${remote_path}\"" 2>/dev/null || true

    # Upload both files to SMB share
    if ! smbclient "//${server}/${share}" -U "${username}%${password}" -c "put ${tmp_archive} \"${remote_path}/ssh_backup.tar.gz\""; then
        print_error "Failed to upload backup to SMB share"
        rm -f "$tmp_archive" "$tmp_metadata"
        return 1
    fi

    if ! smbclient "//${server}/${share}" -U "${username}%${password}" -c "put ${tmp_metadata} \"${remote_path}/metadata.txt\""; then
        print_warning "Failed to upload metadata file to SMB share"
    fi

    rm -f "$tmp_archive" "$tmp_metadata"
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
    local tmp_metadata="/tmp/metadata.txt"

    tar -czf "$tmp_archive" -C "$CONFIG_DIR/backups" ssh
    cp "$SSH_BACKUP_DIR/metadata.txt" "$tmp_metadata"

    if [ "$auth_type" = "password" ]; then
        local password
        password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")
        sshpass -p "$password" ssh -p "$port" "${username}@${server}" "mkdir -p ${path}/ssh_backup"
        sshpass -p "$password" scp -P "$port" "$tmp_archive" "${username}@${server}:${path}/ssh_backup/ssh_backup.tar.gz"
        sshpass -p "$password" scp -P "$port" "$tmp_metadata" "${username}@${server}:${path}/ssh_backup/metadata.txt"
    else
        local key_path
        key_path=$(echo "$location" | jq -r .key_path)
        ssh -i "$key_path" -p "$port" "${username}@${server}" "mkdir -p ${path}/ssh_backup"
        scp -i "$key_path" -P "$port" "$tmp_archive" "${username}@${server}:${path}/ssh_backup/ssh_backup.tar.gz"
        scp -i "$key_path" -P "$port" "$tmp_metadata" "${username}@${server}:${path}/ssh_backup/metadata.txt"
    fi

    rm -f "$tmp_archive" "$tmp_metadata"
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
                location_id=$(select_network_location_id "ssh_backup")
            else
                return 1
            fi
        else
            location_id=$(select_network_location_id "ssh_backup")
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
        local network_location
        network_location=$(jq -r '.locations[] | select(.type == "ssh_backup")' "$NETWORK_CONFIG")
        if [ -n "$network_location" ] && check_ssh_backup; then
            read -p "Would you like to sync your local backup to the network now? (Y/n): " sync_now
            if [[ ! "$sync_now" =~ ^[Nn]$ ]]; then
                backup_ssh_to_network
            fi
        fi
    fi
}

check_network_ssh_backup_exists() {
    local location_id="$1"
    local location

    # If no location_id provided, try to get the ssh_backup location
    if [ -z "$location_id" ]; then
        location=$(jq -r '.locations[] | select(.type == "ssh_backup")' "$NETWORK_CONFIG")
    else
        location=$(get_network_location_by_id "$location_id")
    fi

    if [ -z "$location" ] || [ "$location" = "null" ]; then
        return 1
    fi

    local protocol
    protocol=$(echo "$location" | jq -r .protocol)

    case "$protocol" in
    "smb")
        check_smb_ssh_backup_exists "$location"
        return $?
        ;;
    "ssh")
        check_ssh_ssh_backup_exists "$location"
        return $?
        ;;
    *)
        return 1
        ;;
    esac
}

get_backup_date_from_metadata() {
    local metadata_file="$1"
    if [ -f "$metadata_file" ]; then
        local backup_date
        backup_date=$(grep "Backup Date:" "$metadata_file" | cut -d: -f2- | xargs)
        echo "$backup_date"
        return 0
    fi
    return 1
}

get_network_ssh_backup_date() {
    local location_id="$1"
    local location

    # If no location_id provided, try to get the ssh_backup location
    if [ -z "$location_id" ]; then
        location=$(jq -r '.locations[] | select(.type == "ssh_backup")' "$NETWORK_CONFIG")
    else
        location=$(get_network_location_by_id "$location_id")
    fi

    if [ -z "$location" ] || [ "$location" = "null" ]; then
        return 1
    fi

    local protocol
    protocol=$(echo "$location" | jq -r .protocol)
    local tmp_file="/tmp/metadata.txt"

    case "$protocol" in
    "smb")
        # Download metadata file from SMB share
        if ! download_smb_metadata "$location" "$tmp_file"; then
            return 1
        fi
        ;;
    "ssh")
        # Download metadata file from SSH location
        if ! download_ssh_metadata "$location" "$tmp_file"; then
            return 1
        fi
        ;;
    esac

    if [ -f "$tmp_file" ]; then
        get_backup_date_from_metadata "$tmp_file"
        rm -f "$tmp_file"
        return 0
    fi
    return 1
}

download_smb_metadata() {
    local location="$1"
    local output_file="$2"
    local server share username path password

    server=$(echo "$location" | jq -r .server)
    share=$(echo "$location" | jq -r .share)
    username=$(echo "$location" | jq -r .username)
    path=$(echo "$location" | jq -r .path)
    password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")

    if [ -z "$password" ]; then
        return 1
    fi

    smbclient "//${server}/${share}" -U "${username}%${password}" \
        -c "get ${path}/ssh_backup/metadata.txt ${output_file}" >/dev/null 2>&1
}

download_ssh_metadata() {
    local location="$1"
    local output_file="$2"
    local server port username path auth_type

    server=$(echo "$location" | jq -r .server)
    port=$(echo "$location" | jq -r .port)
    username=$(echo "$location" | jq -r .username)
    path=$(echo "$location" | jq -r .path)
    auth_type=$(echo "$location" | jq -r .auth_type)

    if [ "$auth_type" = "password" ]; then
        local password
        password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")
        sshpass -p "$password" scp -P "$port" \
            "${username}@${server}:${path}/ssh_backup/metadata.txt" "$output_file" >/dev/null 2>&1
    else
        local key_path
        key_path=$(echo "$location" | jq -r .key_path)
        scp -i "$key_path" -P "$port" \
            "${username}@${server}:${path}/ssh_backup/metadata.txt" "$output_file" >/dev/null 2>&1
    fi
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
                local network_location
                network_location=$(jq -r '.locations[] | select(.type == "ssh_backup")' "$NETWORK_CONFIG")
                if [ -n "$network_location" ]; then
                    local location_id
                    location_id=$(echo "$network_location" | jq -r .location_id)
                    backup_ssh_to_network "$location_id"

                else
                    print_error "Failed to get network location"
                    pause_for_user
                fi
            else
                configure_network_ssh_backup
            fi
            ;;

        4)
            if [ "$has_network_backup" = true ]; then
                restore_ssh_from_network
            else
                print_error "No network backup exists"
                pause_for_user
            fi
            ;;
        esac
    else
        case $choice in
        1) backup_ssh ;;
        2)
            if [ "$has_network_location" = true ] && [ "$has_network_backup" = true ]; then
                restore_ssh_from_network
            else
                print_error "No network backup exists"
                pause_for_user
            fi
            ;;
        esac
    fi
}
