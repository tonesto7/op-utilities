#!/bin/bash

###############################################################################
# Global Variables
###############################################################################
readonly TRANSFERS_SCRIPT_VERSION="3.0.1"
readonly TRANSFERS_SCRIPT_MODIFIED="2025-02-08"

###############################################################################
# Transfer Management Functions
###############################################################################

# Prerequisites Check
check_prerequisites() {
    local errors=0

    # Check required commands
    for cmd in jq rsync smbclient tar wget; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            print_error "Required command not found: $cmd"
            errors=$((errors + 1))
        fi
    done

    # Check required directories
    for dir in "$ROUTES_DIR" "$CONFIG_DIR" "$CREDENTIALS_DIR"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
        fi
    done

    # Check write permissions
    if [ ! -w "$CONFIG_DIR" ]; then
        print_error "No write permission for $CONFIG_DIR"
        errors=$((errors + 1))
    fi

    return $errors
}

verify_network_connectivity() {
    local type="$1"
    local location="$2"

    if [ "$type" = "smb" ]; then
        local status
        status=$(test_smb_connection "$location")
        [ "$status" = "Valid" ] || {
            print_error "SMB connection failed: $status"
            return 1
        }
    else
        local status
        status=$(test_ssh_connection "$location")
        [ "$status" = "Valid" ] || {
            print_error "SSH connection failed: $status"
            return 1
        }
    fi
    return 0
}

get_location_label() {
    local location_id="$1"
    jq -r --arg id "$location_id" '.smb[] + .ssh[] | select(.location_id == $id) | .label' "$NETWORK_CONFIG"
}

generate_location_id() {
    local seed="$1"
    echo -n "$seed" | md5sum | cut -d ' ' -f1
}

# Enhance select_network_location to output location ID when needed
select_network_location_id() {
    local location_info
    location_info=$(select_network_location)
    if [ $? -eq 0 ]; then
        local json_location
        json_location=$(echo "$location_info" | cut -d' ' -f2-)
        echo "$json_location" | jq -r '.location_id'
        return 0
    fi
    return 1
}

verify_network_config() {
    if [ ! -f "$NETWORK_CONFIG" ]; then
        print_error "Network configuration file not found. Please configure network locations first."
        return 1
    fi
    if ! jq empty "$NETWORK_CONFIG" 2>/dev/null; then
        print_error "Network configuration file is corrupted. Please reconfigure network locations."
        return 1
    fi
    return 0
}

# State Management Functions
save_transfer_state() {
    local route="$1"
    local network_id="$2"
    local progress="$3"
    mkdir -p "$CONFIG_DIR/state"
    echo "{\"route\":\"$route\",\"network_id\":\"$network_id\",\"progress\":$progress,\"timestamp\":\"$(date -Iseconds)\"}" >"$CONFIG_DIR/state/transfer_${route}.json"
}

load_transfer_state() {
    local route="$1"
    if [ -f "$CONFIG_DIR/state/transfer_${route}.json" ]; then
        cat "$CONFIG_DIR/state/transfer_${route}.json"
        return 0
    fi
    return 1
}

clear_transfer_state() {
    local route="$1"
    rm -f "$CONFIG_DIR/state/transfer_${route}.json"
}

# Cleanup Functions
cleanup_temp_files() {
    # Only remove if paths are non-empty and exist
    if [ -n "$CONCAT_DIR" ] && [ -d "$CONCAT_DIR" ]; then
        rm -rf "${CONCAT_DIR:?}"/*
    fi

    if [ -d "/tmp/route_transfer" ]; then
        rm -rf "/tmp/route_transfer"/*
    fi
}

cleanup_old_logs() {
    find "$CONFIG_DIR" -name "transfer_logs.json" -mtime +30 -delete
}

trap_cleanup() {
    # Extra safety - if called before variables initialized
    if [ -z "$CONCAT_DIR" ]; then
        exit 1
    fi
    cleanup_temp_files
    exit 1
}

trap trap_cleanup INT TERM

###############################################################################
# Syncing Management Functions
###############################################################################
# Update the launch_env.sh file with a block containing the job command.
# The job_type parameter must be either "route_sync" or "backup".
# The saved_network_location_id is the network location ID to embed in the command.
update_job_in_launch_env() {
    local job_type="$1"
    local saved_network_location_id="$2"
    local start_marker end_marker command

    if [ "$job_type" = "backup" ]; then
        start_marker="### Start CommaUtility Backup"
        end_marker="### End CommaUtility Backup"
        command="/data/CommaUtility.sh -network ${saved_network_location_id}"
    elif [ "$job_type" = "route_sync" ]; then
        start_marker="### Start CommaUtilityRoute Sync"
        end_marker="### End CommaUtilityRoute Sync"
        command="/data/CommaUtilityRoutes.sh -network ${saved_network_location_id}"
    else
        print_error "Invalid job type: $job_type"
        return 1
    fi

    # Remove any existing block from LAUNCH_ENV.
    sed -i "/^${start_marker}/,/^${end_marker}/d" "$LAUNCH_ENV"

    # Append the new block at the end of the file.
    cat <<EOF >>"$LAUNCH_ENV"
${start_marker}
${command}
${end_marker}
EOF
    print_success "Updated ${job_type} job in ${LAUNCH_ENV}"
}

# Configure a Route Sync job.
# This writes a block that will eventually run:
#   CommaUtilityRoutes.sh -network <saved_network_location_id>
configure_route_sync_job() {
    if is_onroad; then
        print_error "Cannot configure route sync while onroad."
        pause_for_user
        return 1
    fi

    local route_loc
    route_loc=$(jq -r '.locations[] | select(.type == "route_sync")' "$NETWORK_CONFIG")

    if [ -z "$route_loc" ]; then
        print_warning "No route sync location configured."
        read -p "Would you like to configure one now? (Y/n): " configure_choice
        if [[ "$configure_choice" =~ ^[Nn]$ ]]; then
            return 1
        fi
        configure_network_location "route_sync"
        route_loc=$(jq -r '.locations[] | select(.type == "route_sync")' "$NETWORK_CONFIG")
        if [ -z "$route_loc" ]; then
            return 1
        fi
    fi

    local location_id
    location_id=$(echo "$route_loc" | jq -r .location_id)

    update_job_in_launch_env "route_sync" "$location_id"
    print_success "Route sync job configured."
    pause_for_user
}

# Configure a Backup job.
# This writes a block that will eventually run:
#   CommaUtility.sh -network <saved_network_location_id>
configure_backup_job() {
    clear
    if is_onroad; then
        print_error "Cannot configure backup job while onroad."
        pause_for_user
        return 1
    fi

    local location_info network_json saved_network_location_id
    location_info=$(select_network_location "device_backup") || return 1
    network_json=$(echo "$location_info" | sed -E 's/^[^ ]+ //')
    saved_network_location_id=$(echo "$network_json" | jq -r '.location_id')
    if [ -z "$saved_network_location_id" ] || [ "$saved_network_location_id" = "null" ]; then
        print_error "Failed to retrieve the network location ID."
        pause_for_user
        return 1
    fi

    update_job_in_launch_env "backup" "$saved_network_location_id"
    print_success "Backup job configured."
    pause_for_user
}

# Remove a job block from launch_env.sh based on job type.
remove_job_block() {
    # clear
    local job_type="$1"
    local start_marker end_marker

    if [ "$job_type" = "backup" ]; then
        start_marker="### Start CommaUtility Backup"
        end_marker="### End CommaUtility Backup"
    elif [ "$job_type" = "route_sync" ]; then
        start_marker="### Start CommaUtilityRoute Sync"
        end_marker="### End CommaUtilityRoute Sync"
    else
        print_error "Invalid job type: $job_type"
        return 1
    fi

    sed -i "/^${start_marker}/,/^${end_marker}/d" "$LAUNCH_ENV"
    print_success "${job_type} job removed from ${LAUNCH_ENV}"
    pause_for_user
}

# Menu to manage Route Sync job
manage_auto_sync_jobs() {
    while true; do
        clear
        echo "+------------------------------------------------+"
        echo "│              Manage Route Sync Job             │"
        echo "+------------------------------------------------+"
        # Grab the job block (if it exists)
        local job_block network_id network_label
        job_block=$(grep -A1 "^### Start CommaUtilityRoute Sync" "$LAUNCH_ENV")
        if [ -n "$job_block" ]; then
            # Extract the network id from the command line following the start marker
            network_id=$(echo "$job_block" | tail -n1 | sed -n 's/.*-network[[:space:]]\+\([^[:space:]]\+\).*/\1/p')
            if [ -n "$network_id" ]; then
                network_label=$(jq -r --arg id "$network_id" '(.smb[] + .ssh[]) | select(.location_id == $id) | .label' "$NETWORK_CONFIG")
            fi
            [ -z "$network_label" ] && network_label="Unknown"
            echo -e "│ Current Route Sync: ${GREEN}Route Sync ($network_label)${NC}"
        else
            echo -e "│ Current Route Sync: ${RED}None configured${NC}"
        fi
        echo "│"
        echo "│ Available Options:"
        if [ -z "$job_block" ]; then
            echo "│ 1. Add Route Sync Job"
        else
            echo "│ 1. Remove Route Sync Job"
        fi
        echo "│ Q. Back"
        echo "+------------------------------------------------+"
        read -p "Enter your choice: " choice
        case $choice in
        1)
            if [ -z "$job_block" ]; then
                configure_route_sync_job
            else
                remove_job_block "route_sync"
            fi
            ;;
        [qQ]) break ;;
        *) print_error "Invalid option." && pause_for_user ;;
        esac
    done
}

