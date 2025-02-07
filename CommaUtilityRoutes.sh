#!/bin/bash
###############################################################################
# CommaUtilityRoutes.sh
#
# Version: 1.0.0
# Last Modified: 2025-02-06
#
# Description:
#   This script handles all route-related operations including viewing,
#   concatenating, transferring, and syncing routes. It mimics the update
#   logic of the main CommaUtility script and includes an option to return to
#   the main menu.
#
###############################################################################

# Colors and helper functions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

print_info() { echo -e "$1"; }
print_error() { echo -e "${RED}$1${NC}"; }
print_success() { echo -e "${GREEN}$1${NC}"; }
pause_for_user() { echo -en "${NC}" && read -p "Press enter to continue..."; }

# Route-related global variables (adjust as needed)
readonly ROUTES_DIR="/data/media/0/realdata"
readonly ROUTES_DIR_BACKUP="/data/media/0/realdata_backup"
readonly TMP_DIR="${BUILD_DIR}-build-tmp"
readonly CONCAT_DIR="/data/tmp/concat_tmp"
readonly CONFIG_DIR="/data/commautil"
readonly NETWORK_CONFIG="$CONFIG_DIR/network_locations.json"
readonly CREDENTIALS_DIR="$CONFIG_DIR/credentials"
readonly TRANSFER_STATE_DIR="$CONFIG_DIR/transfer_state"

###############################################################################
# Update Logic for Routes Script
###############################################################################
readonly ROUTES_SCRIPT_VERSION="1.0.0"
readonly ROUTES_SCRIPT_MODIFIED="2025-02-06"

check_for_routes_updates() {
    print_info "Checking for CommaUtility_Routes.sh updates..."
    local script_path
    script_path=$(realpath "$0")
    local tmp_file="${script_path}.tmp"
    # Download the latest version from GitHub (adjust URL as needed)
    if wget --timeout=10 -q -O "$tmp_file" "https://raw.githubusercontent.com/tonesto7/op-utilities/main/CommaUtility_Routes.sh"; then
        local latest_version
        latest_version=$(grep "^readonly ROUTES_SCRIPT_VERSION=" "$tmp_file" | cut -d'"' -f2)
        if [ -n "$latest_version" ]; then
            if [ "$latest_version" != "$ROUTES_SCRIPT_VERSION" ]; then
                print_info "New version ($latest_version) available. Updating..."
                mv "$tmp_file" "$script_path"
                chmod +x "$script_path"
                print_success "Updated to version $latest_version. Restarting..."
                exec "$script_path"
            else
                rm -f "$tmp_file"
                print_info "Routes script is up to date (v$ROUTES_SCRIPT_VERSION)."
            fi
        else
            print_error "Unable to determine latest version."
            rm -f "$tmp_file"
        fi
    else
        print_error "Unable to check for updates."
    fi
}

# Run update check at startup
check_for_routes_updates

###############################################################################
# Route Management Functions
###############################################################################

format_route_timestamp() {
    local route_dir="$1"
    # Find the first segment of this route
    local first_segment=$(find "$ROUTES_DIR" -maxdepth 1 -name "${route_dir}--*" | sort | head -1)
    if [ -d "$first_segment" ]; then
        local timestamp=$(stat -c %y "$first_segment" | cut -d. -f1)
        echo "$timestamp"
    else
        echo "Unknown"
    fi
}

get_route_duration() {
    local route_base="$1"
    local segments=0
    local total_duration=0

    # Count segments using find
    segments=$(find "$ROUTES_DIR" -maxdepth 1 -type d -name "${route_base}--*" | wc -l)
    total_duration=$((segments * 60))

    printf "%02d:%02d:%02d" $((total_duration / 3600)) $((total_duration % 3600 / 60)) $((total_duration % 60))
}

get_segment_count() {
    local route_base="$1"
    find "$ROUTES_DIR" -maxdepth 1 -type d -name "${route_base}--*" | wc -l
}

concat_route_segments() {
    local route_base="$1"
    local concat_type="$2" # rlog, qlog, or video
    local output_dir="$3"  # Will now include full route ID path
    local keep_originals="$4"

    mkdir -p "$CONCAT_DIR"
    local success=true
    local total_segments
    total_segments=$(get_segment_count "$route_base")
    local current_segment=0

    case "$concat_type" in
    rlog)
        local output_file="$output_dir/rlog" # Simplified name without _complete or extension
        : >"$output_file"                    # Clear/create output file

        for segment in "$ROUTES_DIR/$route_base"--*; do
            if [ -f "$segment/rlog" ]; then
                current_segment=$((current_segment + 1))
                echo -ne "Processing rlog segment $current_segment/$total_segments\r"
                {
                    echo "=== Segment ${segment##*--} ==="
                    cat "$segment/rlog"
                    echo ""
                } >>"$output_file"
            fi
        done
        # Get the size of the concatenated file
        local file_size
        file_size=$(du -h "$output_file" | cut -f1)
        print_success "RLog concatenation completed on ($current_segment/$total_segments segments) [$file_size]"
        ;;

    qlog)
        local output_file="$output_dir/qlog" # Simplified name without _complete or extension
        : >"$output_file"

        for segment in "$ROUTES_DIR/$route_base"--*; do
            if [ -f "$segment/qlog" ]; then
                current_segment=$((current_segment + 1))
                echo -ne "Processing qlog segment $current_segment/$total_segments\r"
                cat "$segment/qlog" >>"$output_file"
            fi
        done
        # Get the size of the concatenated file
        local file_size
        file_size=$(du -h "$output_file" | cut -f1)
        print_success "QLog concatenation completed on ($current_segment/$total_segments segments) [$file_size]"
        ;;

    video)
        if ! command -v ffmpeg >/dev/null 2>&1; then
            print_error "ffmpeg not found. Cannot concatenate video files."
            return 1
        fi

        local cameras=("dcamera" "ecamera" "fcamera" "qcamera")
        local extensions=("hevc" "hevc" "hevc" "ts")

        for i in "${!cameras[@]}"; do
            local camera="${cameras[$i]}"
            local ext="${extensions[$i]}"
            local output_file="$output_dir/${camera}.${ext}" # Simplified name without _complete

            # Remove any pre-existing output file to avoid collision
            if [ -f "$output_file" ]; then
                print_info "DEBUG: Removing existing output file: $output_file"
                rm -f "$output_file"
            fi

            local concat_list="$CONCAT_DIR/${camera}_concat_list.txt"
            : >"$concat_list"

            # Count total segments for this camera
            local total_camera_segments=0
            for segment in "$ROUTES_DIR/$route_base"--*; do
                if [ -f "$segment/$camera.$ext" ]; then
                    total_camera_segments=$((total_camera_segments + 1))
                fi
            done

            if [ "$total_camera_segments" -eq 0 ]; then
                print_info "No segments found for $camera, skipping concatenation."
                continue
            fi

            local cam_segment=0
            # Build the concat list while updating progress on the same line
            for segment in "$ROUTES_DIR/$route_base"--*; do
                if [ -f "$segment/$camera.$ext" ]; then
                    cam_segment=$((cam_segment + 1))
                    printf "\rProcessing %s segment %d/%d" "$camera" "$cam_segment" "$total_camera_segments"
                    echo "file '$segment/$camera.$ext'" >>"$concat_list"
                fi
            done
            # Clear the processing line
            printf "\r\033[K"

            print_info "Concatenating $camera videos..."

            # Only proceed if the concat list is non-empty
            if [ ! -s "$concat_list" ]; then
                print_error "No video segments found for $camera, skipping."
                continue
            fi

            # Run ffmpeg and update progress on the same line
            ffmpeg -nostdin -y -f concat -safe 0 -i "$concat_list" -c copy -fflags +genpts "$output_file" -progress pipe:1 2>&1 |
                while read -r line; do
                    if [[ $line =~ time=([0-9:.]+) ]]; then
                        printf "\r\033[KProgress: %s" "${BASH_REMATCH[1]}"
                    fi
                done
            ret=${PIPESTATUS[0]}
            # Clear the ffmpeg progress line
            printf "\r\033[K"
            if [ $ret -ne 0 ]; then
                print_error "Failed to concatenate $camera videos"
                return 1
            fi

            # Get the size of the concatenated file
            local file_size
            file_size=$(du -h "$output_file" | cut -f1)
            print_success "$camera concatenation completed on ($total_camera_segments/$total_camera_segments segments) [$file_size]"
            rm -f "$concat_list"
        done
        ;;
    *)
        print_error "Invalid concatenation type"
        return 1
        ;;
    esac

    if [ "$keep_originals" = "false" ]; then
        read -p "Remove original segment files? (y/N): " remove_confirm
        if [[ "$remove_confirm" =~ ^[Yy]$ ]]; then
            for segment in "$ROUTES_DIR/$route_base"--*; do
                rm -f "$segment/$concat_type"
            done
            print_success "Original segment files removed"
        fi
    fi

    return 0
}

