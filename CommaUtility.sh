#!/bin/bash

# Script Version
SCRIPT_VERSION="1.2.0"
SCRIPT_MODIFIED="2024-12-10"

# Function to display SSH status
display_ssh_status() {
    echo "+--------------------------------------------------------------------------+"
    echo "|          SSH Status                                                      |"
    echo "+--------------------------------------------------------------------------+"

    # Define the expected owner and permissions
    expected_owner="comma"
    expected_permissions="-rw-------"
    ssh_status=()

    # Check for SSH key in ~/.ssh/ and verify owner and permissions
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

    # Similar checks for SSH key in /usr/default/home/comma/.ssh/
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

    # Check SSH backup status
    if [ -f "/data/ssh_backup/github" ] && [ -f "/data/ssh_backup/github.pub" ] && [ -f "/data/ssh_backup/config" ]; then
        echo "- SSH Backup Status: ✅"
        if [ -f "/data/ssh_backup/metadata.txt" ]; then
            backup_date=$(grep "Backup Date:" /data/ssh_backup/metadata.txt | cut -d: -f2- | xargs)
            ssh_fingerprint=$(grep "SSH Key Fingerprint:" /data/ssh_backup/metadata.txt | cut -d: -f2- | xargs)
            echo "  └─ Last Backup: $backup_date"
            echo "  └─ Key Fingerprint: $ssh_fingerprint"

            # Verify if backup matches current SSH files
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

    echo "+--------------------------------------------------------------------------+"
}

# Function to display Git repo status
display_git_status() {
    echo "+--------------------------------------------------------------------------+"
    echo "|       Openpilot Repository                                               |"
    echo "+--------------------------------------------------------------------------+"

    # Check for /data/openpilot and display current branch and repo name
    if [ -d /data/openpilot ]; then
        cd /data/openpilot
        local branch_name=$(git rev-parse --abbrev-ref HEAD)
        local repo_url=$(git config --get remote.origin.url)
        echo "- Openpilot directory: ✅"
        echo "- Current branch: $branch_name"
        echo "- Repository URL: $repo_url"
        cd - >/dev/null 2>&1
    else
        echo "- Openpilot directory: ❌"
    fi

    echo "+--------------------------------------------------------------------------+"
}

# Function to display available branches
list_git_branches() {
    echo "+--------------------------------------------------------------------------+"
    echo "|        Available Branches                                                |"
    echo "+--------------------------------------------------------------------------+"
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
    echo "+--------------------------------------------------------------------------+"
    read -p "Press enter to continue..."
}

# Function to display general status
display_general_status() {
    agnos_version=$(cat /VERSION)
    build_time=$(awk 'NR==2' /BUILD)

    echo "+--------------------------------------------------------------------------+"
    echo "|           Other Items                                                    |"
    echo "+--------------------------------------------------------------------------+"
    echo "- AGNOS: v$agnos_version ($build_time)"
    echo "+--------------------------------------------------------------------------+"
}

# Function to create SSH config
create_ssh_config() {
    mkdir -p /home/comma/.ssh
    echo "Creating SSH config file..."
    cat >/home/comma/.ssh/config <<EOF
Host github.com
  AddKeysToAgent yes
  IdentityFile /home/comma/.ssh/github
EOF
}

# Function to check if valid SSH backup exists
check_ssh_backup() {
    if [ -f "/data/ssh_backup/github" ] && [ -f "/data/ssh_backup/github.pub" ] && [ -f "/data/ssh_backup/config" ]; then
        return 0 # Valid backup exists
    else
        return 1 # No valid backup
    fi
}

# Function to backup SSH files
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