# Updated Manage Backup Job Menu
manage_auto_backup_jobs() {
    while true; do
        clear
        echo "+------------------------------------------------+"
        echo "│                Manage Backup Job               │"
        echo "+------------------------------------------------+"
        local job_block network_id network_label
        job_block=$(grep -A1 "^### Start CommaUtility Backup" "$LAUNCH_ENV")
        if [ -n "$job_block" ]; then
            network_id=$(echo "$job_block" | tail -n1 | sed -n 's/.*-network[[:space:]]\+\([^[:space:]]\+\).*/\1/p')
            if [ -n "$network_id" ]; then
                network_label=$(jq -r --arg id "$network_id" '(.smb[] + .ssh[]) | select(.location_id == $id) | .label' "$NETWORK_CONFIG")
            fi
            [ -z "$network_label" ] && network_label="Unknown"
            echo -e "│ Current Backup: ${GREEN}Backup ($network_label)${NC}"
        else
            echo -e "│ Current Backup: ${RED}None configured${NC}"
        fi
        echo "│"
        echo "│ Available Options:"
        if [ -z "$job_block" ]; then
            echo "│ 1. Add Backup Job"
        else
            echo "│ 1. Remove Backup Job"
        fi
        echo "│ Q. Back"
        echo "+------------------------------------------------+"
        read -p "Enter your choice: " choice
        case $choice in
        1)
            if [ -z "$job_block" ]; then
                configure_backup_job
            else
                remove_job_block "backup"
            fi
            ;;
        [qQ]) break ;;
        *) print_error "Invalid option." && pause_for_user ;;
        esac
    done
}

# A combined menu to manage both Route Sync and Backup jobs.
manage_auto_sync_and_backup_jobs() {
    while true; do
        clear
        echo "+------------------------------------------------+"
        echo "│    Manage Auto Sync & Backup Jobs              │"
        echo "+------------------------------------------------+"

        # Show Route Sync Status
        local route_loc route_job
        route_loc=$(jq -r '.locations[] | select(.type == "route_sync")' "$NETWORK_CONFIG")
        route_job=$(grep -A1 "^### Start CommaUtilityRoute Sync" "$LAUNCH_ENV")
        if [ -n "$route_loc" ]; then
            local label=$(echo "$route_loc" | jq -r .label)
            if [ -n "$route_job" ]; then
                echo -e "│ Route Sync: ${GREEN}Enabled${NC} ($label)"
            else
                echo -e "│ Route Sync: ${YELLOW}Location Configured${NC} ($label) but job disabled"
            fi
        else
            echo -e "│ Route Sync: ${RED}No Location Configured${NC}"
        fi

        # Show Backup Status
        local backup_loc backup_job
        backup_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG")
        backup_job=$(grep -A1 "^### Start CommaUtility Backup" "$LAUNCH_ENV")
        if [ -n "$backup_loc" ]; then
            local label=$(echo "$backup_loc" | jq -r .label)
            if [ -n "$backup_job" ]; then
                echo -e "│ Device Backup: ${GREEN}Enabled${NC} ($label)"
            else
                echo -e "│ Device Backup: ${YELLOW}Location Configured${NC} ($label) but job disabled"
            fi
        else
            echo -e "│ Device Backup: ${RED}No Location Configured${NC}"
        fi

        echo "│"
        echo "│ Available Options:"
        if [ -n "$route_loc" ]; then
            if [ -n "$route_job" ]; then
                echo "│ 1. Disable Route Sync Job"
            else
                echo "│ 1. Enable Route Sync Job"
            fi
        else
            echo "│ 1. Configure Route Sync Location"
        fi

        if [ -n "$backup_loc" ]; then
            if [ -n "$backup_job" ]; then
                echo "│ 2. Disable Device Backup Job"
            else
                echo "│ 2. Enable Device Backup Job"
            fi
        else
            echo "│ 2. Configure Device Backup Location"
        fi

        echo "│ Q. Back"
        echo "+------------------------------------------------+"

        read -p "Enter your choice: " choice
        case $choice in
        1)
            if [ -z "$route_loc" ]; then
                configure_network_location "route_sync"
            else
                if [ -n "$route_job" ]; then
                    remove_job_block "route_sync"
                else
                    configure_route_sync_job
                fi
            fi
            ;;
        2)
            if [ -z "$backup_loc" ]; then
                configure_network_location "device_backup"
            else
                if [ -n "$backup_job" ]; then
                    remove_job_block "backup"
                else
                    configure_backup_job
                fi
            fi
            ;;
        [qQ]) break ;;
        *) print_error "Invalid choice." && pause_for_user ;;
        esac
    done
}