concat_route_menu() {
    local route_base="$1"
    local output_dir="$ROUTES_DIR/concatenated"
    mkdir -p "$output_dir"

    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "|            Concatenate Route Files           |"
        echo "+----------------------------------------------+"
        echo "Route: $route_base"
        echo ""
        echo "Select files to concatenate:"
        echo "1. RLog files"
        echo "2. QLog files"
        echo "3. Video files"
        echo "4. All files"
        echo "Q. Back"

        read -p "Enter your choice: " concat_choice
        case $concat_choice in
        1) concat_route_segments "$route_base" "rlog" "$output_dir" "true" ;;
        2) concat_route_segments "$route_base" "qlog" "$output_dir" "true" ;;
        3) concat_route_segments "$route_base" "video" "$output_dir" "true" ;;
        4)
            concat_route_segments "$route_base" "rlog" "$output_dir" "true"
            concat_route_segments "$route_base" "qlog" "$output_dir" "true"
            concat_route_segments "$route_base" "video" "$output_dir" "true"
            ;;
        [qQ]) return ;;
        *) print_error "Invalid choice." ;;
        esac
        pause_for_user
    done
}

# Encryption/decryption functions
encrypt_credentials() {
    local data="$1"
    local output="$2"
    openssl enc -aes-256-cbc -salt -pbkdf2 -in <(echo "$data") -out "$output" -pass file:/data/params/d/GithubSshKeys
}

decrypt_credentials() {
    local input="$1"
    openssl enc -d -aes-256-cbc -pbkdf2 -in "$input" -pass file:/data/params/d/GithubSshKeys
}

# Network location management
init_network_config() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CREDENTIALS_DIR"
    if [ ! -f "$NETWORK_CONFIG" ]; then
        echo '{"smb":[],"ssh":[]}' >"$NETWORK_CONFIG"
    fi
}

add_smb_location() {
    clear
    print_info "Add New SMB Share..."
    print_info "----------------------------------------"
    read -p "Server (IP/hostname): " server
    read -p "Share name: " share
    read -p "Path [Inside $server/$share] (optional): " path
    read -p "Username: (Will be encrypted): " username
    read -s -p "Password: (Will be encrypted): " password
    echo ""

    # Ensure the credentials directory exists
    mkdir -p "$CREDENTIALS_DIR"

    local cred_file="$CREDENTIALS_DIR/smb_${server}_${share}"
    encrypt_credentials "$password" "$cred_file"
    if [ $? -ne 0 ]; then
        print_error "Error encrypting credentials for SMB share."
        pause_for_user
        return 1
    fi

    local location
    location=$(jq -n \
        --arg server "$server" \
        --arg share "$share" \
        --arg path "$path" \
        --arg username "$username" \
        --arg cred_file "$cred_file" \
        '{server: $server, share: $share, path: $path, username: $username, credential_file: $cred_file}')

    local temp_file="/tmp/network_config.json"
    if ! jq ".smb += [$location]" "$NETWORK_CONFIG" >"$temp_file"; then
        print_error "Error updating network configuration."
        pause_for_user
        return 1
    fi
    mv "$temp_file" "$NETWORK_CONFIG"
    print_success "SMB share added successfully."
    pause_for_user
}

add_ssh_location() {
    clear
    print_info "Add New SSH Location..."
    print_info "----------------------------------------"
    read -p "Server (IP/hostname): " server
    read -p "Port [22]: " port
    port=${port:-22}
    read -p "Path: " path
    read -p "Username: " username
    echo "Authentication type:"
    echo "1. Password"
    echo "2. SSH Key"
    read -p "Select Authentication Type: " auth_choice

    # Ensure the credentials directory exists
    mkdir -p "$CREDENTIALS_DIR"

    local location
    if [ "$auth_choice" = "1" ]; then
        read -s -p "Password: (Will be encrypted): " password
        echo ""
        local cred_file="$CREDENTIALS_DIR/ssh_${server}_${port}"
        encrypt_credentials "$password" "$cred_file"
        if [ $? -ne 0 ]; then
            print_error "Error encrypting credentials for SSH location."
            pause_for_user
            return 1
        fi
        location=$(jq -n \
            --arg server "$server" \
            --arg port "$port" \
            --arg path "$path" \
            --arg username "$username" \
            --arg cred_file "$cred_file" \
            --arg auth_type "password" \
            '{server: $server, port: $port, path: $path, username: $username, credential_file: $cred_file, auth_type: $auth_type}')
    elif [ "$auth_choice" = "2" ]; then
        read -p "SSH Key path: " key_path
        location=$(jq -n \
            --arg server "$server" \
            --arg port "$port" \
            --arg path "$path" \
            --arg username "$username" \
            --arg key_path "$key_path" \
            --arg auth_type "key" \
            '{server: $server, port: $port, path: $path, username: $username, key_path: $key_path, auth_type: $auth_type}')
    else
        print_error "Invalid authentication type."
        pause_for_user
        return 1
    fi

    local temp_file="/tmp/network_config.json"
    if ! jq ".ssh += [$location]" "$NETWORK_CONFIG" >"$temp_file"; then
        print_error "Error updating network configuration."
        pause_for_user
        return 1
    fi
    mv "$temp_file" "$NETWORK_CONFIG"
    print_success "SSH location added successfully."
    pause_for_user
}

