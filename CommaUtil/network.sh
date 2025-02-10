#!/bin/bash
###############################################################################
# network.sh - Device Network Helper Functions for CommaUtility
#
# Version: NETWORK_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script contains helper functions for network operations.
###############################################################################
readonly NETWORK_SCRIPT_VERSION="3.0.1"
readonly NETWORK_SCRIPT_MODIFIED="2025-02-09"

###############################################################################
# Network Helper Functions
###############################################################################
check_network_connectivity() {
    local host="${1:-github.com}"
    local timeout="${2:-5}"
    local retry_count="${3:-3}"
    local retry_delay="${4:-2}"

    for ((i = 1; i <= retry_count; i++)); do
        if ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1; then
            return 0
        fi

        if [ $i -lt $retry_count ]; then
            print_warning "Network check attempt $i failed. Retrying in $retry_delay seconds..."
            sleep "$retry_delay"
        fi
    done

    return 1
}

execute_with_network_retry() {
    local cmd="$1"
    local error_msg="${2:-Network operation failed}"
    local retry_count="${3:-3}"
    local retry_delay="${4:-5}"
    local attempt=1

    while [ $attempt -le $retry_count ]; do
        if ! check_network_connectivity; then
            print_warning "No network connectivity. Checking again in $retry_delay seconds..."
            sleep "$retry_delay"
            attempt=$((attempt + 1))
            continue
        fi

        if eval "$cmd"; then
            return 0
        fi

        print_warning "Attempt $attempt of $retry_count failed. Retrying in $retry_delay seconds..."
        sleep "$retry_delay"
        attempt=$((attempt + 1))
    done

    print_error "$error_msg after $retry_count attempts"
    return 1
}

###############################################################################
# Network Location Functions
###############################################################################

verify_network_connectivity() {
    local type="$1"
    local location="$2"

    if [ "$type" = "smb" ]; then
        local status
        status=$(test_smb_connection "$location")
        [ "$status" = "Valid" ] || {
            print_error "SMB connection failed: $status"
            return 1
        }
    else
        local status
        status=$(test_network_ssh "$location")
        [ "$status" = "Valid" ] || {
            print_error "SSH connection failed: $status"
            return 1
        }
    fi
    return 0
}

get_location_label() {
    local location_id="$1"
    jq -r --arg id "$location_id" '.smb[] + .ssh[] | select(.location_id == $id) | .label' "$NETWORK_CONFIG"
}

generate_location_id() {
    local seed="$1"
    echo -n "$seed" | md5sum | cut -d ' ' -f1
}

# Enhance select_network_location to output location ID when needed
select_network_location_id() {
    local required_type="$1"
    if [ -n "$required_type" ]; then
        local location_id=$(jq -r --arg type "$required_type" '.locations[] | select(.type == $type) | .location_id' "$NETWORK_CONFIG")
        if [ -n "$location_id" ] && [ "$location_id" != "null" ]; then
            echo "$location_id"
            return 0
        fi
    fi
    return 1
}

verify_network_config() {
    if [ ! -f "$NETWORK_CONFIG" ]; then
        print_error "Network configuration file not found. Please configure network locations first."
        return 1
    fi
    if ! jq empty "$NETWORK_CONFIG" 2>/dev/null; then
        print_error "Network configuration file is corrupted. Please reconfigure network locations."
        return 1
    fi
    return 0
}

###############################################################################
# Network Location Management Functions (with label, storage_type, location_id)
###############################################################################
init_network_config() {
    mkdir -p "$CONFIG_DIR" "$CREDENTIALS_DIR"
    if [ ! -f "$NETWORK_CONFIG" ]; then
        # Initialize with empty locations array
        echo '{"locations":[]}' >"$NETWORK_CONFIG"
    fi
}

get_network_location_by_id() {
    local network_id="$1"
    local location
    location=$(jq --arg id "$network_id" '.locations[] | select(.location_id == $id)' "$NETWORK_CONFIG")
    if [ -z "$location" ] || [ "$location" = "null" ]; then
        print_error "Network location not found"
        return 1
    fi
    echo "$location"
    return 0
}

