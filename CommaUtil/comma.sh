#!/bin/bash

###############################################################################
# Global Variables
###############################################################################
readonly COMMA_SCRIPT_VERSION="3.0.2"
readonly COMMA_SCRIPT_MODIFIED="2025-02-08"

###############################################################################
# Boot & Logo Update Functions
###############################################################################

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
# Comma Log Functions
###############################################################################

display_logs() {
    clear
    echo "+---------------------------------+"
    echo "│            Log Files            │"
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