test_smb_connection() {
    # clear
    # print_info "Testing SMB Connection(s)..."
    local location="$1"
    local server=$(echo "$location" | jq -r .server)
    local share=$(echo "$location" | jq -r .share)
    local username=$(echo "$location" | jq -r .username)
    local cred_file=$(echo "$location" | jq -r .credential_file)
    local password=$(decrypt_credentials "$cred_file")
    local mount_point="/tmp/test_smb_mount"

    mkdir -p "$mount_point"
    # Attempt to mount the share read-only
    local output
    output=$(smbclient "//${server}/${share}" -U "${username}%${password}" -c 'ls' 2>&1)
    if [ $? -eq 0 ]; then
        echo "Valid"
        return 0
    else
        echo "$output"
        return 1
    fi
}

test_ssh_connection() {
    # clear
    # print_info "Testing SSH Connection(s)..."
    local location="$1"
    local server=$(echo "$location" | jq -r .server)
    local port=$(echo "$location" | jq -r .port)
    local username=$(echo "$location" | jq -r .username)
    local auth_type=$(echo "$location" | jq -r .auth_type)

    local ssh_cmd="ssh -p $port -o BatchMode=yes -o ConnectTimeout=5"
    if [ "$auth_type" = "password" ]; then
        cred_file=$(echo "$location" | jq -r .credential_file)
        password=$(decrypt_credentials "$cred_file")
        output=$(sshpass -p "$password" $ssh_cmd "$username@$server" 'exit' 2>&1)
        if [ $? -eq 0 ]; then
            echo "Valid"
            return 0
        else
            echo "$output"
            return 1
        fi
    else
        key_path=$(echo "$location" | jq -r .key_path)
        output=$($ssh_cmd -i "$key_path" "$username@$server" 'exit' 2>&1)
        if [ $? -eq 0 ]; then
            echo "Valid"
            return 0
        else
            echo "$output"
            return 1
        fi
    fi
}

remove_network_location() {
    clear
    print_info "----------------------------------------"
    print_info "| Remove a Network Location..."
    print_info "----------------------------------------"
    echo "Select location to remove:"
    local locations=()
    local i=1
    while IFS= read -r location; do
        locations+=("smb|$location")
        echo "$i. SMB: $(echo "$location" | jq -r '.server + "/" + .share')"
        i=$((i + 1))
    done < <(jq -c '.smb[]' "$NETWORK_CONFIG" 2>/dev/null)
    while IFS= read -r location; do
        locations+=("ssh|$location")
        echo "$i. SSH: $(echo "$location" | jq -r '.server + ":" + .port')"
        i=$((i + 1))
    done < <(jq -c '.ssh[]' "$NETWORK_CONFIG" 2>/dev/null)
    # Add a back menu option
    echo "B. Go Back"
    echo "----------------------------------------"
    read -p "Enter the Location Number to remove: " remove_num

    if [ -n "$remove_num" ] && [ "$remove_num" -le "${#locations[@]}" ]; then
        local type idx temp_file
        type=$(echo "${locations[$((remove_num - 1))]}" | cut -d'|' -f1)
        idx=$((remove_num - 1))
        temp_file="/tmp/network_config.json"
        if [ "$type" = "smb" ]; then
            jq "del(.smb[$idx])" "$NETWORK_CONFIG" >"$temp_file"
        else
            jq "del(.ssh[$idx])" "$NETWORK_CONFIG" >"$temp_file"
        fi
        mv "$temp_file" "$NETWORK_CONFIG"
        print_success "Location ($type) [$(echo "${locations[$((remove_num - 1))]}" | cut -d'|' -f2)] removed."
    elif [ "$remove_num" = "b" -o "$remove_num" = "B" ]; then
        return
    else
        print_error "Invalid selection."
    fi
    pause_for_user
}

manage_network_locations_menu() {
    if ! command -v smbclient >/dev/null 2>&1; then
        print_error "smbclient not found. Installing..."
        sudo apt update && sudo apt install -y smbclient
    fi

    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "|         Network Location Management          |"
        echo "+----------------------------------------------+"

        # Get counts and default to 0 if empty.
        local smb_count ssh_count
        smb_count=$(jq '.smb | length' "$NETWORK_CONFIG" 2>/dev/null)
        ssh_count=$(jq '.ssh | length' "$NETWORK_CONFIG" 2>/dev/null)
        declare -a smb_status_list ssh_status_list

        # Test all SMB connections and store the full status message:
        for ((i = 0; i < smb_count; i++)); do
            local connection status
            connection=$(jq -c ".smb[$i]" "$NETWORK_CONFIG")
            status=$(test_smb_connection "$connection")
            smb_status_list[$i]="$status"
        done

        # Test all SSH connections similarly:
        for ((i = 0; i < ssh_count; i++)); do
            local connection status
            connection=$(jq -c ".ssh[$i]" "$NETWORK_CONFIG")
            status=$(test_ssh_connection "$connection")
            ssh_status_list[$i]="$status"
        done

        echo "SMB Shares:"
        if [ "$smb_count" -gt 0 ]; then
            for ((i = 0; i < smb_count; i++)); do
                local connection server share username status
                connection=$(jq -c ".smb[$i]" "$NETWORK_CONFIG")
                server=$(echo "$connection" | jq -r .server)
                share=$(echo "$connection" | jq -r .share)
                username=$(echo "$connection" | jq -r .username)
                status=${smb_status_list[$i]}
                if [ "$status" = "Valid" ]; then
                    echo -e "  - ${GREEN}${server}/${share} (${username}) - Valid${NC}"
                else
                    echo -e "  - ${RED}${server}/${share} (${username}) - $status${NC}"
                fi
            done
        else
            echo "  None saved."
        fi

        echo -e "\nSSH Locations:"
        if [ "$ssh_count" -gt 0 ]; then
            for ((i = 0; i < ssh_count; i++)); do
                local connection server port username path status
                connection=$(jq -c ".ssh[$i]" "$NETWORK_CONFIG")
                server=$(echo "$connection" | jq -r .server)
                port=$(echo "$connection" | jq -r .port)
                username=$(echo "$connection" | jq -r .username)
                path=$(echo "$connection" | jq -r .path)
                status=${ssh_status_list[$i]}
                if [ "$status" = "Valid" ]; then
                    echo -e "  - ${GREEN}${server}:${port} ${path} (${username}) - Valid${NC}"
                else
                    echo -e "  - ${RED}${server}:${port} ${path} (${username}) - $status${NC}"
                fi
            done
        else
            echo "  None saved."
        fi

        echo -e "\nOptions:"
        echo "1. Add a New SMB Share"
        echo "2. Add a New SSH Location"
        if [ "$smb_count" -gt 0 ] || [ "$ssh_count" -gt 0 ]; then
            echo "3. Re-test All Connections"
            echo "4. Remove Location"
        fi
        echo "Q. Back"
        print_info "----------------------------------------"
        read -p "Make a selection: " choice
        case $choice in
        1) add_smb_location ;;
        2) add_ssh_location ;;
        3)
            # Re-test all connections and update statuses
            for ((i = 0; i < smb_count; i++)); do
                local connection
                connection=$(jq -c ".smb[$i]" "$NETWORK_CONFIG")
                if test_smb_connection "$connection"; then
                    smb_status_list[$i]="Connected"
                else
                    smb_status_list[$i]="Failed"
                fi
            done
            for ((i = 0; i < ssh_count; i++)); do
                local connection
                connection=$(jq -c ".ssh[$i]" "$NETWORK_CONFIG")
                if test_ssh_connection "$connection"; then
                    ssh_status_list[$i]="Connected"
                else
                    ssh_status_list[$i]="Failed"
                fi
            done
            print_success "Connections re-tested."
            pause_for_user
            ;;
        4)
            remove_network_location
            ;;
        [qQ]) return ;;

        *)
            print_error "Invalid choice."
            pause_for_user
            ;;

        esac
    done
}

