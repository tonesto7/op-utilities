#!/bin/bash

###############################################################################
# CommaUtility Script
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
readonly SCRIPT_VERSION="2.1.0"
readonly SCRIPT_MODIFIED="2025-01-13"

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
readonly GIT_SP_REPO="git@github.com:sunnypilot/sunnypilot.git"

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
            print_success "SSH files restored successfully."
        else
            print_info "Restore cancelled."
        fi
    else
        print_warning "No valid SSH backup found to restore."
    fi
    pause_for_user
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

    local submodule_cmd="git submodule update --init --recursive"
    execute_with_network_retry "$submodule_cmd" "Failed to update submodules"
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
display_mini_ssh_status() {

    if [ -f "/home/comma/.ssh/github" ]; then
        echo "| SSH Key: Found"
        if [ -f "/data/ssh_backup/metadata.txt" ]; then
            local last_backup
            last_backup=$(grep "Backup Date:" /data/ssh_backup/metadata.txt | cut -d: -f2- | xargs)
            echo "| SSH Backup: Last Backup $last_backup"
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

    # Use timeout to prevent hanging
    if ! result=$(timeout 10 ssh -T git@github.com 2>&1); then
        connection_status=$?
        if [ $connection_status -eq 124 ]; then
            print_error "SSH connection test timed out"
            pause_for_user
            return 1
        fi
    fi

    if echo "$result" | grep -q "You've successfully authenticated"; then
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
    backup_ssh
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

###############################################################################
# Next Chunk of Code (Continuing the Script)
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
    local data_usage_root
    local data_usage_data
    data_usage_root=$(df -h / | awk 'NR==2 {printf "Used: %s/%s (%s)", $3, $2, $5}')
    data_usage_data=$(df -h /data | awk 'NR==2 {printf "Used: %s/%s (%s)", $3, $2, $5}')
    echo "| Disk Space (/): $data_usage_root"
    echo "| Disk Space (/data): $data_usage_data"
}

display_git_status_short() {
    if [ -d "/data/openpilot" ]; then
        (
            cd "/data/openpilot" || return
            local branch_name
            branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
            echo "| Git Branch: $branch_name"
        )
    else
        echo "| Git Branch: Missing"
    fi
}

display_git_status() {
    echo "+----------------------------------------------+"
    echo "|       Openpilot Repository                   |"
    echo "+----------------------------------------------+"
    if [ -d "/data/openpilot" ]; then
        (
            cd "/data/openpilot" || exit 1
            local branch_name
            local repo_url
            branch_name=$(git rev-parse --abbrev-ref HEAD)
            repo_url=$(git config --get remote.origin.url)
            echo "- Openpilot directory: ✅"
            echo "- Current branch: $branch_name"
            echo "- Repository URL: $repo_url"
        )
    else
        echo "- Openpilot directory: ❌"
    fi
    echo "+----------------------------------------------+"
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

    # Verify that the openpilot directory exists.
    if [ ! -d "/data/openpilot" ]; then
        print_warning "No openpilot directory found."
        return 1
    fi
    cd "/data/openpilot" || return 1

    # Check if working directory is clean
    if ! check_working_directory; then
        print_error "Please commit or stash changes before switching branches."
        return 1
    fi

    # Fetch latest branch info
    if ! git_operation_with_timeout "git fetch" 60; then
        print_error "Failed to fetch latest branch information."
        return 1
    fi

    # Get repository URL
    local repo_url
    repo_url=$(git config --get remote.origin.url)
    if [ -z "$repo_url" ]; then
        print_error "Repository URL not found."
        return 1
    fi

    # Invoke the reusable branch selection menu
    if ! select_branch_menu "$repo_url"; then
        return 1
    fi

    clear
    print_info "Changing the branch of the repository..."

    # Reset any local changes and update submodules
    print_info "Cleaning repository and submodules..."

    # Reset the main repository
    if ! git_operation_with_timeout "git reset --hard HEAD" 30; then
        print_error "Failed to reset repository"
        return 1
    fi

    # Clean untracked files and directories
    if ! git_operation_with_timeout "git clean -fd" 30; then
        print_error "Failed to clean repository"
        return 1
    fi

    # Attempt to checkout the selected branch
    if ! git_operation_with_timeout "git checkout $SELECTED_BRANCH" 30; then
        print_error "Failed to checkout branch: $SELECTED_BRANCH"
        return 1
    fi

    # Reset and clean submodules
    print_info "Updating submodules..."

    # Initialize and update submodules
    if ! git_operation_with_timeout "git submodule update --init --recursive" 300; then
        print_error "Failed to initialize submodules"
        return 1
    fi

    # Reset and clean each submodule
    if ! git_operation_with_timeout "git submodule foreach --recursive 'git reset --hard HEAD && git clean -fd'" 300; then
        print_error "Failed to reset submodules"
        return 1
    fi

    print_success "Successfully switched to branch: $SELECTED_BRANCH"
    print_success "All submodules have been updated and cleaned"
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
            if ! git_operation_with_timeout "git submodule update --init --recursive" 300; then
                print_error "Failed to update submodules"
                return 1
            fi
        )
    else
        if ! git_operation_with_timeout "git clone -b $branch_name git@github.com:$github_repo openpilot" 300; then
            print_error "Failed to clone repository"
            return 1
        fi
        (
            cd openpilot || return
            if ! git_operation_with_timeout "git submodule update --init --recursive" 300; then
                print_error "Failed to update submodules"
                return 1
            fi
        )
    fi
    pause_for_user
}

