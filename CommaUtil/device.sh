#!/bin/bash
###############################################################################
# device.sh - Device Management Functions for CommaUtility
#
# Version: DEVICE_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script manages device status, controls, and statistics.
###############################################################################
readonly DEVICE_SCRIPT_VERSION="3.0.0"
readonly DEVICE_SCRIPT_MODIFIED="2025-02-10"

###############################################################################
# Boot & Logo Update Functions
###############################################################################

# Define paths:
readonly BOOT_IMG="/usr/comma/bg.jpg"
readonly LOGO_IMG="/data/openpilot/selfdrive/assets/img_spinner_comma.png"

readonly BLUEPILOT_BOOT_IMG="/data/openpilot/selfdrive/assets/img_bluepilot_boot.jpg"
readonly BLUEPILOT_LOGO_IMG="/data/openpilot/selfdrive/assets/img_bluepilot_logo.png"

readonly BOOT_IMG_BKP="${BOOT_IMG}.backup"
readonly LOGO_IMG_BKP="${LOGO_IMG}.backup"

update_boot_and_logo() {
    print_info "Updating boot and logo images..."
    mount_partition_rw "/"

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
    mount_partition_ro "/"
    pause_for_user
}

restore_boot_and_logo() {
    mount_partition_rw "/"

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
    mount_partition_ro "/"
    pause_for_user
}

toggle_boot_logo() {
    clear
    echo "┌───────────────────────────────────────────────"
    echo "│ Boot Icon and Logo Update/Restore Utility"
    echo "└───────────────────────────────────────────────"

    # Check if the original files exist
    if [ ! -f "$BOOT_IMG" ]; then
        print_error "Boot image file ($BOOT_IMG) is missing; cannot proceed."
        pause_for_user
        return 1
    fi
    if [ ! -f "$LOGO_IMG" ]; then
        print_error "Logo image file ($LOGO_IMG) is missing; cannot proceed."
        pause_for_user
        return 1
    fi

    # If backup files exist, offer restoration; otherwise, offer update.
    if [ -f "$BOOT_IMG_BKP" ] && [ -f "$LOGO_IMG_BKP" ]; then
        echo "No Boot image or logo image backup exists."
        read -p "Do you want to restore the original boot image and logo image? (y/N): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            restore_boot_and_logo
        else
            print_info "│ Restore cancelled."
            pause_for_user
        fi
    else
        echo "No Boot image or logo image backup files found."
        read -p "Do you want to update boot and logo images with BluePilot files? (y/N): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            update_boot_and_logo
        else
            print_info "│ Update cancelled."
            pause_for_user
        fi
    fi
}

###############################################################################
# System Status & Logs
###############################################################################

display_os_info_short() {
    print_info "│ OS Information:"
    local agnos_version
    agnos_version=$(cat /VERSION 2>/dev/null)
    build_time=$(awk 'NR==2' /BUILD 2>/dev/null)
    if [ -n "$agnos_version" ]; then
        echo "│ ├─ AGNOS: v$agnos_version ($build_time)"
    else
        echo "│ ├─ AGNOS: Unknown"
    fi

    echo "│ ├─ Dongle ID: $(get_dongle_id)"
    echo "│ ├─ Serial Number: $(get_serial_number)"
    echo "│ ├─ WiFi MAC Address: $(get_wifi_mac_address)"
    echo "│ ├─ WiFi SSID: $(get_wifi_ssid)"

    if [ -f "$BOOT_IMG_BKP" ] && [ -f "$LOGO_IMG_BKP" ]; then
        echo -e "│ └─ Custom Boot/Logo: ${GREEN}Yes${NC}"
    else
        echo -e "│ └─ Custom Boot/Logo: No"
    fi
}