select_network_location() {
    {
        echo "-----------------------------------------------"
        echo "| Select a Network Location..."
        echo "+----------------------------------------------"
        echo "| Available locations:"
    } >&2

    local locations=()
    local i=1

    # Process SMB locations.
    while IFS= read -r loc; do
        locations+=("smb|$loc")
        local server share
        server=$(echo "$loc" | jq -r '.server')
        share=$(echo "$loc" | jq -r '.share')
        {
            echo "| $i. SMB: ${server}/${share}"
        } >&2
        i=$((i + 1))
    done < <(jq -c '.smb[]' "$NETWORK_CONFIG")

    # Process SSH locations.
    while IFS= read -r loc; do
        locations+=("ssh|$loc")
        local server port
        server=$(echo "$loc" | jq -r '.server')
        port=$(echo "$loc" | jq -r '.port')
        {
            echo "| $i. SSH: ${server}:${port}"
        } >&2
        i=$((i + 1))
    done < <(jq -c '.ssh[]' "$NETWORK_CONFIG")

    {
        echo "+----------------------------------------------"
        echo "| N. New Location"
        echo "| B. Go Back"
        echo "+----------------------------------------------"
    } >&2

    # Read from the terminal so that our stdout remains clean.
    read -p "Select location (or 'n' for new): " choice </dev/tty

    if [ "$choice" = "n" ] || [ "$choice" = "N" ]; then
        manage_network_locations_menu
        return 1
    elif [ "$choice" = "b" ] || [ "$choice" = "B" ]; then
        return 1
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#locations[@]}" ]; then
        IFS='|' read -r type location <<<"${locations[$((choice - 1))]}"
        # Output the selection (e.g. "smb <json>")
        echo "$type $location"
        return 0
    fi

    return 1
}

###############################################################################
# Progress tracking function: monitors a file’s size until it reaches
# an expected size (the estimate of uncompressed input). Adjust as needed.
###############################################################################
track_transfer_progress() {
    local file="$1"
    local expected_size="$2" # expected size in bytes
    local start_time=$(date +%s)
    while true; do
        if [ ! -f "$file" ]; then
            sleep 1
            continue
        fi
        local current_size
        current_size=$(stat -c %s "$file" 2>/dev/null || echo 0)
        local progress=$((current_size * 100 / expected_size))
        local elapsed=$(($(date +%s) - start_time))
        local speed=$((elapsed > 0 ? current_size / elapsed : 0))
        printf "\rProgress: %3d%% | %s/s" "$progress" "$(numfmt --to=iec-i --suffix=B/s $speed)"
        # When the file size reaches or exceeds our estimate, assume done.
        if [ "$current_size" -ge "$expected_size" ]; then
            break
        fi
        sleep 1
    done
    echo
}

