#!/bin/bash
###############################################################################
# ssh.sh - Device SSH Operations for CommaUtility
#
# Version: SSH_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script manages device SSH operations (SSH key management, configuration,
# and testing).
###############################################################################
readonly SSH_SCRIPT_VERSION="3.0.0"
readonly SSH_SCRIPT_MODIFIED="2025-02-09"

###############################################################################
# Global Variables
###############################################################################

backup_ssh() {
    print_info "Backing up SSH files..."
    local backup_success=false

    # Create backup directories
    mkdir -p "$SSH_BACKUP_DIR/.ssh"
    mkdir -p "$SSH_BACKUP_DIR/persist_comma"

    # Backup home directory SSH files if they exist
    if [ -f "/home/comma/.ssh/github" ] &&
        [ -f "/home/comma/.ssh/github.pub" ] &&
        [ -f "/home/comma/.ssh/config" ]; then
        cp "/home/comma/.ssh/github" "$SSH_BACKUP_DIR/.ssh/"
        cp "/home/comma/.ssh/github.pub" "$SSH_BACKUP_DIR/.ssh/"
        cp "/home/comma/.ssh/config" "$SSH_BACKUP_DIR/.ssh/"
        backup_success=true
    fi

    # Backup /persist/comma directory if it exists
    if [ -d "/persist/comma" ]; then
        cp -R "/persist/comma/." "$SSH_BACKUP_DIR/persist_comma/"
        backup_success=true
    fi

    if [ "$backup_success" = true ]; then
        # Set correct permissions
        sudo chown comma:comma "$SSH_BACKUP_DIR" -R
        sudo chmod 700 "$SSH_BACKUP_DIR/.ssh"
        sudo chmod 600 "$SSH_BACKUP_DIR/.ssh/github"
        sudo chmod 700 "$SSH_BACKUP_DIR/persist_comma"

        save_ssh_backup_metadata
        print_success "SSH files backed up successfully to $SSH_BACKUP_DIR/"
    else
        print_warning "No valid SSH files found to backup."
    fi
    pause_for_user
}

