#!/bin/bash

###############################################################################
# Global Variables (from both scripts)
###############################################################################
SCRIPT_VERSION="2.0.1"
SCRIPT_MODIFIED="2024-12-10"

ssh_status=()

# Variables from build_bluepilot script
SCRIPT_ACTION=""
REPO=""
CLONE_BRANCH=""
BUILD_BRANCH=""

OS=$(uname)
GIT_BP_PUBLIC_REPO="git@github.com:BluePilotDev/bluepilot.git"
GIT_BP_PRIVATE_REPO="git@github.com:ford-op/sp-dev-c3.git"
GIT_SP_REPO="git@github.com:sunnypilot/sunnypilot.git"

if [ "$OS" = "Darwin" ]; then
    BUILD_DIR="$HOME/Documents/bluepilot-utility/bp-build"
else
    BUILD_DIR="/data/openpilot"
    SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
fi

TMP_DIR="${BUILD_DIR}-build-tmp"

###############################################################################
# SSH Status Functions
###############################################################################

# Displays a condensed single-line SSH status for the main menu
# Shows if SSH exists and if any repairs are needed
display_ssh_status_short() {
    # Shortened SSH status for main menu
    expected_owner="comma"
    expected_permissions="-rw-------"

    ssh_exists=false
    ssh_fix_needed=false

    if [ -f /home/comma/.ssh/github ]; then
        ssh_exists=true
        actual_permissions=$(stat -c "%A" /home/comma/.ssh/github 2>/dev/null)
        actual_owner=$(stat -c "%U" /home/comma/.ssh/github 2>/dev/null)
        actual_group=$(stat -c "%G" /home/comma/.ssh/github 2>/dev/null)

        if [ "$actual_permissions" != "$expected_permissions" ]; then
            ssh_fix_needed=true
        fi
        if [ "$actual_owner" != "comma" ] || [ "$actual_group" != "comma" ]; then
            ssh_fix_needed=true
        fi
    fi

    # Show a single line summary
    if $ssh_exists; then
        if $ssh_fix_needed; then
            echo "| SSH Status: ❌ Exists (Needs Repair)"
        else
            echo "| SSH Status: ✅"
        fi
    else
        echo "| SSH Status: ❌ (Missing)"
    fi
}

# Displays detailed SSH status information including:
# - SSH key presence in ~/.ssh/ and /usr/default/home/comma/.ssh/
# - File permissions and ownership
# - Backup status and metadata
display_ssh_status() {
    echo "+----------------------------------------------+"
    echo "|          SSH Status                          |"
    echo "+----------------------------------------------+"

    # Define the expected owner and permissions
    expected_owner="comma"
    expected_permissions="-rw-------"
    ssh_status=()

    # Check for SSH key in ~/.ssh/
    if [ -f /home/comma/.ssh/github ]; then
        actual_permissions=$(ls -l /home/comma/.ssh/github | awk '{ print $1 }')
        actual_owner=$(ls -l /home/comma/.ssh/github | awk '{ print $3 }')
        actual_group=$(ls -l /home/comma/.ssh/github | awk '{ print $4 }')

        echo "- SSH key in ~/.ssh/: ✅"
        ssh_status+=("exists")

        # Check permissions
        if [ "$actual_permissions" == "$expected_permissions" ]; then
            echo "- Permissions: ✅ ($actual_permissions)"
        else
            echo "- Permissions: ❌ (Expected: $expected_permissions, Actual: $actual_permissions)"
            ssh_status+=("fix_permissions")
        fi

        # Check owner
        if [ "$actual_owner" == "$expected_owner" ] && [ "$actual_group" == "$expected_owner" ]; then
            echo "- Owner: ✅ ($actual_owner:$actual_group)"
        else
            echo "- Owner: ❌ (Expected: $expected_owner:$expected_owner, Actual: $actual_owner:$actual_group)"
            ssh_status+=("fix_owner")
        fi
    else
        echo "- SSH key in ~/.ssh/: ❌"
        ssh_status+=("missing")
    fi

    # Check for SSH key in /usr/default/home/comma/.ssh/
    if [ -f /usr/default/home/comma/.ssh/github ]; then
        actual_permissions=$(ls -l /usr/default/home/comma/.ssh/github | awk '{ print $1 }')
        actual_owner=$(ls -l /usr/default/home/comma/.ssh/github | awk '{ print $3 }')
        actual_group=$(ls -l /usr/default/home/comma/.ssh/github | awk '{ print $4 }')

        echo "- SSH key in /usr/default/home/comma/.ssh/: ✅"

        # Check permissions
        if [ "$actual_permissions" == "$expected_permissions" ]; then
            echo "- Permissions: ✅ ($actual_permissions)"
        else
            echo "- Permissions: ❌ (Expected: $expected_permissions, Actual: $actual_permissions)"
            ssh_status+=("fix_permissions_usr")
        fi

        # Check owner
        if [ "$actual_owner" == "$expected_owner" ] && [ "$actual_group" == "$expected_owner" ]; then
            echo "- Owner: ✅ ($actual_owner:$actual_group)"
        else
            echo "- Owner: ❌ (Expected: $expected_owner:$expected_owner, Actual: $actual_owner:$actual_group)"
            ssh_status+=("fix_owner_usr")
        fi
    else
        echo "- SSH key in /usr/default/home/comma/.ssh/: ❌"
        ssh_status+=("missing_usr")
    fi

    # Check SSH backup status (no fingerprint displayed)
    if [ -f "/data/ssh_backup/github" ] && [ -f "/data/ssh_backup/github.pub" ] && [ -f "/data/ssh_backup/config" ]; then
        echo "- SSH Backup Status: ✅"
        if [ -f "/data/ssh_backup/metadata.txt" ]; then
            backup_date=$(grep "Backup Date:" /data/ssh_backup/metadata.txt | cut -d: -f2- | xargs)
            echo "  └─ Last Backup: $backup_date"
            if [ -f "/home/comma/.ssh/github" ]; then
                if diff -q "/home/comma/.ssh/github" "/data/ssh_backup/github" >/dev/null; then
                    echo "  └─ Backup is current with active SSH files"
                else
                    echo "  └─ Backup differs from active SSH files"
                fi
            fi
        else
            echo "  └─ Backup metadata not found"
        fi
    else
        echo "- SSH Backup Status: ❌"
        ssh_status+=("no_backup")
    fi

    echo "+----------------------------------------------+"
}