reset_openpilot_repo() {
    print_info "Removing the Openpilot repository..."
    cd /data || return
    rm -rf openpilot
    clone_openpilot_repo "true"
}

###############################################################################
# System Status & Logs
###############################################################################

display_general_status_short() {
    local agnos_version
    agnos_version=$(cat /VERSION 2>/dev/null)
    if [ -n "$agnos_version" ]; then
        echo "| AGNOS: v$agnos_version"
    else
        echo "| AGNOS: Unknown"
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
    script_path=$(get_absolute_path "$SCRIPT_DIR/CommaUtility.sh")
    cp "$script_path" "$script_path.backup"

    local download_cmd="wget -O '$script_path.tmp' https://raw.githubusercontent.com/tonesto7/op-utilities/main/CommaUtility.sh"
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
        if latest_version=$(wget --timeout=10 -qO- https://raw.githubusercontent.com/tonesto7/op-utilities/main/CommaUtility.sh | grep "SCRIPT_VERSION=" | head -n 1 | cut -d'"' -f2); then
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
CommaUtility Script (V$SCRIPT_VERSION) - Last Modified: $SCRIPT_MODIFIED
------------------------------------------------------------

Usage: ./CommaUtility.sh [OPTIONS]

Build Options:
  --build-dev                       Build BP Internal Dev
  --build-public                    Build BP Public Experimental
  --custom-build                    Perform a custom build
    --repo <repository_name>        Select repository (bluepilotdev or sp-dev-c3)
    --clone-branch <branch_name>    Branch to clone from the selected repository
    --build-branch <branch_name>    Branch name for the build

Clone Options:
  --clone-public-bp                 Clone BP staging-DONOTUSE Repo
  --clone-internal-dev-build        Clone bp-internal-dev-build
  --clone-internal-dev              Clone bp-internal-dev
  --custom-clone                    Perform a custom clone
    --repo <repository_name>        Select repository (bluepilotdev, sp-dev-c3, or sunnypilot)
    --clone-branch <branch_name>    Branch to clone from the selected repository

System Operations:
  --update                          Update this script to the latest version
  --reboot                          Reboot the device
  --shutdown                        Shutdown the device
  --view-logs                       View system logs

SSH Operations:
  --test-ssh                        Test SSH connection to GitHub
  --backup-ssh                      Backup SSH files
  --restore-ssh                     Restore SSH files from backup
  --reset-ssh                       Reset SSH configuration

Git Operations:
  --git-pull                        Fetch and pull latest changes
  --git-status                      Show Git repository status
  --git-branch <branch_name>        Switch to specified branch

General:
  -h, --help                        Show this help message and exit

Examples:
  # Build operations
  ./CommaUtility.sh --build-dev
  ./CommaUtility.sh --build-public
  ./CommaUtility.sh --custom-build --repo bluepilotdev --clone-branch feature --build-branch build-feature

  # Clone operations
  ./CommaUtility.sh --custom-clone --repo sp-dev-c3 --clone-branch experimental

  # System operations
  ./CommaUtility.sh --update
  ./CommaUtility.sh --reboot

  # SSH operations
  ./CommaUtility.sh --test-ssh
  ./CommaUtility.sh --backup-ssh

  # Git operations
  ./CommaUtility.sh --git-pull
  ./CommaUtility.sh --git-branch my-branch
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

process_submodules() {
    local MOD_DIR="$1"
    local SUBMODULES=("msgq_repo" "opendbc" "rednose_repo" "panda" "tinygrad_repo" "teleoprtc_repo")

    for SUBMODULE in "${SUBMODULES[@]}"; do
        mkdir -p "${MOD_DIR}/${SUBMODULE}_tmp"
        cp -r "${MOD_DIR}/$SUBMODULE/." "${MOD_DIR}/${SUBMODULE}_tmp" || :
        git submodule deinit -f "$SUBMODULE" 2>/dev/null
        git rm -rf --cached "$SUBMODULE" 2>/dev/null
        rm -rf "${MOD_DIR}/$SUBMODULE"
        mv "${MOD_DIR}/${SUBMODULE}_tmp" "${MOD_DIR}/$SUBMODULE"
        rm -rf "${MOD_DIR}/.git/modules/$SUBMODULE"
        git add -f "$SUBMODULE" 2>/dev/null
    done
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
    git add -A >/dev/null 2>&1
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
    if git ls-remote --heads "$ORIGIN_REPO" "$BUILD_BRANCH" | grep "$BUILD_BRANCH" >/dev/null 2>&1; then
        git push "$ORIGIN_REPO" --delete "$BUILD_BRANCH" || exit 1
    fi

    git branch -m "$BUILD_BRANCH" >/dev/null 2>&1 || exit 1
    git push -f "$ORIGIN_REPO" "$BUILD_BRANCH" || exit 1
}

build_cross_repo_branch() {
    local CLONE_BRANCH="$1"
    local BUILD_BRANCH="$2"
    local COMMIT_DESC_HEADER="$3"
    local GIT_REPO_ORIGIN="$4"
    local GIT_PUBLIC_REPO_ORIGIN="$5"

    local CURRENT_DIR
    CURRENT_DIR=$(pwd)

    rm -rf "$BUILD_DIR" "$TMP_DIR"
    git clone --single-branch --branch "$BUILD_BRANCH" "$GIT_PUBLIC_REPO_ORIGIN" "$BUILD_DIR"
    cd "$BUILD_DIR" || exit 1
    find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
    git clone --depth 1 "$GIT_REPO_ORIGIN" -b "$CLONE_BRANCH" "$TMP_DIR"
    cd "$TMP_DIR" || exit 1
    git submodule update --init --recursive
    process_submodules "$TMP_DIR"
    cd "$BUILD_DIR" || exit 1
    rsync -a --exclude='.git' "$TMP_DIR/" "$BUILD_DIR/"
    rm -rf "$TMP_DIR"
    setup_git_env_bp
    build_openpilot_bp
    handle_panda_directory
    create_opendbc_gitignore
    update_main_gitignore
    cleanup_files
    create_prebuilt_marker
    prepare_commit_push "$COMMIT_DESC_HEADER" "$GIT_PUBLIC_REPO_ORIGIN" "$BUILD_BRANCH"
    cd "$CURRENT_DIR" || exit 1
}

build_repo_branch() {
    local CLONE_BRANCH="$1"
    local BUILD_BRANCH="$2"
    local COMMIT_DESC_HEADER="$3"
    local GIT_REPO_ORIGIN="$4"

    # Check available disk space first
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
    if ! git_operation_with_timeout "git submodule update --init --recursive" 300; then
        print_error "Failed to update submodules"
        return 1
    fi

    setup_git_env_bp
    build_openpilot_bp
    handle_panda_directory
    process_submodules "$BUILD_DIR"
    create_opendbc_gitignore
    update_main_gitignore
    cleanup_files
    create_prebuilt_marker
    prepare_commit_push "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN" "$BUILD_BRANCH"
    cd "$CURRENT_DIR" || exit 1
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
    git submodule update --init --recursive

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

    print_info "Selected branch: $CLONE_BRANCH"
    print_info "Build branch will be: $BUILD_BRANCH"
    return 0
}

clone_custom_repo() {
    if ! choose_repository_and_branch "clone"; then
        return
    fi

    case "$REPO" in
    bluepilotdev)
        GIT_REPO_URL="$GIT_BP_PUBLIC_REPO"
        ;;
    sp-dev-c3)
        GIT_REPO_URL="$GIT_BP_PRIVATE_REPO"
        ;;
    sunnypilot)
        GIT_REPO_URL="$GIT_SP_REPO"
        ;;
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
    else
        print_error "Invalid repository selected"
        return
    fi

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
        echo "2. Copy SSH config and keys"
        echo "3. Reset SSH setup"
        echo "4. Test SSH connection"
        echo "5. View SSH key"
        echo "6. Change Github SSH port to 443"
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
        2) copy_ssh_config_and_keys ;;
        3) reset_ssh ;;
        4) test_ssh_connection ;;
        5) view_ssh_key ;;
        6) change_github_ssh_port ;;
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
        *) print_error "Invalid choice." && pause_for_user ;;
        esac
    done
}