add_smb_location() {
    local location_type="$1"
    local type_label
    type_label="SSH Backup"

    # Check if location of this type already exists
    local existing_location
    existing_location=$(jq -r --arg type "$location_type" '.locations[] | select(.type == $type)' "$NETWORK_CONFIG")

    if [ -n "$existing_location" ]; then
        clear
        print_warning "A $type_label location is already configured."
        echo "Current configuration:"
        echo "Server: $(echo "$existing_location" | jq -r .server)"
        echo "Share: $(echo "$existing_location" | jq -r .share)"
        echo "Label: $(echo "$existing_location" | jq -r .label)"
        echo ""
        read -p "Do you want to replace this configuration? (y/N): " replace_choice
        if [[ ! "$replace_choice" =~ ^[Yy]$ ]]; then
            print_info "Configuration cancelled."
            pause_for_user
            return 1
        fi
        # Remove existing location before adding new one
        local temp_file="/tmp/network_config.json"
        jq --arg type "$location_type" '.locations = [.locations[] | select(.type != $type)]' "$NETWORK_CONFIG" >"$temp_file"
        mv "$temp_file" "$NETWORK_CONFIG"
    fi

    clear
    print_info "Add New SMB Share for $type_label..."
    print_info "----------------------------------------"
    read -p "Server (IP/hostname): " server
    read -p "Share name: " share
    read -p "Path [Inside $server/$share] (optional): " path
    read -p "Location Label (e.g. Home_NAS): " label
    read -p "Username: " username
    read -s -p "Password: (Will be encrypted): " password
    echo ""

    # Create credentials file with unique name based on type
    local cred_file="$CREDENTIALS_DIR/smb_${location_type}_${server}_${share}"
    encrypt_credentials "$password" "$cred_file" || {
        print_error "Encryption error."
        pause_for_user
        return 1
    }

    # Generate unique location ID
    local loc_id
    loc_id=$(generate_location_id "${server}_${share}_${label}_${location_type}")

    # Create location object
    local location
    location=$(jq -n \
        --arg server "$server" \
        --arg share "$share" \
        --arg path "$path" \
        --arg username "$username" \
        --arg cred_file "$cred_file" \
        --arg label "$label" \
        --arg type "$location_type" \
        --arg protocol "smb" \
        --arg location_id "$loc_id" \
        '{
            server: $server,
            share: $share,
            path: $path,
            username: $username,
            credential_file: $cred_file,
            label: $label,
            type: $type,
            protocol: $protocol,
            location_id: $location_id
        }')

    # Add to config
    local temp_file="/tmp/network_config.json"
    jq --argjson loc "$location" '.locations += [$loc]' "$NETWORK_CONFIG" >"$temp_file"
    mv "$temp_file" "$NETWORK_CONFIG"

    print_success "$type_label SMB share added successfully."
    pause_for_user
}