###############################################################################
# Unified transfer_route() with progress tracking, trap for interruptions,
# remote transfer (SMB/SSH), and SHA-256 verification.
###############################################################################
transfer_route() {
    local route_base="$1" # For example, "00000084"
    local location="$2"   # JSON string from select_network_location
    local type="$3"       # "smb" or "ssh"

    # Calculate full_route_id first
    local sample_dir full_route_id
    sample_dir=$(find "$ROUTES_DIR" -maxdepth 1 -type d -name "${route_base}--*" | head -n 1)
    if [ -z "$sample_dir" ]; then
        print_error "No route segments found for route $route_base."
        return 1
    fi
    full_route_id=$(basename "$sample_dir")
    full_route_id=$(echo "$full_route_id" | sed -E 's/--[^-]+$//')

    # Set up temp and output directories
    local temp_dir="/tmp/route_transfer"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"

    # Set the output directory to include the full route ID
    local output_dir="$ROUTES_DIR/concatenated/${full_route_id}"
    mkdir -p "$output_dir"

    # Concatenate all file types
    print_info "Concatenating RLog segments..."
    concat_route_segments "$route_base" "rlog" "$output_dir" "true"
    print_info "Concatenating QLog segments..."
    concat_route_segments "$route_base" "qlog" "$output_dir" "true"
    print_info "Concatenating Video segments..."
    concat_route_segments "$route_base" "video" "$output_dir" "true"

    # Build array of files to transfer with proper names
    local files_to_transfer=()
    local rlog_file="$output_dir/rlog"
    local qlog_file="$output_dir/qlog"
    [ -f "$rlog_file" ] && files_to_transfer+=("$rlog_file")
    [ -f "$qlog_file" ] && files_to_transfer+=("$qlog_file")

    local cameras=("dcamera" "ecamera" "fcamera" "qcamera")
    local extensions=("hevc" "hevc" "hevc" "ts")
    for i in "${!cameras[@]}"; do
        local video_file="$output_dir/${cameras[$i]}.${extensions[$i]}"
        [ -f "$video_file" ] && files_to_transfer+=("$video_file")
    done

    # Helper function to clean up concatenated files
    cleanup_concatenated_files() {
        rm -rf "$output_dir"
        print_info "Cleaned up temporary concatenated files."
    }

    # Transfer files based on type
    case "$type" in
    smb)
        local server share username cred_file password destination remote_path
        server=$(echo "$location" | jq -r .server)
        share=$(echo "$location" | jq -r .share)
        username=$(echo "$location" | jq -r .username)
        cred_file=$(echo "$location" | jq -r .credential_file)
        password=$(decrypt_credentials "$cred_file")
        destination=$(echo "$location" | jq -r .path)
        remote_path="${destination%/}/${full_route_id}"

        print_info "Transferring route segments... ($route_base) via SMB"
        # print_info "Server: $server"
        # print_info "Share: $share"
        # print_info "Username: $username"
        # print_info "Password: $password"
        # print_info "Destination: $destination"
        # print_info "Remote Path: $remote_path"
        # print_info "Files: $output_dir/*"

        # Create remote directory
        mkdir_output=$(smbclient "//${server}/${share}" -U "${username}%${password}" \
            -c "mkdir \"$remote_path\"" 2>&1)
        if echo "$mkdir_output" | grep -qi "NT_STATUS_OBJECT_NAME_COLLISION"; then
            print_info "Remote directory already exists: $remote_path"
        fi

        # Transfer each file
        local error_flag=0
        for f in "${files_to_transfer[@]}"; do
            local base_f=$(basename "$f")
            print_info "Checking $base_f..."

            # Get local file size using ls to match remote format
            local local_size
            local_size=$(ls -l "$f" | awk '{print $5}')
            echo "DEBUG: Parsed local_size: '$local_size'"

            local smb_ls_output
            smb_ls_output=$(smbclient "//${server}/${share}" -U "${username}%${password}" \
                -c "cd \"$remote_path\"; ls \"$base_f\"" 2>/dev/null)
            # echo "DEBUG: smbclient ls output for '$base_f':"
            # echo "$smb_ls_output"

            # Get remote file size using ls
            local remote_size
            # Filter for the exact file line and extract the size (adjust field if needed)
            remote_size=$(echo "$smb_ls_output" | awk '$1=="'"$base_f"'" {print $3}')
            echo "DEBUG: Parsed remote_size: '$remote_size'"

            if [ -n "$remote_size" ] && [[ "$remote_size" =~ ^[0-9]+$ ]]; then
                if [ "$local_size" -eq "$remote_size" ]; then
                    print_info "Skipping $base_f - already exists with same size (${remote_size} bytes)"
                    continue
                else
                    print_info "Size mismatch for $base_f (local: $local_size, remote: $remote_size) - will transfer"
                fi
            else
                print_info "File $base_f not found on remote - will transfer"
            fi

            # Transfer the file
            print_info "Transferring $base_f..."
            smb_output=$(smbclient "//${server}/${share}" -U "${username}%${password}" \
                -c "cd \"$remote_path\"; put \"$f\" \"$base_f\"" 2>/dev/null)

            if [ $? -eq 0 ]; then
                print_success "Transferred $base_f"
            else
                print_error "Failed to transfer file $base_f via SMB: $smb_output"
                error_flag=1
            fi
        done

        if [ $error_flag -ne 0 ]; then
            cleanup_concatenated_files
            pause_for_user
            return 1
        else
            print_success "All files transferred via SMB."
        fi
        ;;

    ssh)
        local server port username auth_type destination dest_path
        server=$(echo "$location" | jq -r .server)
        port=$(echo "$location" | jq -r .port)
        destination=$(echo "$location" | jq -r .path)
        username=$(echo "$location" | jq -r .username)
        auth_type=$(echo "$location" | jq -r .auth_type)
        dest_path="$destination/$full_route_id"

        if [ "$auth_type" = "password" ]; then
            local cred_file password
            cred_file=$(echo "$location" | jq -r .credential_file)
            password=$(decrypt_credentials "$cred_file")
            sshpass -p "$password" ssh -p "$port" "$username@$server" "mkdir -p '$dest_path'" 2>/dev/null
            rsync -av --delete -e "sshpass -p '$password' ssh -p $port" "${files_to_transfer[@]}" "$username@$server:$dest_path/"
        else
            local key_path
            key_path=$(echo "$location" | jq -r .key_path)
            ssh -p "$port" "$username@$server" "mkdir -p '$dest_path'" 2>/dev/null
            rsync -av --delete -e "ssh -p $port -i $key_path" "${files_to_transfer[@]}" "$username@$server:$dest_path/"
        fi
        if [ $? -ne 0 ]; then
            cleanup_concatenated_files
            print_error "Rsync to SSH location failed."
            pause_for_user
            return 1
        else
            print_success "Sync to SSH location completed."
        fi
        ;;
    *)
        print_error "Invalid transfer type: $type"
        cleanup_concatenated_files
        pause_for_user
        return 1
        ;;
    esac

    # Clean up concatenated files
    cleanup_concatenated_files
    pause_for_user
    return 0
}

log_transfer() {
    local route="$1"
    local status="$2"
    local destination="$3"
    local size="$4"
    local duration="$5"

    local log_file="$CONFIG_DIR/transfer_logs.json"
    local entry=$(jq -n \
        --arg route "$route" \
        --arg status "$status" \
        --arg destination "$destination" \
        --arg size "$size" \
        --arg duration "$duration" \
        --arg timestamp "$(date -Iseconds)" \
        '{timestamp: $timestamp, route: $route, status: $status, destination: $destination, size: $size, duration: $duration}')

    if [ ! -f "$log_file" ]; then
        echo "[]" >"$log_file"
    fi

    jq --argjson entry "$entry" '. += [$entry]' "$log_file" >"$log_file.tmp"
    mv "$log_file.tmp" "$log_file"
}

handle_transfer_interruption() {
    local route="$1"
    local destination="$2"
    local transfer_id="$3"
    local state_file="$TRANSFER_STATE_DIR/${transfer_id}.state"

    mkdir -p "$TRANSFER_STATE_DIR"

    # Save transfer state
    jq -n \
        --arg route "$route" \
        --arg destination "$destination" \
        --arg timestamp "$(date -Iseconds)" \
        --arg bytes_transferred "$(stat -c%s "$temp_file")" \
        '{route: $route, destination: $destination, timestamp: $timestamp, bytes_transferred: $bytes_transferred}' \
        >"$state_file"
}

resume_transfer() {
    local transfer_id="$1"
    local state_file="$TRANSFER_STATE_DIR/${transfer_id}.state"

    if [ ! -f "$state_file" ]; then
        return 1
    fi

    local route=$(jq -r .route "$state_file")
    local destination=$(jq -r .destination "$state_file")
    local bytes_transferred=$(jq -r .bytes_transferred "$state_file")

    # Resume from last position
    case "$type" in
    smb)
        mount -t cifs "//${server}/${share}" "$mount_point" -o "username=$username,password=$password"
        rsync --append-verify --progress --partial \
            "$temp_dir/$transfer_file" "$mount_point/$path/"
        umount "$mount_point"
        ;;
    ssh)
        if [ "$auth_type" = "password" ]; then
            sshpass -p "$password" rsync -e "ssh -p $port" --append-verify --progress --partial \
                "$temp_dir/$transfer_file" "$username@$server:$path/"
        else
            rsync -e "ssh -p $port -i $key_path" --append-verify --progress --partial \
                "$temp_dir/$transfer_file" "$username@$server:$path/"
        fi
        ;;
    esac

    rm -f "$state_file"
    return 0
}