# Creates the SSH config file in ~/.ssh/ with GitHub configuration
# Sets up the IdentityFile path and enables AddKeysToAgent
create_ssh_config() {
    mkdir -p /home/comma/.ssh
    echo "Creating SSH config file..."
    cat >/home/comma/.ssh/config <<EOF
Host github.com
  AddKeysToAgent yes
  IdentityFile /home/comma/.ssh/github
EOF
}

# Verifies if a valid SSH backup exists
# Returns:
# - 0 if backup exists with all required files
# - 1 if backup is missing or incomplete
check_ssh_backup() {
    if [ -f "/data/ssh_backup/github" ] && [ -f "/data/ssh_backup/github.pub" ] && [ -f "/data/ssh_backup/config" ]; then
        return 0 # Valid backup exists
    else
        return 1 # No valid backup
    fi
}

###############################################################################
# SSH Management Functions
###############################################################################

# Creates a backup of all SSH files to /data/ssh_backup/
# Includes: SSH keys, config, and metadata
# Preserves permissions and ownership
backup_ssh_files() {
    echo "Backing up SSH files..."
    if [ -f "/home/comma/.ssh/github" ] && [ -f "/home/comma/.ssh/github.pub" ] && [ -f "/home/comma/.ssh/config" ]; then
        mkdir -p /data/ssh_backup
        cp /home/comma/.ssh/github /data/ssh_backup/
        cp /home/comma/.ssh/github.pub /data/ssh_backup/
        cp /home/comma/.ssh/config /data/ssh_backup/
        sudo chown comma:comma /data/ssh_backup -R
        sudo chmod 600 /data/ssh_backup/github
        save_backup_metadata
        echo "SSH files backed up successfully to /data/ssh_backup/"
    else
        echo "No valid SSH files found to backup"
    fi
    read -p "Press enter to continue..."
}