add_ssh_location() {
    local location_type="$1"
    local type_label
    type_label="SSH Backup"

    # Check if location of this type already exists
    local existing_location
    existing_location=$(jq -r --arg type "$location_type" '.locations[] | select(.type == $type)' "$NETWORK_CONFIG")

    if [ -n "$existing_location" ]; then
        clear
        print_warning "A $type_label location is already configured."
        echo "Current configuration:"
        echo "Server: $(echo "$existing_location" | jq -r .server)"
        echo "Port: $(echo "$existing_location" | jq -r .port)"
        echo "Label: $(echo "$existing_location" | jq -r .label)"
        echo ""
        read -p "Do you want to replace this configuration? (y/N): " replace_choice
        if [[ ! "$replace_choice" =~ ^[Yy]$ ]]; then
            print_info "Configuration cancelled."
            pause_for_user
            return 1
        fi
        # Remove existing location before adding new one
        local temp_file="/tmp/network_config.json"
        jq --arg type "$location_type" '.locations = [.locations[] | select(.type != $type)]' "$NETWORK_CONFIG" >"$temp_file"
        mv "$temp_file" "$NETWORK_CONFIG"
    fi

    clear
    print_info "Add New SSH Location for $type_label..."
    print_info "----------------------------------------"
    read -p "Server (IP/hostname): " server
    read -p "Port [22]: " port
    port=${port:-22}
    read -p "Path: " path
    read -p "Location Label (e.g. Home_Server): " label
    read -p "Username: " username

    echo "Authentication type:"
    echo "1. Password"
    echo "2. SSH Key"
    read -p "Select Authentication Type (1/2): " auth_choice

    # Generate unique location ID
    local loc_id
    loc_id=$(generate_location_id "${server}_${port}_${label}_${location_type}")

    local location
    if [ "$auth_choice" = "1" ]; then
        read -s -p "Password: (Will be encrypted): " password
        echo ""
        local cred_file="$CREDENTIALS_DIR/ssh_${location_type}_${server}_${port}"
        encrypt_credentials "$password" "$cred_file" || {
            print_error "Encryption error."
            pause_for_user
            return 1
        }
        location=$(jq -n \
            --arg server "$server" \
            --arg port "$port" \
            --arg path "$path" \
            --arg username "$username" \
            --arg cred_file "$cred_file" \
            --arg label "$label" \
            --arg type "$location_type" \
            --arg protocol "ssh" \
            --arg auth_type "password" \
            --arg location_id "$loc_id" \
            '{
                server: $server,
                port: $port,
                path: $path,
                username: $username,
                credential_file: $cred_file,
                label: $label,
                type: $type,
                protocol: $protocol,
                auth_type: $auth_type,
                location_id: $location_id
            }')
    elif [ "$auth_choice" = "2" ]; then
        read -p "SSH Key path: " key_path
        location=$(jq -n \
            --arg server "$server" \
            --arg port "$port" \
            --arg path "$path" \
            --arg username "$username" \
            --arg key_path "$key_path" \
            --arg label "$label" \
            --arg type "$location_type" \
            --arg protocol "ssh" \
            --arg auth_type "key" \
            --arg location_id "$loc_id" \
            '{
                server: $server,
                port: $port,
                path: $path,
                username: $username,
                key_path: $key_path,
                label: $label,
                type: $type,
                protocol: $protocol,
                auth_type: $auth_type,
                location_id: $location_id
            }')
    else
        print_error "Invalid authentication type."
        pause_for_user
        return 1
    fi

    # Add to config
    local temp_file="/tmp/network_config.json"
    jq --argjson loc "$location" '.locations += [$loc]' "$NETWORK_CONFIG" >"$temp_file"
    mv "$temp_file" "$NETWORK_CONFIG"

    print_success "$type_label SSH location added successfully."
    pause_for_user
}

test_all_connections() {
    clear
    echo "┌───────────────────────────────────────────────┐"
    echo "│           Testing Network Locations           │"
    echo "└───────────────────────────────────────────────┘"

    # Test SSH Backup Location
    local backup_loc status
    backup_loc=$(jq -r '.locations[] | select(.type == "ssh_backup")' "$NETWORK_CONFIG")
    if [ -n "$backup_loc" ]; then
        local protocol label
        protocol=$(echo "$backup_loc" | jq -r .protocol)
        label=$(echo "$backup_loc" | jq -r .label)
        echo -n "│ Testing SSH Backup Location ($label)... "
        if [ "$protocol" = "smb" ]; then
            status=$(test_smb_connection "$backup_loc")
        else
            status=$(test_network_ssh "$backup_loc")
        fi
        if [ "$status" = "Valid" ]; then
            echo -e "│ ${GREEN}Connected${NC}"
        else
            echo -e "│ ${RED}Failed${NC}"
            echo "│ Error: $status"
        fi
    else
        echo -e "│ ${YELLOW}No SSH Backup Location configured${NC}"
    fi

    pause_for_user
}