git_menu() {
    while true; do
        clear
        display_git_status
        echo "1. Fetch and pull latest changes"
        echo "2. Change branch"
        echo "3. Clone branch by Name"
        echo "4. Reset/Change Openpilot Repository"
        echo "5. List available branches"
        echo "Q. Back to Main Menu"
        read -p "Enter your choice: " choice
        case $choice in
        1) fetch_pull_latest_changes ;;
        2) change_branch ;;
        3) clone_openpilot_repo "true" ;;
        4) reset_openpilot_repo ;;
        5) list_git_branches ;;
        [qQ]) break ;;
        *) print_error "Invalid choice." && pause_for_user ;;
        esac
    done
}

bluepilot_menu() {
    while true; do
        clear
        echo "****************************************"
        echo "BluePilot Utilities"
        echo "****************************************"
        echo "1) Build BP Internal Dev"
        echo "2) Build BP Public Experimental"
        echo "3) Build Any Branch"
        echo "4) Clone BP staging-DONOTUSE Repo"
        echo "5) Clone bp-internal-dev-build"
        echo "6) Clone bp-internal-dev"
        echo "7) Clone Any Branch"
        echo "Q) Back to Main Menu"
        read -p "Enter your choice: " choice
        case $choice in
        1)
            build_repo_branch "bp-internal-dev" "bp-internal-dev-build" "bluepilot internal dev" "$GIT_BP_PRIVATE_REPO"
            pause_for_user
            ;;
        2)
            build_cross_repo_branch "bp-public-experimental" "staging-DONOTUSE" "bluepilot experimental" "$GIT_BP_PRIVATE_REPO" "$GIT_BP_PUBLIC_REPO"
            pause_for_user
            ;;
        3)
            custom_build_process
            pause_for_user
            ;;
        4)
            clone_public_bluepilot
            pause_for_user
            ;;
        5)
            clone_internal_dev_build
            pause_for_user
            ;;
        6)
            clone_internal_dev
            pause_for_user
            ;;
        7)
            clone_custom_repo
            pause_for_user
            ;;
        [qQ]) break ;;
        *) print_error "Invalid choice." && pause_for_user ;;
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
# Main Menu & Argument Handling
###############################################################################

