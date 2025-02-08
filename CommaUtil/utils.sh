#!/bin/bash

###############################################################################
# Global Variables
###############################################################################
readonly UTILS_SCRIPT_VERSION="3.0.1"
readonly UTILS_SCRIPT_MODIFIED="2025-02-08"

###############################################################################
# Encryption/Decryption Functions
###############################################################################
encrypt_credentials() {
    local data="$1" output="$2"
    openssl enc -aes-256-cbc -salt -pbkdf2 -in <(echo "$data") -out "$output" -pass file:/data/params/d/GithubSshKeys
}
decrypt_credentials() {
    local input="$1"
    openssl enc -d -aes-256-cbc -pbkdf2 -in "$input" -pass file:/data/params/d/GithubSshKeys
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
    local error_msg="$2"
    local max_retries=3
    local retry_count=0
    local success=false

    while [ $retry_count -lt $max_retries ]; do
        if eval "$cmd"; then
            success=true
            break
        fi
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            print_warning "Attempt $retry_count failed. Retrying in 5 seconds..."
            sleep 5
        fi
    done

    if [ "$success" = false ]; then
        print_error "$error_msg after $max_retries attempts"
        return 1
    fi
    return 0
}

# A convenient prompt-pause function to unify "Press Enter" prompts:
pause_for_user() {
    read -p "Press enter to continue..."
}

###############################################################################
# Helper functions for colored output
###############################################################################
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

is_onroad() {
    if [ -f "/data/params/d/IsOnroad" ] && grep -q "^1" "/data/params/d/IsOnroad"; then
        return 0
    fi
    return 1
}

get_device_id() {
    serial=$(cat /data/params/d/HardwareSerial)
    if [ -z "$serial" ]; then
        echo "Unknown"
    else
        echo "$serial"
    fi
}

get_dongle_id() {
    dongle_id=$(cat /data/params/d/DongleId)
    if [ -z "$dongle_id" ]; then
        echo "Unknown"
    else
        echo "$dongle_id"
    fi
}

get_wifi_mac() {
    mac=$(cat /sys/class/net/wlan0/address)
    if [ -z "$mac" ]; then
        echo "Unknown"
    else
        echo "$mac"
    fi
}

###############################################################################
# Directory and Path Functions
###############################################################################

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
