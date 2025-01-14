#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

print_info() {
    echo -e "$1"
}

# Function to check if a command exists
check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Function to find SSH keys in common locations
find_ssh_keys() {
    local ssh_keys=()
    local search_dirs=(
        "$HOME/.ssh"
        "/etc/ssh"
    )

    for dir in "${search_dirs[@]}"; do
        if [ -d "$dir" ]; then
            while IFS= read -r -d '' file; do
                if [[ -f "$file.pub" ]]; then
                    ssh_keys+=("$file")
                fi
            done < <(find "$dir" -type f ! -name "*.pub" -print0)
        fi
    done

    if [ ${#ssh_keys[@]} -eq 0 ]; then
        print_error "No SSH keys found."
        return 1
    fi

    echo "Available SSH keys:"
    for i in "${!ssh_keys[@]}"; do
        local key_type
        key_type=$(ssh-keygen -l -f "${ssh_keys[$i]}" 2>/dev/null | awk '{print $2}')
        echo "$((i + 1)). ${ssh_keys[$i]} ($key_type)"
    done

    local selection
    while true; do
        read -p "Select SSH key number: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#ssh_keys[@]}" ]; then
            SELECTED_KEY="${ssh_keys[$((selection - 1))]}"
            echo "Selected key: $SELECTED_KEY"
            return 0
        fi
        print_error "Invalid selection. Please try again."
    done
}

# Function to test SSH connection
test_ssh_connection() {
    local ip="$1"
    if ! ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        print_error "Cannot reach device at $ip"
        return 1
    fi

    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "comma@$ip" echo 2>/dev/null; then
        print_error "Cannot establish SSH connection to device"
        return 1
    fi

    return 0
}

# Main script execution
main() {
    # Check for required commands
    local required_commands=(ssh scp wget)
    for cmd in "${required_commands[@]}"; do
        if ! check_command "$cmd"; then
            print_error "Required command '$cmd' not found. Please install it and try again."
            exit 1
        fi
    done

    # Find and select SSH key
    if ! find_ssh_keys; then
        print_error "No SSH keys available. Please generate an SSH key pair first."
        exit 1
    fi

    # Get comma device IP
    local device_ip
    while true; do
        read -p "Enter comma device IP address: " device_ip
        if [[ "$device_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if test_ssh_connection "$device_ip"; then
                break
            fi
        else
            print_error "Invalid IP address format. Please try again."
        fi
    done

    # Check for CommaUtility.sh on device and download if needed
    print_info "Checking for CommaUtility.sh on device..."
    if ! ssh "comma@$device_ip" "test -f /data/CommaUtility.sh"; then
        print_info "Downloading CommaUtility.sh to device..."
        ssh "comma@$device_ip" "cd /data && wget https://raw.githubusercontent.com/tonesto7/op-utilities/main/CommaUtility.sh && chmod +x CommaUtility.sh"
        if [ $? -ne 0 ]; then
            print_error "Failed to download CommaUtility.sh to device"
            exit 1
        fi
    fi

    # Execute CommaUtility.sh with SSH parameters
    print_info "Configuring SSH on device..."

    # First create temporary directory and files on device
    ssh "comma@$device_ip" "mkdir -p /tmp/ssh_transfer"
    scp "$SELECTED_KEY" "comma@$device_ip:/tmp/ssh_transfer/private_key"
    scp "$SELECTED_KEY.pub" "comma@$device_ip:/tmp/ssh_transfer/public_key"

    # Execute the utility script with paths instead of content
    ssh "comma@$device_ip" "/data/CommaUtility.sh --import-ssh --private-key-file /tmp/ssh_transfer/private_key --public-key-file /tmp/ssh_transfer/public_key"

    # Clean up temporary files
    ssh "comma@$device_ip" "rm -rf /tmp/ssh_transfer"

    if [ $? -eq 0 ]; then
        print_success "SSH key transfer and configuration completed successfully!"
    else
        print_error "SSH key transfer failed. Please try again or check the device logs."
    fi
}

# Execute main function
main