###############################################################################
# transfer_route
#
# Description:
#   Concatenates all segments (rlog, qlog, video) for a given route,
#   then transfers the concatenated files to a specified network location.
#   The remote destination path is automatically appended with the device_id.
#
# Parameters:
#   $1 - route_base: The base name of the route (without segment suffix).
#   $2 - location: JSON object containing network location details.
#   $3 - type: The network location type ("smb" or "ssh").
#
# Returns:
#   0 on success, non-zero on error.
###############################################################################
transfer_route() {
    local route_base="$1"
    local location="$2"
    local type="$3"
    local network_id=$(echo "$location" | jq -r '.location_id')

    # Load previous state if exists
    local previous_state=""
    if previous_state=$(load_transfer_state "$route_base"); then
        print_info "Found previous transfer state for $route_base"
        read -p "Resume previous transfer? [y/N]: " resume
        if [[ "$resume" =~ ^[Yy]$ ]]; then
            print_info "Resuming transfer..."
        else
            clear_transfer_state "$route_base"
        fi
    fi

    # Find the first segment directory to determine the full route ID
    local sample_dir
    sample_dir=$(find "$ROUTES_DIR" -maxdepth 1 -type d -name "${route_base}--*" | head -n 1)
    if [ -z "$sample_dir" ]; then
        print_error "No route segments found for route $route_base."
        return 1
    fi

    # Extract full route ID from the first segment directory
    local full_route_id
    full_route_id=$(basename "$sample_dir" | sed -E 's/--[^-]+$//')

    # Get the persistent device identifier
    local device_id
    device_id=$(get_device_id)

    # Set up a temporary directory for the transfer process
    local temp_dir="/tmp/route_transfer"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"

    # Create an output directory for concatenated files
    local output_dir="$ROUTES_DIR/concatenated/${full_route_id}"
    mkdir -p "$output_dir"

    # Save initial state
    save_transfer_state "$route_base" "$network_id" "0"

    # Concatenate segments for each file type
    print_info "Concatenating segments for route $route_base..."
    concat_route_segments "$route_base" "rlog" "$output_dir" "true" || {
        print_error "Failed to concatenate rlog segments"
        cleanup_temp_files
        clear_transfer_state "$route_base"
        return 1
    }
    save_transfer_state "$route_base" "$network_id" "25"

    concat_route_segments "$route_base" "qlog" "$output_dir" "true" || {
        print_error "Failed to concatenate qlog segments"
        cleanup_temp_files
        clear_transfer_state "$route_base"
        return 1
    }
    save_transfer_state "$route_base" "$network_id" "50"

    concat_route_segments "$route_base" "video" "$output_dir" "true" || {
        print_error "Failed to concatenate video segments"
        cleanup_temp_files
        clear_transfer_state "$route_base"
        return 1
    }
    save_transfer_state "$route_base" "$network_id" "75"

    # Build an array of files to transfer
    local files_to_transfer=()
    [ -f "$output_dir/rlog" ] && files_to_transfer+=("$output_dir/rlog")
    [ -f "$output_dir/qlog" ] && files_to_transfer+=("$output_dir/qlog")
    # Loop over camera types to add video files
    for camera in dcamera ecamera fcamera qcamera; do
        local ext
        # qcamera uses .ts, others use .hevc
        ext=$([ "$camera" = "qcamera" ] && echo "ts" || echo "hevc")
        local video_file="$output_dir/${camera}.${ext}"
        [ -f "$video_file" ] && files_to_transfer+=("$video_file")
    done

    # Build the remote destination path:
    # Append the device_id and full_route_id to the base path
    local destination remote_path
    destination=$(echo "$location" | jq -r .path)
    remote_path="${destination%/}/${device_id}/${full_route_id}"

    local transfer_start_time=$(date +%s)

    case "$type" in
    smb)
        # Retrieve SMB connection details
        local server share username cred_file password
        server=$(echo "$location" | jq -r .server)
        share=$(echo "$location" | jq -r .share)
        username=$(echo "$location" | jq -r .username)
        cred_file=$(echo "$location" | jq -r .credential_file)
        password=$(decrypt_credentials "$cred_file")

        print_info "Syncing route ${route_base} via SMB to ${remote_path}..."

        # Create the remote directory
        local mkdir_output
        mkdir_output=$(smbclient "//${server}/${share}" -U "${username}%${password}" \
            -c "mkdir \"$remote_path\"" 2>&1)
        if echo "$mkdir_output" | grep -qi "NT_STATUS_OBJECT_NAME_COLLISION"; then
            print_info "Remote directory already exists: $remote_path"
        fi

        # Transfer each file via SMB
        local transfer_success=true
        for file in "${files_to_transfer[@]}"; do
            local base_file
            base_file=$(basename "$file")
            print_info "Transferring $base_file..."
            if ! smbclient "//${server}/${share}" -U "${username}%${password}" \
                -c "cd \"$remote_path\"; put \"$file\" \"$base_file\"" >/dev/null; then
                print_error "Failed to transfer $base_file"
                transfer_success=false
                break
            fi
            print_success "Transferred $base_file"
        done

        if [ "$transfer_success" = false ]; then
            cleanup_temp_files
            clear_transfer_state "$route_base"
            return 1
        fi
        ;;
    ssh)
        # Retrieve SSH connection details
        local server port username auth_type key_path
        server=$(echo "$location" | jq -r .server)
        port=$(echo "$location" | jq -r .port)
        username=$(echo "$location" | jq -r .username)
        auth_type=$(echo "$location" | jq -r .auth_type)

        print_info "Syncing route ${route_base} via SSH to ${remote_path}..."
        # Ensure the remote directory exists
        ssh -p "$port" "$username@$server" "mkdir -p '$remote_path'" >/dev/null || {
            print_error "Failed to create remote directory"
            cleanup_temp_files
            clear_transfer_state "$route_base"
            return 1
        }

        # Transfer files using rsync
        if [ "$auth_type" = "password" ]; then
            local cred_file password
            cred_file=$(echo "$location" | jq -r .credential_file)
            password=$(decrypt_credentials "$cred_file")
            if ! rsync -av --delete -e "sshpass -p '$password' ssh -p $port" \
                "${files_to_transfer[@]}" "$username@$server:$remote_path/"; then
                print_error "Failed to transfer files via SSH (password auth)"
                cleanup_temp_files
                clear_transfer_state "$route_base"
                return 1
            fi
        else
            key_path=$(echo "$location" | jq -r .key_path)
            if ! rsync -av --delete -e "ssh -p $port -i $key_path" \
                "${files_to_transfer[@]}" "$username@$server:$remote_path/"; then
                print_error "Failed to transfer files via SSH (key auth)"
                cleanup_temp_files
                clear_transfer_state "$route_base"
                return 1
            fi
        fi
        ;;
    *)
        print_error "Invalid transfer type: $type"
        cleanup_temp_files
        clear_transfer_state "$route_base"
        return 1
        ;;
    esac

    local transfer_end_time=$(date +%s)
    local transfer_duration=$((transfer_end_time - transfer_start_time))
    local total_size=$(du -sh "${files_to_transfer[@]}" | awk '{total += $1} END {print total}')

    # Log successful transfer
    log_transfer "$route_base" "success" "$remote_path" "$total_size" "$transfer_duration"

    print_success "Sync complete for route ${route_base}"
    cleanup_temp_files
    clear_transfer_state "$route_base"
    rm -rf "$output_dir"
    return 0
}

