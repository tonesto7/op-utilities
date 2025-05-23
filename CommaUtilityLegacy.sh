#!/bin/bash

###############################################################################
# CommaUtilityLegacy Script
#
# Description:
# - This script is designed to help manage and maintain the comma device and
#   it's Openpilot software.
# - It provides a menu-driven interface for various tasks related to the comma
#   utility.
#
###############################################################################

###############################################################################
# Global Variables
###############################################################################
readonly SCRIPT_VERSION="2.5.0"
readonly SCRIPT_MODIFIED="2025-03-24"

# We unify color-coded messages in a single block for consistency:
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Helper functions for colored output
print_success() {
    echo -e "${GREEN}$1${NC}"
}
print_error() {
    echo -e "${RED}$1${NC}"
}
print_warning() {
    echo -e "${YELLOW}$1${NC}"
}
print_blue() {
    echo -e "${BLUE}$1${NC}"
}
print_info() {
    echo -e "$1"
}

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

# A convenient prompt-pause function to unify "Press Enter" prompts:
pause_for_user() {
    read -p "Press enter to continue..."
}

# Array-based detection data
declare -A ISSUE_FIXES
declare -A ISSUE_DESCRIPTIONS
declare -A ISSUE_PRIORITIES # 1=Critical, 2=Warning, 3=Recommendation

ssh_status=()

# Variables from build_bluepilot script
SCRIPT_ACTION=""
REPO=""
CLONE_BRANCH=""
BUILD_BRANCH=""

# OS checks and directories
readonly OS=$(uname)
readonly GIT_BP_PUBLIC_REPO="git@github.com:BluePilotDev/bluepilot.git"
readonly GIT_BP_PRIVATE_REPO="git@github.com:ford-op/sp-dev-c3.git"
readonly GIT_OP_PRIVATE_FORD_REPO="git@github.com:ford-op/openpilot.git"
readonly GIT_SP_REPO="git@github.com:sunnypilot/sunnypilot.git"
readonly GIT_COMMA_REPO="git@github.com:commaai/openpilot.git"

if [ "$OS" = "Darwin" ]; then
    readonly BUILD_DIR="$HOME/Documents/bluepilot-utility/bp-build"
    readonly SCRIPT_DIR=$(dirname "$0")
else
    readonly BUILD_DIR="/data/openpilot"
    # Get absolute path of script regardless of where it's called from
    readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd || echo "/data")
    if [ "$SCRIPT_DIR" = "" ]; then
        print_error "Error: Could not determine script directory"
        exit 1
    fi
fi

readonly TMP_DIR="${BUILD_DIR}-build-tmp"

# Check file permissions and owner
# Returns:
# - 0: Match
# - 1: Mismatch
# - 2: File missing
check_file_permissions_owner() {
    local file_path="$1"
    local expected_permissions="$2"
    local expected_owner="$3"

    if [ ! -f "$file_path" ]; then
        # Return 2 for "file missing"
        return 2
    fi

    local actual_permissions
    local actual_owner
    local actual_group

    actual_permissions=$(stat -c "%A" "$file_path" 2>/dev/null)
    actual_owner=$(stat -c "%U" "$file_path" 2>/dev/null)
    actual_group=$(stat -c "%G" "$file_path" 2>/dev/null)

    if [ "$actual_permissions" != "$expected_permissions" ] ||
        [ "$actual_owner" != "$expected_owner" ] ||
        [ "$actual_group" != "$expected_owner" ]; then
        # Return 1 for mismatch
        return 1
    fi

    return 0
}

# Create a backup of all SSH files
# Returns:
# - 0: Success
# - 1: Failure
backup_ssh() {
    # clear
    print_info "Backing up SSH files..."
    if [ -f "/home/comma/.ssh/github" ] &&
        [ -f "/home/comma/.ssh/github.pub" ] &&
        [ -f "/home/comma/.ssh/config" ]; then
        mkdir -p "/data/ssh_backup"
        cp "/home/comma/.ssh/github" "/data/ssh_backup/"
        cp "/home/comma/.ssh/github.pub" "/data/ssh_backup/"
        cp "/home/comma/.ssh/config" "/data/ssh_backup/"
        sudo chown comma:comma "/data/ssh_backup" -R
        sudo chmod 600 "/data/ssh_backup/github"
        save_backup_metadata
        print_success "SSH files backed up successfully to /data/ssh_backup/"
    else
        print_warning "No valid SSH files found to backup."
    fi
    pause_for_user
}

# Restore SSH files from backup with verification
restore_ssh() {
    # clear
    print_info "Restoring SSH files..."
    if check_ssh_backup; then
        if ! verify_backup_integrity; then
            print_error "Backup files appear to be corrupted"
            pause_for_user
            return 1
        fi

        print_info "Found backup with the following information:"
        get_backup_metadata
        read -p "Do you want to proceed with restore? (y/N): " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            # Always clean both locations before restore
            remove_ssh_contents

            # Restore to home directory
            mkdir -p /home/comma/.ssh
            cp /data/ssh_backup/github /home/comma/.ssh/
            cp /data/ssh_backup/github.pub /home/comma/.ssh/
            cp /data/ssh_backup/config /home/comma/.ssh/
            sudo chown comma:comma /home/comma/.ssh -R
            sudo chmod 600 /home/comma/.ssh/github

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

# Check disk usage and resize root if needed
# Returns:
# - 0: Success
# - 1: Failure
check_disk_usage_and_resize() {
    # This function unifies the disk usage check from detect_issues() and
    # check_root_space() to avoid code duplication.
    local partition="/"
    local root_usage=$(df -h "$partition" | awk 'NR==2 {gsub("%","",$5); print $5}')
    # Return usage for other logic as needed
    echo "$root_usage"
}

# Resize root filesystem if needed
# Returns:
# - 0: Success
# - 1: Failure
resize_root_if_needed() {
    local usage="$1"
    if [ "$usage" -ge 100 ]; then
        print_warning "Root filesystem is full ($usage%)."
        print_info "To fix this, do you want to resize the root filesystem?"
        read -p "Enter y or n: " root_space_choice
        if [ "$root_space_choice" = "y" ]; then
            sudo mount -o remount,rw /
            sudo resize2fs "$(findmnt -n -o SOURCE /)"
            print_success "Root filesystem resized successfully."
        fi
    fi
}

###############################################################################
# Git Operations
###############################################################################

# Clone and initialize a git repository
# Returns:
# - 0: Success
# - 1: Failure
git_clone_and_init() {
    local repo_url="$1"
    local branch="$2"
    local dest_dir="$3"

    if ! check_network_connectivity "github.com"; then
        print_error "No network connectivity to GitHub. Cannot proceed with clone operation."
        return 1
    fi

    local clone_cmd="git clone --depth 1 -b '$branch' '$repo_url' '$dest_dir'"
    if ! execute_with_network_retry "$clone_cmd" "Failed to clone repository"; then
        return 1
    fi

    cd "$dest_dir" || return 1

    # Check if there are any submodules and .gitmodules file if so, update them
    if [ -f ".gitmodules" ]; then
        local submodule_cmd="git submodule update --init --recursive"
        execute_with_network_retry "$submodule_cmd" "Failed to update submodules"
    fi
}

git_operation_with_timeout() {
    local cmd="$1"
    local timeout="$2"
    timeout "$timeout" $cmd || {
        print_error "Operation timed out after ${timeout} seconds"
        return 1
    }
}

# Check if the working directory is clean
# Returns:
# - 0: Clean
# - 1: Not clean
check_working_directory() {
    if [ -n "$(git status --porcelain)" ]; then
        print_error "Working directory is not clean"
        return 1
    fi
    return 0
}

###############################################################################
# Directory and Path Functions
###############################################################################

# Ensure the current directory is the target directory
# Returns:
# - 0: Success
# - 1: Failure
ensure_directory() {
    local target_dir="$1"
    local current_dir
    current_dir=$(pwd)
    if [ "$current_dir" != "$target_dir" ]; then
        cd "$target_dir" || {
            print_error "Could not change to directory: $target_dir"
            return 1
        }
        return 0
    fi
}

# Get the absolute path of a given path
# Returns:
# - Absolute path
get_absolute_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        echo "$path"
    else
        echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
    fi
}

###############################################################################
# SSH Status & Management Functions
###############################################################################

# Function to display mini SSH status
# Returns:
# - 0: Success
# - 1: Failure
display_ssh_status_short() {
    print_info "| SSH Status:"
    if [ -f "/home/comma/.ssh/github" ]; then
        echo "| └─ Key: Found"
        if [ -f "/data/ssh_backup/metadata.txt" ]; then
            local last_backup
            last_backup=$(grep "Backup Date:" /data/ssh_backup/metadata.txt | cut -d: -f2- | xargs)
            echo "| └─ Backup: Last Backup $last_backup"
        fi
    fi
}

# Display detailed SSH status
# Returns:
# - 0: Success
# - 1: Failure
display_ssh_status() {
    echo "+----------------------------------------------+"
    echo "|          SSH Status                          |"
    echo "+----------------------------------------------+"

    local expected_owner="comma"
    local expected_permissions="-rw-------"
    ssh_status=()

    # Backup age check
    local backup_date
    local backup_age
    local backup_days

    if [ -f "/data/ssh_backup/metadata.txt" ]; then
        backup_date=$(grep "Backup Date:" /data/ssh_backup/metadata.txt | cut -d: -f2- | xargs)
        backup_age=$(($(date +%s) - $(date -d "$backup_date" +%s)))
        backup_days=$((backup_age / 86400))
    fi

    # Check main key
    check_file_permissions_owner "/home/comma/.ssh/github" "$expected_permissions" "$expected_owner"
    local ssh_check_result=$?

    if [ "$ssh_check_result" -eq 0 ]; then
        echo -e "${NC}|${GREEN} SSH key in ~/.ssh/: ✅${NC}"
        local fingerprint
        fingerprint=$(ssh-keygen -lf /home/comma/.ssh/github 2>/dev/null | awk '{print $2}')
        if [ -n "$fingerprint" ]; then
            echo -e "|  └─ Fingerprint: $fingerprint"
        fi
    elif [ "$ssh_check_result" -eq 1 ]; then
        echo -e "${NC}|${RED} SSH key in ~/.ssh/: ❌ (permissions/ownership mismatch)${NC}"
        ssh_status+=("fix_permissions")
    else
        echo -e "${NC}|${RED} SSH key in ~/.ssh/: ❌ (missing)${NC}"
        ssh_status+=("missing")
    fi

    # Backup status
    if [ -f "/data/ssh_backup/github" ] &&
        [ -f "/data/ssh_backup/github.pub" ] &&
        [ -f "/data/ssh_backup/config" ]; then
        echo -e "${NC}|${GREEN} SSH Backup Status: ✅${NC}"
        if [ -f "/data/ssh_backup/metadata.txt" ]; then
            echo -e "|  └─ Last Backup: $backup_date"
            if [ "$backup_days" -gt 30 ]; then
                echo -e "${NC}|${YELLOW}  └─ Warning: Backup is $backup_days days old${NC}"
            fi
            if [ -f "/home/comma/.ssh/github" ]; then
                if diff -q "/home/comma/.ssh/github" "/data/ssh_backup/github" >/dev/null; then
                    echo -e "|  └─ Backup is current with active SSH files"
                else
                    echo -e "${NC}|${YELLOW}  └─ Backup differs from active SSH files${NC}"
                fi
            fi
        else
            echo -e "${NC}|${YELLOW}  └─ Backup metadata not found${NC}"
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
    # Return 0 if valid backup found, else 1
    if [ -f "/data/ssh_backup/github" ] &&
        [ -f "/data/ssh_backup/github.pub" ] &&
        [ -f "/data/ssh_backup/config" ]; then
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
    local backup_dir="/data/ssh_backup"
    for file in "github" "github.pub" "config"; do
        if [ ! -f "$backup_dir/$file" ] || [ ! -s "$backup_dir/$file" ]; then
            return 1
        fi
    done
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

        if [ -f "/data/ssh_backup/metadata.txt" ]; then
            # Check if Last SSH Test line exists
            if grep -q "Last SSH Test:" "/data/ssh_backup/metadata.txt"; then
                # Update existing line
                sed -i "s/Last SSH Test:.*/Last SSH Test: $test_date/" "/data/ssh_backup/metadata.txt"
            else
                # Append new line if it doesn't exist
                echo "Last SSH Test: $test_date" >>"/data/ssh_backup/metadata.txt"
            fi
        else
            # Create new metadata file if it doesn't exist
            mkdir -p "/data/ssh_backup"
            cat >"/data/ssh_backup/metadata.txt" <<EOF
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
    print_info "Copying SSH config and keys to /usr/default/home/comma/.ssh/..."
    if [ ! -d /usr/default/home/comma/.ssh/ ]; then
        sudo mkdir -p /usr/default/home/comma/.ssh/
    fi
    sudo cp /home/comma/.ssh/config /usr/default/home/comma/.ssh/
    sudo cp /home/comma/.ssh/github* /usr/default/home/comma/.ssh/
    sudo chown comma:comma /usr/default/home/comma/.ssh/ -R
    sudo chmod 600 /usr/default/home/comma/.ssh/github
}