# Restore SSH files from backup with verification
restore_ssh() {
    print_info "Restoring SSH files..."
    if check_ssh_backup; then
        if ! verify_backup_integrity; then
            print_error "Backup files appear to be corrupted"
            pause_for_user
            return 1
        fi

        print_info "Found backup with the following information:"
        get_ssh_backup_metadata
        read -p "Do you want to proceed with restore? (y/N): " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            # Always clean both locations before restore
            remove_ssh_contents

            # Restore to home directory
            mkdir -p /home/comma/.ssh
            cp "$SSH_BACKUP_DIR/.ssh/github" "/home/comma/.ssh/"
            cp "$SSH_BACKUP_DIR/.ssh/github.pub" "/home/comma/.ssh/"
            cp "$SSH_BACKUP_DIR/.ssh/config" "/home/comma/.ssh/"
            sudo chown comma:comma /home/comma/.ssh -R
            sudo chmod 700 /home/comma/.ssh
            sudo chmod 600 /home/comma/.ssh/github

            # Restore persist_comma directory if it exists in backup
            if [ -d "$SSH_BACKUP_DIR/persist_comma" ]; then
                mkdir -p /persist/comma
                cp -R "$SSH_BACKUP_DIR/persist_comma/." "/persist/comma/"
                sudo chown comma:comma /persist/comma -R
                sudo chmod 700 /persist/comma
            fi

            # Ensure persistent storage is updated
            copy_ssh_config_and_keys

            # Restart SSH agent
            restart_ssh_agent

            print_success "SSH files restored successfully."
        else
            print_info "Restore cancelled."
        fi
    else
        print_warning "No valid SSH backup found to restore."
    fi
    pause_for_user
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

save_ssh_backup_metadata() {
    local backup_time
    backup_time=$(date '+%Y-%m-%d %H:%M:%S')
    cat >"$SSH_BACKUP_DIR/metadata.txt" <<EOF
Backup Date: $backup_time
Last SSH Test: $backup_time
Backup Contents:
- ~/.ssh/ files
- /persist/comma/ contents
EOF
}

get_ssh_backup_metadata() {
    if [ -f "$SSH_BACKUP_DIR/metadata.txt" ]; then
        echo "Backup Information:"
        cat "$SSH_BACKUP_DIR/metadata.txt"
        echo ""

        # Show file counts
        local ssh_files
        local persist_files
        ssh_files=$(find "$SSH_BACKUP_DIR/.ssh" -type f | wc -l)
        persist_files=$(find "$SSH_BACKUP_DIR/persist_comma" -type f | wc -l)

        echo "File Counts:"
        echo "- SSH files: $ssh_files"
        echo "- Persist files: $persist_files"
    else
        print_warning "No backup metadata found"
    fi
}

display_ssh_status_short() {
    print_info "│ SSH Status:"
    if [ -f "/home/comma/.ssh/github" ]; then
        echo "│ ├─ SSH Key: Found in ~/.ssh/"
        if [ -d "/persist/comma" ]; then
            echo "│ ├─ Persist: Found in /persist/comma/"
        fi
        if [ -f "$SSH_BACKUP_DIR/.ssh/github" ]; then
            local last_backup
            last_backup=$(grep "Backup Date:" "$SSH_BACKUP_DIR/metadata.txt" | cut -d: -f2- | xargs)
            echo "│ └─ Backup: Last backup $last_backup"
        fi
    else
        echo "│ └─ SSH Key: Not found"
    fi
}

display_ssh_status() {
    echo "┌───────────────────────────────────────────────┐"
    echo "│                  SSH Status                   │"
    echo "├───────────────────────────────────────────────┘"

    local expected_owner="comma"
    local expected_permissions="-rw-------"
    ssh_status=()

    # Backup age check
    local backup_date
    local backup_age
    local backup_days

    if [ -f "$SSH_BACKUP_DIR/metadata.txt" ]; then
        backup_date=$(grep "Backup Date:" "$SSH_BACKUP_DIR/metadata.txt" | cut -d: -f2- | xargs)
        backup_age=$(($(date +%s) - $(date -d "$backup_date" +%s)))
        backup_days=$((backup_age / 86400))
    fi

    # Check main key
    check_file_permissions_owner "/home/comma/.ssh/github" "$expected_permissions" "$expected_owner"
    local ssh_check_result=$?

    if [ "$ssh_check_result" -eq 0 ]; then
        echo -e "${NC}│${GREEN} SSH key in ~/.ssh/: ✅${NC}"
        local fingerprint
        fingerprint=$(ssh-keygen -lf /home/comma/.ssh/github 2>/dev/null | awk '{print $2}')
        if [ -n "$fingerprint" ]; then
            echo -e "│  └─ Fingerprint: $fingerprint"
        fi
    elif [ "$ssh_check_result" -eq 1 ]; then
        echo -e "${NC}│${RED} SSH key in ~/.ssh/: ❌ (permissions/ownership mismatch)${NC}"
        ssh_status+=("fix_permissions")
    else
        echo -e "${NC}│${RED} SSH key in ~/.ssh/: ❌ (missing)${NC}"
        ssh_status+=("missing")
    fi

    # Backup status
    if [ -f "$SSH_BACKUP_DIR/github" ] &&
        [ -f "$SSH_BACKUP_DIR/github.pub" ] &&
        [ -f "$SSH_BACKUP_DIR/config" ]; then
        echo -e "${NC}│${GREEN} SSH Backup Status: ✅${NC}"
        if [ -f "$SSH_BACKUP_DIR/metadata.txt" ]; then
            echo -e "│  └─ Last Backup: $backup_date"
            if [ "$backup_days" -gt 30 ]; then
                echo -e "${NC}│${YELLOW}  └─ Warning: Backup is $backup_days days old${NC}"
            fi
            if [ -f "/home/comma/.ssh/github" ]; then
                if diff -q "/home/comma/.ssh/github" "$SSH_BACKUP_DIR/github" >/dev/null; then
                    echo -e "│  └─ Backup is current with active SSH files"
                else
                    echo -e "${NC}│${YELLOW}  └─ Backup differs from active SSH files${NC}"
                fi
            fi
        else
            echo -e "${NC}│${YELLOW}  └─ Backup metadata not found${NC}"
        fi
    else
        echo -e "${NC}│${RED} SSH Backup Status: ❌${NC}"
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
    # Return 0 if valid backup found, else 1
    if [ -f "$SSH_BACKUP_DIR/.ssh/github" ] &&
        [ -f "$SSH_BACKUP_DIR/.ssh/github.pub" ] &&
        [ -f "$SSH_BACKUP_DIR/.ssh/config" ] &&
        [ -d "$SSH_BACKUP_DIR/persist_comma" ]; then
        return 0
    else
        return 1
    fi
}

ssh_operation_with_timeout() {
    local cmd="$1"
    local timeout="$2"
    timeout "$timeout" $cmd || {
        print_error "SSH operation timed out after ${timeout} seconds"
        return 1
    }
}

verify_backup_integrity() {
    local backup_dir="$SSH_BACKUP_DIR"

    # Check if backup directories exist
    if [ ! -d "$backup_dir/.ssh" ] || [ ! -d "$backup_dir/persist_comma" ]; then
        print_error "Missing required backup directories"
        return 1
    fi

    # Check SSH file permissions and content
    for file in "github" "github.pub" "config"; do
        local file_path="$backup_dir/.ssh/$file"
        if [ ! -f "$file_path" ] || [ ! -s "$file_path" ]; then
            print_error "Missing or empty SSH file: $file"
            return 1
        fi

        # Check permissions
        local perms
        perms=$(stat -c "%a" "$file_path")
        if [ "$file" = "github" ] && [ "$perms" != "600" ]; then
            print_error "Incorrect permissions on $file"
            return 1
        fi
    done

    # Check .ssh directory permissions
    local ssh_perms
    ssh_perms=$(stat -c "%a" "$backup_dir/.ssh")
    if [ "$ssh_perms" != "700" ]; then
        print_error "Incorrect permissions on .ssh backup directory"
        return 1
    fi

    # Check persist_comma directory permissions
    local persist_perms
    persist_perms=$(stat -c "%a" "$backup_dir/persist_comma")
    if [ "$persist_perms" != "700" ]; then
        print_error "Incorrect permissions on persist_comma backup directory"
        return 1
    fi

    return 0
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
    backup_ssh
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
    # mkdir -p /home/comma/.ssh
    touch /home/comma/.ssh/known_hosts

    # Use yes to automatically accept the host key and pipe to ssh
    result=$(yes yes | ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1)

    if echo "$result" | grep -q "successfully authenticated"; then
        print_success "SSH connection test successful."

        # Update metadata file with test date
        local test_date
        test_date=$(date '+%Y-%m-%d %H:%M:%S')

        if [ -f "$SSH_BACKUP_DIR/metadata.txt" ]; then
            # Check if Last SSH Test line exists
            if grep -q "Last SSH Test:" "$SSH_BACKUP_DIR/metadata.txt"; then
                # Update existing line
                sed -i "s/Last SSH Test:.*/Last SSH Test: $test_date/" "$SSH_BACKUP_DIR/metadata.txt"
            else
                # Append new line if it doesn't exist
                echo "Last SSH Test: $test_date" >>"$SSH_BACKUP_DIR/metadata.txt"
            fi
        else
            # Create new metadata file if it doesn't exist
            mkdir -p "$SSH_BACKUP_DIR"
            cat >"$SSH_BACKUP_DIR/metadata.txt" <<EOF
Backup Date: Not backed up
Last SSH Test: $test_date
EOF
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
        print_info "Displaying the SSH public key. Please add it to your GitHub account."
        cat /home/comma/.ssh/github.pub
        pause_for_user
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
        restore_ssh
        return 0
    fi

    # If missing from both locations and no backup
    if [ "$home_ssh_exists" = false ] && [ "$usr_ssh_exists" = false ]; then
        print_info "Creating new SSH setup..."
        remove_ssh_contents
        create_ssh_config
        generate_ssh_key
        copy_ssh_config_and_keys
        backup_ssh
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
        backup_ssh
    fi
    remove_ssh_contents
    create_ssh_config
    generate_ssh_key
    copy_ssh_config_and_keys
    restart_ssh_agent
    test_ssh_connection
    print_info "Creating backup of new SSH setup..."
    backup_ssh
    pause_for_user
}

copy_ssh_config_and_keys() {
    mount_rw
    print_info "Copying SSH config and keys to persistent storage..."

    # Copy to /usr/default/home/comma/.ssh/
    if [ ! -d /usr/default/home/comma/.ssh/ ]; then
        sudo mkdir -p /usr/default/home/comma/.ssh/
    fi
    sudo cp /home/comma/.ssh/config /usr/default/home/comma/.ssh/
    sudo cp /home/comma/.ssh/github* /usr/default/home/comma/.ssh/

    # Set permissions
    sudo chown comma:comma /usr/default/home/comma/.ssh/ -R
    sudo chmod 700 /usr/default/home/comma/.ssh/
    sudo chmod 600 /usr/default/home/comma/.ssh/github

    # Ensure persist/comma exists with correct permissions
    if [ ! -d /persist/comma ]; then
        sudo mkdir -p /persist/comma
        sudo chown comma:comma /persist/comma
        sudo chmod 700 /persist/comma
    fi

    print_success "SSH files copied to persistent storage"
}

get_ssh_key() {
    if [ -f /home/comma/.ssh/github.pub ]; then
        local ssh_key
        ssh_key=$(cat /home/comma/.ssh/github.pub)
        echo "SSH public key"
        echo "─────────────(Copy the text between these lines)─────────────"
        echo -e "${GREEN}$ssh_key${NC}"
        echo "─────────────────────────────────────────────────────────────"
        echo ""
        echo "Copy the key above to add to your GitHub account"
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

    # Remove home .ssh contents
    rm -rf /home/comma/.ssh/*

    # Remove persist/comma contents
    sudo rm -rf /persist/comma/*

    # Remove persistent storage .ssh contents
    sudo rm -rf /usr/default/home/comma/.ssh/*

    print_success "SSH contents removed from all locations"
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
    backup_ssh

    # Restart SSH agent
    restart_ssh_agent

    # Test connection
    test_ssh_connection

    print_success "SSH configuration completed successfully"
}

import_ssh_menu() {
    clear
    echo "┌───────────────────────────────────────────────┐"
    echo "│            SSH Transfer Tool Info             │"
    echo "├───────────────────────────────────────────────┘"
    echo "│ This tool allows you to transfer SSH keys from your computer"
    echo "│ to your comma device automatically."
    echo "│"
    echo "│ To use the transfer tool, run this command on your computer:"
    echo "│"
    echo -e "│ ${GREEN}cd /data && wget https://raw.githubusercontent.com/tonesto7/op-utilities/main/CommaSSHTransfer.sh && chmod +x CommaSSHTransfer.sh && ./CommaSSHTransfer.sh${NC}"
    echo "│"
    echo "│The tool will:"
    echo "│ 1. Show available SSH keys on your computer"
    echo "│ 2. Let you select which key to transfer"
    echo "│ 3. Ask for your comma device's IP address"
    echo "│ 4. Automatically transfer and configure the keys"
    echo "│ 5. Create necessary backups"
    echo "│"
    echo "│ Requirements:"
    echo "│ - SSH access to your comma device"
    echo "│ - Existing SSH keys on your computer"
    echo "│ - Network connection to your comma device"
    pause_for_user
}

ssh_menu() {
    while true; do
        clear
        display_ssh_status
        echo "┌───────────────────────────────────────────────┐"
        echo "│"
        echo -e "│ ${GREEN}Available Actions:${NC}"
        echo "│ 1. Repair/Create SSH setup"
        echo "│ 2. Import SSH keys from host system"
        echo "│ 3. Copy SSH config and keys to persistent storage"
        echo "│ 4. Reset SSH setup and recreate keys"
        echo "│ 5. Test SSH connection"
        echo "│ 6. View SSH key"
        echo "│ 7. Change Github SSH port to 443"
        if [ -f "/home/comma/.ssh/github" ]; then
            echo "│ B. Backup SSH files"
        fi
        if check_ssh_backup; then
            echo "│ X. Restore SSH files from backup"
        fi
        echo "│ Q. Back to Main Menu"
        read -p "│ Enter your choice: " choice
        case $choice in
        1) repair_create_ssh ;;
        2) import_ssh_menu ;;
        3) copy_ssh_config_and_keys ;;
        4) reset_ssh ;;
        5) test_ssh_connection ;;
        6) view_ssh_key ;;
        7) change_github_ssh_port ;;
        [bB])
            if [ -f "/home/comma/.ssh/github" ]; then
                backup_ssh
            fi
            ;;
        [xX])
            if check_ssh_backup; then
                restore_ssh
            fi
            ;;
        [qQ]) break ;;
        *) print_error "Invalid choice." ;;
        esac
    done
}