display_main_menu() {
    clear
    echo "+----------------------------------------------+"
    echo "|       CommaUtility Script v$SCRIPT_VERSION"
    echo "|       (Last Modified: $SCRIPT_MODIFIED)"
    echo "+----------------------------------------------+"

    # Display System Status
    echo "| System Status:"
    display_general_status_short
    display_disk_space_short
    display_mini_ssh_status

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
    echo "2. Openpilot Folder Tools"
    echo "3. BluePilot Utilities"
    echo "4. View Logs"
    echo "5. View Recent Error"
    echo "6. Reboot Device"
    echo "7. Shutdown Device"

    # Dynamic fix options
    local fix_number=8
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

    echo "U. Update Script"
    echo "Q. Exit"
}

handle_main_menu_input() {
    read -p "Enter your choice: " main_choice
    case $main_choice in
    1) ssh_menu ;;
    2) git_menu ;;
    3) bluepilot_menu ;;
    4) display_logs ;;
    5) view_error_log ;;
    6) reboot_device ;;
    7) shutdown_device ;;
    [8-9] | [1-9][0-9])
        # Adjusting the fix index: option 8 corresponds to index 1
        local fix_index=$((main_choice - 7))
        if [ -n "${ISSUE_FIXES[$fix_index]}" ]; then
            ${ISSUE_FIXES[$fix_index]}
        else
            print_error "Invalid option"
        fi
        ;;
    [uU]) update_script ;;
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

main() {
    if [ -z "$SCRIPT_ACTION" ]; then
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
                build_cross_repo_branch "bp-public-experimental" "staging-DONOTUSE" "bluepilot experimental" "$GIT_BP_PRIVATE_REPO" "$GIT_BP_PUBLIC_REPO"
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
                        cd /data/openpilot
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
                if [ "$REPO" = "bluepilotdev" ]; then
                    GIT_REPO_ORIGIN="$GIT_BP_PUBLIC_REPO"
                elif [ "$REPO" = "sp-dev-c3" ]; then
                    GIT_REPO_ORIGIN="$GIT_BP_PRIVATE_REPO"
                else
                    print_error "Invalid repository selected"
                    exit 1
                fi
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