log_transfer() {
    local route="$1" status="$2" destination="$3" size="$4" duration="$5"
    local log_file="$CONFIG_DIR/transfer_logs.json"
    local entry
    entry=$(jq -n \
        --arg route "$route" \
        --arg status "$status" \
        --arg destination "$destination" \
        --arg size "$size" \
        --arg duration "$duration" \
        --arg timestamp "$(date -Iseconds)" \
        '{timestamp: $timestamp, route: $route, status: $status, destination: $destination, size: $size, duration: $duration}')
    [ ! -f "$log_file" ] && echo "[]" >"$log_file"
    jq --argjson entry "$entry" '. += [$entry]' "$log_file" >"$log_file.tmp"
    mv "$log_file.tmp" "$log_file"
}

handle_transfer_interruption() {
    local route="$1" destination="$2" transfer_id="$3"
    local state_file="$TRANSFER_STATE_DIR/${transfer_id}.state"
    mkdir -p "$TRANSFER_STATE_DIR"
    jq -n \
        --arg route "$route" \
        --arg destination "$destination" \
        --arg timestamp "$(date -Iseconds)" \
        --arg bytes_transferred "$(stat -c%s "$temp_file" 2>/dev/null)" \
        '{route: $route, destination: $destination, timestamp: $timestamp, bytes_transferred: $bytes_transferred}' \
        >"$state_file"
}

resume_transfer() {
    local transfer_id="$1" state_file="$TRANSFER_STATE_DIR/${transfer_id}.state"
    [ ! -f "$state_file" ] && return 1
    # (Resume logic here)
    rm -f "$state_file"
    return 0
}

list_interrupted_transfers() {
    local filter_route="$1"
    for state in "$TRANSFER_STATE_DIR"/*.state; do
        [ -f "$state" ] || continue
        local route destination timestamp id
        route=$(jq -r .route "$state")
        [ -n "$filter_route" ] && [ "$route" != "$filter_route" ] && continue
        destination=$(jq -r .destination "$state")
        timestamp=$(jq -r .timestamp "$state")
        id=$(basename "$state" .state)
        printf "%s | %s | %s | %s\n" "$id" "$timestamp" "$route" "$destination"
    done
}

sync_all_routes() {
    if is_onroad; then
        print_error "Cannot sync routes while onroad."
        exit 1
    fi

    # Get the route sync location
    local route_loc
    route_loc=$(jq -r '.locations[] | select(.type == "route_sync")' "$NETWORK_CONFIG")
    if [ -z "$route_loc" ]; then
        print_error "No route sync location configured."
        exit 1
    fi

    # Get location ID
    local location_id=$(echo "$route_loc" | jq -r .location_id)

    # Verify connectivity
    local protocol status
    protocol=$(echo "$route_loc" | jq -r .protocol)
    if [ "$protocol" = "smb" ]; then
        status=$(test_smb_connection "$route_loc")
    else
        status=$(test_ssh_connection "$route_loc")
    fi

    if [ "$status" != "Valid" ]; then
        print_error "Route sync location not reachable."
        exit 1
    fi

    # Get all unique routes
    local routes=()
    while IFS= read -r dir; do
        local route_base="${dir##*/}"
        route_base="${route_base%%--*}"
        [[ " ${routes[*]} " =~ " ${route_base} " ]] || routes+=("$route_base")
    done < <(find "$ROUTES_DIR" -maxdepth 1 -type d -name "*--*")

    for route in "${routes[@]}"; do
        print_info "Syncing route $route..."
        transfer_route "$route" "$route_loc" "$protocol"
    done
    exit 0
}

sync_backup_to_network() {
    local backup_dir="$1"
    local location_id="$2"

    # Get location details with proper error handling
    if [ ! -f "$NETWORK_CONFIG" ]; then
        print_error "Network configuration file not found"
        return 1
    fi

    local location
    location=$(jq -r --arg id "$location_id" '.locations[] | select(.location_id == $id)' "$NETWORK_CONFIG")
    if [ -z "$location" ] || [ "$location" = "null" ]; then
        print_error "Network location ID '$location_id' not found in configuration"
        return 1
    fi

    # Verify required fields exist
    local server share path username
    server=$(echo "$location" | jq -r '.server')
    share=$(echo "$location" | jq -r '.share')
    path=$(echo "$location" | jq -r '.path')
    username=$(echo "$location" | jq -r '.username')

    if [ -z "$server" ] || [ "$server" = "null" ] ||
        [ -z "$share" ] || [ "$share" = "null" ] ||
        [ -z "$username" ] || [ "$username" = "null" ]; then
        print_error "Invalid network location configuration - missing required fields"
        return 1
    fi

    # Determine protocol
    local protocol
    protocol=$(echo "$location" | jq -r '.protocol')
    if [ "$protocol" != "smb" ] && [ "$protocol" != "ssh" ]; then
        print_error "Invalid protocol specified in network configuration"
        return 1
    fi

    # Verify network connectivity
    if ! verify_network_connectivity "$protocol" "$location"; then
        print_error "Network location not reachable"
        return 1
    fi

    # Transfer the backup
    if ! transfer_backup "$backup_dir" "$location_id"; then
        print_error "Backup transfer failed"
        return 1
    fi

    print_success "Backup transferred successfully"
    return 0
}