test_smb_connection() {
    local location="$1"
    local server=$(echo "$location" | jq -r .server)
    local share=$(echo "$location" | jq -r .share)
    local username=$(echo "$location" | jq -r .username)
    local cred_file=$(echo "$location" | jq -r .credential_file)

    if [ ! -f "$cred_file" ]; then
        echo "Credential file not found"
        return 1
    fi

    local password
    password=$(decrypt_credentials "$cred_file")
    if [ -z "$password" ]; then
        echo "Failed to decrypt credentials"
        return 1
    fi

    local output
    output=$(smbclient "//${server}/${share}" -U "${username}%${password}" -c 'ls' 2>&1)
    if [ $? -eq 0 ]; then
        echo "Valid"
        return 0
    else
        echo "$output"
        return 1
    fi
}

test_network_ssh() {
    local location="$1"
    local server port username auth_type

    server=$(echo "$location" | jq -r .server)
    port=$(echo "$location" | jq -r .port)
    username=$(echo "$location" | jq -r .username)
    auth_type=$(echo "$location" | jq -r .auth_type)

    local ssh_cmd="ssh -p $port -o BatchMode=yes -o ConnectTimeout=5"

    if [ "$auth_type" = "password" ]; then
        local password
        password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")
        if sshpass -p "$password" $ssh_cmd "$username@$server" 'exit' 2>/dev/null; then
            echo "Valid"
            return 0
        fi
    else
        local key_path
        key_path=$(echo "$location" | jq -r .key_path)
        if $ssh_cmd -i "$key_path" "$username@$server" 'exit' 2>/dev/null; then
            echo "Valid"
            return 0
        fi
    fi

    echo "Connection failed"
    return 1
}

check_smb_ssh_backup_exists() {
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
        return 1
    fi

    # Check if backup exists by trying to access the backup file
    local remote_path="$path/ssh_backup"
    if ! smbclient "//${server}/${share}" -U "${username}%${password}" -c "ls ${remote_path}/ssh_backup.tar.gz" >/dev/null 2>&1; then
        return 1
    fi

    return 0
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

remove_network_location() {
    local location_type="$1"
    local type_label
    type_label="SSH Backup"

    local existing_location
    existing_location=$(jq -r --arg type "$location_type" '.locations[] | select(.type == $type)' "$NETWORK_CONFIG")

    if [ -z "$existing_location" ]; then
        print_error "No $type_label location configured."
        pause_for_user
        return 1
    fi

    clear
    echo "Current $type_label location:"
    echo "Server: $(echo "$existing_location" | jq -r .server)"
    if [ "$(echo "$existing_location" | jq -r .protocol)" = "smb" ]; then
        echo "Share: $(echo "$existing_location" | jq -r .share)"
    else
        echo "Port: $(echo "$existing_location" | jq -r .port)"
    fi
    echo "Label: $(echo "$existing_location" | jq -r .label)"
    echo ""

    read -p "Are you sure you want to remove this location? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local temp_file="/tmp/network_config.json"
        jq --arg type "$location_type" '.locations = [.locations[] | select(.type != $type)]' "$NETWORK_CONFIG" >"$temp_file"
        mv "$temp_file" "$NETWORK_CONFIG"

        # Remove credentials file if it exists
        local cred_file
        cred_file=$(echo "$existing_location" | jq -r '.credential_file // empty')
        if [ -n "$cred_file" ] && [ -f "$cred_file" ]; then
            rm -f "$cred_file"
        fi

        print_success "$type_label location removed."
    else
        print_info "Removal cancelled."
    fi
    pause_for_user
}

manage_network_locations_menu() {
    while true; do
        clear
        echo "┌───────────────────────────────────────────────┐"
        echo "│          Network Location Management          │"
        echo "└───────────────────────────────────────────────┘"

        # Show SSH Backup Location
        local backup_loc
        backup_loc=$(jq -r '.locations[] | select(.type == "ssh_backup")' "$NETWORK_CONFIG")
        if [ -n "$backup_loc" ]; then
            local protocol label status
            protocol=$(echo "$backup_loc" | jq -r .protocol)
            label=$(echo "$backup_loc" | jq -r .label)
            if [ "$protocol" = "smb" ]; then
                status=$(test_smb_connection "$backup_loc")
            else
                status=$(test_network_ssh "$backup_loc")
            fi
            if [ "$status" = "Valid" ]; then
                echo -e "│ SSH Backup Location:"
                echo -e "│  - Label: ${GREEN}$label${NC}"
                echo -e "│  - Protocol: ${GREEN}$protocol${NC}"
                echo -e "│  - Status: ${GREEN}Connected${NC}"
            else
                echo -e "│ SSH Backup Location:"
                echo -e "│  - Label: ${RED}$label${NC}"
                echo -e "│  - Protocol: ${RED}$protocol${NC}"
                echo -e "│  - Status: ${RED}Disconnected${NC}"
            fi
        else
            echo -e "│ SSH Backup Location: ${YELLOW}Not Configured${NC}"
        fi

        echo "│"
        echo "│ Available Options:"
        if [ -n "$backup_loc" ]; then
            echo "│ 1. Configure SSH Backup Location"
        else
            echo "│ 1. Remove SSH Backup Location"
            echo "│ 2. Test Connection"
        fi
        echo "│ Q. Back"
        echo "└───────────────────────────────────────────────┘"

        read -p "Make a selection: " choice
        case $choice in
        1)
            if [ -n "$backup_loc" ]; then
                configure_network_location "ssh_backup"
            else
                remove_network_location "ssh_backup"
            fi
            ;;
        2)
            if [ -n "$backup_loc" ]; then
                test_all_connections
            else
                print_error "No SSH Backup Location configured."
                pause_for_user
            fi
            ;;
        [qQ]) return ;;
        *) print_error "Invalid choice." && pause_for_user ;;
        esac
    done
}