# Function to restore SSH files
restore_ssh_files() {
    echo "Restoring SSH files..."
    if check_ssh_backup; then
        echo "Found backup with the following information:"
        get_backup_metadata
        read -p "Do you want to proceed with restore? (y/N): " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            # Remove existing SSH contents
            remove_ssh_contents

            # Restore from backup
            mkdir -p /home/comma/.ssh
            cp /data/ssh_backup/* /home/comma/.ssh/
            rm -f /home/comma/.ssh/metadata.txt # Don't copy metadata to SSH directory
            sudo chown comma:comma /home/comma/.ssh -R
            sudo chmod 600 /home/comma/.ssh/github

            # Copy to persistent storage
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

# Function to save backup metadata
save_backup_metadata() {
    local backup_time=$(date '+%Y-%m-%d %H:%M:%S')
    local ssh_key_fingerprint=$(ssh-keygen -lf /data/ssh_backup/github.pub 2>/dev/null | awk '{print $2}')
    cat >/data/ssh_backup/metadata.txt <<EOF
Backup Date: $backup_time
SSH Key Fingerprint: $ssh_key_fingerprint
EOF
}

# Function to read backup metadata
get_backup_metadata() {
    if [ -f "/data/ssh_backup/metadata.txt" ]; then
        cat /data/ssh_backup/metadata.txt
    else
        echo "No backup metadata found"
    fi
}

# Create a function to fetch and pull the latest changes from the repository
fetch_pull_latest_changes() {
    echo "Fetching and pulling the latest changes for the current branch..."
    cd /data/openpilot
    git fetch
    git pull
    cd /data
    read -p "Press enter to continue..."
}

# Function to change the branch of the repository
change_branch() {
    echo "Changing the branch of the repository..."
    cd /data/openpilot
    # prompt the user to enter the branch name
    git fetch
    read -p "Enter the branch name: " branch_name
    git checkout "$branch_name"
    cd /data
    read -p "Press enter to continue..."
}

# Function to generate SSH key with dynamic email input
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

# Function to repair or create SSH setup
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

# Function to reset SSH setup
reset_ssh() {
    # Backup existing SSH files if they exist
    if [ -f "/home/comma/.ssh/github" ]; then
        backup_ssh_files
    fi
    remove_ssh_contents
    create_ssh_config
    generate_ssh_key
    copy_ssh_config_and_keys
    backup_ssh_files # Backup the new SSH files
    test_ssh_connection
    read -p "Press enter to continue..."
}

create_and_copy_ssh_config() {
    create_ssh_config
    copy_ssh_config_and_keys
    read -p "Press enter to continue..."
}

# Function to copy SSH config and keys
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

# Function to test SSH connection
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

# Function to mount the / partition as read-write
mount_rw() {
    echo "Mounting the / partition as read-write..."
    sudo mount -o remount,rw /
}

# Function to remove the openpilot directory and clone the repository again
reset_openpilot_repo() {
    echo "Removing the Openpilot repository..."
    cd /data
    rm -rf openpilot
    clone_openpilot_repo "true"
}

# Function to clone Openpilot repository
clone_openpilot_repo() {
    local shallow="${1:-true}"
    read -p "Enter the branch name: " branch_name
    # prompt the user to enter the GitHub repository and pre-fill with the default repository
    read -p "Enter the GitHub repository (e.g., ford-op/openpilot): " github_repo
    if [ "$shallow" = true ]; then
        echo "Cloning the Openpilot repository (Shallow)..."
    else
        echo "Cloning the Openpilot repository (Full)..."
    fi
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

# Function to view the SSH key
view_ssh_key() {
    if [ -f /home/comma/.ssh/github.pub ]; then
        echo "Displaying the SSH public key:"
        cat /home/comma/.ssh/github.pub
    else
        echo "SSH public key does not exist."
    fi
    read -p "Press enter to continue..."
}

# Function to remove SSH folder contents
remove_ssh_contents() {
    mount_rw
    echo "Removing SSH folder contents..."
    rm -rf /home/comma/.ssh/*
    sudo rm -rf /usr/default/home/comma/.ssh/*
}

# Function to reboot the device
reboot_device() {
    echo "Rebooting the device..."
    sudo reboot
}

# Function to shutdown the device
shutdown_device() {
    echo "Shutting down the device..."
    sudo shutdown now
}

# Function to download the latest version of the script from GitHub
update_script() {
    echo "Downloading the latest version of the script..."
    wget https://raw.githubusercontent.com/tonesto7/op-utilities/main/CommaUtility.sh -O CommaUtility.sh
    chmod +x CommaUtility.sh

    echo "Script updated successfully. Restarting the updated script."
    read -p "Press enter to continue..."
    exec /data/CommaUtility.sh
    return
}

download_bp_utility() {
    echo "Downloading the latest version of the bluepilot utility script..."
    wget https://raw.githubusercontent.com/tonesto7/op-utilities/main/build_scripts/build_bluepilot.sh -O build_bluepilot.sh
    chmod +x build_bluepilot.sh

    # Exit the script after updating and run the updated script
    echo "Script updated the bp utility script successfully. Please run the updated script."
    read -p "Press enter to continue..."
    return
}

# Function to display logs
display_logs() {
    clear
    echo "+---------------------------------+"
    echo "|            Log Files            |"
    echo "+---------------------------------+"

    log_files=(/data/log/*)
    for i in "${!log_files[@]}"; do
        echo "$((i + 1)). ${log_files[$i]}"
    done
    echo "Q. Back to main menu"

    read -p "Enter the number of the log file to view or [Q] to go back: " log_choice

    if [[ $log_choice =~ ^[0-9]+$ ]] && ((log_choice > 0 && log_choice <= ${#log_files[@]})); then
        log_file="${log_files[$((log_choice - 1))]}"
        echo "Displaying contents of $log_file:"
        cat "$log_file"
    elif [[ $log_choice =~ ^[Qq]$ ]]; then
        return
    else
        echo "Invalid choice. Please enter a valid number or Q to go back."
    fi

    read -p "Press enter to continue..."
}

# Function to get the AGNOS Version installed on the device
get_agnos_version() {
    agnos_version=$(cat /VERSION)
    echo "AGNOS Version: $agnos_version"
}

# Main menu loop with the updated items and organized groups
while true; do
    clear

    # Display the Script version and last modified date
    echo "+--------------------------------------------------------------------------+"
    echo "|      CommaUtility Script                                                 |"
    echo "+--------------------------------------------------------------------------+"
    echo "Version: $SCRIPT_VERSION"
    echo "Last Modified: $SCRIPT_MODIFIED"
    echo ""

    display_ssh_status
    menu_item_1="Repair/Create SSH setup"
    if [[ " ${ssh_status[@]} " =~ "missing" || " ${ssh_status[@]} " =~ "missing_usr" ]]; then
        menu_item_1="Create SSH setup"
    elif [[ " ${ssh_status[@]} " =~ "fix_permissions" || " ${ssh_status[@]} " =~ "fix_owner" || " ${ssh_status[@]} " =~ "fix_permissions_usr" || " ${ssh_status[@]} " =~ "fix_owner_usr" ]]; then
        menu_item_1="Repair SSH setup"
    fi
    echo "1. $menu_item_1"
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
    echo ""

    display_git_status
    echo "6. Fetch and pull latest changes"
    echo "7. Change branch"
    echo "8. Clone Openpilot Repository"
    echo "9. Change Openpilot Repository"
    echo "10. List available branches"
    echo ""
    display_general_status
    echo "L. View logs"
    echo "R. Reboot device"
    echo "S. Shutdown device"
    echo "BP. Download BluePilot Utility"
    echo "U. Update this script"
    echo "Q. Exit"
    read -p "Enter your choice [1-10] or [Q] to Exit: " choice

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
    6) fetch_pull_latest_changes ;;
    7) change_branch ;;
    8) clone_openpilot_repo "true" ;;
    9) reset_openpilot_repo ;;
    10) list_git_branches ;;
    l | L) display_logs ;;
    r | R) reboot_device ;;
    s | S) shutdown_device ;;
    u | U) update_script ;;
    q | Q)
        echo "Exiting..."
        exit 0
        ;;
    bp | BP) download_bp_utility ;;
    *) echo "Invalid choice. Please enter a number between 1 and 10 or Q to Exit" ;;
    esac
done