###############################################################################
# Transfer Routes Menu
###############################################################################
transfer_routes_menu() {
    local route_base="$1"
    if [ -n "$route_base" ]; then
        # Simplified transfer menu when a route is already selected.
        while true; do
            clear
            echo "+----------------------------------------------------+"
            echo "│             Transfer Route: $route_base            │"
            echo "+----------------------------------------------------+"
            echo "│ Available Options:"
            echo "│ 1. Transfer this route"
            echo "│ 2. View Transfer Logs (for $route_base)"
            echo "│ 3. Resume Interrupted Transfers (for $route_base)"
            echo "│ Q. Back"
            echo "+----------------------------------------------+"
            read -p "Make a selection: " choice
            case $choice in
            1)
                local location_info
                location_info=$(select_network_location) || continue
                clear
                IFS=' ' read -r type json_location <<<"$location_info"
                server=$(echo "$json_location" | jq -r .server)
                share=$(echo "$json_location" | jq -r .share)
                path=$(echo "$json_location" | jq -r .path)
                label=$(echo "$json_location" | jq -r .label)
                echo "Selected Network Location: ${server}/${share}/${path} (${label})"
                IFS=' ' read -r type location <<<"$location_info"
                transfer_route "$route_base" "$location" "$type"
                ;;
            2)
                clear
                echo "+----------------------------------------------------+"
                echo "│           Transfer Logs for $route_base            │"
                echo "+----------------------------------------------------+"
                if [ -f "$CONFIG_DIR/transfer_logs.json" ]; then
                    jq -r --arg route "$route_base" '.[] | select(.route == $route) | "\(.timestamp) | \(.route) | \(.status) | \(.destination) | \(.size) | \(.duration)"' "$CONFIG_DIR/transfer_logs.json" | column -t -s'|'
                else
                    echo "No transfer logs found."
                fi
                pause_for_user
                ;;
            3)
                clear
                echo "+----------------------------------------------------+"
                echo "│     Interrupted Transfers for $route_base          │"
                echo "+----------------------------------------------------+"
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
            echo "│                  Transfer Routes                   │"
            echo "+----------------------------------------------------+"
            echo "│ Available Options:"
            echo "│ 1. Transfer single route"
            echo "│ 2. Transfer multiple routes"
            echo "│ 3. Transfer all routes"
            echo "│ 4. Manage network locations"
            echo "│ 5. View Transfer Logs (all routes)"
            echo "│ 6. Resume Interrupted Transfers (all routes)"
            echo "│ Q. Back"
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
                server=$(echo "$json_location" | jq -r .server)
                share=$(echo "$json_location" | jq -r .share)
                path=$(echo "$json_location" | jq -r .path)
                label=$(echo "$json_location" | jq -r .label)
                echo "Selected Network Location: ${server}/${share}/${path} (${label})"
                IFS=' ' read -r type location <<<"$location_info"
                transfer_route "$route_base" "$location" "$type"
                ;;
            2)
                echo "Option 2 not implemented."
                pause_for_user
                ;;
            3)
                clear
                local location_info
                location_info=$(select_network_location) || continue
                clear
                IFS=' ' read -r type json_location <<<"$location_info"
                server=$(echo "$json_location" | jq -r .server)
                share=$(echo "$json_location" | jq -r .share)
                path=$(echo "$json_location" | jq -r .path)
                label=$(echo "$json_location" | jq -r .label)
                echo "Selected Network Location: ${server}/${share}/${path} (${label})"
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
                    transfer_route "$route" "$location" "$type"
                done
                ;;
            4) manage_network_locations_menu ;;
            5)
                clear
                echo "+----------------------------------------------------+"
                echo "│                    Transfer Logs                   │"
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
                echo "│                Interrupted Transfers               │"
                echo "+----------------------------------------------------+"
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

sync_routes_menu() {
    clear
    if is_onroad; then
        print_error "Cannot sync routes while onroad."
        pause_for_user
        return
    fi
    echo "+--------------------------------------------+"
    echo "│              Sync Routes Menu              │"
    echo "+--------------------------------------------+"
    echo "│"
    echo "│ Available Options:"
    echo "│ 1. Sync all routes"
    echo "│ 2. Sync a selected route"
    echo "│ Q. Back"
    echo "+---------------------------------------------"
    read -p "Enter your choice: " sync_choice
    case $sync_choice in
    1)
        # First, let the user select a network location.
        local net_info
        net_info=$(select_network_location) || return
        IFS=' ' read -r type json_location <<<"$net_info"
        # Test connectivity.
        if ! verify_network_connectivity "$type" "$json_location"; then
            print_error "Network location not reachable."
            pause_for_user
            return
        fi
        # Sync all routes.
        local routes=()
        while IFS= read -r dir; do
            local route_base="${dir##*/}"
            route_base="${route_base%%--*}"
            [[ " ${routes[*]} " =~ " ${route_base} " ]] || routes+=("$route_base")
        done < <(find "$ROUTES_DIR" -maxdepth 1 -type d -name "*--*")
        for route in "${routes[@]}"; do
            print_info "Syncing route $route..."
            transfer_route "$route" "$json_location" "$type"
        done
        pause_for_user
        ;;
    2)
        # Let the user select a route then sync only that one.
        local route
        route=$(select_single_route) || return
        local net_info
        net_info=$(select_network_location) || return
        IFS=' ' read -r type json_location <<<"$net_info"
        if ! verify_network_connectivity "$type" "$json_location"; then
            print_error "Network location not reachable."
            pause_for_user
            return
        fi
        print_info "Syncing route $route..."
        transfer_route "$route" "$json_location" "$type"
        pause_for_user
        ;;
    [Qq]) return ;;
    *)
        print_error "Invalid choice."
        pause_for_user
        ;;
    esac
}

###############################################################################
# Backup Transfer Functions
###############################################################################
transfer_backup() {
    local backup_dir="$1"
    local network_id="$2"

    # Get network location details
    local location
    location=$(jq --arg id "$network_id" '.smb[] + .ssh[] | select(.location_id == $id)' "$NETWORK_CONFIG")
    if [ -z "$location" ]; then
        print_error "Network location not found"
        return 1
    fi

    local type
    type=$(echo "$location" | jq -r 'if has("share") then "smb" else "ssh" end')

    # Verify network connectivity
    if ! verify_network_connectivity "$type" "$location"; then
        print_error "Network location not reachable"
        return 1
    fi

    # Get device ID for path creation
    local device_id
    device_id=$(get_device_id)

    # Build remote path
    local remote_base
    remote_base=$(echo "$location" | jq -r '.path')
    local remote_path="${remote_base%/}/${device_id}/backups"

    case "$type" in
    smb)
        transfer_backup_smb "$backup_dir" "$location" "$remote_path"
        ;;
    ssh)
        transfer_backup_ssh "$backup_dir" "$location" "$remote_path"
        ;;
    esac
}

transfer_backup_smb() {
    local backup_dir="$1"
    local location="$2"
    local remote_path="$3"

    local server share username password
    server=$(echo "$location" | jq -r .server)
    share=$(echo "$location" | jq -r .share)
    username=$(echo "$location" | jq -r .username)
    password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")

    print_info "Transferring backup to SMB location..."

    # Create remote directory
    smbclient "//${server}/${share}" -U "${username}%${password}" \
        -c "mkdir \"$remote_path\"" >/dev/null 2>&1

    # Transfer the backup directory
    tar czf - -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")" |
        smbclient "//${server}/${share}" -U "${username}%${password}" \
            -c "cd \"$remote_path\"; put - backup.tar.gz" || {
        print_error "Failed to transfer backup"
        return 1
    }

    print_success "Backup transfer completed"
    return 0
}