configure_network_location() {
    local location_type="$1"
    local type_label
    type_label="SSH Backup"

    clear
    echo "┌───────────────────────────────────────────────┐"
    echo "│        Configure $type_label Location         │"
    echo "└───────────────────────────────────────────────┘"
    echo "│ Select Protocol:"
    echo "│ 1. SMB Share"
    echo "│ 2. SSH Location"
    echo "│ Q. Cancel"
    echo "└────────────────────────────────────────────────"

    read -p "Enter choice: " protocol_choice

    case $protocol_choice in
    1)
        add_smb_location "$location_type"
        ;;
    2)
        add_ssh_location "$location_type"
        ;;
    [qQ])
        return
        ;;
    *)
        print_error "Invalid choice."
        pause_for_user
        return
        ;;
    esac
}

select_network_location() {
    local required_type="$1"
    local location

    # If type is specified, try to get that specific location
    if [ -n "$required_type" ]; then
        location=$(jq -r --arg type "$required_type" '.locations[] | select(.type == $type)' "$NETWORK_CONFIG")
        if [ -n "$location" ]; then
            echo "$location"
            return 0
        fi
        print_error "No location configured for $required_type"
        return 1
    fi

    # Otherwise, show selection menu
    clear
    echo "┌───────────────────────────────────────────────┐"
    echo "│            Select Network Location            │"
    echo "└───────────────────────────────────────────────┘"

    local locations
    locations=$(jq -r '.locations[] | "\(.type)|\(.label)"' "$NETWORK_CONFIG")

    if [ -z "$locations" ]; then
        print_error "No network locations configured."
        return 1
    fi

    local count=1
    while IFS='|' read -r type label; do
        echo "│ $count) $type: $label"
        count=$((count + 1))
    done <<<"$locations"

    echo "│ Q) Cancel"
    echo "└────────────────────────────────────────────────"

    read -p "Select location: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$count" ]; then
        location=$(jq -r ".locations[$(($choice - 1))]" "$NETWORK_CONFIG")
        echo "$location"
        return 0
    elif [[ "$choice" =~ ^[qQ]$ ]]; then
        return 1
    else
        print_error "Invalid selection."
        return 1
    fi
}
