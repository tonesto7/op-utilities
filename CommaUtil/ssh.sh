#!/bin/bash

###############################################################################
# Global Variables
###############################################################################
readonly SSH_SCRIPT_VERSION="3.0.1"
readonly SSH_SCRIPT_MODIFIED="2025-02-08"

# Array to store SSH status
ssh_status=()

###############################################################################
# SSH Status & Management Functions
###############################################################################

test_ssh_connection() {
    local location="$1"
    local server=$(echo "$location" | jq -r .server)
    local port=$(echo "$location" | jq -r .port)
    local username=$(echo "$location" | jq -r .username)
    local auth_type=$(echo "$location" | jq -r .auth_type)
    local ssh_cmd="ssh -p $port -o BatchMode=yes -o ConnectTimeout=5"
    if [ "$auth_type" = "password" ]; then
        local cred_file password
        cred_file=$(echo "$location" | jq -r .credential_file)
        password=$(decrypt_credentials "$cred_file")
        output=$(sshpass -p "$password" $ssh_cmd "$username@$server" 'exit' 2>&1)
        if [ $? -eq 0 ]; then
            echo "Valid"
            return 0
        else
            echo "$output"
            return 1
        fi
    else
        local key_path
        key_path=$(echo "$location" | jq -r .key_path)
        output=$($ssh_cmd -i "$key_path" "$username@$server" 'exit' 2>&1)
        if [ $? -eq 0 ]; then
            echo "Valid"
            return 0
        else
            echo "$output"
            return 1
        fi
    fi
}

# Function to display mini SSH status
# Returns:
# - 0: Success
# - 1: Failure
display_ssh_status_short() {
    print_info "│ SSH Status:"
    if [ -f "/home/comma/.ssh/github" ]; then
        local latest_backup
        latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -c "%Y %n" {} \; 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2)

        if [ -n "$latest_backup" ] && [ -d "${latest_backup}/ssh" ] && [ -f "${latest_backup}/ssh/backup.tar.gz" ]; then
            local ssh_file_count
            ssh_file_count=$(tar -tzf "${latest_backup}/ssh/backup.tar.gz" 2>/dev/null | wc -l || echo 0)
            if [ "$ssh_file_count" -gt 0 ]; then
                echo -e "│ └─ Key: ${GREEN}Found (Backed Up)${NC}"
            else
                echo -e "│ └─ Key: ${GREEN}Found${NC} (Not Backed Up)"
            fi
        else
            echo -e "│ └─ Key: ${GREEN}Found${NC} (Not Backed Up)"
        fi
    else
        echo -e "${RED}| └─ Key: Not Found${NC}"
    fi
}