transfer_backup_ssh() {
    local backup_dir="$1"
    local location="$2"
    local remote_path="$3"

    local server port username auth_type
    server=$(echo "$location" | jq -r .server)
    port=$(echo "$location" | jq -r .port)
    username=$(echo "$location" | jq -r .username)
    auth_type=$(echo "$location" | jq -r .auth_type)

    print_info "Transferring backup to SSH location..."

    # Create remote directory
    ssh -p "$port" "$username@$server" "mkdir -p '$remote_path'" || {
        print_error "Failed to create remote directory"
        return 1
    }

    # Transfer using rsync with appropriate auth
    if [ "$auth_type" = "password" ]; then
        local password
        password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")
        rsync -az -e "sshpass -p '$password' ssh -p $port" \
            "$backup_dir/" "$username@$server:$remote_path/" || {
            print_error "Failed to transfer backup"
            return 1
        }
    else
        local key_path
        key_path=$(echo "$location" | jq -r .key_path)
        rsync -az -e "ssh -p $port -i $key_path" \
            "$backup_dir/" "$username@$server:$remote_path/" || {
            print_error "Failed to transfer backup"
            return 1
        }
    fi

    print_success "Backup transfer completed"
    return 0
}

fetch_backup() {
    local dest_dir="$1"
    local location_info="$2"

    IFS=' ' read -r type json_location <<<"$location_info"

    # Create destination directory
    mkdir -p "$dest_dir"

    local server path username device_id
    server=$(echo "$json_location" | jq -r .server)
    path=$(echo "$json_location" | jq -r .path)
    username=$(echo "$json_location" | jq -r .username)
    device_id=$(get_device_id)

    # Build remote path
    local remote_path="${path%/}/${device_id}/backups"

    case "$type" in
    smb)
        local share password cred_file
        share=$(echo "$json_location" | jq -r .share)
        cred_file=$(echo "$json_location" | jq -r .credential_file)
        password=$(decrypt_credentials "$cred_file")

        print_info "Fetching backup from SMB location..."

        # Check if remote directory exists
        if ! smbclient "//${server}/${share}" -U "${username}%${password}" \
            -c "cd \"$remote_path\"" >/dev/null 2>&1; then
            print_error "Remote backup directory not found"
            return 1
        fi

        # Fetch the backup
        if ! smbclient "//${server}/${share}" -U "${username}%${password}" \
            -c "cd \"$remote_path\"; get backup.tar.gz \"$dest_dir/backup.tar.gz\"" >/dev/null; then
            print_error "Failed to fetch backup"
            return 1
        fi
        ;;

    ssh)
        local port auth_type
        port=$(echo "$json_location" | jq -r .port)
        auth_type=$(echo "$json_location" | jq -r .auth_type)

        print_info "Fetching backup from SSH location..."

        if [ "$auth_type" = "password" ]; then
            local password
            password=$(decrypt_credentials "$(echo "$json_location" | jq -r .credential_file)")
            if ! sshpass -p "$password" rsync -az -e "ssh -p $port" \
                "$username@$server:$remote_path/" "$dest_dir/"; then
                print_error "Failed to fetch backup via SSH (password auth)"
                return 1
            fi
        else
            local key_path
            key_path=$(echo "$json_location" | jq -r .key_path)
            if ! rsync -az -e "ssh -p $port -i $key_path" \
                "$username@$server:$remote_path/" "$dest_dir/"; then
                print_error "Failed to fetch backup via SSH (key auth)"
                return 1
            fi
        fi
        ;;

    *)
        print_error "Invalid location type: $type"
        return 1
        ;;
    esac

    # Extract the backup if it was downloaded as tar.gz
    if [ -f "$dest_dir/backup.tar.gz" ]; then
        cd "$dest_dir" || return 1
        tar xzf backup.tar.gz
        rm backup.tar.gz
    fi

    print_success "Backup fetched successfully"
    return 0
}

###############################################################################
# Network Location Management Functions (with label, storage_type, location_id)
###############################################################################
init_network_config() {
    mkdir -p "$CONFIG_DIR" "$CREDENTIALS_DIR"
    if [ ! -f "$NETWORK_CONFIG" ]; then
        # Initialize with empty locations array
        echo '{"locations":[]}' >"$NETWORK_CONFIG"
    fi
}

get_network_location_by_id() {
    local network_id="$1"
    local location
    location=$(jq --arg id "$network_id" '.locations[] | select(.location_id == $id)' "$NETWORK_CONFIG")
    if [ -z "$location" ] || [ "$location" = "null" ]; then
        print_error "Network location not found"
        return 1
    fi
    echo "$location"
    return 0
}

add_smb_location() {
    local location_type="$1"
    local type_label

    if [ "$location_type" = "route_sync" ]; then
        type_label="Route Sync"
    else
        type_label="Device Backup"
    fi

    # Check if location of this type already exists
    local existing_location
    existing_location=$(jq -r --arg type "$location_type" '.locations[] | select(.type == $type)' "$NETWORK_CONFIG")

    if [ -n "$existing_location" ]; then
        clear
        print_warning "A $type_label location is already configured."
        echo "Current configuration:"
        echo "Server: $(echo "$existing_location" | jq -r .server)"
        echo "Share: $(echo "$existing_location" | jq -r .share)"
        echo "Label: $(echo "$existing_location" | jq -r .label)"
        echo ""
        read -p "Do you want to replace this configuration? (y/N): " replace_choice
        if [[ ! "$replace_choice" =~ ^[Yy]$ ]]; then
            print_info "Configuration cancelled."
            pause_for_user
            return 1
        fi
        # Remove existing location before adding new one
        local temp_file="/tmp/network_config.json"
        jq --arg type "$location_type" '.locations = [.locations[] | select(.type != $type)]' "$NETWORK_CONFIG" >"$temp_file"
        mv "$temp_file" "$NETWORK_CONFIG"
    fi

    clear
    print_info "Add New SMB Share for $type_label..."
    print_info "----------------------------------------"
    read -p "Server (IP/hostname): " server
    read -p "Share name: " share
    read -p "Path [Inside $server/$share] (optional): " path
    read -p "Location Label (e.g. Home_NAS): " label
    read -p "Username: " username
    read -s -p "Password: (Will be encrypted): " password
    echo ""

    # Create credentials file with unique name based on type
    local cred_file="$CREDENTIALS_DIR/smb_${location_type}_${server}_${share}"
    encrypt_credentials "$password" "$cred_file" || {
        print_error "Encryption error."
        pause_for_user
        return 1
    }

    # Generate unique location ID
    local loc_id
    loc_id=$(generate_location_id "${server}_${share}_${label}_${location_type}")

    # Create location object
    local location
    location=$(jq -n \
        --arg server "$server" \
        --arg share "$share" \
        --arg path "$path" \
        --arg username "$username" \
        --arg cred_file "$cred_file" \
        --arg label "$label" \
        --arg type "$location_type" \
        --arg protocol "smb" \
        --arg location_id "$loc_id" \
        '{
            server: $server,
            share: $share,
            path: $path,
            username: $username,
            credential_file: $cred_file,
            label: $label,
            type: $type,
            protocol: $protocol,
            location_id: $location_id
        }')

    # Add to config
    local temp_file="/tmp/network_config.json"
    jq --argjson loc "$location" '.locations += [$loc]' "$NETWORK_CONFIG" >"$temp_file"
    mv "$temp_file" "$NETWORK_CONFIG"

    print_success "$type_label SMB share added successfully."
    pause_for_user
}

