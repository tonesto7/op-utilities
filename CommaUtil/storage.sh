#!/bin/bash

###############################################################################
# Global Variables
###############################################################################
readonly STORAGE_SCRIPT_VERSION="3.0.1"
readonly STORAGE_SCRIPT_MODIFIED="2025-02-08"

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

check_root_space() {
    local usage
    usage=$(check_disk_usage_and_resize)
    resize_root_if_needed "$usage"
}

mount_rw() {
    print_info "Mounting the / partition as read-write..."
    sudo mount -o remount,rw /
}

###############################################################################
# Git/Openpilot Status Functions
###############################################################################

display_disk_space_status_short() {
    print_info "│ Disk Space:"
    local root_usage data_usage

    # Safely get root usage
    root_usage=$(df -h / 2>/dev/null | awk 'NR==2 {printf "Used: %s/%s (%s)", $3, $2, $5}' || echo "Unknown")

    # Safely get data usage
    data_usage=$(df -h /data 2>/dev/null | awk 'NR==2 {printf "Used: %s/%s (%s)", $3, $2, $5}' || echo "Unknown")

    echo "│ ├─ (/):     ${root_usage}"
    echo "│ └─ (/data): ${data_usage}"
}

###############################################################################
# Storage Management Functions
###############################################################################

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
