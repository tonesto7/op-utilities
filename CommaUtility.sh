#!/bin/bash

# Function to display SSH status
display_ssh_status() {
    echo "+---------------------------------+"
    echo "|          SSH Status             |"
    echo "+---------------------------------+"

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

    echo "+---------------------------------+"
}

# Function to display Git repo status
display_git_status() {
    echo "+---------------------------------+"
    echo "|       Openpilot Repository      |"
    echo "+---------------------------------+"

    # Check for /data/openpilot and display current branch and repo name
    if [ -d /data/openpilot ]; then
        cd /data/openpilot
        local branch_name=$(git rev-parse --abbrev-ref HEAD)
        local repo_url=$(git config --get remote.origin.url)
        echo "- Openpilot directory: ✅"
        echo "- Current branch: $branch_name"
        echo "- Repository URL: $repo_url"
        cd - > /dev/null 2>&1
    else
        echo "- Openpilot directory: ❌"
    fi

    echo "+---------------------------------+"
}

# Function to display available branches
list_git_branches() {
    echo "+---------------------------------+"
    echo "|        Available Branches       |"
    echo "+---------------------------------+"
    if [ -d /data/openpilot ]; then
        cd /data/openpilot
        branches=$(git branch --all)
        if [ -n "$branches" ]; then
            echo "$branches"
        else
            echo "No branches found."
        fi
        cd - > /dev/null 2>&1
    else
        echo "Openpilot directory does not exist."
    fi
    echo "+---------------------------------+"
}

# Function to display general status
display_general_status() {
    echo "+---------------------------------+"
    echo "|           Other Items           |"
    echo "+---------------------------------+"
}

# Function to create SSH config
create_ssh_config() {
    mkdir -p /home/comma/.ssh
    echo "Creating SSH config file..."
    cat > /home/comma/.ssh/config <<EOF
Host github.com
  AddKeysToAgent yes
  IdentityFile /home/comma/.ssh/github
EOF
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
}

# Function to reset SSH setup
reset_ssh() {
    remove_ssh_contents
    create_ssh_config
    generate_ssh_key
    copy_ssh_config_and_keys
    test_ssh_connection
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
    clone_openpilot_repo
}

# Function to clone Openpilot repository
clone_openpilot_repo() {
    read -p "Enter the branch name: " branch_name
    read -p "Enter the GitHub repository (e.g., ford-op/openpilot): " github_repo
    echo "Cloning the Openpilot repository..."
    cd /data
    rm -rf ./openpilot
    git clone -b "$branch_name" --recurse-submodules git@github.com:"$github_repo" openpilot
    cd openpilot
}

# Function to view the SSH key
view_ssh_key() {
    if [ -f /home/comma/.ssh/github.pub ]; then
        echo "Displaying the SSH public key:"
        cat /home/comma/.ssh/github.pub
    else
        echo "SSH public key does not exist."
    fi
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

    # Exit the script after updating and run the updated script
    echo "Script updated successfully. Please run the updated script."
    exit 0
}

# Main menu loop with the updated items and organized groups
while true; do
    clear
    display_ssh_status
    menu_item_1="Repair/Create SSH setup"
    if [[ " ${ssh_status[@]} " =~ "missing" || " ${ssh_status[@]} " =~ "missing_usr" ]]; then
        menu_item_1="Create SSH setup"
    elif [[ " ${ssh_status[@]} " =~ "fix_permissions" || " ${ssh_status[@]} " =~ "fix_owner" || " ${ssh_status[@]} " =~ "fix_permissions_usr" || " ${ssh_status[@]} " =~ "fix_owner_usr" ]]; then
        menu_item_1="Repair SSH setup"
    fi
    echo "1. $menu_item_1"
    echo "2. Reset SSH setup"
    echo "3. Test SSH connection"
    echo "4. View SSH key"
    echo ""
    display_git_status
    echo "5. Clone Openpilot Repository"
    echo "6. Change Openpilot Repository"
    echo "7. List available branches"
    echo ""
    display_general_status
    # echo "General Tasks:"
    echo "R. Reboot device"
    echo "S. Shutdown device"
    echo "U. Update script"
    echo "Q. Exit"
    read -p "Enter your choice [1-8] or [Q] to Exit: " choice

    case $choice in
        1) repair_create_ssh ;;
        2) reset_ssh ;;
        3) test_ssh_connection ;;
        4) view_ssh_key ;;
        5) clone_openpilot_repo ;;
        6) reset_openpilot_repo ;;
        7) list_git_branches ;;
        R) reboot_device ;;
        r) reboot_device ;;
        S) shutdown_device ;;
        s) shutdown_device ;;
        U) update_script ;;
        u) update_script ;;
        Q) echo "Exiting..."; exit 0 ;;
        q) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid choice. Please enter a number between 1 and 8 or Q to Exit" ;;
    esac

    read -p "Press enter to continue..."
done