view_ssh_key() {
    clear
    if [ -f /home/comma/.ssh/github.pub ]; then
        print_info "Displaying the SSH public key:"
        echo -e "${GREEN}$(cat /home/comma/.ssh/github.pub)${NC}"
    else
        print_error "SSH public key does not exist."
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
    backup_ssh

    # Restart SSH agent
    restart_ssh_agent

    # Test connection
    test_ssh_connection

    print_success "SSH configuration completed successfully"
}

import_ssh_menu() {
    clear
    echo "+----------------------------------------------+"
    echo "|           SSH Transfer Tool Info              |"
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

###############################################################################
# SSH Metadata Functions
###############################################################################

save_backup_metadata() {
    local backup_time
    backup_time=$(date '+%Y-%m-%d %H:%M:%S')
    cat >/data/ssh_backup/metadata.txt <<EOF
Backup Date: $backup_time
Last SSH Test: $backup_time
EOF
}

get_backup_metadata() {
    if [ -f "/data/ssh_backup/metadata.txt" ]; then
        cat /data/ssh_backup/metadata.txt
    else
        print_warning "No backup metadata found"
    fi
}

###############################################################################
# Disk Space Management
###############################################################################

verify_disk_space() {
    local required_space=$1
    local available=$(df -m "$BUILD_DIR" | awk 'NR==2 {print $4}')
    if [ "$available" -lt "$required_space" ]; then
        print_error "Insufficient disk space. Need ${required_space}MB, have ${available}MB"
        return 1
    fi
    return 0
}

###############################################################################
# Git/Openpilot Status Functions
###############################################################################

display_disk_space_short() {
    print_info "| Disk Space:"
    local data_usage_root
    local data_usage_data
    data_usage_root=$(df -h / | awk 'NR==2 {printf "Used: %s/%s (%s)", $3, $2, $5}')
    data_usage_data=$(df -h /data | awk 'NR==2 {printf "Used: %s/%s (%s)", $3, $2, $5}')
    echo "| ├─ (/):     $data_usage_root"
    echo "| └─ (/data): $data_usage_data"
}

display_git_status_short() {
    print_info "| Openpilot Repository:"
    if [ -d "/data/openpilot" ]; then
        (
            cd "/data/openpilot" || return
            local repo_name
            local branch_name
            repo_name=$(git config --get remote.origin.url | awk -F'/' '{print $NF}' | sed 's/.git//')
            branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
            echo "| ├─ Repository: $repo_name"
            echo "| └─ Branch: $branch_name"
        )
    else
        echo -e "${YELLOW}| └─ Repository: Missing${NC}"
    fi
}

display_git_status() {
    if [ -d "/data/openpilot" ]; then
        # echo "| Gathering repository details, please wait..."

        (
            cd "/data/openpilot" || exit 1
            local branch_name
            local repo_url
            local repo_status
            local submodule_status

            branch_name=$(git rev-parse --abbrev-ref HEAD)
            repo_url=$(git config --get remote.origin.url)

            # Check if working directory is clean
            if [ -n "$(git status --porcelain)" ]; then
                repo_status="${RED}Uncommitted changes${NC}"
            else
                repo_status="${GREEN}Clean${NC}"
            fi

            # Check submodule status
            if [ -f ".gitmodules" ]; then
                if git submodule status | grep -q '^-'; then
                    submodule_status="${RED}Not initialized${NC}"
                elif git submodule status | grep -q '^+'; then
                    submodule_status="${YELLOW}Out of date${NC}"
                else
                    submodule_status="${GREEN}Up to date${NC}"
                fi
            else
                submodule_status="No submodules"
            fi

            # clear
            # echo "+----------------------------------------------+"
            echo "| Openpilot directory: ✅"
            echo "| ├─ Branch: $branch_name"
            echo "| ├─ Repo: $repo_url"
            echo -e "| ├─ Status: $repo_status"
            echo -e "| └─ Submodules: $submodule_status"
        )
    else
        echo "| Openpilot directory: ❌"
    fi
}

list_git_branches() {
    clear
    echo "+----------------------------------------------+"
    echo "|        Available Branches                    |"
    echo "+----------------------------------------------+"
    if [ -d "/data/openpilot" ]; then
        (
            cd "/data/openpilot" || return
            local branches
            branches=$(git branch --all)
            if [ -n "$branches" ]; then
                echo "$branches"
            else
                echo "No branches found."
            fi
        )
    else
        echo "Openpilot directory does not exist."
    fi
    echo "+----------------------------------------------+"
    pause_for_user
}

# Reusable branch selection function.
# Parameters:
#   $1 - Repository URL (e.g., git@github.com:username/repo.git)
# Returns:
#   Sets SELECTED_BRANCH with the chosen branch name.
select_branch_menu() {
    clear
    local repo_url="$1"
    local remote_branches branch_array branch_count branch_choice
    SELECTED_BRANCH="" # Reset global variable

    # Display placeholder message.
    print_info "Fetching branches from ${repo_url}, please wait..."

    # Fetch branch list using git ls-remote.
    remote_branches=$(git ls-remote --heads "$repo_url" 2>/dev/null | awk '{print $2}' | sed 's#refs/heads/##')
    if [ -z "$remote_branches" ]; then
        print_error "No branches found or failed to contact repository: $repo_url"
        return 1
    fi

    clear
    # Load branches into an array.
    readarray -t branch_array <<<"$remote_branches"
    branch_count=${#branch_array[@]}

    # Display branch menu.
    echo "Available branches from ${repo_url}:"
    for ((i = 0; i < branch_count; i++)); do
        printf "%d) %s\n" $((i + 1)) "${branch_array[i]}"
    done

    # Prompt for selection.
    while true; do
        read -p "Select a branch by number (or 'q' to cancel): " branch_choice
        if [[ "$branch_choice" =~ ^[Qq]$ ]]; then
            print_info "Branch selection canceled."
            return 1
        elif [[ "$branch_choice" =~ ^[0-9]+$ ]] && [ "$branch_choice" -ge 1 ] && [ "$branch_choice" -le "$branch_count" ]; then
            clear
            SELECTED_BRANCH="${branch_array[$((branch_choice - 1))]}"
            print_info "Selected branch: $SELECTED_BRANCH"
            break
        else
            print_error "Invalid choice. Please enter a number between 1 and ${branch_count}."
        fi
    done

    return 0
}

fetch_pull_latest_changes() {
    print_info "Fetching and pulling the latest changes for the current branch..."
    if [ -d "/data/openpilot" ]; then
        (
            cd "/data/openpilot" || return

            if ! git_operation_with_timeout "git fetch" 60; then
                print_error "Failed to fetch latest changes"
                return 1
            fi

            if ! git_operation_with_timeout "git pull" 300; then
                print_error "Failed to pull latest changes"
                return 1
            fi

            print_success "Successfully updated repository"
        )
    else
        print_warning "No openpilot directory found."
    fi
    pause_for_user
}

change_branch() {
    clear
    print_info "Changing the branch of the repository..."

    # Directory check
    if [ ! -d "/data/openpilot" ]; then
        print_error "No openpilot directory found."
        pause_for_user
        return 1
    fi
    cd "/data/openpilot" || {
        print_error "Could not change to openpilot directory"
        pause_for_user
        return 1
    }

    # Working directory check with force options
    if ! check_working_directory; then
        print_warning "Working directory has uncommitted changes."
        echo ""
        echo "Options:"
        echo "1. Stash changes (save them for later)"
        echo "2. Discard changes and force branch switch"
        echo "3. Cancel branch switch"
        echo ""
        read -p "Enter your choice (1-3): " force_choice

        case $force_choice in
        1)
            if ! git stash; then
                print_error "Failed to stash changes"
                pause_for_user
                return 1
            fi
            print_success "Changes stashed successfully"
            ;;
        2)
            print_warning "This will permanently discard all uncommitted changes!"
            read -p "Are you sure? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                print_info "Branch switch cancelled"
                pause_for_user
                return 1
            fi
            ;;
        *)
            print_info "Branch switch cancelled"
            pause_for_user
            return 1
            ;;
        esac
    fi

    # Repository URL
    local repo_url
    repo_url=$(git config --get remote.origin.url)
    if [ -z "$repo_url" ]; then
        print_error "Could not determine repository URL"
        pause_for_user
        return 1
    fi

    # Fetch latest
    print_info "Fetching latest repository information..."
    if ! git fetch; then
        print_error "Failed to fetch latest information"
        pause_for_user
        return 1
    fi

    # Branch selection
    if ! select_branch_menu "$repo_url"; then
        print_error "Branch selection cancelled or failed"
        pause_for_user
        return 1
    fi

    if [ -z "$SELECTED_BRANCH" ]; then
        print_error "No branch was selected"
        pause_for_user
        return 1
    fi

    clear
    print_info "Switching to branch: $SELECTED_BRANCH"

    # If force switch chosen, clean everything
    if [ "$force_choice" = "2" ]; then
        print_info "Cleaning repository and submodules..."

        # Reset main repository
        git reset --hard HEAD

        # Clean untracked files
        git clean -fd
    fi

    # Checkout branch
    if ! git checkout "$SELECTED_BRANCH"; then
        print_error "Failed to checkout branch: $SELECTED_BRANCH"
        pause_for_user
        return 1
    fi

    if [ -f ".gitmodules" ]; then
        # Handle submodules
        print_info "Updating submodules..."

        # First deinitialize all submodules
        git submodule deinit -f .

        # Remove old submodule directories
        local submodules=("msgq_repo" "opendbc_repo" "panda" "rednose_repo" "teleoprtc_repo" "tinygrad_repo")
        for submodule in "${submodules[@]}"; do
            if [ -d "$submodule" ]; then
                print_info "Removing old $submodule directory..."
                rm -rf "$submodule"
                rm -rf ".git/modules/$submodule"
            fi
        done

        # Initialize and update submodules
        print_info "Initializing submodules..."
        if ! git submodule init; then
            print_error "Failed to initialize submodules"
            pause_for_user
            return 1
        fi

        print_info "Updating submodules (this may take a while)..."
        if ! git submodule update --recursive; then
            print_error "Failed to update submodules"
            pause_for_user
            return 1
        fi
    fi

    print_success "Successfully switched to branch: $SELECTED_BRANCH"
    print_success "All submodules have been updated"

    # Handle stashed changes if applicable
    if [ "$force_choice" = "1" ]; then
        echo ""
        read -p "Would you like to reapply your stashed changes? (y/N): " reapply
        if [[ "$reapply" =~ ^[Yy]$ ]]; then
            if ! git stash pop; then
                print_warning "Note: There were conflicts while reapplying changes."
                print_info "Your changes are still saved in the stash."
                print_info "Use 'git stash list' to see them and 'git stash pop' to try again."
            else
                print_success "Stashed changes reapplied successfully"
            fi
        fi
    fi

    pause_for_user
    return 0
}