display_general_status() {
    local agnos_version
    local build_time
    agnos_version=$(cat /VERSION 2>/dev/null)
    build_time=$(awk 'NR==2' /BUILD 2>/dev/null)
    echo "┌───────────────────────────────────────────────────┐"
    echo "│                    Other Items                    │"
    echo "├───────────────────────────────────────────────────┘"
    echo "│ AGNOS: v$agnos_version ($build_time)"

    # Check is the device has custom boot and logo images
    if [ -f "$BOOT_IMG_BKP" ] && [ -f "$LOGO_IMG_BKP" ]; then
        echo -e "│ Custom Boot/Logo Images: ${GREEN}Active${NC}"
    else
        echo -e "│ Custom Boot/Logo Images: Inactive"
    fi
    echo "├────────────────────────────────────────────────────"
}

display_logs() {
    clear
    echo "┌────────────────────────────────────────┐"
    echo "│                Log Files               │"
    echo "├────────────────────────────────────────┘"
    local log_files
    log_files=(/data/log/*)
    local i
    for i in "${!log_files[@]}"; do
        echo "│ $((i + 1)). ${log_files[$i]}"
    done
    echo "│ Q. Back to previous menu"
    echo "├────────────────────────────────────────┘"

    read -p "Enter the number of the log file to view or [Q] to go back: " log_choice

    if [[ $log_choice =~ ^[0-9]+$ ]] && ((log_choice > 0 && log_choice <= ${#log_files[@]})); then
        local log_file="${log_files[$((log_choice - 1))]}"
        echo "│ Displaying contents of $log_file:"
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

turn_off_screen() {
    print_info "Turning off the screen..."
    echo 1 >/sys/class/backlight/panel0-backlight/bl_power
}

turn_on_screen() {
    print_info "Turning on the screen..."
    echo 0 >/sys/class/backlight/panel0-backlight/bl_power
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
# Device Information Functions
###############################################################################

get_dongle_id() {
    # print_info "Getting dongle ID..."
    local dongle_id
    dongle_id=$(cat /data/params/d/DongleId 2>/dev/null)
    if [ -z "$dongle_id" ]; then
        return "Unknown"
    fi
    echo "$dongle_id"
}

get_serial_number() {
    # print_info "Getting serial number..."
    local serial_number
    serial_number=$(cat /data/params/d/HardwareSerial 2>/dev/null)
    if [ -z "$serial_number" ]; then
        return "Unknown"
    fi
    echo "$serial_number"
}

get_is_onroad() {
    local is_onroad = false
    local is_onroad_file="/data/params/d/IsOnroad"
    if [ -f "$is_onroad_file" ]; then
        is_onroad=$(cat "$is_onroad_file" 2>/dev/null)
        if [ "$is_onroad" = "1" ]; then
            return 1
        else
            return 0
        fi
    else
        return 0
    fi
}

get_wifi_mac_address() {
    # print_info "Getting WiFi MAC address..."
    local wifi_mac_address
    wifi_mac_address=$(cat /sys/class/net/wlan0/address 2>/dev/null)
    echo "$wifi_mac_address"
}

get_wifi_ssid() {
    # print_info "Getting WiFi SSID..."
    local wifi_ssid
    wifi_ssid=$(nmcli -t -f DEVICE,CONNECTION dev status | grep wifi | while IFS=: read -r dev conn; do
        if [ "$conn" != "--" ]; then
            echo "$conn"
            break
        fi
    done)
    echo "$wifi_ssid"
}

manage_wifi_networks() {
    clear
    echo "┌───────────────────────────────────────────────┐"
    echo "│            WiFi Network Management            │"
    echo "├───────────────────────────────────────────────┘"

    # Check if nmcli is available
    if ! command -v nmcli >/dev/null 2>&1; then
        print_error "Network Manager (nmcli) not found."
        pause_for_user
        return 1
    fi

    # Show current connection status
    echo "│ Current Connection:"
    nmcli -t -f DEVICE,CONNECTION dev status | grep wifi | while IFS=: read -r dev conn; do
        if [ "$conn" != "--" ]; then
            echo "│ Connected to: $conn"
        else
            echo "│ Not connected"
        fi
    done
    echo "│"

    # Scan for networks
    echo -ne "│ Scanning for networks...\r\033[K"
    nmcli dev wifi rescan
    echo "│ Available Networks:"
    nmcli -f SSID,SIGNAL,SECURITY dev wifi list | sort -k2 -nr | head -n 10

    echo "│"
    echo "│ Options:"
    echo "│ 1. Connect to network"
    echo "│ 2. Disconnect current network"
    echo "│ 3. Enable WiFi"
    echo "│ 4. Disable WiFi"
    echo "│ Q. Back to Device Controls"

    read -p "Enter your choice: " wifi_choice
    case $wifi_choice in
    1)
        read -p "Enter SSID to connect to: " ssid
        read -s -p "Enter password: " password
        echo ""
        nmcli dev wifi connect "$ssid" password "$password"
        ;;
    2)
        nmcli dev disconnect wlan0
        ;;
    3)
        nmcli radio wifi on
        ;;
    4)
        nmcli radio wifi off
        ;;
    [qQ])
        return
        ;;
    *)
        print_error "Invalid choice."
        ;;
    esac
    pause_for_user
}

restart_cellular_radio() {
    clear
    print_info "Restarting cellular radio..."

    # Check if ModemManager is available
    if ! command -v mmcli >/dev/null 2>&1; then
        print_error "ModemManager not found."
        pause_for_user
        return 1
    fi

    # Get modem index
    local modem_index
    modem_index=$(mmcli -L | grep -o '[0-9]*' | head -1)

    if [ -n "$modem_index" ]; then
        print_info "Disabling modem..."
        mmcli -m "$modem_index" -d
        sleep 2
        print_info "Enabling modem..."
        mmcli -m "$modem_index" -e
        print_success "Cellular radio restart completed."
    else
        print_error "No modem found."
    fi
    pause_for_user
}

manage_bluetooth() {
    clear
    echo "┌───────────────────────────────────────────────┐"
    echo "│              Bluetooth Management             │"
    echo "├───────────────────────────────────────────────┘"

    # Check if bluetoothctl is available
    if ! command -v bluetoothctl >/dev/null 2>&1; then
        print_error "Bluetooth control (bluetoothctl) not found."
        pause_for_user
        return 1
    fi

    echo "│ Current Status:"
    bluetoothctl show | grep "Powered:"

    echo "│"
    echo "│ Options:"
    echo "│ 1. Turn Bluetooth On"
    echo "│ 2. Turn Bluetooth Off"
    echo "│ 3. Show Paired Devices"
    echo "│ 4. Scan for Devices"
    echo "│ Q. Back to Device Controls"

    read -p "Enter your choice: " bt_choice
    case $bt_choice in
    1)
        bluetoothctl power on
        ;;
    2)
        bluetoothctl power off
        ;;
    3)
        bluetoothctl paired-devices
        ;;
    4)
        print_info "Scanning for devices (10 seconds)..."
        bluetoothctl scan on &
        sleep 10
        bluetoothctl scan off
        ;;
    [qQ])
        return
        ;;
    *)
        print_error "Invalid choice."
        ;;
    esac
    pause_for_user
}

device_controls_menu() {
    while true; do
        clear
        echo "┌───────────────────────────────────────────────┐"
        echo "│                 Device Controls               │"
        echo "├───────────────────────────────────────────────┘"
        echo "│ 1. WiFi Network Management"
        echo "│ 2. Restart Cellular Radio"
        echo "│ 3. Bluetooth Management"
        echo "│ 4. Turn Screen Off"
        echo "│ 5. Turn Screen On"
        echo "│ Q. Back to Main Menu"

        read -p "Enter your choice: " control_choice
        case $control_choice in
        1) manage_wifi_networks ;;
        2) restart_cellular_radio ;;
        3) manage_bluetooth ;;
        4) turn_off_screen ;;
        5) turn_on_screen ;;
        [qQ]) break ;;
        *) print_error "Invalid choice." ;;
        esac
    done
}

###############################################################################
# System Statistics Functions
###############################################################################

get_cpu_stats() {
    # Get CPU usage and top process
    local cpu_usage
    local top_process

    # Get overall CPU usage from 'top' (first cpu line, second field)
    cpu_usage=$(top -bn1 | awk '/^%Cpu/{print $2}')

    # Get top process by CPU
    top_process=$(ps -eo cmd,%cpu --sort=-%cpu | head -2 | tail -1 | awk '{print $1 " (" $2 "%)"}')

    echo "CPU Usage: ${cpu_usage}% | Top: ${top_process}"
}

get_memory_stats() {
    # Get memory usage
    local total
    local used
    local percentage

    total=$(free -m | awk 'NR==2 {print $2}')
    used=$(free -m | awk 'NR==2 {print $3}')
    percentage=$(free | awk 'NR==2 {printf "%.1f", $3*100/$2}')

    echo "Memory: ${used}MB/${total}MB (${percentage}%)"
}

get_cellular_stats() {
    # Get cellular information using mmcli if ModemManager is available
    if command -v mmcli >/dev/null 2>&1; then
        local modem_index
        local carrier
        local signal
        local roaming
        local tech

        # Get the first modem index
        modem_index=$(mmcli -L | grep -o '[0-9]*' | head -1)

        if [ -n "$modem_index" ]; then
            # Get carrier name
            carrier=$(mmcli -m "$modem_index" | grep "operator name" | awk -F': ' '{print $2}')

            # Get signal strength
            signal=$(mmcli -m "$modem_index" | grep "signal quality" | awk -F': ' '{print $2}' | awk '{print $1}')

            # Get network tech
            tech=$(mmcli -m "$modem_index" | grep "access tech" | awk -F': ' '{print $2}')

            # Get roaming status
            roaming=$(mmcli -m "$modem_index" | grep "state" | grep -i "roaming" >/dev/null && echo "Roaming" || echo "Home")

            echo "${carrier:-Unknown} | ${tech:-Unknown} | Signal: ${signal:-0}% | ${roaming}"
        else
            echo "No modem detected"
        fi
    else
        echo "ModemManager not available"
    fi
}

system_statistics_menu() {
    while true; do
        clear
        echo "┌───────────────────────────────────────────────┐"
        echo "│               System Statistics               │"
        echo "├───────────────────────────────────────────────┘"
        echo "│ CPU Usage:"
        echo "│ ├─ $(get_cpu_stats)"
        echo "│ ├─ Top Processes by CPU:"
        ps -eo cmd,%cpu --sort=-%cpu | head -4 | tail -3 |
            awk '{printf "│  %-40s %5.1f%%\n", substr($1,1,40), $NF}'
        echo "│"

        echo "│ Memory Usage:"
        echo "│ ├─ $(get_memory_stats)"
        echo "│ ├─ Memory Details:"
        free -h | awk 'NR==2{printf "│  %-8s %8s %8s %8s %8s\n", "", "total", "used", "free", "cache"}'
        free -h | awk 'NR==2{printf "│  %-8s %8s %8s %8s %8s\n", "Mem:", $2, $3, $4, $6}'
        free -h | awk 'NR==3{printf "│  %-8s %8s %8s %8s\n", "Swap:", $2, $3, $4}'
        echo "│"

        echo "│ Cellular Connection:"
        echo "│ ├─ $(get_cellular_stats)"
        if command -v mmcli >/dev/null 2>&1; then
            local modem_index
            modem_index=$(mmcli -L | grep -o '[0-9]*' | head -1)
            if [ -n "$modem_index" ]; then
                echo "│ ├─ Additional Details:"
                mmcli -m "$modem_index" | grep -E "operator name|signal quality|state|access tech|power state|packet service state" |
                    sed 's/^/│  /' | sed 's/|//'
            fi
        fi
        echo "│"

        echo "│ Disk Usage:"
        echo "│ ├─ Filesystem Details:"
        df -h | grep -E '^/dev|Filesystem' |
            awk '{printf "│  %-15s %8s %8s %8s %8s\n", substr($1,length($1)>15?length($1)-15:0), $2, $3, $4, $5}'
        echo "│"

        echo "├────────────────────────────────────────────────"
        echo "│ R. Refresh Statistics"
        echo "│ Q. Back to Main Menu"

        read -t 30 -p "Enter your choice (auto-refresh in 30s): " stats_choice

        case $stats_choice in
        [rR]) continue ;;
        [qQ]) break ;;
        "") continue ;; # Timeout occurred, refresh
        *) print_error "Invalid choice." ;;
        esac
    done
}