list_interrupted_transfers() {
    local filter_route="$1"
    for state in "$TRANSFER_STATE_DIR"/*.state; do
        [ -f "$state" ] || continue
        local route
        route=$(jq -r .route "$state")
        if [ -n "$filter_route" ] && [ "$route" != "$filter_route" ]; then
            continue
        fi
        local destination
        destination=$(jq -r .destination "$state")
        local timestamp
        timestamp=$(jq -r .timestamp "$state")
        local id
        id=$(basename "$state" .state)
        printf "%s | %s | %s | %s\n" "$id" "$timestamp" "$route" "$destination"
    done
}

transfer_routes_menu() {
    local route_base="$1"
    if [ -n "$route_base" ]; then
        # Simplified transfer menu when a route is already selected.
        while true; do
            clear
            echo "+----------------------------------------------------+"
            echo "|             Transfer Route: $route_base            |"
            echo "+----------------------------------------------------+"
            echo "| Available Options:"
            echo "| 1. Transfer this route"
            echo "| 2. View Transfer Logs (for $route_base)"
            echo "| 3. Resume Interrupted Transfers (for $route_base)"
            echo "| Q. Back"
            echo "+----------------------------------------------+"
            read -p "Make a selection: " choice
            case $choice in
            1)
                local location_info
                location_info=$(select_network_location) || continue
                clear
                IFS=' ' read -r type json_location <<<"$location_info"
                server=$(echo "$json_location" | jq -r '.server')
                share=$(echo "$json_location" | jq -r '.share')
                path=$(echo "$json_location" | jq -r '.path')
                label=$(echo "$json_location" | jq -r '.label')
                echo "Selected Network Location: ${server}/${share}/${path} (${label})"
                read -p "Compress data? (Y/n): " compress
                compress=${compress:-y}
                IFS=' ' read -r type location <<<"$location_info"
                if [[ "$compress" =~ ^[Yy]$ ]]; then
                    transfer_route "$route_base" "$location" "$type" true
                else
                    transfer_route "$route_base" "$location" "$type" false
                fi
                ;;
            2)
                clear
                echo "+----------------------------------------------------+"
                echo "|           Transfer Logs for $route_base            |"
                echo "+----------------------------------------------------+"
                if [ -f "$CONFIG_DIR/transfer_logs.json" ]; then
                    jq -r --arg route "$route_base" \
                        '.[] | select(.route == $route) | "\(.timestamp) | \(.route) | \(.status) | \(.destination) | \(.size) | \(.duration)"' \
                        "$CONFIG_DIR/transfer_logs.json" | column -t -s'|'
                else
                    echo "No transfer logs found."
                fi
                pause_for_user
                ;;
            3)
                clear
                echo "+----------------------------------------------------+"
                echo "|     Interrupted Transfers for $route_base          |"
                echo "+----------------------------------------------------+"
                echo "| Available Options:"
                list_interrupted_transfers "$route_base"
                echo "-----------------------------------------------------"
                read -p "Enter transfer ID to resume (or Q to cancel): " resume_id
                case $resume_id in
                [Qq]) continue ;;
                *)
                    if resume_transfer "$resume_id"; then
                        print_success "Transfer resumed and completed"
                    else
                        print_error "Failed to resume transfer"
                    fi
                    ;;
                esac
                pause_for_user
                ;;
            [qQ]) return ;;
            *)
                print_error "Invalid choice."
                pause_for_user
                ;;
            esac
        done
    else
        # Full transfer menu from the main menu.
        while true; do
            clear
            echo "+----------------------------------------------------+"
            echo "|                  Transfer Routes                   |"
            echo "+----------------------------------------------------+"
            echo "| Available Options:"
            echo "| 1. Transfer single route"
            echo "| 2. Transfer multiple routes"
            echo "| 3. Transfer all routes"
            echo "| 4. Manage network locations"
            echo "| 5. View Transfer Logs (all routes)"
            echo "| 6. Resume Interrupted Transfers (all routes)"
            echo "| Q. Back"
            echo "+----------------------------------------------------+"
            read -p "Make a selection: " choice
            case $choice in
            1)
                clear
                local route_base
                route_base=$(select_single_route) || continue
                echo "Selected route: $route_base"
                clear
                local location_info
                location_info=$(select_network_location) || continue
                clear
                IFS=' ' read -r type json_location <<<"$location_info"
                server=$(echo "$json_location" | jq -r '.server')
                share=$(echo "$json_location" | jq -r '.share')
                path=$(echo "$json_location" | jq -r '.path')
                label=$(echo "$json_location" | jq -r '.label')
                echo "Selected Network Location: ${server}/${share}/${path} (${label})"
                read -p "Compress data? (Y/n): " compress
                compress=${compress:-y}
                clear
                IFS=' ' read -r type location <<<"$location_info"
                if [[ "$compress" =~ ^[Yy]$ ]]; then
                    transfer_route "$route_base" "$location" "$type" true
                else
                    transfer_route "$route_base" "$location" "$type" false
                fi
                ;;
            2)
                # (Your existing multiple route transfer logic here)
                echo "Option 2 not implemented."
                pause_for_user
                ;;
            3)
                clear
                local location_info
                location_info=$(select_network_location) || continue
                clear
                IFS=' ' read -r type json_location <<<"$location_info"
                server=$(echo "$json_location" | jq -r '.server')
                share=$(echo "$json_location" | jq -r '.share')
                path=$(echo "$json_location" | jq -r '.path')
                label=$(echo "$json_location" | jq -r '.label')
                echo "Selected Network Location: ${server}/${share}/${path} (${label})"
                read -p "Compress data? (Y/n): " compress
                compress=${compress:-y}
                clear
                IFS=' ' read -r type location <<<"$location_info"
                local routes=()
                while IFS= read -r dir; do
                    local base="${dir%%--*}"
                    if [[ ! " ${routes[@]} " =~ " ${base} " ]]; then
                        routes+=("$base")
                    fi
                done < <(ls -1d "$ROUTES_DIR"/*--* 2>/dev/null)
                for route in "${routes[@]}"; do
                    echo "Transferring $route..."
                    transfer_route "$route" "$location" "$type" [[ "$compress" =~ ^[Yy]$ ]]
                done
                ;;
            4) manage_network_locations_menu ;;
            5)
                clear
                echo "+----------------------------------------------------+"
                echo "|                    Transfer Logs                   |"
                echo "+----------------------------------------------------+"
                if [ -f "$CONFIG_DIR/transfer_logs.json" ]; then
                    jq -r '.[] | "\(.timestamp) | \(.route) | \(.status) | \(.destination) | \(.size) | \(.duration)"' "$CONFIG_DIR/transfer_logs.json" | column -t -s'|'
                else
                    echo "No transfer logs found."
                fi
                pause_for_user
                ;;
            6)
                clear
                echo "+----------------------------------------------------+"
                echo "|                Interrupted Transfers               |"
                echo "+----------------------------------------------------+"
                echo "| Available Options:"
                list_interrupted_transfers
                echo "-----------------------------------------------------"
                read -p "Enter transfer ID to resume (or Q to cancel): " resume_id
                case $resume_id in
                [Qq]) continue ;;
                *)
                    if resume_transfer "$resume_id"; then
                        print_success "Transfer resumed and completed"
                    else
                        print_error "Failed to resume transfer"
                    fi
                    ;;
                esac
                pause_for_user
                ;;
            [qQ]) return ;;
            *)
                print_error "Invalid choice."
                pause_for_user
                ;;
            esac
        done
    fi
}

select_single_route() {
    update_route_cache
    local cache_file="$CONFIG_DIR/route_cache.json"
    if [ ! -f "$cache_file" ]; then
        print_error "Route cache not found." >&2
        return 1
    fi

    local total_routes
    total_routes=$(jq 'length' "$cache_file")
    if [ "$total_routes" -eq 0 ]; then
        print_error "No routes found in the cache." >&2
        return 1
    fi

    {
        echo "+----------------------------------------------------+"
        echo "|             Select a Route to Transfer             |"
        echo "+----------------------------------------------------+"
        for ((i = 0; i < total_routes; i++)); do
            local route timestamp duration segments size
            route=$(jq -r ".[$i].route" "$cache_file")
            timestamp=$(jq -r ".[$i].timestamp" "$cache_file")
            duration=$(jq -r ".[$i].duration" "$cache_file")
            segments=$(jq -r ".[$i].segments" "$cache_file")
            size=$(jq -r ".[$i].size" "$cache_file")
            echo "$((i + 1))) Route: $route | Date: $timestamp | Duration: $duration | Segments: $segments | Size: $size"
        done
        echo "+----------------------------------------------------+"
    } >&2

    read -p "Enter route number: " route_choice
    if ! [[ "$route_choice" =~ ^[0-9]+$ ]]; then
        print_error "Invalid input." >&2
        return 1
    fi

    local idx=$((route_choice - 1))
    if [ "$idx" -ge "$total_routes" ] || [ "$idx" -lt 0 ]; then
        print_error "Selection out of range." >&2
        return 1
    fi

    # Echo only the selected route ID to stdout.
    jq -r ".[$idx].route" "$cache_file"
}

select_multiple_routes() {
    local selected_routes=()
    local available_routes=()

    # Build available routes based on the naming convention.
    while IFS= read -r dir; do
        local base
        base=$(basename "$dir")
        base="${base%%--*}"
        # Only add if not already in the list.
        if [[ ! " ${available_routes[@]} " =~ " ${base} " ]]; then
            available_routes+=("$base")
        fi
    done < <(ls -1d "$ROUTES_DIR"/*--* 2>/dev/null)

    while true; do
        {
            echo "+----------------------------------------------------+"
            echo "|                    Select Routes                   |"
            echo "+----------------------------------------------------+"
            echo "| Selected: ${#selected_routes[@]} routes"
        } >&2

        local i=1
        for route in "${available_routes[@]}"; do
            local mark=" "
            if [[ " ${selected_routes[@]} " =~ " ${route} " ]]; then
                mark="*"
            fi
            local timestamp
            timestamp=$(format_route_timestamp "$route")
            local segments
            segments=$(get_segment_count "$route")
            {
                printf "%s %2d. %-20s | %s | %d segments\n" "$mark" "$i" "$route" "$timestamp" "$segments"
            } >&2
            i=$((i + 1))
        done

        {
            echo ""
            echo "| Available Commands:"
            echo "| [Numbers]: Toggle selection"
            echo "| A: Select all"
            echo "| N: Select none"
            echo "| D: Done"
            echo "| Q: Cancel"
            echo "-----------------------------------------------------"
        } >&2

        read -p "Enter command: " cmd </dev/tty
        case $cmd in
        [0-9]*)
            if [ "$cmd" -gt 0 ] && [ "$cmd" -le "${#available_routes[@]}" ]; then
                local route="${available_routes[$((cmd - 1))]}"
                # Toggle selection.
                if [[ " ${selected_routes[@]} " =~ " ${route} " ]]; then
                    local new_selection=()
                    for r in "${selected_routes[@]}"; do
                        if [ "$r" != "$route" ]; then
                            new_selection+=("$r")
                        fi
                    done
                    selected_routes=("${new_selection[@]}")
                else
                    selected_routes+=("$route")
                fi
            fi
            ;;
        [Aa])
            selected_routes=("${available_routes[@]}")
            ;;
        [Nn])
            selected_routes=()
            ;;
        [Dd])
            if [ ${#selected_routes[@]} -gt 0 ]; then
                # Output only the selected routes (space-separated).
                echo "${selected_routes[@]}"
                return 0
            fi
            ;;
        [Qq])
            return 1
            ;;
        esac
    done
}

view_complete_rlog() {
    local route_base="$1"
    clear
    echo "Displaying complete RLog for route $route_base"
    echo "-----------------------------------------------------"
    for segment in "$ROUTES_DIR/$route_base"--*; do
        if [ -f "$segment/rlog" ]; then
            echo "=== Segment ${segment##*--} ==="
            cat "$segment/rlog"
            echo ""
        fi
    done
    pause_for_user
}

view_segment_rlog() {
    local route_base="$1"
    local segments=$(get_segment_count "$route_base")

    clear
    echo "Select segment (0-$((segments - 1))):"
    read -p "Enter segment number: " segment_num

    if [ -f "$ROUTES_DIR/${route_base}--${segment_num}/rlog" ]; then
        clear
        echo "Displaying RLog for segment $segment_num"
        echo "-----------------------------------------------------"
        cat "$ROUTES_DIR/${route_base}--${segment_num}/rlog"
    else
        print_error "Segment not found or no rlog available."
    fi
    pause_for_user
}

view_filtered_rlog() {
    local route_base="$1"
    clear
    echo "Displaying Errors and Warnings for route $route_base"
    echo "-----------------------------------------------------"
    for segment in "$ROUTES_DIR/$route_base"--*; do
        if [ -f "$segment/rlog" ]; then
            echo "=== Segment ${segment##*--} ==="
            grep -i "error\|warning" "$segment/rlog"
            echo ""
        fi
    done
    pause_for_user
}

play_route_video() {
    local route_base="$1"
    local segment="0"

    if [ ! -f "$ROUTES_DIR/${route_base}--${segment}/fcamera.hevc" ]; then
        print_error "Video file not found."
        return 1
    fi

    if command -v ffplay >/dev/null 2>&1; then
        ffplay "$ROUTES_DIR/${route_base}--${segment}/fcamera.hevc"
    else
        print_error "Video playback not supported. ffplay not installed."
    fi
    pause_for_user
}

update_route_cache() {
    local cache_file="$CONFIG_DIR/route_cache.json"
    local cache_duration=300 # 5 minutes in seconds
    local now
    now=$(date +%s)

    # If the cache exists and is less than 5 minutes old, just return.
    if [ -f "$cache_file" ]; then
        local last_modified
        last_modified=$(stat -c %Y "$cache_file")
        if ((now - last_modified < cache_duration)); then
            return 0
        fi
    fi

    # Build an array of unique route bases.
    local routes=()
    while IFS= read -r dir; do
        local base_name="${dir##*/}"
        local route_base="${base_name%%--*}"
        if [[ ! " ${routes[*]} " =~ " ${route_base} " ]]; then
            routes+=("$route_base")
        fi
    done < <(find "$ROUTES_DIR" -maxdepth 1 -type d -name "*--*")

    # Build details for each route.
    local routes_details=()
    for route in "${routes[@]}"; do
        local segments
        segments=$(find "$ROUTES_DIR" -maxdepth 1 -type d -name "${route}--*" | wc -l)
        local timestamp
        timestamp=$(format_route_timestamp "$route")
        local duration
        duration=$(get_route_duration "$route")
        local size
        size=$(du -sh "$ROUTES_DIR"/${route}--* 2>/dev/null | head -1 | awk '{print $1}')
        local details
        details=$(jq -n \
            --arg route "$route" \
            --arg timestamp "$timestamp" \
            --arg duration "$duration" \
            --arg segments "$segments" \
            --arg size "$size" \
            '{route: $route, timestamp: $timestamp, duration: $duration, segments: $segments, size: $size}')
        routes_details+=("$details")
    done

    # Save the details array as a JSON array in the cache file.
    printf '%s\n' "${routes_details[@]}" | jq -s '.' >"$cache_file"
}