add_ssh_location() {
    local location_type="$1"
    local type_label

    if [ "$location_type" = "route_sync" ]; then
        type_label="Route Sync"
    else
        type_label="Device Backup"
    fi

    # Check if location of this type already exists
    local existing_location
    existing_location=$(jq -r --arg type "$location_type" '.locations[] | select(.type == $type)' "$NETWORK_CONFIG")

    if [ -n "$existing_location" ]; then
        clear
        print_warning "A $type_label location is already configured."
        echo "Current configuration:"
        echo "Server: $(echo "$existing_location" | jq -r .server)"
        echo "Port: $(echo "$existing_location" | jq -r .port)"
        echo "Label: $(echo "$existing_location" | jq -r .label)"
        echo ""
        read -p "Do you want to replace this configuration? (y/N): " replace_choice
        if [[ ! "$replace_choice" =~ ^[Yy]$ ]]; then
            print_info "Configuration cancelled."
            pause_for_user
            return 1
        fi
        # Remove existing location before adding new one
        local temp_file="/tmp/network_config.json"
        jq --arg type "$location_type" '.locations = [.locations[] | select(.type != $type)]' "$NETWORK_CONFIG" >"$temp_file"
        mv "$temp_file" "$NETWORK_CONFIG"
    fi

    clear
    print_info "Add New SSH Location for $type_label..."
    print_info "----------------------------------------"
    read -p "Server (IP/hostname): " server
    read -p "Port [22]: " port
    port=${port:-22}
    read -p "Path: " path
    read -p "Location Label (e.g. Home_Server): " label
    read -p "Username: " username

    echo "Authentication type:"
    echo "1. Password"
    echo "2. SSH Key"
    read -p "Select Authentication Type (1/2): " auth_choice

    # Generate unique location ID
    local loc_id
    loc_id=$(generate_location_id "${server}_${port}_${label}_${location_type}")

    local location
    if [ "$auth_choice" = "1" ]; then
        read -s -p "Password: (Will be encrypted): " password
        echo ""
        local cred_file="$CREDENTIALS_DIR/ssh_${location_type}_${server}_${port}"
        encrypt_credentials "$password" "$cred_file" || {
            print_error "Encryption error."
            pause_for_user
            return 1
        }
        location=$(jq -n \
            --arg server "$server" \
            --arg port "$port" \
            --arg path "$path" \
            --arg username "$username" \
            --arg cred_file "$cred_file" \
            --arg label "$label" \
            --arg type "$location_type" \
            --arg protocol "ssh" \
            --arg auth_type "password" \
            --arg location_id "$loc_id" \
            '{
                server: $server,
                port: $port,
                path: $path,
                username: $username,
                credential_file: $cred_file,
                label: $label,
                type: $type,
                protocol: $protocol,
                auth_type: $auth_type,
                location_id: $location_id
            }')
    elif [ "$auth_choice" = "2" ]; then
        read -p "SSH Key path: " key_path
        location=$(jq -n \
            --arg server "$server" \
            --arg port "$port" \
            --arg path "$path" \
            --arg username "$username" \
            --arg key_path "$key_path" \
            --arg label "$label" \
            --arg type "$location_type" \
            --arg protocol "ssh" \
            --arg auth_type "key" \
            --arg location_id "$loc_id" \
            '{
                server: $server,
                port: $port,
                path: $path,
                username: $username,
                key_path: $key_path,
                label: $label,
                type: $type,
                protocol: $protocol,
                auth_type: $auth_type,
                location_id: $location_id
            }')
    else
        print_error "Invalid authentication type."
        pause_for_user
        return 1
    fi

    # Add to config
    local temp_file="/tmp/network_config.json"
    jq --argjson loc "$location" '.locations += [$loc]' "$NETWORK_CONFIG" >"$temp_file"
    mv "$temp_file" "$NETWORK_CONFIG"

    print_success "$type_label SSH location added successfully."
    pause_for_user
}

test_all_connections() {
    clear
    echo "+----------------------------------------------+"
    echo "│           Testing Network Locations          │"
    echo "+----------------------------------------------+"

    # Test Route Sync Location
    local route_loc status
    route_loc=$(jq -r '.locations[] | select(.type == "route_sync")' "$NETWORK_CONFIG")
    if [ -n "$route_loc" ]; then
        local protocol label
        protocol=$(echo "$route_loc" | jq -r .protocol)
        label=$(echo "$route_loc" | jq -r .label)
        echo -n "Testing Route Sync Location ($label)... "
        if [ "$protocol" = "smb" ]; then
            status=$(test_smb_connection "$route_loc")
        else
            status=$(test_ssh_connection "$route_loc")
        fi
        if [ "$status" = "Valid" ]; then
            echo -e "${GREEN}Connected${NC}"
        else
            echo -e "${RED}Failed${NC}"
            echo "Error: $status"
        fi
    else
        echo -e "${YELLOW}No Route Sync Location configured${NC}"
    fi

    # Test Device Backup Location
    local backup_loc
    backup_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG")
    if [ -n "$backup_loc" ]; then
        local protocol label
        protocol=$(echo "$backup_loc" | jq -r .protocol)
        label=$(echo "$backup_loc" | jq -r .label)
        echo -n "Testing Device Backup Location ($label)... "
        if [ "$protocol" = "smb" ]; then
            status=$(test_smb_connection "$backup_loc")
        else
            status=$(test_ssh_connection "$backup_loc")
        fi
        if [ "$status" = "Valid" ]; then
            echo -e "${GREEN}Connected${NC}"
        else
            echo -e "${RED}Failed${NC}"
            echo "Error: $status"
        fi
    else
        echo -e "${YELLOW}No Device Backup Location configured${NC}"
    fi

    pause_for_user
}