# Display detailed SSH status
# Returns:
# - 0: Success
# - 1: Failure
display_ssh_status() {
    echo "+----------------------------------------------+"
    echo "│                  SSH Status                  │"
    echo "+----------------------------------------------+"

    local expected_owner="comma"
    local expected_permissions="-rw-------"
    ssh_status=()

    # Check main key
    check_file_permissions_owner "/home/comma/.ssh/github" "$expected_permissions" "$expected_owner"
    local ssh_check_result=$?

    if [ "$ssh_check_result" -eq 0 ]; then
        echo -e "${NC}|${GREEN} SSH key in ~/.ssh/: ✅${NC}"
        local fingerprint
        fingerprint=$(ssh-keygen -lf /home/comma/.ssh/github 2>/dev/null | awk '{print $2}')
        if [ -n "$fingerprint" ]; then
            echo -e "│  └─ Fingerprint: $fingerprint"
        fi
    elif [ "$ssh_check_result" -eq 1 ]; then
        echo -e "${NC}|${RED} SSH key in ~/.ssh/: ❌ (permissions/ownership mismatch)${NC}"
        ssh_status+=("fix_permissions")
    else
        echo -e "${NC}|${RED} SSH key in ~/.ssh/: ❌ (missing)${NC}"
        ssh_status+=("missing")
    fi

    # Find most recent backup
    local latest_backup
    latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -c "%Y %n" {} \; | sort -nr | head -n1 | cut -d' ' -f2)

    # Backup status
    if [ -n "$latest_backup" ] && [ -f "${latest_backup}/${BACKUP_METADATA_FILE}" ]; then
        echo -e "${NC}|${GREEN} SSH Backup Status: ✅${NC}"

        local backup_timestamp
        backup_timestamp=$(jq -r '.timestamp' "${latest_backup}/${BACKUP_METADATA_FILE}")
        echo -e "│  ├─ Last Backup: $backup_timestamp"

        # Calculate backup age
        local backup_age
        local backup_days
        backup_age=$(($(date +%s) - $(date -d "$backup_timestamp" +%s)))
        backup_days=$((backup_age / 86400))

        if [ "$backup_days" -gt 30 ]; then
            echo -e "${NC}|${YELLOW}  └─ Warning: Backup is $backup_days days old${NC}"
        fi

        if [ -f "/home/comma/.ssh/github" ]; then
            # Check if backup metadata includes SSH files (files count > 0)
            if jq -e '.directories[] | select(.type=="ssh") | select(.files | tonumber > 0)' "${latest_backup}/${BACKUP_METADATA_FILE}" >/dev/null; then
                echo -e "│  └─ SSH files included in backup"
            else
                echo -e "|  └─${YELLOW} Warning: SSH files not included in backup${NC}"
            fi
        fi
    else
        echo -e "${NC}|${RED} SSH Backup Status: ❌${NC}"
        ssh_status+=("no_backup")
    fi
}

# Create SSH config file
create_ssh_config() {
    mkdir -p /home/comma/.ssh
    print_info "Creating SSH config file..."
    cat >/home/comma/.ssh/config <<EOF
Host github.com
  AddKeysToAgent yes
  IdentityFile /home/comma/.ssh/github
  Hostname ssh.github.com
  Port 443
  User git
EOF
}

check_ssh_backup() {
    # Find most recent backup
    local latest_backup
    latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -c "%Y %n" {} \; | sort -nr | head -n1 | cut -d' ' -f2)

    # Return 0 if valid backup with SSH files found, else 1
    if [ -n "$latest_backup" ] && [ -f "${latest_backup}/${BACKUP_METADATA_FILE}" ]; then
        # Check if SSH directory exists in backup metadata
        if jq -e '.directories[] | select(.type=="ssh")' "${latest_backup}/${BACKUP_METADATA_FILE}" >/dev/null; then
            # Verify the actual SSH files exist in the backup
            if [ -f "${latest_backup}/ssh/backup.tar.gz" ]; then
                # Optional: Could add additional verification by checking the tar contents
                return 0
            fi
        fi
    fi
    return 1
}

ssh_operation_with_timeout() {
    local cmd="$1"
    local timeout="$2"
    timeout "$timeout" $cmd || {
        print_error "SSH operation timed out after ${timeout} seconds"
        return 1
    }
}

restart_ssh_agent() {
    print_info "Restarting SSH agent..."
    # Kill existing SSH agent if running
    if [ -n "$SSH_AGENT_PID" ]; then
        kill -9 "$SSH_AGENT_PID" 2>/dev/null
    fi
    pkill -f ssh-agent

    # Start new SSH agent
    eval "$(ssh-agent -s)"

    # Add the SSH key if it exists
    if [ -f "/home/comma/.ssh/github" ]; then
        ssh-add /home/comma/.ssh/github
        print_success "SSH agent restarted and key added."
    else
        print_warning "SSH agent restarted but no key found to add."
    fi
}

