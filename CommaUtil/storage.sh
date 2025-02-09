#!/bin/bash
###############################################################################
# storage.sh - Device Storage Management Functions for CommaUtility
#
# Version: STORAGE_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script manages device storage operations (disk space, filesystem, etc.)
###############################################################################
readonly STORAGE_SCRIPT_VERSION="3.0.0"
readonly STORAGE_SCRIPT_MODIFIED="2025-02-09"

###############################################################################
# Storage Helper Functions
###############################################################################

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

check_disk_usage_and_resize() {
    # This function unifies the disk usage check from detect_issues() and
    # check_root_space() to avoid code duplication.
    local partition="/"
    local root_usage=$(df -h "$partition" | awk 'NR==2 {gsub("%","",$5); print $5}')
    # Return usage for other logic as needed
    echo "$root_usage"
}

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

check_working_directory() {
    if [ -n "$(git status --porcelain)" ]; then
        print_error "Working directory is not clean"
        return 1
    fi
    return 0
}

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

get_absolute_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        echo "$path"
    else
        echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
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

display_disk_space_status_short() {
    print_info "│ Disk Space:"
    local data_usage_root
    local data_usage_data
    data_usage_root=$(df -h / | awk 'NR==2 {printf "Used: %s/%s (%s)", $3, $2, $5}')
    data_usage_data=$(df -h /data | awk 'NR==2 {printf "Used: %s/%s (%s)", $3, $2, $5}')
    echo "│ ├─ (/):     $data_usage_root"
    echo "│ └─ (/data): $data_usage_data"
}

check_root_space() {
    local usage
    usage=$(check_disk_usage_and_resize)
    resize_root_if_needed "$usage"
}

mount_rw() {
    print_info "Mounting the / partition as read-write..."
    sudo mount -o remount,rw /
}