test_smb_connection() {
    local location="$1"
    local server=$(echo "$location" | jq -r .server)
    local share=$(echo "$location" | jq -r .share)
    local username=$(echo "$location" | jq -r .username)
    local cred_file=$(echo "$location" | jq -r .credential_file)

    if [ ! -f "$cred_file" ]; then
        echo "Credential file not found"
        return 1
    fi

    local password
    password=$(decrypt_credentials "$cred_file")
    if [ -z "$password" ]; then
        echo "Failed to decrypt credentials"
        return 1
    fi

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

remove_network_location() {
    local location_type="$1"
    local type_label

    if [ "$location_type" = "route_sync" ]; then
        type_label="Route Sync"
    else
        type_label="Device Backup"
    fi

    local existing_location
    existing_location=$(jq -r --arg type "$location_type" '.locations[] | select(.type == $type)' "$NETWORK_CONFIG")

    if [ -z "$existing_location" ]; then
        print_error "No $type_label location configured."
        pause_for_user
        return 1
    fi

    clear
    echo "Current $type_label location:"
    echo "Server: $(echo "$existing_location" | jq -r .server)"
    if [ "$(echo "$existing_location" | jq -r .protocol)" = "smb" ]; then
        echo "Share: $(echo "$existing_location" | jq -r .share)"
    else
        echo "Port: $(echo "$existing_location" | jq -r .port)"
    fi
    echo "Label: $(echo "$existing_location" | jq -r .label)"
    echo ""

    read -p "Are you sure you want to remove this location? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local temp_file="/tmp/network_config.json"
        jq --arg type "$location_type" '.locations = [.locations[] | select(.type != $type)]' "$NETWORK_CONFIG" >"$temp_file"
        mv "$temp_file" "$NETWORK_CONFIG"

        # Remove credentials file if it exists
        local cred_file
        cred_file=$(echo "$existing_location" | jq -r '.credential_file // empty')
        if [ -n "$cred_file" ] && [ -f "$cred_file" ]; then
            rm -f "$cred_file"
        fi

        print_success "$type_label location removed."
    else
        print_info "Removal cancelled."
    fi
    pause_for_user
}

manage_network_locations_menu() {
    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "│         Network Location Management          │"
        echo "+----------------------------------------------+"

        # Show Route Sync Location
        local route_loc
        route_loc=$(jq -r '.locations[] | select(.type == "route_sync")' "$NETWORK_CONFIG")
        if [ -n "$route_loc" ]; then
            local protocol label status
            protocol=$(echo "$route_loc" | jq -r .protocol)
            label=$(echo "$route_loc" | jq -r .label)
            if [ "$protocol" = "smb" ]; then
                status=$(test_smb_connection "$route_loc")
            else
                status=$(test_ssh_connection "$route_loc")
            fi
            if [ "$status" = "Valid" ]; then
                echo -e "│ Route Sync Location:"
                echo -e "│  - Label: ${GREEN}$label${NC}"
                echo -e "│  - Protocol: ${GREEN}$protocol${NC}"
                echo -e "│  - Status: ${GREEN}Connected${NC}"
            else
                echo -e "│ Route Sync Location:"
                echo -e "│  - Label: ${RED}$label${NC}"
                echo -e "│  - Protocol: ${RED}$protocol${NC}"
                echo -e "│  - Status: ${RED}Disconnected${NC}"
            fi
        else
            echo -e "│ Route Sync Location: ${YELLOW}Not Configured${NC}"
        fi

        # Show Device Backup Location
        local backup_loc
        backup_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG")
        if [ -n "$backup_loc" ]; then
            local protocol label status
            protocol=$(echo "$backup_loc" | jq -r .protocol)
            label=$(echo "$backup_loc" | jq -r .label)
            if [ "$protocol" = "smb" ]; then
                status=$(test_smb_connection "$backup_loc")
            else
                status=$(test_ssh_connection "$backup_loc")
            fi
            if [ "$status" = "Valid" ]; then
                echo -e "│ Device Backup Location:"
                echo -e "│  - Label: ${GREEN}$label${NC}"
                echo -e "│  - Protocol: ${GREEN}$protocol${NC}"
                echo -e "│  - Status: ${GREEN}Connected${NC}"
            else
                echo -e "│ Device Backup Location:"
                echo -e "│  - Label: ${RED}$label${NC}"
                echo -e "│  - Protocol: ${RED}$protocol${NC}"
                echo -e "│  - Status: ${RED}Disconnected${NC}"
            fi
        else
            echo -e "│ Device Backup Location: ${YELLOW}Not Configured${NC}"
        fi

        echo "│"
        echo "│ Available Options:"
        echo "│ 1. Configure Route Sync Location"
        echo "│ 2. Configure Device Backup Location"
        echo "│ 3. Remove Route Sync Location"
        echo "│ 4. Remove Device Backup Location"
        echo "│ 5. Test Connections"
        echo "│ Q. Back"
        echo "+----------------------------------------------+"

        read -p "Make a selection: " choice
        case $choice in
        1) configure_network_location "route_sync" ;;
        2) configure_network_location "device_backup" ;;
        3) remove_network_location "route_sync" ;;
        4) remove_network_location "device_backup" ;;
        5) test_all_connections ;;
        [qQ]) return ;;
        *) print_error "Invalid choice." && pause_for_user ;;
        esac
    done
}

configure_network_location() {
    local location_type="$1"
    local type_label

    if [ "$location_type" = "route_sync" ]; then
        type_label="Route Sync"
    else
        type_label="Device Backup"
    fi

    clear
    echo "+----------------------------------------------+"
    echo "│       Configure $type_label Location         │"
    echo "+----------------------------------------------+"
    echo "│ Select Protocol:"
    echo "│ 1. SMB Share"
    echo "│ 2. SSH Location"
    echo "│ Q. Cancel"
    echo "+----------------------------------------------+"

    read -p "Enter choice: " protocol_choice

    case $protocol_choice in
    1)
        add_smb_location "$location_type"
        ;;
    2)
        add_ssh_location "$location_type"
        ;;
    [qQ])
        return
        ;;
    *)
        print_error "Invalid choice."
        pause_for_user
        return
        ;;
    esac
}

select_network_location() {
    local required_type="$1"
    local location

    # If type is specified, try to get that specific location
    if [ -n "$required_type" ]; then
        location=$(jq -r --arg type "$required_type" '.locations[] | select(.type == $type)' "$NETWORK_CONFIG")
        if [ -n "$location" ]; then
            echo "$location"
            return 0
        fi
        print_error "No location configured for $required_type"
        return 1
    fi

    # Otherwise, show selection menu
    clear
    echo "+----------------------------------------------+"
    echo "│         Select Network Location              │"
    echo "+----------------------------------------------+"

    local route_loc backup_loc
    route_loc=$(jq -r '.locations[] | select(.type == "route_sync")' "$NETWORK_CONFIG")
    backup_loc=$(jq -r '.locations[] | select(.type == "device_backup")' "$NETWORK_CONFIG")

    local count=1
    if [ -n "$route_loc" ]; then
        echo "$count) Route Sync: $(echo "$route_loc" | jq -r .label)"
        count=$((count + 1))
    fi
    if [ -n "$backup_loc" ]; then
        echo "$count) Device Backup: $(echo "$backup_loc" | jq -r .label)"
    fi

    if [ -z "$route_loc" ] && [ -z "$backup_loc" ]; then
        print_error "No network locations configured."
        return 1
    fi

    echo "Q) Cancel"
    echo "+----------------------------------------------+"

    read -p "Select location: " choice
    case $choice in
    1)
        if [ -n "$route_loc" ]; then
            echo "$route_loc"
            return 0
        fi
        ;;
    2)
        if [ -n "$backup_loc" ]; then
            echo "$backup_loc"
            return 0
        fi
        ;;
    [qQ]) return 1 ;;
    *) print_error "Invalid selection." ;;
    esac
    return 1
}