check_ssh_config_completeness() {
    local config_file="/home/comma/.ssh/config"
    if [ ! -f "$config_file" ]; then
        echo "SSH config file is missing."
        return 1
    fi

    local missing_keys=()
    grep -q "AddKeysToAgent yes" "$config_file" || missing_keys+=("AddKeysToAgent")
    grep -q "IdentityFile /home/comma/.ssh/github" "$config_file" || missing_keys+=("IdentityFile")
    grep -q "Hostname ssh.github.com" "$config_file" || missing_keys+=("Hostname")
    grep -q "Port 443" "$config_file" || missing_keys+=("Port")
    grep -q "User git" "$config_file" || missing_keys+=("User")

    if [ ${#missing_keys[@]} -gt 0 ]; then
        echo "Missing SSH config keys: ${missing_keys[*]}"
        return 1
    fi

    return 0
}

change_github_ssh_port() {
    clear
    print_info "Updating github SSH config to use port 443..."
    create_ssh_config
    copy_ssh_config_and_keys
    backup_device
    print_success "github SSH config updated successfully."
    pause_for_user
}

test_ssh_connection() {
    clear
    print_info "Testing SSH connection to GitHub..."

    if ! check_network_connectivity "github.com"; then
        print_error "No network connectivity to GitHub. Cannot test SSH connection."
        pause_for_user
        return 1
    fi

    # Create known_hosts directory if it doesn't exist
    touch /home/comma/.ssh/known_hosts

    # Use yes to automatically accept the host key and pipe to ssh
    result=$(yes yes | ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1)

    if echo "$result" | grep -q "successfully authenticated"; then
        print_success "SSH connection test successful."

        # Update metadata for the most recent backup if it exists
        local latest_backup
        latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -c "%Y %n" {} \; | sort -nr | head -n1 | cut -d' ' -f2)

        if [ -n "$latest_backup" ] && [ -f "${latest_backup}/${BACKUP_METADATA_FILE}" ]; then
            local test_date
            test_date=$(date -Iseconds)

            # Update the metadata file with the new test date
            # Create a temporary file with updated metadata
            jq --arg date "$test_date" '. + {"last_ssh_test": $date}' "${latest_backup}/${BACKUP_METADATA_FILE}" >"${latest_backup}/${BACKUP_METADATA_FILE}.tmp"
            mv "${latest_backup}/${BACKUP_METADATA_FILE}.tmp" "${latest_backup}/${BACKUP_METADATA_FILE}"

            print_info "Updated backup metadata with successful test date"
        else
            print_info "No recent backup found - create a backup to store SSH test results"
        fi
    else
        print_error "SSH connection test failed."
        print_error "Error: $result"
    fi
    pause_for_user
}

check_github_known_hosts() {
    local known_hosts="/home/comma/.ssh/known_hosts"

    # Create known_hosts if it doesn't exist
    if [ ! -f "$known_hosts" ]; then
        mkdir -p /home/comma/.ssh
        touch "$known_hosts"
        chown comma:comma "$known_hosts"
        chmod 644 "$known_hosts"
    fi

    # Check if GitHub's key is already in known_hosts
    if ! grep -q "ssh.github.com" "$known_hosts"; then
        print_info "Adding GitHub's host key..."
        ssh-keyscan -p 443 ssh.github.com >>"$known_hosts" 2>/dev/null
        chown comma:comma "$known_hosts"
        return 1
    fi
    return 0
}

generate_ssh_key() {
    if [ ! -f /home/comma/.ssh/github ]; then
        ssh-keygen -t ed25519 -f /home/comma/.ssh/github
        print_info "SSH key generated successfully."
        # print the key
        view_ssh_key
    else
        print_info "SSH key already exists. Skipping SSH key generation..."
    fi
}

repair_create_ssh() {
    print_info "Analyzing SSH setup..."
    local home_ssh_exists=false
    local usr_ssh_exists=false
    local needs_permission_fix=false

    # Check existence in both locations
    [ -f "/home/comma/.ssh/github" ] && home_ssh_exists=true
    [ -f "/usr/default/home/comma/.ssh/github" ] && usr_ssh_exists=true

    # Check/update known_hosts early in the process
    # check_github_known_hosts

    # If SSH exists in persistent location but not in home
    if [ "$usr_ssh_exists" = true ] && [ "$home_ssh_exists" = false ]; then
        print_info "Restoring SSH key from persistent storage..."
        mkdir -p /home/comma/.ssh
        sudo cp /usr/default/home/comma/.ssh/github* /home/comma/.ssh/
        sudo cp /usr/default/home/comma/.ssh/config /home/comma/.ssh/
        sudo chown comma:comma /home/comma/.ssh -R
        sudo chmod 600 /home/comma/.ssh/github
        print_success "SSH files restored from persistent storage"
        return 0
    fi

    # If missing from both locations but backup exists
    if [ "$home_ssh_exists" = false ] && [ "$usr_ssh_exists" = false ] && check_ssh_backup; then
        print_info "No SSH keys found. Restoring from backup..."
        pause_for_user
        restore_backup
        return 0
    fi

    # If missing from both locations and no backup
    if [ "$home_ssh_exists" = false ] && [ "$usr_ssh_exists" = false ]; then
        print_info "Creating new SSH setup..."
        remove_ssh_contents
        create_ssh_config
        generate_ssh_key
        copy_ssh_config_and_keys
        backup_device
        test_ssh_connection
        return 0
    fi

    # Check and fix permissions if needed
    check_file_permissions_owner "/home/comma/.ssh/github" "-rw-------" "comma"
    if [ $? -eq 1 ]; then
        print_info "Fixing SSH permissions..."
        sudo chmod 600 /home/comma/.ssh/github
        sudo chown comma:comma /home/comma/.ssh/github
        needs_permission_fix=true
    fi

    if [ -f "/usr/default/home/comma/.ssh/github" ]; then
        check_file_permissions_owner "/usr/default/home/comma/.ssh/github" "-rw-------" "comma"
        if [ $? -eq 1 ]; then
            print_info "Fixing persistent SSH permissions..."
            sudo chmod 600 /usr/default/home/comma/.ssh/github
            sudo chown comma:comma /usr/default/home/comma/.ssh/github
            needs_permission_fix=true
        fi
    fi

    if [ "$needs_permission_fix" = true ]; then
        copy_ssh_config_and_keys
        print_success "SSH permissions fixed"
    fi

    pause_for_user
}

reset_ssh() {
    clear
    if [ -f "/home/comma/.ssh/github" ]; then
        backup_device
    fi
    remove_ssh_contents
    create_ssh_config
    generate_ssh_key
    copy_ssh_config_and_keys
    restart_ssh_agent
    test_ssh_connection
    print_info "Creating backup of new SSH setup..."
    backup_device
    pause_for_user
}

copy_ssh_config_and_keys() {
    mount_rw
    print_info "Copying SSH config and keys to /usr/default/home/comma/.ssh/..."
    if [ ! -d /usr/default/home/comma/.ssh/ ]; then
        sudo mkdir -p /usr/default/home/comma/.ssh/
    fi
    sudo cp /home/comma/.ssh/config /usr/default/home/comma/.ssh/
    sudo cp /home/comma/.ssh/github* /usr/default/home/comma/.ssh/
    sudo chown comma:comma /usr/default/home/comma/.ssh/ -R
    sudo chmod 600 /usr/default/home/comma/.ssh/github
}

get_ssh_key() {
    if [ -f /home/comma/.ssh/github.pub ]; then
        local ssh_key
        ssh_key=$(cat /home/comma/.ssh/github.pub)
        echo "SSH public key:"
        echo "-------------(Copy the text between these lines)-------------"
        echo -e "${GREEN}$ssh_key${NC}" | fold -w 50
        echo "-------------------------------------------------------------"
        echo ""
        echo "Copy the key above to add to your GitHub account"
        echo "(Copy the entire key as one line)"
    else
        echo ""
    fi
}

view_ssh_key() {
    clear
    # return the result of get_ssh_key if it returns 0
    local result
    result=$(get_ssh_key)
    if [ "$result" = "" ]; then
        print_error "SSH public key does not exist."
    else
        echo "$result"
    fi
    pause_for_user
}

remove_ssh_contents() {
    clear
    mount_rw
    print_info "Removing SSH folder contents..."
    rm -rf /home/comma/.ssh/*
    sudo rm -rf /usr/default/home/comma/.ssh/*
}

import_ssh_keys() {
    local private_key_file="$1"
    local public_key_file="$2"

    # Create SSH directory
    clear
    print_info "Importing SSH keys..."

    if [ ! -d /home/comma/.ssh ]; then
        print_info "Creating SSH directory..."
        mkdir -p /home/comma/.ssh
    fi

    # Copy key files
    print_info "Copying Private Key to /home/comma/.ssh/github..."
    cp "$private_key_file" "/home/comma/.ssh/github_test"
    print_info "Copying Public Key to /home/comma/.ssh/github_test.pub..."
    cp "$public_key_file" "/home/comma/.ssh/github.pub_test"

    # Set permissions
    print_info "Setting key permissions..."
    chmod 600 /home/comma/.ssh/github_test
    chmod 644 /home/comma/.ssh/github.pub_test
    chown -R comma:comma /home/comma/.ssh

    # Create SSH config
    create_ssh_config

    # Copy to persistent storage
    copy_ssh_config_and_keys

    # Create backup
    backup_device

    # Restart SSH agent
    restart_ssh_agent

    # Test connection
    test_ssh_connection

    print_success "SSH configuration completed successfully"
}

import_ssh_menu() {
    clear
    echo "+----------------------------------------------+"
    echo "│           SSH Transfer Tool Info             │"
    echo "+----------------------------------------------+"
    echo "This tool allows you to transfer SSH keys from your computer"
    echo "to your comma device automatically."
    echo ""
    echo "To use the transfer tool, run this command on your computer:"
    echo ""
    echo -e "${GREEN}cd /data && wget https://raw.githubusercontent.com/tonesto7/op-utilities/main/CommaSSHTransfer.sh && chmod +x CommaSSHTransfer.sh && ./CommaSSHTransfer.sh${NC}"
    echo ""
    echo "The tool will:"
    echo "1. Show available SSH keys on your computer"
    echo "2. Let you select which key to transfer"
    echo "3. Ask for your comma device's IP address"
    echo "4. Automatically transfer and configure the keys"
    echo "5. Create necessary backups"
    echo ""
    echo "Requirements:"
    echo "- SSH access to your comma device"
    echo "- Existing SSH keys on your computer"
    echo "- Network connection to your comma device"
    pause_for_user
}

ssh_menu() {
    while true; do
        clear
        display_ssh_status
        echo "+----------------------------------------------+"
        echo "│               SSH Key Manager                │"
        echo "+----------------------------------------------+"
        echo "│ 1. Import SSH Keys from Host"
        echo "│ 2. Reset SSH Setup"
        echo "│ 3. View SSH Public Key"
        echo "│ 4. Copy SSH Config to Persistent Storage"
        echo "│ 5. Change Github SSH Port to 443"
        echo "│ 6. Test SSH Connection"
        echo "│ Q. Back to Main Menu"
        echo "+----------------------------------------------+"
        read -p "Enter your choice: " choice
        case $choice in
        1) import_ssh_menu ;;
        2) reset_ssh ;;
        3) view_ssh_key ;;
        4) copy_ssh_config_and_keys ;;
        5) change_github_ssh_port ;;
        6) test_ssh_connection ;;
        [qQ]) break ;;
        *) print_error "Invalid choice." ;;
        esac
    done
}