display_route_stats() {
    update_route_cache
    local cache_file="$CONFIG_DIR/route_cache.json"
    local total_routes total_segments total_size_bytes total_size

    total_routes=$(jq 'length' "$cache_file")
    total_segments=$(jq '[.[].segments | tonumber] | add' "$cache_file")
    total_size_bytes=$(find "$ROUTES_DIR" -maxdepth 1 -name "*--*" -type d -exec du -b {} + | awk '{sum += $1} END {print sum}')
    total_size=$(numfmt --to=iec-i --suffix=B "$total_size_bytes")

    echo "| Routes: $total_routes | Segments: $total_segments"
    echo "| Total Size: $total_size"
    echo "+------------------------------------------------------+"
}

view_route_details() {
    local route_base="$1"
    update_route_cache
    local cache_file="$CONFIG_DIR/route_cache.json"
    local route_detail
    route_detail=$(jq -r --arg route "$route_base" 'map(select(.route == $route)) | .[0]' "$cache_file")
    if [ "$route_detail" = "null" ]; then
        print_error "Route details not found in cache."
        pause_for_user
        return
    fi

    local timestamp duration segments size
    timestamp=$(echo "$route_detail" | jq -r .timestamp)
    duration=$(echo "$route_detail" | jq -r .duration)
    segments=$(echo "$route_detail" | jq -r .segments)
    size=$(echo "$route_detail" | jq -r .size)

    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "|                Route Details                 |"
        echo "+----------------------------------------------+"
        echo "Route ID: $route_base"
        echo "Date/Time: $timestamp"
        echo "Duration: $duration"
        echo "Segments: $segments"
        echo "Total Size: $size"
        echo "------------------------------------------------"
        echo ""
        echo "Available Options:"
        echo "1. View RLog (all segments)"
        echo "2. View RLog by segment"
        echo "3. View Errors/Warnings only"
        echo "4. Play Video (if supported)"
        echo "5. Concatenate Route Files"
        echo "6. Transfer Route"
        echo "Q. Back"
        echo "+----------------------------------------------+"
        read -p "Make a selection: " choice
        case $choice in
        1) view_complete_rlog "$route_base" ;;
        2) view_segment_rlog "$route_base" ;;
        3) view_filtered_rlog "$route_base" ;;
        4) play_route_video "$route_base" ;;
        5) concat_route_menu "$route_base" ;;
        6) transfer_routes_menu "$route_base" ;;
        [qQ]) return ;;
        *)
            print_error "Invalid choice."
            pause_for_user
            ;;
        esac
    done
}