reset_git_changes() {
    clear
    if [ ! -d "/data/openpilot" ]; then
        print_error "Openpilot directory does not exist."
        pause_for_user
        return 1
    fi

    cd "/data/openpilot" || return 1

    echo "This will reset all uncommitted changes in the repository."
    echo "Options:"
    echo "1. Soft reset (preserve changes but unstage them)"
    echo "2. Hard reset (discard all changes)"
    echo "3. Clean (remove untracked files)"
    echo "4. Hard reset and clean (complete reset)"
    echo "Q. Cancel"

    read -p "Enter your choice: " reset_choice

    case $reset_choice in
    1)
        git reset HEAD
        print_success "Soft reset completed."
        ;;
    2)
        git reset --hard HEAD
        print_success "Hard reset completed."
        ;;
    3)
        read -p "Remove untracked files? This cannot be undone. (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            git clean -fd
            print_success "Repository cleaned."
        fi
        ;;
    4)
        read -p "This will remove ALL changes and untracked files. Continue? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            git reset --hard HEAD
            git clean -fd
            print_success "Repository reset and cleaned."
        fi
        ;;
    [qQ]) return 0 ;;
    *) print_error "Invalid choice." ;;
    esac
    pause_for_user
}

manage_submodules() {
    clear
    if [ ! -d "/data/openpilot" ]; then
        print_error "Openpilot directory does not exist."
        pause_for_user
        return 1
    fi

    cd "/data/openpilot" || return 1

    echo "Submodule Management:"
    echo "1. Initialize submodules"
    echo "2. Update submodules"
    echo "3. Reset submodules"
    echo "4. Status check"
    echo "5. Full reset (initialize, update, and reset)"
    echo "Q. Cancel"

    read -p "Enter your choice: " submodule_choice

    case $submodule_choice in
    1)
        print_info "Initializing submodules..."
        git submodule init
        print_success "Submodules initialized."
        ;;
    2)
        print_info "Updating submodules..."
        git submodule update
        print_success "Submodules updated."
        ;;
    3)
        print_info "Resetting submodules..."
        git submodule foreach --recursive 'git reset --hard HEAD'
        print_success "Submodules reset."
        ;;
    4)
        print_info "Submodule status:"
        git submodule status
        ;;
    5)
        print_info "Performing full submodule reset..."
        git submodule update --init --recursive
        git submodule foreach --recursive 'git reset --hard HEAD'
        print_success "Full submodule reset completed."
        ;;
    [qQ]) return 0 ;;
    *) print_error "Invalid choice." ;;
    esac
    pause_for_user
}

# Clone the Openpilot repository
clone_openpilot_repo() {
    local shallow="${1:-true}"

    # Check available disk space first
    verify_disk_space 2000 || {
        print_error "Insufficient space for repository clone"
        return 1
    }

    read -p "Enter the branch name: " branch_name
    read -p "Enter the GitHub repository (e.g., ford-op/openpilot): " github_repo
    cd /data || return
    rm -rf ./openpilot

    if [ "$shallow" = true ]; then
        if ! git_operation_with_timeout "git clone -b $branch_name --depth 1 git@github.com:$github_repo openpilot" 300; then
            print_error "Failed to clone repository"
            return 1
        fi
        (
            cd openpilot || return
            if [ -f ".gitmodules" ]; then
                if ! git_operation_with_timeout "git submodule update --init --recursive" 300; then
                    print_error "Failed to update submodules"
                    return 1
                fi
            fi
        )
    else
        if ! git_operation_with_timeout "git clone -b $branch_name git@github.com:$github_repo openpilot" 300; then
            print_error "Failed to clone repository"
            return 1
        fi
        (
            cd openpilot || return
            if [ -f ".gitmodules" ]; then
                if ! git_operation_with_timeout "git submodule update --init --recursive" 300; then
                    print_error "Failed to update submodules"
                    return 1
                fi
            fi
        )
    fi
    pause_for_user
}

reset_openpilot_repo() {
    read -p "Are you sure you want to reset the Openpilot repository? This will remove the current repository and clone a new one. (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Removing the Openpilot repository..."
        cd /data || return
        rm -rf openpilot
        clone_openpilot_repo "true"
    else
        print_info "Reset cancelled."
    fi
}

###############################################################################
# Boot & Logo Update Functions
###############################################################################

# Define paths:
readonly BOOT_IMG="/usr/comma/bg.jpg"
readonly LOGO_IMG="/data/openpilot/selfdrive/assets/img_spinner_comma.png"

readonly BLUEPILOT_BOOT_IMG="/data/openpilot/selfdrive/assets/img_bluepilot_boot.jpg"
readonly BLUEPILOT_LOGO_IMG="/data/openpilot/selfdrive/assets/img_bluepilot_logo.png"

readonly BOOT_IMG_BKP="${BOOT_IMG}.backup"
readonly LOGO_IMG_BKP="${LOGO_IMG}.backup"

mount_rw_boot_logo() {
    print_info "Mounting / partition as read-write for boot image update..."
    sudo mount -o remount,rw /
}

update_boot_and_logo() {
    mount_rw_boot_logo

    # Ensure the original files exist before proceeding
    if [ ! -f "$BOOT_IMG" ]; then
        print_error "Boot image ($BOOT_IMG) does not exist. Aborting update."
        pause_for_user
        return 1
    fi
    if [ ! -f "$LOGO_IMG" ]; then
        print_error "Logo image ($LOGO_IMG) does not exist. Aborting update."
        pause_for_user
        return 1
    fi

    # Create backups if they do not already exist
    if [ ! -f "$BOOT_IMG_BKP" ]; then
        sudo cp "$BOOT_IMG" "$BOOT_IMG_BKP"
        print_success "Backup created for boot image at $BOOT_IMG_BKP"
    else
        print_info "Backup for boot image already exists at $BOOT_IMG_BKP"
    fi

    if [ ! -f "$LOGO_IMG_BKP" ]; then
        sudo cp "$LOGO_IMG" "$LOGO_IMG_BKP"
        print_success "Backup created for logo image at $LOGO_IMG_BKP"
    else
        print_info "Backup for logo image already exists at $LOGO_IMG_BKP"
    fi

    # Ensure the BluePilot images exist
    if [ ! -f "$BLUEPILOT_BOOT_IMG" ]; then
        print_error "BluePilot boot image ($BLUEPILOT_BOOT_IMG) not found."
        pause_for_user
        return 1
    fi
    if [ ! -f "$BLUEPILOT_LOGO_IMG" ]; then
        print_error "BluePilot logo image ($BLUEPILOT_LOGO_IMG) not found."
        pause_for_user
        return 1
    fi

    # Overwrite the original files with the BluePilot images
    sudo cp "$BLUEPILOT_BOOT_IMG" "$BOOT_IMG"
    sudo cp "$BLUEPILOT_LOGO_IMG" "$LOGO_IMG"
    print_success "Boot and logo images updated with BluePilot files."
    pause_for_user
}

restore_boot_and_logo() {
    mount_rw_boot_logo

    # Check if backups exist before attempting restoration
    if [ ! -f "$BOOT_IMG_BKP" ]; then
        print_error "Backup for boot image not found at $BOOT_IMG_BKP"
        pause_for_user
        return 1
    fi
    if [ ! -f "$LOGO_IMG_BKP" ]; then
        print_error "Backup for logo image not found at $LOGO_IMG_BKP"
        pause_for_user
        return 1
    fi

    # Restore backups to the original file locations
    sudo cp "$BOOT_IMG_BKP" "$BOOT_IMG"
    sudo cp "$LOGO_IMG_BKP" "$LOGO_IMG"

    # Remove the backups
    sudo rm -f "$BOOT_IMG_BKP"
    sudo rm -f "$LOGO_IMG_BKP"

    print_success "Boot and logo images restored from backup."
    pause_for_user
}

toggle_boot_logo() {
    # clear
    print_info "Boot Icon and Logo Update/Restore Utility"
    echo "+-------------------------------------------------+"

    # Check if the original files exist
    if [ ! -f "$BOOT_IMG" ]; then
        print_error "Boot image ($BOOT_IMG) is missing; cannot proceed."
        pause_for_user
        return 1
    fi
    if [ ! -f "$LOGO_IMG" ]; then
        print_error "Logo image ($LOGO_IMG) is missing; cannot proceed."
        pause_for_user
        return 1
    fi

    # If backup files exist, offer restoration; otherwise, offer update.
    if [ -f "$BOOT_IMG_BKP" ] && [ -f "$LOGO_IMG_BKP" ]; then
        echo "Backup files exist."
        read -p "Do you want to restore the original boot and logo images? (y/N): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            restore_boot_and_logo
        else
            print_info "Restore cancelled."
            pause_for_user
        fi
    else
        echo "No backups found."
        read -p "Do you want to update boot and logo images with BluePilot files? (y/N): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            update_boot_and_logo
        else
            print_info "Update cancelled."
            pause_for_user
        fi
    fi
}

###############################################################################
# System Status & Logs
###############################################################################

display_os_info_short() {
    print_info "| OS Information:"
    local agnos_version
    agnos_version=$(cat /VERSION 2>/dev/null)
    if [ -n "$agnos_version" ]; then
        echo "| └─ AGNOS: v$agnos_version"
    else
        echo "| └─ AGNOS: Unknown"
    fi
}

display_general_status() {
    local agnos_version
    local build_time
    agnos_version=$(cat /VERSION 2>/dev/null)
    build_time=$(awk 'NR==2' /BUILD 2>/dev/null)
    echo "+----------------------------------------------+"
    echo "|           Other Items                        |"
    echo "+----------------------------------------------+"
    echo "- AGNOS: v$agnos_version ($build_time)"
    echo "+----------------------------------------------+"
}

