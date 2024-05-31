#!/bin/bash

# Function to display the status section with borders and dash prefixes
# Function to display the status section with enhanced checks
display_status() {
    echo "+---------------------------------+"
    echo "|            Status               |"
    echo "+---------------------------------+"

    # Define the expected owner and permissions
    expected_owner="comma"
    expected_permissions="-rw-------"

    # Check for SSH key in ~/.ssh/ and verify owner and permissions
    if [ -f /home/comma/.ssh/github ]; then
        actual_permissions=$(ls -l /home/comma/.ssh/github | awk '{ print $1 }')
        actual_owner=$(ls -l /home/comma/.ssh/github | awk '{ print $3 }')
        actual_group=$(ls -l /home/comma/.ssh/github | awk '{ print $4 }')

        echo "- SSH key in ~/.ssh/: ✅"

        # Check permissions
        if [ "$actual_permissions" == "$expected_permissions" ]; then
            echo "- Permissions: ✅ ($actual_permissions)"
        else
            echo "- Permissions: ❌ (Expected: $expected_permissions, Actual: $actual_permissions)"
        fi

        # Check owner
        if [ "$actual_owner" == "$expected_owner" ] && [ "$actual_group" == "$expected_owner" ]; then
            echo "- Owner: ✅ ($actual_owner:$actual_group)"
        else
            echo "- Owner: ❌ (Expected: $expected_owner:$expected_owner, Actual: $actual_owner:$actual_group)"
        fi
    else
        echo "- SSH key in ~/.ssh/: ❌"
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
        fi

        # Check owner
        if [ "$actual_owner" == "$expected_owner" ] && [ "$actual_group" == "$expected_owner" ]; then
            echo "- Owner: ✅ ($actual_owner:$actual_group)"
        else
            echo "- Owner: ❌ (Expected: $expected_owner:$expected_owner, Actual: $actual_owner:$actual_group)"
        fi
    else
        echo "- SSH key in /usr/default/home/comma/.ssh/: ❌"
    fi

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
        # read -p "Enter your email for the SSH key: " email
        # echo "Generating SSH key..."
        # ssh-keygen -t rsa -b 4096 -C "$email" -f /home/comma/.ssh/github -N ""
        ssh-keygen -t ed25519 -f /home/comma/.ssh/github
        echo "Displaying the SSH public key. Please add it to your GitHub account."
        cat /home/comma/.ssh/github.pub
        read -p "Press enter to continue after adding the SSH key to your GitHub account..."
    else
        echo "SSH key already exists. Skipping SSH key generation..."
    fi
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
    ssh -vT git@github.com
}

# Function to mount the / partition as read-write
mount_rw() {
    echo "Mounting the / partition as read-write..."
    sudo mount -o remount,rw /
}

# function to remove the openpilot directory and clone the repository again
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

# Function to reset and run all tasks
reset_and_run_all() {
    remove_ssh_contents
    create_ssh_config
    generate_ssh_key
    copy_ssh_config_and_keys
    test_ssh_connection
    reset_openpilot_repo
    clone_openpilot_repo
}

# Function to fix permissions and owner for /usr/default/home/comma/.ssh and its contents
fix_ssh_permissions_and_owner() {
    mount_rw
    echo "Fixing permissions and owner for /usr/default/home/comma/.ssh and its contents..."
    if [ -d /usr/default/home/comma/.ssh/ ]; then
        sudo chown comma:comma /usr/default/home/comma/.ssh/ -R
        sudo find /usr/default/home/comma/.ssh/ -type f -exec chmod 600 {} \;
        sudo find /usr/default/home/comma/.ssh/ -type d -exec chmod 700 {} \;
        echo "Permissions and owner fixed successfully."
    else
        echo "/usr/default/home/comma/.ssh/ directory does not exist."
    fi
}

reboot_device() {
    echo "Rebooting the device..."
    sudo reboot
}

# Main menu loop with the new menu item for fixing SSH permissions and owner
while true; do
    clear
    display_status
    echo "Menu:"
    echo "1. Create SSH config"
    echo "2. Generate SSH key"
    echo "3. Copy SSH config and keys"
    echo "4. Test SSH connection"
    echo "5. Clone Openpilot repository"
    echo "6. Remove Openpilot repository and Clone Again"
    echo "7. View SSH key"
    echo "8. Remove SSH folder contents"
    echo "9. Reset and run all tasks"
    echo "10. Fix SSH permissions and owner"
    echo "11. Reboot device"
    echo "Q. Exit"
    read -p "Enter your choice [1-10] or [Q] to Exit: " choice

    case $choice in
        1) create_ssh_config ;;
        2) generate_ssh_key ;;
        3) copy_ssh_config_and_keys ;;
        4) test_ssh_connection ;;
        5) clone_openpilot_repo ;;
        6) reset_openpilot_repo ;;
        7) view_ssh_key ;;
        8) remove_ssh_contents ;;
        9) reset_and_run_all ;;
        10) fix_ssh_permissions_and_owner ;;
        11) reboot_device ;;
        Q) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid choice. Please enter a number between 1 and 10 or Q to Exit" ;;
    esac

    read -p "Press enter to continue..."
done