# Restores SSH files from backup with verification
# - Verifies backup exists and is valid
# - Prompts for confirmation before restore
# - Maintains proper permissions and ownership
restore_ssh_files() {
    echo "Restoring SSH files..."
    if check_ssh_backup; then
        echo "Found backup with the following information:"
        get_backup_metadata
        read -p "Do you want to proceed with restore? (y/N): " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            remove_ssh_contents
            mkdir -p /home/comma/.ssh
            cp /data/ssh_backup/* /home/comma/.ssh/
            rm -f /home/comma/.ssh/metadata.txt
            sudo chown comma:comma /home/comma/.ssh -R
            sudo chmod 600 /home/comma/.ssh/github
            copy_ssh_config_and_keys
            echo "SSH files restored successfully"
        else
            echo "Restore cancelled"
        fi
    else
        echo "No valid SSH backup found to restore"
    fi
    read -p "Press enter to continue..."
}

# Creates metadata file for SSH backup
# Records:
# - Backup timestamp
save_backup_metadata() {
    local backup_time=$(date '+%Y-%m-%d %H:%M:%S')
    cat >/data/ssh_backup/metadata.txt <<EOF
Backup Date: $backup_time
EOF
}

# Retrieves and displays SSH backup metadata
# Shows backup date and configuration info if available
get_backup_metadata() {
    if [ -f "/data/ssh_backup/metadata.txt" ]; then
        cat /data/ssh_backup/metadata.txt
    else
        echo "No backup metadata found"
    fi
}

# Tests SSH connectivity to GitHub
# Verifies authentication and displays connection status
test_ssh_connection() {
    echo "Testing SSH connection to GitHub..."
    result=$(ssh -vT git@github.com 2>&1)
    if echo "$result" | grep -q "You've successfully authenticated"; then
        echo "SSH connection test successful: You are successfully authenticating with GitHub."
    else
        echo "SSH connection test failed."
    fi
    read -p "Press enter to continue..."
}

# Generates new ED25519 SSH key pair
# - Creates keys if they don't exist
# - Displays public key for GitHub setup
# - Prompts for GitHub addition confirmation
generate_ssh_key() {
    if [ ! -f /home/comma/.ssh/github ]; then
        ssh-keygen -t ed25519 -f /home/comma/.ssh/github
        echo "Displaying the SSH public key. Please add it to your GitHub account."
        cat /home/comma/.ssh/github.pub
        read -p "Press enter to continue after adding the SSH key to your GitHub account..."
    else
        echo "SSH key already exists. Skipping SSH key generation..."
    fi
}

# Repairs existing SSH setup or creates new one
# - Fixes permissions and ownership issues
# - Creates new setup if missing
# - Verifies and tests configuration
repair_create_ssh() {
    if [[ " ${ssh_status[@]} " =~ "missing" || " ${ssh_status[@]} " =~ "missing_usr" ]]; then
        echo "Creating SSH setup..."
        remove_ssh_contents
        create_ssh_config
        generate_ssh_key
        test_ssh_connection
    else
        echo "Repairing SSH setup..."
        [[ " ${ssh_status[@]} " =~ "fix_permissions" ]] && sudo chmod 600 /home/comma/.ssh/github
        [[ " ${ssh_status[@]} " =~ "fix_owner" ]] && sudo chown comma:comma /home/comma/.ssh/github
        [[ " ${ssh_status[@]} " =~ "fix_permissions_usr" ]] && sudo chmod 600 /usr/default/home/comma/.ssh/github
        [[ " ${ssh_status[@]} " =~ "fix_owner_usr" ]] && sudo chown comma:comma /usr/default/home/comma/.ssh/github
    fi
    copy_ssh_config_and_keys
    read -p "Press enter to continue..."
}

# Completely resets SSH configuration
# - Backs up existing configuration if present
# - Creates fresh SSH setup
# - Generates new keys
# - Tests new configuration
reset_ssh() {
    if [ -f "/home/comma/.ssh/github" ]; then
        backup_ssh_files
    fi
    remove_ssh_contents
    create_ssh_config
    generate_ssh_key
    copy_ssh_config_and_keys
    backup_ssh_files
    test_ssh_connection
    read -p "Press enter to continue..."
}

# Copies SSH configuration to persistent storage
# - Ensures SSH survives reboots
# - Maintains proper permissions
# - Creates necessary directories
copy_ssh_config_and_keys() {
    mount_rw
    echo "Copying SSH config and keys to /usr/default/home/comma/.ssh/..."
    if [ ! -d /usr/default/home/comma/.ssh/ ]; then
        sudo mkdir -p /usr/default/home/comma/.ssh/
    fi
    sudo cp /home/comma/.ssh/config /usr/default/home/comma/.ssh/
    sudo cp /home/comma/.ssh/github* /usr/default/home/comma/.ssh/
    sudo chown comma:comma /usr/default/home/comma/.ssh/ -R
    sudo chmod 600 /usr/default/home/comma/.ssh/github
}

# Displays the public SSH key
# Useful for adding key to GitHub
view_ssh_key() {
    if [ -f /home/comma/.ssh/github.pub ]; then
        echo "Displaying the SSH public key:"
        cat /home/comma/.ssh/github.pub
    else
        echo "SSH public key does not exist."
    fi
    read -p "Press enter to continue..."
}

# Removes all SSH-related files
# Used during reset operations
remove_ssh_contents() {
    mount_rw
    echo "Removing SSH folder contents..."
    rm -rf /home/comma/.ssh/*
    sudo rm -rf /usr/default/home/comma/.ssh/*
}

###############################################################################
# Git/Openpilot Status Functions
###############################################################################

# Displays condensed disk space for main menu
# Shows used, total, and percentage
display_disk_space_short() {
    local data_usage_root=$(df -h / | awk 'NR==2 {printf "Used: %s/%s (%s)", $3, $2, $5}')
    local data_usage_data=$(df -h /data | awk 'NR==2 {printf "Used: %s/%s (%s)", $3, $2, $5}')
    echo "| Disk Space (/): $data_usage_root"
    echo "| Disk Space (/data): $data_usage_data"
}

# Displays condensed Git status for main menu
# Shows current branch or indicates missing repository
display_git_status_short() {
    if [ -d /data/openpilot ]; then
        cd /data/openpilot
        branch_name=$(git rev-parse --abbrev-ref HEAD)
        cd - >/dev/null 2>&1
        echo "| Git Branch: $branch_name"
    else
        echo "| Git Branch: Missing"
    fi
}

# Shows detailed Git repository information
# - Repository presence
# - Current branch
# - Remote URL
display_git_status() {
    echo "+----------------------------------------------+"
    echo "|       Openpilot Repository                   |"
    echo "+----------------------------------------------+"
    if [ -d /data/openpilot ]; then
        cd /data/openpilot
        branch_name=$(git rev-parse --abbrev-ref HEAD)
        repo_url=$(git config --get remote.origin.url)
        echo "- Openpilot directory: ✅"
        echo "- Current branch: $branch_name"
        echo "- Repository URL: $repo_url"
        cd - >/dev/null 2>&1
    else
        echo "- Openpilot directory: ❌"
    fi
    echo "+----------------------------------------------+"
}

# Lists all available Git branches
# Shows both local and remote branches
list_git_branches() {
    echo "+----------------------------------------------+"
    echo "|        Available Branches                    |"
    echo "+----------------------------------------------+"
    if [ -d /data/openpilot ]; then
        cd /data/openpilot
        branches=$(git branch --all)
        if [ -n "$branches" ]; then
            echo "$branches"
        else
            echo "No branches found."
        fi
        cd - >/dev/null 2>&1
    else
        echo "Openpilot directory does not exist."
    fi
    echo "+----------------------------------------------+"
    read -p "Press enter to continue..."
}

# Updates current branch with latest changes
# - Fetches remote updates
# - Pulls changes into current branch
fetch_pull_latest_changes() {
    echo "Fetching and pulling the latest changes for the current branch..."
    if [ -d /data/openpilot ]; then
        cd /data/openpilot
        git fetch
        git pull
        cd /data
    else
        echo "No openpilot directory found."
    fi
    read -p "Press enter to continue..."
}

# Changes the current Git branch
# - Fetches latest branches
# - Switches to specified branch
change_branch() {
    echo "Changing the branch of the repository..."
    if [ -d /data/openpilot ]; then
        cd /data/openpilot
        git fetch
        read -p "Enter the branch name: " branch_name
        git checkout "$branch_name"
        cd /data
    else
        echo "No openpilot directory found."
    fi
    read -p "Press enter to continue..."
}

# Clones Openpilot repository with specified options
# Parameters:
# - shallow: boolean for depth-1 clone
# Prompts for:
# - Branch name
# - Repository URL
clone_openpilot_repo() {
    local shallow="${1:-true}"
    read -p "Enter the branch name: " branch_name
    read -p "Enter the GitHub repository (e.g., ford-op/openpilot): " github_repo
    cd /data
    rm -rf ./openpilot
    if [ "$shallow" = true ]; then
        git clone -b "$branch_name" --depth 1 --recurse-submodules git@github.com:"$github_repo" openpilot
    else
        git clone -b "$branch_name" --recurse-submodules git@github.com:"$github_repo" openpilot
    fi
    cd openpilot
    read -p "Press enter to continue..."
}

# Removes and re-clones Openpilot repository
# Used for complete repository reset
reset_openpilot_repo() {
    echo "Removing the Openpilot repository..."
    cd /data
    rm -rf openpilot
    clone_openpilot_repo "true"
}

###############################################################################
# System Status Functions
###############################################################################

# Displays general system status
# - Shows AGNOS version
display_general_status_short() {
    agnos_version=$(cat /VERSION 2>/dev/null)
    if [ -n "$agnos_version" ]; then
        echo "| AGNOS: v$agnos_version"
    else
        echo "| AGNOS: Unknown"
    fi
}

# Shows detailed system information
# - AGNOS version
# - Build time
display_general_status() {
    agnos_version=$(cat /VERSION)
    build_time=$(awk 'NR==2' /BUILD)
    echo "+----------------------------------------------+"
    echo "|           Other Items                        |"
    echo "+----------------------------------------------+"
    echo "- AGNOS: v$agnos_version ($build_time)"
    echo "+----------------------------------------------+"
}

# Monitors and manages root filesystem space
# - Checks usage percentage
# - Offers resize option if full
check_root_space() {
    root_usage=$(df -h / | awk 'NR==2 {gsub("%","",$5); print $5}')
    if [ "$root_usage" -ge 100 ]; then
        echo ""
        echo "Warning: Root filesystem is full."
        echo "To fix this, do you want to resize the root filesystem?"
        read -p "Enter y or n: " root_space_choice
        if [ "$root_space_choice" = "y" ]; then
            sudo mount -o remount,rw /
            sudo resize2fs $(findmnt -n -o SOURCE /)
            echo "Root filesystem resized successfully."
        fi
    fi
}

# Remounts root filesystem as read-write
# Required for system modifications
mount_rw() {
    echo "Mounting the / partition as read-write..."
    sudo mount -o remount,rw /
}

# Displays and manages system log files
# - Lists available logs
# - Allows viewing individual logs
display_logs() {
    clear
    echo "+---------------------------------+"
    echo "|            Log Files            |"
    echo "+---------------------------------+"
    log_files=(/data/log/*)
    for i in "${!log_files[@]}"; do
        echo "$((i + 1)). ${log_files[$i]}"
    done
    echo "Q. Back to previous menu"

    read -p "Enter the number of the log file to view or [Q] to go back: " log_choice

    if [[ $log_choice =~ ^[0-9]+$ ]] && ((log_choice > 0 && log_choice <= ${#log_files[@]})); then
        log_file="${log_files[$((log_choice - 1))]}"
        echo "Displaying contents of $log_file:"
        cat "$log_file"
    elif [[ $log_choice =~ ^[Qq]$ ]]; then
        return
    else
        echo "Invalid choice."
    fi

    read -p "Press enter to continue..."
}

# View error log at /data/community/crashes/error.txt
view_error_log() {
    echo "Displaying error log at /data/community/crashes/error.txt:"
    cat /data/community/crashes/error.txt
    read -p "Press enter to continue..."
}

# Initiates system reboot with confirmation
reboot_device() {
    echo "Rebooting the device..."
    sudo reboot
}

# Initiates system shutdown with confirmation
shutdown_device() {
    echo "Shutting down the device..."
    sudo shutdown now
}

# Updates this utility script
# Downloads latest version from GitHub
update_script() {
    echo "Downloading the latest version of the script..."

    # Create backup of current script
    cp /data/CommaUtility.sh /data/CommaUtility.sh.backup

    if wget -O /data/CommaUtility.sh.tmp https://raw.githubusercontent.com/tonesto7/op-utilities/main/CommaUtility.sh; then
        # If download successful, replace old script
        mv /data/CommaUtility.sh.tmp /data/CommaUtility.sh
        chmod +x /data/CommaUtility.sh
        echo "Script updated successfully. Restarting the updated script."
        read -p "Press enter to continue..."
        exec /data/CommaUtility.sh
    else
        echo "Update failed. Restoring backup..."
        mv /data/CommaUtility.sh.backup /data/CommaUtility.sh
        rm -f /data/CommaUtility.sh.tmp
        read -p "Press enter to continue..."
    fi
}

check_for_updates() {
    echo "Checking for script updates..."
    # Download version info from latest script
    latest_version=$(wget -qO- https://raw.githubusercontent.com/tonesto7/op-utilities/main/CommaUtility.sh | grep "SCRIPT_VERSION=" | head -n 1 | cut -d'"' -f2)

    if [ -z "$latest_version" ]; then
        echo "Unable to check for updates. Please check your internet connection."
        return 1
    fi

    # Compare versions
    if [ "$SCRIPT_VERSION" != "$latest_version" ]; then
        echo "New version available: v$latest_version (Current: v$SCRIPT_VERSION)"
        read -p "Would you like to update now? (y/N): " update_choice
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then
            update_script
        fi
    else
        echo "Script is up to date (v$SCRIPT_VERSION)"
    fi
}

###############################################################################
# BluePilot Utility Functions (from build_bluepilot)
###############################################################################

# Resets script variables
# Clears previous build options
reset_variables() {
    SCRIPT_ACTION=""
    REPO=""
    CLONE_BRANCH=""
    BUILD_BRANCH=""
}

# Displays help information for the script
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

setup_git_env_bp() {
    if [ -f "$BUILD_DIR/release/identity_ford_op.sh" ]; then
        source "$BUILD_DIR/release/identity_ford_op.sh"
    else
        echo "[-] identity_ford_op.sh not found"
        exit 1
    fi

    if [ -f /data/gitkey ]; then
        export GIT_SSH_COMMAND="ssh -i /data/gitkey"
    elif [ -f ~/.ssh/github ]; then
        export GIT_SSH_COMMAND="ssh -i ~/.ssh/github"
    else
        echo "[-] No git key found"
        exit 1
    fi
}

build_openpilot_bp() {
    export PYTHONPATH="$BUILD_DIR"
    echo "[-] Building Openpilot"
    scons -j"$(nproc)"
}

create_prebuilt_marker() {
    touch prebuilt
}

handle_panda_directory() {
    echo "Creating panda_tmp directory"
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
    SUBMODULES=("msgq_repo" "opendbc" "rednose_repo" "panda" "tinygrad_repo" "teleoprtc_repo")

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
    GITIGNORE_PATH=".gitignore"
    LINES_TO_REMOVE=(
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

    cleanup_directory "cereal" "*tests* *.md"
    cleanup_directory "common" "*tests* *.md"
    cleanup_directory "msgq_repo" "*tests* *.md .git*"
    cleanup_directory "opendbc_repo" "*tests* *.md .git* LICENSE"
    cleanup_directory "rednose_repo" "*tests* *.md .git* LICENSE"
    cleanup_directory "selfdrive" "*.h *.md *test*"
    cleanup_directory "system" "*tests* *.md"
    cleanup_directory "third_party" "*Darwin* LICENSE README.md"

    cleanup_tinygrad_repo
}

cleanup_directory() {
    local dir=$1
    local patterns=$2
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
        echo "Error: $BUILD_DIR/common/version.h not found."
        exit 1
    fi

    VERSION=$(date '+%Y.%m.%d')
    TIME_CODE=$(date +"%H%M")
    GIT_HASH=$(git rev-parse HEAD)
    DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
    SP_VERSION=$(cat $BUILD_DIR/common/version.h | awk -F\" '{print $2}')

    echo "#define COMMA_VERSION \"$VERSION-$TIME_CODE\"" >"$BUILD_DIR/common/version.h"

    create_prebuilt_marker

    git checkout --orphan temp_branch --quiet
    git add -A >/dev/null 2>&1
    git commit -m "$COMMIT_DESC_HEADER | v$VERSION-$TIME_CODE
version: $COMMIT_DESC_HEADER v$SP_VERSION release
date: $DATETIME
master commit: $GIT_HASH
" || {
        echo "[-] Commit failed"
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

    rm -rf "$BUILD_DIR" "$TMP_DIR"
    git clone --single-branch --branch "$BUILD_BRANCH" "$GIT_PUBLIC_REPO_ORIGIN" "$BUILD_DIR"
    cd "$BUILD_DIR"
    find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
    git clone --recurse-submodules --depth 1 "$GIT_REPO_ORIGIN" -b "$CLONE_BRANCH" "$TMP_DIR"
    cd "$TMP_DIR"
    process_submodules "$TMP_DIR"
    cd "$BUILD_DIR"
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
}

build_repo_branch() {
    local CLONE_BRANCH="$1"
    local BUILD_BRANCH="$2"
    local COMMIT_DESC_HEADER="$3"
    local GIT_REPO_ORIGIN="$4"

    rm -rf "$BUILD_DIR" "$TMP_DIR"
    git clone --recurse-submodules "$GIT_REPO_ORIGIN" -b "$CLONE_BRANCH" "$BUILD_DIR"
    cd "$BUILD_DIR"
    setup_git_env_bp
    build_openpilot_bp
    handle_panda_directory
    process_submodules "$BUILD_DIR"
    create_opendbc_gitignore
    update_main_gitignore
    cleanup_files
    create_prebuilt_marker
    prepare_commit_push "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN" "$BUILD_BRANCH"
}

clone_repo_bp() {
    local description="$1"
    local repo_url="$2"
    local branch="$3"
    local build="$4"
    local skip_reboot="${5:-no}"

    cd /data || exit 1
    rm -rf openpilot
    if [[ "$branch" != *-build* ]]; then
        git clone --recurse-submodules --depth 1 "${repo_url}" -b "${branch}" openpilot || exit 1
    else
        git clone --depth 1 "${repo_url}" -b "${branch}" openpilot || exit 1
    fi

    cd openpilot || exit 1

    if [ "$build" == "yes" ]; then
        scons -j"$(nproc)" || exit 1
    fi

    if [ "$skip_reboot" != "yes" ]; then
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
        echo "Reboot canceled."
    fi
}

choose_repository_and_branch() {
    local action="$1"
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
            ;;
        2)
            REPO="sp-dev-c3"
            GIT_REPO_ORIGIN="$GIT_BP_PRIVATE_REPO"
            ;;
        3)
            REPO="sunnypilot"
            GIT_REPO_ORIGIN="$GIT_SP_REPO"
            ;;
        C | c)
            return 1
            ;;
        *)
            echo "Invalid choice. Please try again."
            continue
            ;;
        esac
        break
    done

    echo "[-] Fetching list of branches..."
    REMOTE_BRANCHES=$(git ls-remote --heads "$GIT_REPO_ORIGIN" 2>&1)
    if [ $? -ne 0 ]; then
        echo "[-] Failed to fetch branches."
        return 1
    fi

    REMOTE_BRANCHES=$(echo "$REMOTE_BRANCHES" | awk '{print $2}' | sed 's#refs/heads/##')

    if [ "$action" = "build" ]; then
        REMOTE_BRANCHES=$(echo "$REMOTE_BRANCHES" | grep -v -- "-build")
    fi

    readarray -t BRANCH_ARRAY <<<"$REMOTE_BRANCHES"

    if [ ${#BRANCH_ARRAY[@]} -eq 0 ]; then
        echo "[-] No branches found."
        return 1
    fi

    echo "Available branches in $REPO:"
    for i in "${!BRANCH_ARRAY[@]}"; do
        printf "%d) %s\n" $((i + 1)) "${BRANCH_ARRAY[i]}"
    done

    while true; do
        read -p "Select a branch by number (or 'c' to cancel): " branch_choice
        if [[ "$branch_choice" == "c" || "$branch_choice" == "C" ]]; then
            return 1
        elif [[ "$branch_choice" =~ ^[0-9]+$ ]] && [ "$branch_choice" -ge 1 ] && [ "$branch_choice" -le "${#BRANCH_ARRAY[@]}" ]; then
            SELECTED_BRANCH="${BRANCH_ARRAY[$((branch_choice - 1))]}"
            CLONE_BRANCH="$SELECTED_BRANCH"
            BUILD_BRANCH="${CLONE_BRANCH}-build"
            echo "Selected branch: $CLONE_BRANCH"
            echo "Build branch will be: $BUILD_BRANCH"
            break
        else
            echo "Invalid choice."
        fi
    done
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
        echo "[-] Unknown repository: $REPO"
        return
        ;;
    esac

    clone_repo_bp "repository '$REPO' with branch '$CLONE_BRANCH'" "$GIT_REPO_URL" "$CLONE_BRANCH" "no" "yes"

    if [ ! -f "/data/openpilot/prebuilt" ]; then
        echo "[-] No prebuilt marker found. Might need to compile."
        read -p "Compile now? (y/N): " compile_confirm
        if [[ "$compile_confirm" =~ ^[Yy]$ ]]; then
            echo "[-] Running scons..."
            cd /data/openpilot
            scons -j"$(nproc)" || {
                echo "[-] SCons failed."
                exit 1
            }
            echo "[-] Compilation completed."
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
        echo "Invalid repository selected"
        return
    fi

    local COMMIT_DESC_HEADER="Custom Build"
    build_repo_branch "$CLONE_BRANCH" "$BUILD_BRANCH" "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN"
    echo "[-] Action completed successfully"
}

###############################################################################
# Menus
###############################################################################

ssh_menu() {
    while true; do
        clear
        display_ssh_status
        echo "1. Repair/Create SSH setup"
        echo "2. Copy SSH config and keys"
        echo "3. Reset SSH setup"
        echo "4. Test SSH connection"
        echo "5. View SSH key"
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
        b | B)
            if [ -f "/home/comma/.ssh/github" ]; then
                backup_ssh_files
            fi
            ;;
        x | X)
            if check_ssh_backup; then
                restore_ssh_files
            fi
            ;;
        q | Q) break ;;
        *) echo "Invalid choice." ;;
        esac
    done
}

git_menu() {
    while true; do
        clear
        display_git_status
        echo "1. Fetch and pull latest changes"
        echo "2. Change branch"
        echo "3. Clone Openpilot Repository"
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
        q | Q) break ;;
        *) echo "Invalid choice." ;;
        esac
    done
}

bluepilot_menu() {
    # BluePilot menu adapted from build_bluepilot logic
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
            read -p "Press enter..."
            ;;
        2)
            build_cross_repo_branch "bp-public-experimental" "staging-DONOTUSE" "bluepilot experimental" "$GIT_BP_PRIVATE_REPO" "$GIT_BP_PUBLIC_REPO"
            read -p "Press enter..."
            ;;
        3)
            custom_build_process
            read -p "Press enter..."
            ;;
        4)
            clone_public_bluepilot
            read -p "Press enter..."
            ;;
        5)
            clone_internal_dev_build
            read -p "Press enter..."
            ;;
        6)
            clone_internal_dev
            read -p "Press enter..."
            ;;
        7)
            clone_custom_repo
            read -p "Press enter..."
            ;;
        q | Q) break ;;
        *) echo "Invalid choice." ;;
        esac
    done
}

###############################################################################
# Argument Parsing (from build_bluepilot)
###############################################################################

# Attempt to parse arguments before showing menus
# Updated argument parsing with all functionality
if [ $# -gt 0 ]; then
    TEMP=$(getopt -o h --long build-dev,build-public,custom-build,repo:,clone-branch:,build-branch:,clone-public-bp,clone-internal-dev-build,clone-internal-dev,custom-clone,update,reboot,shutdown,view-logs,test-ssh,backup-ssh,restore-ssh,reset-ssh,git-pull,git-status,git-branch:,help -n 'CommaUtility.sh' -- "$@")

    if [ $? != 0 ]; then
        echo "Terminating..." >&2
        exit 1
    fi

    eval set -- "$TEMP"

    while true; do
        case "$1" in
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

        # Help
        -h | --help)
            show_help
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Internal error!"
            exit 1
            ;;
        esac
    done
fi

###############################################################################
# Main (If SCRIPT_ACTION is set by arguments, run that directly)
###############################################################################

main() {
    while true; do
        if [ -z "$SCRIPT_ACTION" ]; then
            # No arguments provided or no action set by arguments: show main menu
            check_for_updates
            while true; do
                clear
                check_root_space
                echo "+----------------------------------------------+"
                echo "|      CommaUtility Script v$SCRIPT_VERSION"
                echo "|        (Last Modified: $SCRIPT_MODIFIED)"
                echo "+----------------------------------------------+"
                display_ssh_status_short
                display_git_status_short
                display_general_status_short
                display_disk_space_short
                echo "----------------------------------------------"
                echo ""
                echo "1. SSH Setup"
                echo "2. Openpilot Folder Tools"
                echo "3. BluePilot Utilities"
                echo "4. View Logs"
                echo "5. View Recent Error"
                echo "6. Reboot Device"
                echo "7. Shutdown Device"
                echo "U. Update Script"
                echo "Q. Exit"
                read -p "Enter your choice: " main_choice
                case $main_choice in
                1) ssh_menu ;;
                2) git_menu ;;
                3) bluepilot_menu ;;
                4) display_logs ;;
                5) view_error_log ;;
                6) reboot_device ;;
                7) shutdown_device ;;
                u | U) update_script ;;
                q | Q)
                    echo "Exiting..."
                    exit 0
                    ;;
                *)
                    echo "Invalid choice."
                    ;;
                esac
            done
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
                    echo "Error: --custom-clone requires --repo and --clone-branch parameters."
                    show_help
                    exit 1
                fi
                # Perform custom clone with provided parameters directly
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
                    echo "[-] Unknown repository: $REPO"
                    exit 1
                    ;;
                esac
                clone_repo_bp "repository '$REPO' with branch '$CLONE_BRANCH'" "$GIT_REPO_URL" "$CLONE_BRANCH" "no" "yes"
                if [ ! -f "/data/openpilot/prebuilt" ]; then
                    echo "[-] No prebuilt marker found. Might need to compile."
                    read -p "Compile now? (y/N): " compile_confirm
                    if [[ "$compile_confirm" =~ ^[Yy]$ ]]; then
                        echo "[-] Running scons..."
                        cd /data/openpilot
                        scons -j"$(nproc)" || {
                            echo "[-] SCons failed."
                            exit 1
                        }
                        echo "[-] Compilation completed."
                    fi
                fi
                reboot_device_bp
                ;;
            custom-build)
                if [ -z "$REPO" ] || [ -z "$CLONE_BRANCH" ] || [ -z "$BUILD_BRANCH" ]; then
                    echo "Error: --custom-build requires --repo, --clone-branch, and --build-branch parameters."
                    show_help
                    exit 1
                fi

                if [ "$REPO" = "bluepilotdev" ]; then
                    GIT_REPO_ORIGIN="$GIT_BP_PUBLIC_REPO"
                elif [ "$REPO" = "sp-dev-c3" ]; then
                    GIT_REPO_ORIGIN="$GIT_BP_PRIVATE_REPO"
                else
                    echo "Invalid repository selected"
                    exit 1
                fi

                COMMIT_DESC_HEADER="Custom Build"
                build_repo_branch "$CLONE_BRANCH" "$BUILD_BRANCH" "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN"
                echo "[-] Action completed successfully"
                ;;

                # System operations
            update)
                update_script
                ;;
            reboot)
                reboot_device
                ;;
            shutdown)
                shutdown_device
                ;;
            view-logs)
                display_logs
                ;;

            # SSH operations
            test-ssh)
                test_ssh_connection
                ;;
            backup-ssh)
                backup_ssh_files
                ;;
            restore-ssh)
                restore_ssh_files
                ;;
            reset-ssh)
                reset_ssh
                ;;

            # Git operations
            git-pull)
                fetch_pull_latest_changes
                ;;
            git-status)
                display_git_status
                ;;
            git-branch)
                if [ -n "$NEW_BRANCH" ]; then
                    cd /data/openpilot && git checkout "$NEW_BRANCH"
                else
                    echo "Error: Branch name required"
                    exit 1
                fi
                ;;
            *)
                echo "Invalid build type. Exiting."
                exit 1
                ;;
            esac

            # After completing the action, exit since it's argument driven
            exit 0
        fi
    done
}

# Run main
main