route_management_menu() {
    while true; do
        clear
        echo "+------------------------------------------------------+"
        echo "|                Route Management Menu                 |"
        echo "+------------------------------------------------------+"

        # Display route statistics in a cleaner format
        echo "| Gathering Route Statistics..."
        local stats
        stats=$(display_route_stats)
        tput cuu1
        tput el
        echo "$stats"

        echo "| Available Routes (newest first):"
        echo "+------------------------------------------------------+"
        printf "|%-4s | %-17s | %-8s | %-6s | %-6s |\n" "#" "Date & Time" "Duration" "Segs" "Size"
        echo "+------------------------------------------------------+"

        # Get list of unique route bases
        local routes=()
        declare -A seen_routes
        while IFS= read -r dir; do
            local base_name
            base_name=$(basename "$dir")
            local route_base="${base_name%%--*}"
            if [ -z "${seen_routes[$route_base]}" ]; then
                routes+=("$route_base")
                seen_routes[$route_base]=1
            fi
        done < <(find "$ROUTES_DIR" -maxdepth 1 -type d -name "*--*" | sort -r)

        local count=1
        for route in "${routes[@]}"; do
            local segments
            segments=$(find "$ROUTES_DIR" -maxdepth 1 -type d -name "${route}--*" | wc -l)
            local timestamp
            timestamp=$(format_route_timestamp "$route")
            local friendly_date
            friendly_date=$(date -d "$timestamp" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$timestamp")
            local duration
            duration=$(get_route_duration "$route")
            local duration_short
            duration_short=$(echo "$duration" | sed 's/^00://')
            local size
            size=$(du -sh "$ROUTES_DIR"/${route}--* 2>/dev/null | head -1 | awk '{print $1}')

            local line
            line=$(printf "|%3d. | %-17s | %8s | %6d | %6s |" "$count" "$friendly_date" "$duration_short" "$segments" "$size")
            if [ "$segments" -gt 20 ]; then
                echo -e "${GREEN}${line}${NC}"
            elif [ "$segments" -gt 10 ]; then
                echo -e "${BLUE}${line}${NC}"
            elif [ "$segments" -eq 1 ]; then
                echo -e "${YELLOW}${line}${NC}"
            else
                echo "$line"
            fi
            count=$((count + 1))
        done

        echo "+------------------------------------------------------+"
        echo "| Legend:"
        echo -e "| ${GREEN}■${NC} Long trips (>20 segments)"
        echo -e "| ${BLUE}■${NC} Medium trips (11-20 segments)"
        echo -e "| ${YELLOW}■${NC} Single segment trips"
        echo -e "| ${NC}■${NC} Short trips (2-10 segments)"
        echo "+------------------------------------------------------+"
        echo "| Available Options:"
        echo "| T. Transfer Routes"
        echo "| M. Manage Network Locations"
        echo "| Q. Back to Main Menu"
        echo "+------------------------------------------------------+"
        read -p "Select route number or option: " choice
        case $choice in
        [Tt])
            transfer_routes_menu ""
            ;;
        [Mm])
            print_info "Showing Network Location Menu..."
            manage_network_locations_menu
            pause_for_user
            ;;
        [Qq])
            echo "Returning to Main Menu..."
            return
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#routes[@]}" ]; then
                view_route_details "${routes[$((choice - 1))]}"
            else
                print_error "Invalid choice."
                pause_for_user
            fi
            ;;
        esac
    done
}

###############################################################################
# Main Execution
###############################################################################

# Initialize the network configuration
init_network_config

# Start the Route Management Menu.
route_management_menu

# When the user selects “Return to Main Menu”, exit this script.
exit 0