# Combined or replaced by check_disk_usage_and_resize + resize_root_if_needed
check_root_space() {
    local usage
    usage=$(check_disk_usage_and_resize)
    resize_root_if_needed "$usage"
}

mount_rw() {
    print_info "Mounting the / partition as read-write..."
    sudo mount -o remount,rw /
}

check_prerequisites() {
    local errors=0

    # Check disk space in /data
    local available_space
    available_space=$(df -m /data | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 1000 ]; then
        print_warning "Low disk space on /data: ${available_space}MB available"
        errors=$((errors + 1))
    fi

    # Check network connectivity
    if ! ping -c 1 github.com >/dev/null 2>&1; then
        print_error "No network connectivity to GitHub"
        errors=$((errors + 1))
    fi

    # Check git installation
    if ! command -v git >/dev/null 2>&1; then
        print_error "Git is not installed"
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        print_warning "Some prerequisites checks failed. Some features may not work correctly."
        pause_for_user
    fi

    return $errors
}

display_logs() {
    clear
    echo "+---------------------------------+"
    echo "|            Log Files            |"
    echo "+---------------------------------+"
    local log_files
    log_files=(/data/log/*)
    local i
    for i in "${!log_files[@]}"; do
        echo "$((i + 1)). ${log_files[$i]}"
    done
    echo "Q. Back to previous menu"

    read -p "Enter the number of the log file to view or [Q] to go back: " log_choice

    if [[ $log_choice =~ ^[0-9]+$ ]] && ((log_choice > 0 && log_choice <= ${#log_files[@]})); then
        local log_file="${log_files[$((log_choice - 1))]}"
        echo "Displaying contents of $log_file:"
        cat "$log_file"
    elif [[ $log_choice =~ ^[Qq]$ ]]; then
        return
    else
        print_error "Invalid choice."
    fi

    pause_for_user
}

view_error_log() {
    print_info "Displaying error log at /data/community/crashes/error.txt:"
    cat /data/community/crashes/error.txt 2>/dev/null || print_warning "No error log found."
    pause_for_user
}

turn_off_screen() {
    print_info "Turning off the screen..."
    echo 1 >/sys/class/backlight/panel0-backlight/bl_power
}

turn_on_screen() {
    print_info "Turning on the screen..."
    echo 0 >/sys/class/backlight/panel0-backlight/bl_power
}

reboot_device() {
    print_info "Rebooting the device..."
    sudo reboot
}

shutdown_device() {
    print_info "Shutting down the device..."
    sudo shutdown now
}

###############################################################################
# Script Update Logic
###############################################################################

update_script() {
    print_info "Downloading the latest version of the script..."

    local script_path
    script_path=$(get_absolute_path "$SCRIPT_DIR/CommaUtilityLegacy.sh")
    cp "$script_path" "$script_path.backup"

    local download_cmd="wget -O '$script_path.tmp' https://raw.githubusercontent.com/tonesto7/op-utilities/main/CommaUtilityLegacy.sh"
    if execute_with_network_retry "$download_cmd" "Script update download failed"; then
        mv "$script_path.tmp" "$script_path"
        chmod +x "$script_path"
        print_success "Script updated successfully. Restarting the updated script."
        pause_for_user
        exec "$script_path"
    else
        print_error "Update failed. Restoring backup..."
        mv "$script_path.backup" "$script_path"
        rm -f "$script_path.tmp"
        pause_for_user
    fi
}

compare_versions() {
    local ver1="$1"
    local ver2="$2"

    # Remove 'v' prefix if present
    ver1="${ver1#v}"
    ver2="${ver2#v}"

    # Split versions into arrays
    IFS='.' read -ra VER1 <<<"$ver1"
    IFS='.' read -ra VER2 <<<"$ver2"

    # Compare each part of version
    for i in {0..2}; do
        local v1=$([[ ${VER1[$i]} ]] && echo "${VER1[$i]}" || echo "0")
        local v2=$([[ ${VER2[$i]} ]] && echo "${VER2[$i]}" || echo "0")

        # Convert to integers for comparison
        v1=$(echo "$v1" | sed 's/[^0-9]//g')
        v2=$(echo "$v2" | sed 's/[^0-9]//g')

        if ((v1 > v2)); then
            echo "1"
            return
        elif ((v1 < v2)); then
            echo "-1"
            return
        fi
    done
    echo "0"
}

# Add this function to compare semantic versions
compare_versions() {
    local ver1="$1"
    local ver2="$2"

    # Remove 'v' prefix if present
    ver1="${ver1#v}"
    ver2="${ver2#v}"

    # Split versions into arrays
    IFS='.' read -ra VER1 <<<"$ver1"
    IFS='.' read -ra VER2 <<<"$ver2"

    # Compare each part of version
    for i in {0..2}; do
        local v1=$([[ ${VER1[$i]} ]] && echo "${VER1[$i]}" || echo "0")
        local v2=$([[ ${VER2[$i]} ]] && echo "${VER2[$i]}" || echo "0")

        # Convert to integers for comparison
        v1=$(echo "$v1" | sed 's/[^0-9]//g')
        v2=$(echo "$v2" | sed 's/[^0-9]//g')

        if ((v1 > v2)); then
            echo "1"
            return
        elif ((v1 < v2)); then
            echo "-1"
            return
        fi
    done
    echo "0"
}

check_for_updates() {
    print_info "Checking for script updates..."

    # Add timeout and retry logic for wget
    local max_attempts=3
    local attempt=1
    local latest_version=""

    while [ $attempt -le $max_attempts ]; do
        if latest_version=$(wget --timeout=10 -qO- https://raw.githubusercontent.com/tonesto7/op-utilities/main/CommaUtilityLegacy.sh | grep "SCRIPT_VERSION=" | head -n 1 | cut -d'"' -f2); then
            break
        fi
        attempt=$((attempt + 1))
        [ $attempt -le $max_attempts ] && sleep 2
    done

    if [ -z "$latest_version" ]; then
        print_error "Unable to check for updates after $max_attempts attempts."
        return 1
    fi

    local version_comparison=$(compare_versions "$latest_version" "$SCRIPT_VERSION")

    if [ "$version_comparison" = "1" ]; then
        print_info "New version available: v$latest_version (Current: v$SCRIPT_VERSION)"
        read -p "Would you like to update now? (y/N): " update_choice
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then
            update_script
        fi
    elif [ "$version_comparison" = "0" ]; then
        print_info "Script is up to date (v$SCRIPT_VERSION)"
    else
        print_warning "Current version (v$SCRIPT_VERSION) is ahead of remote version (v$latest_version)"
    fi
}

###############################################################################
# BluePilot Utility Functions (from build_bluepilot)
###############################################################################

reset_variables() {
    SCRIPT_ACTION=""
    REPO=""
    CLONE_BRANCH=""
    BUILD_BRANCH=""
}

show_help() {
    cat <<EOL
CommaUtilityLegacy Script (V$SCRIPT_VERSION) - Last Modified: $SCRIPT_MODIFIED
------------------------------------------------------------

Usage: ./CommaUtilityLegacy.sh [OPTION] [PARAMETERS]

SSH Operations:
  --import-ssh                      Import SSH keys from files
    --private-key-file <path>       Path to private key file
    --public-key-file <path>        Path to public key file
  --test-ssh                        Test SSH connection to GitHub
  --backup-ssh                      Backup SSH files
  --restore-ssh                     Restore SSH files from backup
  --reset-ssh                       Reset SSH configuration

Build Operations:
  --build-dev                       Build BluePilot internal dev
  --build-public                    Build BluePilot public experimental
  --custom-build                    Perform a custom build
    --repo <repository>             Select repository (bluepilotdev, sp-dev-c3, sunnypilot, or commaai)
    --clone-branch <branch>         Branch to clone
    --build-branch <branch>         Branch name for build

Clone Operations:
  --clone-public-bp                 Clone BluePilot staging branch
  --clone-internal-dev-build        Clone BluePilot internal dev build
  --clone-internal-dev              Clone BluePilot internal dev
  --custom-clone                    Clone a specific repository/branch
    --repo <repository>             Repository to clone from
    --clone-branch <branch>         Branch to clone

System Operations:
  --update                          Update this script to latest version
  --reboot                          Reboot the device
  --shutdown                        Shutdown the device
  --view-logs                       View system logs

Git Operations:
  --git-pull                        Fetch and pull latest changes
  --git-status                      Show Git repository status
  --git-branch <branch>            Switch to specified branch

General:
  -h, --help                        Show this help message
  --no-update                       Skip checking for script updates

Examples:
  # SSH operations
  ./CommaUtilityLegacy.sh --import-ssh --private-key-file /path/to/key --public-key-file /path/to/key.pub
  ./CommaUtilityLegacy.sh --test-ssh

  # Build operations
  ./CommaUtilityLegacy.sh --custom-build --repo bluepilotdev --clone-branch dev --build-branch build

  # Clone operations
  ./CommaUtilityLegacy.sh --custom-clone --repo sunnypilot --clone-branch master

  # System operations
  ./CommaUtilityLegacy.sh --update
  ./CommaUtilityLegacy.sh --reboot

  # Git operations
  ./CommaUtilityLegacy.sh --git-branch master

Note: When no options are provided, the script will launch in interactive menu mode.
EOL
}

###############################################################################
# BluePilot build logic
###############################################################################

setup_git_env_bp() {
    if [ -f "$BUILD_DIR/release/identity_ford_op.sh" ]; then
        # shellcheck disable=SC1090
        source "$BUILD_DIR/release/identity_ford_op.sh"
    else
        print_error "[-] identity_ford_op.sh not found"
        exit 1
    fi

    if [ -f /data/gitkey ]; then
        export GIT_SSH_COMMAND="ssh -i /data/gitkey"
    elif [ -f ~/.ssh/github ]; then
        export GIT_SSH_COMMAND="ssh -i ~/.ssh/github"
    else
        print_error "[-] No git key found"
        exit 1
    fi
}

build_openpilot_bp() {
    export PYTHONPATH="$BUILD_DIR"
    print_info "[-] Building Openpilot"
    scons -j"$(nproc)"
}

create_prebuilt_marker() {
    touch prebuilt
}

handle_panda_directory() {
    print_info "Creating panda_tmp directory"
    mkdir -p "$BUILD_DIR/panda_tmp/board/obj"
    mkdir -p "$BUILD_DIR/panda_tmp/python"

    cp -f "$BUILD_DIR/panda/board/obj/panda.bin.signed" "$BUILD_DIR/panda_tmp/board/obj/panda.bin.signed" || :
    cp -f "$BUILD_DIR/panda/board/obj/panda_h7.bin.signed" "$BUILD_DIR/panda_tmp/board/obj/panda_h7.bin.signed" || :
    cp -f "$BUILD_DIR/panda/board/obj/bootstub.panda.bin" "$BUILD_DIR/panda_tmp/board/obj/bootstub.panda.bin" || :
    cp -f "$BUILD_DIR/panda/board/obj/bootstub.panda_h7.bin" "$BUILD_DIR/panda_tmp/board/obj/bootstub.panda_h7.bin" || :

    if [ "$OS" = "Darwin" ]; then
        sed -i '' 's/^from .board.jungle import PandaJungle, PandaJungleDFU # noqa: F401/# &/' panda/__init__.py
    else
        sed -i 's/^from .board.jungle import PandaJungle, PandaJungleDFU # noqa: F401/# &/' panda/__init__.py
    fi

    cp -r "$BUILD_DIR/panda/python/." "$BUILD_DIR/panda_tmp/python" || :
    cp -f "$BUILD_DIR/panda/.gitignore" "$BUILD_DIR/panda_tmp/.gitignore" || :
    cp -f "$BUILD_DIR/panda/__init__.py" "$BUILD_DIR/panda_tmp/__init__.py" || :
    cp -f "$BUILD_DIR/panda/mypy.ini" "$BUILD_DIR/panda_tmp/mypy.ini" || :
    cp -f "$BUILD_DIR/panda/panda.png" "$BUILD_DIR/panda_tmp/panda.png" || :
    cp -f "$BUILD_DIR/panda/pyproject.toml" "$BUILD_DIR/panda_tmp/pyproject.toml" || :
    cp -f "$BUILD_DIR/panda/requirements.txt" "$BUILD_DIR/panda_tmp/requirements.txt" || :
    cp -f "$BUILD_DIR/panda/setup.cfg" "$BUILD_DIR/panda_tmp/setup.cfg" || :
    cp -f "$BUILD_DIR/panda/setup.py" "$BUILD_DIR/panda_tmp/setup.py" || :

    rm -rf "$BUILD_DIR/panda"
    mv "$BUILD_DIR/panda_tmp" "$BUILD_DIR/panda"
}

create_opendbc_gitignore() {
    cat >opendbc_repo/.gitignore <<EOL
.mypy_cache/
*.pyc
*.os
*.o
*.tmp
*.dylib
.*.swp
.DS_Store
.sconsign.dblite

opendbc/can/*.so
opendbc/can/*.a
opendbc/can/build/
opendbc/can/obj/
opendbc/can/packer_pyx.cpp
opendbc/can/parser_pyx.cpp
opendbc/can/packer_pyx.html
opendbc/can/parser_pyx.html
EOL
}

update_main_gitignore() {
    local GITIGNORE_PATH=".gitignore"
    local LINES_TO_REMOVE=(
        "*.dylib"
        "*.so"
        "selfdrive/pandad/pandad"
        "cereal/messaging/bridge"
        "selfdrive/logcatd/logcatd"
        "system/camerad/camerad"
        "selfdrive/modeld/_modeld"
        "selfdrive/modeld/_navmodeld"
        "selfdrive/modeld/_dmonitoringmodeld"
    )

    # local LINES_TO_ADD=(
    #     "selfdrive/controls/lib/lateral_mpc_lib/acados_ocp_lat.json"
    #     "selfdrive/controls/lib/longitudinal_mpc_lib/acados_ocp_long.json"
    # )

    # # Add the following lines to the gitignore file
    # for LINE in "${LINES_TO_ADD[@]}"; do
    #     echo "$LINE" >>"$GITIGNORE_PATH"
    # done

    for LINE in "${LINES_TO_REMOVE[@]}"; do
        if [ "$OS" = "Darwin" ]; then
            sed -i '' "/^${LINE//\//\\/}$/d" "$GITIGNORE_PATH"
        else
            sed -i "/^${LINE//\//\\/}$/d" "$GITIGNORE_PATH"
        fi
    done
}

cleanup_files() {
    local CURRENT_DIR
    CURRENT_DIR=$(pwd)
    ensure_directory "$BUILD_DIR" || return 1

    # Remove compiled artifacts
    find . \( -name '*.a' -o -name '*.o' -o -name '*.os' -o -name '*.pyc' -o -name 'moc_*' -o -name '*.cc' -o -name '__pycache__' -o -name '.DS_Store' \) -exec rm -rf {} +
    rm -rf .sconsign.dblite .venv .devcontainer .idea .mypy_cache .run .vscode
    rm -f .clang-tidy .env .gitmodules .gitattributes
    rm -rf teleoprtc_repo teleoprtc release
    rm -f selfdrive/modeld/models/supercombo.onnx
    rm -rf selfdrive/ui/replay/
    rm -rf tools/cabana tools/camerastream tools/car_porting tools/joystick tools/latencylogger tools/plotjuggler tools/profiling
    rm -rf tools/replay tools/rerun tools/scripts tools/serial tools/sim tools/tuning tools/webcam
    rm -f tools/*.py tools/*.sh tools/*.md
    rm -f conftest.py SECURITY.md uv.lock
    rm -f selfdrive/controls/lib/lateral_mpc_lib/.gitignore selfdrive/controls/lib/longitudinal_mpc_lib/.gitignore

    cleanup_directory "$BUILD_DIR/cereal" "*tests* *.md"
    cleanup_directory "$BUILD_DIR/common" "*tests* *.md"
    cleanup_directory "$BUILD_DIR/msgq_repo" "*tests* *.md .git*"
    cleanup_directory "$BUILD_DIR/opendbc_repo" "*tests* *.md .git* LICENSE"
    cleanup_directory "$BUILD_DIR/rednose_repo" "*tests* *.md .git* LICENSE"
    cleanup_directory "$BUILD_DIR/selfdrive" "*.h *.md *test*"
    cleanup_directory "$BUILD_DIR/system" "*tests* *.md"
    cleanup_directory "$BUILD_DIR/third_party" "*Darwin* LICENSE README.md"

    cleanup_tinygrad_repo
    cd "$CURRENT_DIR" || return 1
}

cleanup_directory() {
    local dir="$1"
    local patterns="$2"
    for pattern in $patterns; do
        find "$dir/" -name "$pattern" -exec rm -rf {} +
    done
}

cleanup_tinygrad_repo() {
    rm -rf tinygrad_repo/{cache,disassemblers,docs,examples,models,test,weights}
    rm -rf tinygrad_repo/extra/{accel,assembly,dataset,disk,dist,fastvits,intel,optimization,ptx,rocm,triton}
    find tinygrad_repo/extra -maxdepth 1 -type f -name '*.py' ! -name 'onnx*.py' ! -name 'thneed*.py' ! -name 'utils*.py' -exec rm -f {} +
    rm -rf tinygrad_repo/extra/{datasets,gemm}
    find tinygrad_repo/ -name '*tests*' -exec rm -rf {} +
    find tinygrad_repo/ -name '.git*' -exec rm -rf {} +
    find tinygrad_repo/ -name '*.md' -exec rm -f {} +
    rm -f tinygrad_repo/{.flake8,.pylintrc,.tokeignore,*.sh,*.ini,*.toml,*.py}
}

prepare_commit_push() {
    local COMMIT_DESC_HEADER=$1
    local ORIGIN_REPO=$2
    local BUILD_BRANCH=$3
    local PUSH_REPO=${4:-$ORIGIN_REPO} # Use alternative repo if provided, otherwise use origin

    if [ ! -f "$BUILD_DIR/common/version.h" ]; then
        print_error "Error: $BUILD_DIR/common/version.h not found."
        exit 1
    fi

    local VERSION
    VERSION=$(date '+%Y.%m.%d')
    local TIME_CODE
    TIME_CODE=$(date +"%H%M")
    local GIT_HASH
    GIT_HASH=$(git rev-parse HEAD)
    local DATETIME
    DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
    local SP_VERSION
    SP_VERSION=$(awk -F\" '{print $2}' "$BUILD_DIR/common/version.h")

    echo "#define COMMA_VERSION \"$VERSION-$TIME_CODE\"" >"$BUILD_DIR/common/version.h"
    create_prebuilt_marker

    git checkout --orphan temp_branch --quiet

    git add -f -A >/dev/null 2>&1
    git commit -m "$COMMIT_DESC_HEADER | v$VERSION-$TIME_CODE
version: $COMMIT_DESC_HEADER v$SP_VERSION release
date: $DATETIME
master commit: $GIT_HASH
" || {
        print_error "[-] Commit failed"
        exit 1
    }

    if git show-ref --verify --quiet "refs/heads/$BUILD_BRANCH"; then
        git branch -D "$BUILD_BRANCH" || exit 1
    fi
    if git ls-remote --heads "$PUSH_REPO" "$BUILD_BRANCH" | grep "$BUILD_BRANCH" >/dev/null 2>&1; then
        git push "$PUSH_REPO" --delete "$BUILD_BRANCH" || exit 1
    fi

    git branch -m "$BUILD_BRANCH" >/dev/null 2>&1 || exit 1
    git push -f "$PUSH_REPO" "$BUILD_BRANCH" || exit 1
}

build_repo_branch() {
    local CLONE_BRANCH="$1"
    local BUILD_BRANCH="$2"
    local COMMIT_DESC_HEADER="$3"
    local GIT_REPO_ORIGIN="$4"
    local PUSH_REPO="$5" # Optional alternative push repository

    # Check available disk space first.
    verify_disk_space 5000 || {
        print_error "Insufficient disk space for build operation"
        return 1
    }

    local CURRENT_DIR
    CURRENT_DIR=$(pwd)

    rm -rf "$BUILD_DIR" "$TMP_DIR"
    if ! git_operation_with_timeout "git clone $GIT_REPO_ORIGIN -b $CLONE_BRANCH $BUILD_DIR" 300; then
        print_error "Failed to clone repository"
        return 1
    fi

    cd "$BUILD_DIR" || exit 1

    # Update submodules if any.
    if [ -f ".gitmodules" ]; then
        if ! git_operation_with_timeout "git submodule update --init --recursive" 300; then
            print_error "Failed to update submodules"
            return 1
        fi
    fi

    setup_git_env_bp
    build_openpilot_bp
    handle_panda_directory

    # Convert all submodules into plain directories.
    process_submodules "$BUILD_DIR"

    create_opendbc_gitignore
    update_main_gitignore
    cleanup_files
    create_prebuilt_marker

    if [ -n "$PUSH_REPO" ]; then
        prepare_commit_push "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN" "$BUILD_BRANCH" "$PUSH_REPO"
    else
        prepare_commit_push "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN" "$BUILD_BRANCH"
    fi

    cd "$CURRENT_DIR" || exit 1
}

process_submodules() {
    local mod_dir="$1"
    local submodules=("msgq_repo" "opendbc_repo" "rednose_repo" "panda" "tinygrad_repo" "teleoprtc_repo")

    for sub in "${submodules[@]}"; do
        if [ -d "${mod_dir}/${sub}" ]; then
            # Create a temporary copy preserving all attributes.
            local tmp_dir="${mod_dir}/${sub}_tmp"
            rm -rf "$tmp_dir"
            cp -a "${mod_dir}/${sub}" "$tmp_dir"

            # Remove any .git folder inside the copied submodule so that files are tracked as normal files.
            rm -rf "$tmp_dir/.git"

            # Remove the submodule from git's index.
            git rm -rf --cached "$sub" 2>/dev/null

            # Remove the original submodule directory.
            rm -rf "${mod_dir}/${sub}"

            # Rename the temporary directory to the original name.
            mv "$tmp_dir" "${mod_dir}/${sub}"

            # Remove any leftover git metadata from the main repository.
            rm -rf "${mod_dir}/.git/modules/${sub}"

            # Force add the now-converted directory.
            git add "$sub"
        fi
    done
}

clone_repo_bp() {
    local description="$1"
    local repo_url="$2"
    local branch="$3"
    local build="$4"
    local skip_reboot="${5:-no}"

    local CURRENT_DIR
    CURRENT_DIR=$(pwd)

    cd "/data" || exit 1
    rm -rf openpilot
    git clone --depth 1 "${repo_url}" -b "${branch}" openpilot || exit 1
    cd openpilot || exit 1

    # Check if there are any submodules and if so, update them
    if [ -f ".gitmodules" ]; then
        git submodule update --init --recursive
    fi

    if [ "$build" == "yes" ]; then
        scons -j"$(nproc)" || exit 1
    fi

    if [ "$skip_reboot" == "yes" ]; then
        cd "$CURRENT_DIR" || exit 1
    else
        reboot_device
    fi
}

clone_public_bluepilot() {
    clone_repo_bp "the public BluePilot" "$GIT_BP_PUBLIC_REPO" "staging-DONOTUSE" "no"
}

clone_internal_dev_build() {
    clone_repo_bp "bp-internal-dev-build" "$GIT_BP_PRIVATE_REPO" "bp-internal-dev-build" "no"
}

clone_internal_dev() {
    clone_repo_bp "bp-internal-dev" "$GIT_BP_PRIVATE_REPO" "bp-internal-dev" "yes"
}

reboot_device_bp() {
    read -p "Would you like to reboot the Comma device? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sudo reboot
    else
        print_info "Reboot canceled."
    fi
}

choose_repository_and_branch() {
    clear
    local action="$1"

    # First, select repository.
    while true; do
        echo ""
        echo "Select Repository:"
        echo "1) BluePilotDev/bluepilot"
        echo "2) ford-op/sp-dev-c3"
        echo "3) sunnypilot/sunnypilot"
        echo "4) commaai/openpilot"
        echo "c) Cancel"
        read -p "Enter your choice: " repo_choice
        case $repo_choice in
        1)
            REPO="bluepilotdev"
            GIT_REPO_ORIGIN="$GIT_BP_PUBLIC_REPO"
            break
            ;;
        2)
            REPO="sp-dev-c3"
            GIT_REPO_ORIGIN="$GIT_BP_PRIVATE_REPO"
            break
            ;;
        3)
            REPO="sunnypilot"
            GIT_REPO_ORIGIN="$GIT_SP_REPO"
            break
            ;;
        4)
            REPO="commaai"
            GIT_REPO_ORIGIN="$GIT_COMMA_REPO"
            break
            ;;
        [cC])
            return 1
            ;;
        *)
            print_error "Invalid choice. Please try again."
            ;;
        esac
    done

    clear
    # Use reusable branch selection to choose the branch.
    if ! select_branch_menu "$GIT_REPO_ORIGIN"; then
        return 1
    fi

    # Set the chosen branch to both CLONE_BRANCH and (optionally) BUILD_BRANCH.
    CLONE_BRANCH="$SELECTED_BRANCH"
    BUILD_BRANCH="${CLONE_BRANCH}-build"

    # print_info "Selected branch: $CLONE_BRANCH"
    # print_info "Build branch would be: $BUILD_BRANCH"
    return 0
}

clone_custom_repo() {
    if ! choose_repository_and_branch "clone"; then
        return
    fi

    case "$REPO" in
    bluepilotdev) GIT_REPO_URL="$GIT_BP_PUBLIC_REPO" ;;
    sp-dev-c3) GIT_REPO_URL="$GIT_BP_PRIVATE_REPO" ;;
    sunnypilot) GIT_REPO_URL="$GIT_SP_REPO" ;;
    commaai) GIT_REPO_URL="$GIT_COMMA_REPO" ;;
    *)
        print_error "[-] Unknown repository: $REPO"
        return
        ;;
    esac

    clone_repo_bp "repository '$REPO' with branch '$CLONE_BRANCH'" "$GIT_REPO_URL" "$CLONE_BRANCH" "no" "yes"
    if [ ! -f "/data/openpilot/prebuilt" ]; then
        print_warning "[-] No prebuilt marker found. Might need to compile."
        read -p "Compile now? (y/N): " compile_confirm
        if [[ "$compile_confirm" =~ ^[Yy]$ ]]; then
            print_info "[-] Running scons..."
            cd "/data/openpilot" || exit 1
            scons -j"$(nproc)" || {
                print_error "[-] SCons failed."
                exit 1
            }
            print_success "[-] Compilation completed."
        fi
    fi

    reboot_device_bp
}

custom_build_process() {
    if ! choose_repository_and_branch "build"; then
        return
    fi
    if [ "$REPO" = "bluepilotdev" ]; then
        GIT_REPO_ORIGIN="$GIT_BP_PUBLIC_REPO"
    elif [ "$REPO" = "sp-dev-c3" ]; then
        GIT_REPO_ORIGIN="$GIT_BP_PRIVATE_REPO"
    elif [ "$REPO" = "sunnypilot" ]; then
        GIT_REPO_ORIGIN="$GIT_SP_REPO"
    elif [ "$REPO" = "commaai" ]; then
        GIT_REPO_ORIGIN="$GIT_COMMA_REPO"
    else
        print_error "Invalid repository selected"
        return
    fi

    print_info "Building branch: $CLONE_BRANCH"
    print_info "Build branch would be: $BUILD_BRANCH"
    local COMMIT_DESC_HEADER="Custom Build"
    build_repo_branch "$CLONE_BRANCH" "$BUILD_BRANCH" "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN"
    print_success "[-] Action completed successfully"
}

###############################################################################
# Menu Functions (Refined Outline)
###############################################################################

ssh_menu() {
    while true; do
        clear
        display_ssh_status
        echo "+----------------------------------------------+"
        echo ""
        echo -e "${GREEN}Available Actions:${NC}"
        echo "1. Repair/Create SSH setup"
        echo "2. Import SSH keys from host system"
        echo "3. Copy SSH config and keys to persistent storage"
        echo "4. Reset SSH setup and recreate keys"
        echo "5. Test SSH connection"
        echo "6. View SSH key"
        echo "7. Change Github SSH port to 443"
        if [ -f "/home/comma/.ssh/github" ]; then
            echo "B. Backup SSH files"
        fi
        if check_ssh_backup; then
            echo "X. Restore SSH files from backup"
        fi
        echo "Q. Back to Main Menu"
        read -p "Enter your choice: " choice
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

# Combined menu function
repo_build_and_management_menu() {
    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "|        Repository Build & Management         |"
        echo "+----------------------------------------------+"
        display_git_status
        echo "+----------------------------------------------+"
        echo ""
        echo "Repository Operations:"
        echo "1. Fetch and pull latest changes"
        echo "2. Change current branch"
        echo "3. List available branches"
        echo "4. Reset/clean repository"
        echo "5. Manage submodules"
        echo ""
        echo "Clone Operations:"
        echo "6. Clone a branch by name"
        echo "7. Clone a repository and branch from list"
        echo "8. Clone BluePilot public branch"
        echo "9. Clone BluePilot internal dev branch"
        echo ""
        echo "Build Operations:"
        echo "10. Run SCONS on current branch"
        echo "11. Build BluePilot internal dev"
        echo "12. Build BluePilot public experimental"
        echo "13. Custom build from any branch"
        echo ""
        echo "Reset Operations:"
        echo "14. Remove and Re-clone repository"
        echo ""
        echo "Q. Back to Main Menu"

        read -p "Enter your choice: " choice
        case $choice in
        1) fetch_pull_latest_changes ;;
        2) change_branch ;;
        3) list_git_branches ;;
        4) reset_git_changes ;;
        5) manage_submodules ;;
        6) clone_openpilot_repo "true" ;;
        7) clone_custom_repo ;;
        8) clone_public_bluepilot ;;
        9) clone_internal_dev ;;
        10)
            clear
            cd "/data/openpilot" || return
            scons -j"$(nproc)"
            pause_for_user
            ;;
        11)
            clear
            build_repo_branch "bp-internal-dev" "bp-internal-dev-build" "bluepilot internal dev" "$GIT_BP_PRIVATE_REPO"
            pause_for_user
            ;;
        12)
            clear
            build_repo_branch "bp-public-experimental" "staging-DONOTUSE" "bluepilot experimental" "$GIT_BP_PRIVATE_REPO" "$GIT_BP_PUBLIC_REPO"
            pause_for_user
            ;;
        13)
            clear
            custom_build_process
            pause_for_user
            ;;
        14)
            clear
            reset_openpilot_repo
            pause_for_user
            ;;
        [qQ]) break ;;
        *) print_error "Invalid choice." ;;
        esac
    done
}

###############################################################################
# Issue Detection Functions
###############################################################################

detect_issues() {
    ISSUE_FIXES=()
    ISSUE_DESCRIPTIONS=()
    ISSUE_PRIORITIES=()
    local issues_found=0

    # SSH Status Checks
    local home_ssh_exists=false
    local usr_ssh_exists=false
    local backup_exists=false

    [ -f "/home/comma/.ssh/github" ] && home_ssh_exists=true
    [ -f "/usr/default/home/comma/.ssh/github" ] && usr_ssh_exists=true
    check_ssh_backup && backup_exists=true

    # Scenario 1: Missing from both locations
    if [ "$home_ssh_exists" = false ] && [ "$usr_ssh_exists" = false ]; then
        issues_found=$((issues_found + 1))
        if [ "$backup_exists" = true ]; then
            ISSUE_FIXES[$issues_found]="restore_ssh"
            ISSUE_DESCRIPTIONS[$issues_found]="SSH keys missing from all locations - Backup available for restore"
            ISSUE_PRIORITIES[$issues_found]=1
        else
            ISSUE_FIXES[$issues_found]="repair_create_ssh"
            ISSUE_DESCRIPTIONS[$issues_found]="SSH keys missing from all locations - New setup required"
            ISSUE_PRIORITIES[$issues_found]=1
        fi
    fi

    # Scenario 2: Missing from home but exists in persistent storage
    if [ "$home_ssh_exists" = false ] && [ "$usr_ssh_exists" = true ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="repair_create_ssh"
        ISSUE_DESCRIPTIONS[$issues_found]="SSH keys missing from /home/comma/.ssh/ but available in persistent storage"
        ISSUE_PRIORITIES[$issues_found]=1
    fi

    # Scenario 3: Missing from persistent but exists in home
    if [ "$home_ssh_exists" = true ] && [ "$usr_ssh_exists" = false ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="copy_ssh_config_and_keys"
        ISSUE_DESCRIPTIONS[$issues_found]="SSH keys not synchronized to persistent storage"
        ISSUE_PRIORITIES[$issues_found]=2
    fi

    # Permission checks (only if files exist)
    if [ "$home_ssh_exists" = true ]; then
        check_file_permissions_owner "/home/comma/.ssh/github" "-rw-------" "comma"
        local home_perm_check=$?
        if [ "$home_perm_check" -eq 1 ]; then
            issues_found=$((issues_found + 1))
            ISSUE_FIXES[$issues_found]="repair_create_ssh"
            ISSUE_DESCRIPTIONS[$issues_found]="SSH key permissions/ownership incorrect in home directory"
            ISSUE_PRIORITIES[$issues_found]=2
        fi
    fi

    if [ "$usr_ssh_exists" = true ]; then
        check_file_permissions_owner "/usr/default/home/comma/.ssh/github" "-rw-------" "comma"
        local usr_perm_check=$?
        if [ "$usr_perm_check" -eq 1 ]; then
            issues_found=$((issues_found + 1))
            ISSUE_FIXES[$issues_found]="repair_create_ssh"
            ISSUE_DESCRIPTIONS[$issues_found]="SSH key permissions/ownership incorrect in persistent storage"
            ISSUE_PRIORITIES[$issues_found]=2
        fi
    fi

    # Backup recommendations
    if [ "$home_ssh_exists" = true ] && [ "$backup_exists" = false ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="backup_ssh"
        ISSUE_DESCRIPTIONS[$issues_found]="No SSH backup found - Backup recommended"
        ISSUE_PRIORITIES[$issues_found]=3
    fi

    # Check for GitHub's host key in known_hosts
    # if [ -f "/home/comma/.ssh/known_hosts" ]; then
    #     if ! grep -q "ssh.github.com" "/home/comma/.ssh/known_hosts"; then
    #         issues_found=$((issues_found + 1))
    #         ISSUE_FIXES[$issues_found]="check_github_known_hosts"
    #         ISSUE_DESCRIPTIONS[$issues_found]="GitHub's host key not found in known_hosts"
    #         ISSUE_PRIORITIES[$issues_found]=2
    #     fi
    # else
    #     issues_found=$((issues_found + 1))
    #     ISSUE_FIXES[$issues_found]="check_github_known_hosts"
    #     ISSUE_DESCRIPTIONS[$issues_found]="SSH known_hosts file missing"
    #     ISSUE_PRIORITIES[$issues_found]=2
    # fi

    # Check backup age if it exists
    if [ "$backup_exists" = true ] && [ -f "/data/ssh_backup/metadata.txt" ]; then
        local backup_date
        backup_date=$(grep "Backup Date:" /data/ssh_backup/metadata.txt | cut -d: -f2- | xargs)
        if [ -n "$backup_date" ]; then
            local backup_age
            local backup_days
            backup_age=$(($(date +%s) - $(date -d "$backup_date" +%s)))
            backup_days=$((backup_age / 86400))
            if [ "$backup_days" -gt 30 ]; then
                issues_found=$((issues_found + 1))
                ISSUE_FIXES[$issues_found]="backup_ssh"
                ISSUE_DESCRIPTIONS[$issues_found]="SSH backup is $backup_days days old - Consider updating"
                ISSUE_PRIORITIES[$issues_found]=3
            fi
        fi
    fi
}

###############################################################################
# Device Control Functions
###############################################################################

manage_wifi_networks() {
    clear
    echo "+----------------------------------------------+"
    echo "|           WiFi Network Management            |"
    echo "+----------------------------------------------+"

    # Check if nmcli is available
    if ! command -v nmcli >/dev/null 2>&1; then
        print_error "Network Manager (nmcli) not found."
        pause_for_user
        return 1
    fi

    # Show current connection status
    echo "Current Connection:"
    nmcli -t -f DEVICE,CONNECTION dev status | grep wifi | while IFS=: read -r dev conn; do
        if [ "$conn" != "--" ]; then
            echo "Connected to: $conn"
        else
            echo "Not connected"
        fi
    done
    echo ""

    # Scan for networks
    print_info "Scanning for networks..."
    nmcli dev wifi rescan
    echo "Available Networks:"
    nmcli -f SSID,SIGNAL,SECURITY dev wifi list | sort -k2 -nr | head -n 10

    echo ""
    echo "Options:"
    echo "1. Connect to network"
    echo "2. Disconnect current network"
    echo "3. Enable WiFi"
    echo "4. Disable WiFi"
    echo "Q. Back to Device Controls"

    read -p "Enter your choice: " wifi_choice
    case $wifi_choice in
    1)
        read -p "Enter SSID to connect to: " ssid
        read -s -p "Enter password: " password
        echo ""
        nmcli dev wifi connect "$ssid" password "$password"
        ;;
    2)
        nmcli dev disconnect wlan0
        ;;
    3)
        nmcli radio wifi on
        ;;
    4)
        nmcli radio wifi off
        ;;
    [qQ])
        return
        ;;
    *)
        print_error "Invalid choice."
        ;;
    esac
    pause_for_user
}

restart_cellular_radio() {
    clear
    print_info "Restarting cellular radio..."

    # Check if ModemManager is available
    if ! command -v mmcli >/dev/null 2>&1; then
        print_error "ModemManager not found."
        pause_for_user
        return 1
    fi

    # Get modem index
    local modem_index
    modem_index=$(mmcli -L | grep -o '[0-9]*' | head -1)

    if [ -n "$modem_index" ]; then
        print_info "Disabling modem..."
        mmcli -m "$modem_index" -d
        sleep 2
        print_info "Enabling modem..."
        mmcli -m "$modem_index" -e
        print_success "Cellular radio restart completed."
    else
        print_error "No modem found."
    fi
    pause_for_user
}

manage_bluetooth() {
    clear
    echo "+----------------------------------------------+"
    echo "|           Bluetooth Management               |"
    echo "+----------------------------------------------+"

    # Check if bluetoothctl is available
    if ! command -v bluetoothctl >/dev/null 2>&1; then
        print_error "Bluetooth control (bluetoothctl) not found."
        pause_for_user
        return 1
    fi

    echo "Current Status:"
    bluetoothctl show | grep "Powered:"

    echo ""
    echo "Options:"
    echo "1. Turn Bluetooth On"
    echo "2. Turn Bluetooth Off"
    echo "3. Show Paired Devices"
    echo "4. Scan for Devices"
    echo "Q. Back to Device Controls"

    read -p "Enter your choice: " bt_choice
    case $bt_choice in
    1)
        bluetoothctl power on
        ;;
    2)
        bluetoothctl power off
        ;;
    3)
        bluetoothctl paired-devices
        ;;
    4)
        print_info "Scanning for devices (10 seconds)..."
        bluetoothctl scan on &
        sleep 10
        bluetoothctl scan off
        ;;
    [qQ])
        return
        ;;
    *)
        print_error "Invalid choice."
        ;;
    esac
    pause_for_user
}

device_controls_menu() {
    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "|           Device Controls                    |"
        echo "+----------------------------------------------+"
        echo "1. WiFi Network Management"
        echo "2. Restart Cellular Radio"
        echo "3. Bluetooth Management"
        echo "4. Turn Screen Off"
        echo "5. Turn Screen On"
        echo "Q. Back to Main Menu"

        read -p "Enter your choice: " control_choice
        case $control_choice in
        1) manage_wifi_networks ;;
        2) restart_cellular_radio ;;
        3) manage_bluetooth ;;
        4) turn_off_screen ;;
        5) turn_on_screen ;;
        [qQ]) break ;;
        *) print_error "Invalid choice." ;;
        esac
    done
}

###############################################################################
# System Statistics Functions
###############################################################################

get_cpu_stats() {
    # Get CPU usage and top process
    local cpu_usage
    local top_process

    # Get overall CPU usage from 'top' (first cpu line, second field)
    cpu_usage=$(top -bn1 | awk '/^%Cpu/{print $2}')

    # Get top process by CPU
    top_process=$(ps -eo cmd,%cpu --sort=-%cpu | head -2 | tail -1 | awk '{print $1 " (" $2 "%)"}')

    echo "CPU Usage: ${cpu_usage}% | Top: ${top_process}"
}

get_memory_stats() {
    # Get memory usage
    local total
    local used
    local percentage

    total=$(free -m | awk 'NR==2 {print $2}')
    used=$(free -m | awk 'NR==2 {print $3}')
    percentage=$(free | awk 'NR==2 {printf "%.1f", $3*100/$2}')

    echo "Memory: ${used}MB/${total}MB (${percentage}%)"
}

get_cellular_stats() {
    # Get cellular information using mmcli if ModemManager is available
    if command -v mmcli >/dev/null 2>&1; then
        local modem_index
        local carrier
        local signal
        local roaming
        local tech

        # Get the first modem index
        modem_index=$(mmcli -L | grep -o '[0-9]*' | head -1)

        if [ -n "$modem_index" ]; then
            # Get carrier name
            carrier=$(mmcli -m "$modem_index" | grep "operator name" | awk -F': ' '{print $2}')

            # Get signal strength
            signal=$(mmcli -m "$modem_index" | grep "signal quality" | awk -F': ' '{print $2}' | awk '{print $1}')

            # Get network tech
            tech=$(mmcli -m "$modem_index" | grep "access tech" | awk -F': ' '{print $2}')

            # Get roaming status
            roaming=$(mmcli -m "$modem_index" | grep "state" | grep -i "roaming" >/dev/null && echo "Roaming" || echo "Home")

            echo "${carrier:-Unknown} | ${tech:-Unknown} | Signal: ${signal:-0}% | ${roaming}"
        else
            echo "No modem detected"
        fi
    else
        echo "ModemManager not available"
    fi
}

system_statistics_menu() {
    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "|           System Statistics                  |"
        echo "+----------------------------------------------+"

        echo "CPU Usage:"
        echo "├─ $(get_cpu_stats)"
        echo "├─ Top Processes by CPU:"
        ps -eo cmd,%cpu --sort=-%cpu | head -4 | tail -3 |
            awk '{printf "│  %-40s %5.1f%%\n", substr($1,1,40), $NF}'
        echo ""

        echo "Memory Usage:"
        echo "├─ $(get_memory_stats)"
        echo "├─ Memory Details:"
        free -h | awk 'NR==2{printf "│  %-8s %8s %8s %8s %8s\n", "", "total", "used", "free", "cache"}'
        free -h | awk 'NR==2{printf "│  %-8s %8s %8s %8s %8s\n", "Mem:", $2, $3, $4, $6}'
        free -h | awk 'NR==3{printf "│  %-8s %8s %8s %8s\n", "Swap:", $2, $3, $4}'
        echo ""

        echo "Cellular Connection:"
        echo "├─ $(get_cellular_stats)"
        if command -v mmcli >/dev/null 2>&1; then
            local modem_index
            modem_index=$(mmcli -L | grep -o '[0-9]*' | head -1)
            if [ -n "$modem_index" ]; then
                echo "├─ Additional Details:"
                mmcli -m "$modem_index" | grep -E "operator name|signal quality|state|access tech|power state|packet service state" |
                    sed 's/^/│  /' | sed 's/|//'
            fi
        fi
        echo ""

        echo "Disk Usage:"
        echo "├─ Filesystem Details:"
        df -h | grep -E '^/dev|Filesystem' |
            awk '{printf "│  %-15s %8s %8s %8s %8s\n", substr($1,length($1)>15?length($1)-15:0), $2, $3, $4, $5}'
        echo ""

        echo "+----------------------------------------------+"
        echo "R. Refresh Statistics"
        echo "Q. Back to Main Menu"

        read -t 30 -p "Enter your choice (auto-refresh in 30s): " stats_choice

        case $stats_choice in
        [rR]) continue ;;
        [qQ]) break ;;
        "") continue ;; # Timeout occurred, refresh
        *) print_error "Invalid choice." ;;
        esac
    done
}

###############################################################################
# Main Menu & Argument Handling
###############################################################################

display_main_menu() {
    clear
    echo "+----------------------------------------------+"
    echo "|       CommaUtilityLegacy Script v$SCRIPT_VERSION"
    echo "|       (Last Modified: $SCRIPT_MODIFIED)"
    echo "+----------------------------------------------+"

    # Display System Status
    # echo "| System Status:"
    display_os_info_short
    display_git_status_short
    display_disk_space_short
    display_ssh_status_short

    # Detect and categorize issues
    detect_issues

    # Display Critical Issues
    local critical_found=false
    for i in "${!ISSUE_PRIORITIES[@]}"; do
        if [ "${ISSUE_PRIORITIES[$i]}" -eq 1 ]; then
            if [ "$critical_found" = false ]; then
                echo "|----------------------------------------------|"
                echo -e "| ${RED}Critical Issues:${NC}"
                critical_found=true
            fi
            echo -e "| ❌ ${ISSUE_DESCRIPTIONS[$i]}"
        fi
    done

    # Display Warnings
    local warnings_found=false
    for i in "${!ISSUE_PRIORITIES[@]}"; do
        if [ "${ISSUE_PRIORITIES[$i]}" -eq 2 ]; then
            if [ "$warnings_found" = false ]; then
                echo "|----------------------------------------------|"
                echo -e "| ${YELLOW}Warnings:${NC}"
                warnings_found=true
            fi
            echo -e "| ⚠️  ${ISSUE_DESCRIPTIONS[$i]}"
        fi
    done

    # Display Recommendations
    local recommendations_found=false
    for i in "${!ISSUE_PRIORITIES[@]}"; do
        if [ "${ISSUE_PRIORITIES[$i]}" -eq 3 ]; then
            if [ "$recommendations_found" = false ]; then
                echo "|----------------------------------------------|"
                echo -e "| ${BLUE}Recommendations:${NC}"
                recommendations_found=true
            fi
            echo -e "| → ${ISSUE_DESCRIPTIONS[$i]}"
        fi
    done

    # Close with a consistent bottom divider
    echo "+----------------------------------------------+"

    # Display Main Menu Options
    echo -e "\n${GREEN}Available Actions:${NC}"
    echo "1. SSH Setup"
    echo "2. Repository & Build Tools"
    echo "3. View Logs"
    echo "4. View Recent Error"
    echo "5. System Statistics"
    echo "6. Device Controls"
    echo "7. Modify Boot Icon/Logo"

    # Dynamic fix options
    local fix_number=8 # Start from 6 because we already have 5 options
    for i in "${!ISSUE_FIXES[@]}"; do
        local color=""
        case "${ISSUE_PRIORITIES[$i]}" in
        1) color="$RED" ;;
        2) color="$YELLOW" ;;
        3) color="$BLUE" ;;
        *) color="$NC" ;;
        esac
        echo -e "${fix_number}. ${color}Fix: ${ISSUE_DESCRIPTIONS[$i]}${NC}"
        fix_number=$((fix_number + 1))
    done

    echo "R. Reboot Device"
    echo "S. Shutdown Device"
    echo "U. Update Script"
    echo "Q. Exit"
}

handle_main_menu_input() {
    read -p "Enter your choice: " main_choice
    case $main_choice in
    1) ssh_menu ;;
    2) repo_build_and_management_menu ;;
    3) display_logs ;;
    4) view_error_log ;;
    5) system_statistics_menu ;;
    6) device_controls_menu ;;
    7) toggle_boot_logo ;;
    [8-10] | [1-10][0-10])
        # Calculate array index by adjusting for the 4 standard menu items
        local fix_index=$((main_choice - 7))
        if [ -n "${ISSUE_FIXES[$fix_index]}" ]; then
            ${ISSUE_FIXES[$fix_index]}
        else
            print_error "Invalid option"
        fi
        ;;
    [uU]) update_script ;;
    [rR]) reboot_device ;;
    [sS]) shutdown_device ;;
    [qQ])
        print_info "Exiting..."
        exit 0
        ;;
    *)
        print_error "Invalid choice."
        # pause_for_user
        ;;
    esac
}

###############################################################################
# Parse Command Line Arguments
###############################################################################

# Parse Command Line Arguments
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --import-ssh)
            SCRIPT_ACTION="import-ssh"
            shift
            ;;
        --private-key-file)
            PRIVATE_KEY_FILE="$2"
            shift 2
            ;;
        --public-key-file)
            PUBLIC_KEY_FILE="$2"
            shift 2
            ;;
        # Build operations
        --build-dev)
            SCRIPT_ACTION="build-dev"
            shift
            ;;
        --build-public)
            SCRIPT_ACTION="build-public"
            shift
            ;;
        --custom-build)
            SCRIPT_ACTION="custom-build"
            shift
            ;;
        --repo)
            REPO="$2"
            shift 2
            ;;
        --clone-branch)
            CLONE_BRANCH="$2"
            shift 2
            ;;
        --build-branch)
            BUILD_BRANCH="$2"
            shift 2
            ;;
        # Clone operations
        --clone-public-bp)
            SCRIPT_ACTION="clone-public-bp"
            shift
            ;;
        --clone-internal-dev-build)
            SCRIPT_ACTION="clone-internal-dev-build"
            shift
            ;;
        --clone-internal-dev)
            SCRIPT_ACTION="clone-internal-dev"
            shift
            ;;
        --custom-clone)
            SCRIPT_ACTION="custom-clone"
            shift
            ;;
        # System operations
        --update)
            SCRIPT_ACTION="update"
            shift
            ;;
        --reboot)
            SCRIPT_ACTION="reboot"
            shift
            ;;
        --shutdown)
            SCRIPT_ACTION="shutdown"
            shift
            ;;
        --view-logs)
            SCRIPT_ACTION="view-logs"
            shift
            ;;
        # SSH operations
        --test-ssh)
            SCRIPT_ACTION="test-ssh"
            shift
            ;;
        --backup-ssh)
            SCRIPT_ACTION="backup-ssh"
            shift
            ;;
        --restore-ssh)
            SCRIPT_ACTION="restore-ssh"
            shift
            ;;
        --reset-ssh)
            SCRIPT_ACTION="reset-ssh"
            shift
            ;;
        # Git operations
        --git-pull)
            SCRIPT_ACTION="git-pull"
            shift
            ;;
        --git-status)
            SCRIPT_ACTION="git-status"
            shift
            ;;
        --git-branch)
            SCRIPT_ACTION="git-branch"
            NEW_BRANCH="$2"
            shift 2
            ;;
        -h | --help)
            show_help
            exit 0
            ;;
        --no-update)
            SKIP_UPDATE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        esac
    done
}

# Only parse arguments if any were provided
if [ $# -gt 0 ]; then
    parse_arguments "$@"
fi

main() {
    if [ -z "$SCRIPT_ACTION" ] && [ "$SKIP_UPDATE" != "true" ]; then
        check_for_updates
    fi

    while true; do
        if [ -z "$SCRIPT_ACTION" ]; then
            # No arguments or no action set by arguments: show main menu
            check_prerequisites
            display_main_menu
            handle_main_menu_input
        else
            # SCRIPT_ACTION is set from arguments, run corresponding logic
            case "$SCRIPT_ACTION" in
            build-public)
                build_repo_branch "bp-public-experimental" "staging-DONOTUSE" "bluepilot experimental" "$GIT_BP_PRIVATE_REPO" "$GIT_BP_PUBLIC_REPO"
                ;;
            build-dev)
                build_repo_branch "bp-internal-dev" "bp-internal-dev-build" "bluepilot internal dev" "$GIT_BP_PRIVATE_REPO"
                ;;
            clone-public-bp)
                clone_public_bluepilot
                ;;
            clone-internal-dev-build)
                clone_internal_dev_build
                ;;
            clone-internal-dev)
                clone_internal_dev
                ;;
            custom-clone)
                if [ -z "$REPO" ] || [ -z "$CLONE_BRANCH" ]; then
                    print_error "Error: --custom-clone requires --repo and --clone-branch parameters."
                    show_help
                    exit 1
                fi
                case "$REPO" in
                bluepilotdev) GIT_REPO_URL="$GIT_BP_PUBLIC_REPO" ;;
                sp-dev-c3) GIT_REPO_URL="$GIT_BP_PRIVATE_REPO" ;;
                sunnypilot) GIT_REPO_URL="$GIT_SP_REPO" ;;
                commaai) GIT_REPO_URL="$GIT_COMMA_REPO" ;;
                *)
                    print_error "[-] Unknown repository: $REPO"
                    exit 1
                    ;;
                esac
                clone_repo_bp "repository '$REPO' with branch '$CLONE_BRANCH'" "$GIT_REPO_URL" "$CLONE_BRANCH" "no" "yes"
                if [ ! -f "/data/openpilot/prebuilt" ]; then
                    print_warning "[-] No prebuilt marker found. Might need to compile."
                    read -p "Compile now? (y/N): " compile_confirm
                    if [[ "$compile_confirm" =~ ^[Yy]$ ]]; then
                        print_info "[-] Running scons..."
                        cd "/data/openpilot" || exit 1
                        scons -j"$(nproc)" || {
                            print_error "[-] SCons failed."
                            exit 1
                        }
                        print_success "[-] Compilation completed."
                    fi
                fi
                reboot_device_bp
                ;;
            custom-build)
                if [ -z "$REPO" ] || [ -z "$CLONE_BRANCH" ] || [ -z "$BUILD_BRANCH" ]; then
                    print_error "Error: --custom-build requires --repo, --clone-branch, and --build-branch."
                    show_help
                    exit 1
                fi
                case "$REPO" in
                bluepilotdev) GIT_REPO_URL="$GIT_BP_PUBLIC_REPO" ;;
                sp-dev-c3) GIT_REPO_URL="$GIT_BP_PRIVATE_REPO" ;;
                sunnypilot) GIT_REPO_URL="$GIT_SP_REPO" ;;
                commaai) GIT_REPO_URL="$GIT_COMMA_REPO" ;;
                *)
                    print_error "[-] Unknown repository: $REPO"
                    exit 1
                    ;;
                esac
                local COMMIT_DESC_HEADER="Custom Build"
                build_repo_branch "$CLONE_BRANCH" "$BUILD_BRANCH" "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN"
                print_success "[-] Action completed successfully"
                ;;
            update) update_script ;;
            reboot) reboot_device ;;
            shutdown) shutdown_device ;;
            view-logs) display_logs ;;
            test-ssh) test_ssh_connection ;;
            backup-ssh) backup_ssh ;;
            restore-ssh) restore_ssh ;;
            reset-ssh) reset_ssh ;;
            import-ssh) import_ssh_keys $PRIVATE_KEY_FILE $PUBLIC_KEY_FILE ;;
            git-pull) fetch_pull_latest_changes ;;
            git-status) display_git_status ;;
            git-branch)
                if [ -n "$NEW_BRANCH" ]; then
                    cd /data/openpilot && git checkout "$NEW_BRANCH"
                else
                    print_error "Error: Branch name required"
                    exit 1
                fi
                ;;
            *)
                print_error "Invalid build type. Exiting."
                exit 1
                ;;
            esac
            exit 0
        fi
    done
}

# Start the script
main
