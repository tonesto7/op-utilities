#!/bin/bash
###############################################################################
# jobs.sh - Device Job Management for CommaUtility
#
# Version: JOBS_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script manages device jobs for CommaUtility.
###############################################################################
readonly JOBS_SCRIPT_VERSION="3.0.0"
readonly JOBS_SCRIPT_MODIFIED="2025-02-10"

###############################################################################
# Job Management Functions
###############################################################################
update_job_in_launch_env() {
    local job_type="$1"
    local saved_network_location_id="$2"
    local startup_delay="${3:-0}"
    local start_marker end_marker command

    if [ "$job_type" = "backup" ]; then
        start_marker="### Start CommaUtility Backup"
        end_marker="### End CommaUtility Backup"
        command="/data/CommaUtility.sh --backup --network ${saved_network_location_id}"
    elif [ "$job_type" = "route_sync" ]; then
        start_marker="### Start CommaUtilityRoute Sync"
        end_marker="### End CommaUtilityRoute Sync"
        command="sleep ${startup_delay} && /data/CommaUtility.sh --route-sync --network ${saved_network_location_id}"
    fi

    # Remove any existing block from LAUNCH_ENV_FILE.
    sed -i "/^${start_marker}/,/^${end_marker}/d" "$LAUNCH_ENV_FILE"

    # Append the new block at the end of the file.
    cat <<EOF >>"$LAUNCH_ENV_FILE"
${start_marker}
${command}
${end_marker}
EOF
    print_success "Updated ${job_type} job in ${LAUNCH_ENV_FILE}"
}

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

    sed -i "/^${start_marker}/,/^${end_marker}/d" "$LAUNCH_ENV_FILE"
    print_success "${job_type} job removed from ${LAUNCH_ENV_FILE}"
    pause_for_user
}

###############################################################################
# Route Sync Job Management
###############################################################################

# Constants for route sync settings
readonly DEFAULT_STARTUP_DELAY=60
readonly DEFAULT_RETENTION_DAYS=30
readonly DEFAULT_AUTO_CONCAT=true

# Add to routes.sh

display_sync_status() {
    local status_file="$TRANSFER_STATE_DIR/route_sync_status.json"
    echo "┌───────────────────────────────────────────────"
    echo "│            Route Sync Status Report          "
    echo "├───────────────────────────────────────────────"

    # First display systemd service status
    display_service_status

    # Check if sync is enabled
    local sync_enabled=$(get_route_sync_setting "enabled")
    if [ "$sync_enabled" = "true" ]; then
        echo -e "│ Sync Status: ${GREEN}Enabled${NC}"
    else
        echo -e "│ Sync Status: ${RED}Disabled${NC}"
    fi

    # Display settings
    echo "│"
    echo "│ Current Settings:"
    echo "│ • Startup Delay: $(get_route_sync_setting "startup_delay") seconds"
    echo "│ • Retention Period: $(get_route_sync_setting "retention_days") days"
    echo "│ • Auto Concatenate: $(get_route_sync_setting "auto_concat")"

    # Display sync statistics
    if [ -f "$status_file" ]; then
        local total_synced=0
        local recent_syncs=0
        local now=$(date +%s)

        while IFS= read -r route_data; do
            total_synced=$((total_synced + 1))
            local sync_time
            sync_time=$(echo "$route_data" | jq -r '.last_sync')
            local sync_epoch=$(date -d "$sync_time" +%s)
            if [ $((now - sync_epoch)) -lt 86400 ]; then # Last 24 hours
                recent_syncs=$((recent_syncs + 1))
            fi
        done < <(jq -c '.[]' "$status_file")

        echo "│"
        echo "│ Sync Statistics:"
        echo "│ • Total Routes Synced: $total_synced"
        echo "│ • Synced in Last 24h: $recent_syncs"
    fi

    echo "└───────────────────────────────────────────────"
}

monitor_sync_progress() {
    local route_base="$1"
    local source_dir="$2"
    local total_size=0
    local processed_size=0

    # Calculate total size
    if [ -d "$source_dir/$route_base" ]; then
        total_size=$(du -b "$source_dir/$route_base" | cut -f1)
    fi

    # Display progress
    while [ -d "$source_dir/$route_base" ] && [ "$processed_size" -lt "$total_size" ]; do
        processed_size=$(du -b "$source_dir/$route_base" | cut -f1)
        local progress=$((processed_size * 100 / total_size))
        echo -ne "Progress: $progress% ($((processed_size / 1024 / 1024))MB / $((total_size / 1024 / 1024))MB)\r"
        sleep 1
    done
    echo
}

verify_sync_prerequisites() {
    local error_count=0

    # Check network location configuration
    if ! verify_network_config; then
        print_error "Network configuration is missing or invalid"
        error_count=$((error_count + 1))
    fi

    # Check for routes directory
    if [ ! -d "$ROUTES_DIR" ]; then
        print_error "Routes directory not found"
        error_count=$((error_count + 1))
    fi

    # Check available disk space
    local available_space
    available_space=$(df -m "$ROUTES_DIR" | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 1000 ]; then
        print_warning "Low disk space: ${available_space}MB available"
        error_count=$((error_count + 1))
    fi

    # Check required tools
    local required_tools=("rsync" "smbclient" "ssh" "jq")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            print_error "Required tool not found: $tool"
            error_count=$((error_count + 1))
        fi
    done

    return $error_count
}

check_sync_job_status() {
    if [ ! -f "$LAUNCH_ENV_FILE" ]; then
        return 1
    fi

    grep -q "### Start CommaUtilityRoute Sync" "$LAUNCH_ENV_FILE"
    return $?
}

validate_route_sync_settings() {
    local config_file="$CONFIG_DIR/route_sync_config.json"
    if [ ! -f "$config_file" ]; then
        print_error "Route sync configuration file not found"
        return 1
    fi

    local startup_delay=$(get_route_sync_setting "startup_delay")
    local retention_days=$(get_route_sync_setting "retention_days")
    local auto_concat=$(get_route_sync_setting "auto_concat")

    local valid=true

    # Validate startup delay
    if ! [[ "$startup_delay" =~ ^[0-9]+$ ]] || [ "$startup_delay" -lt 0 ] || [ "$startup_delay" -gt 3600 ]; then
        print_error "Invalid startup delay: $startup_delay (should be between 0 and 3600)"
        valid=false
    fi

    # Validate retention days
    if ! [[ "$retention_days" =~ ^[0-9]+$ ]] || [ "$retention_days" -lt 1 ] || [ "$retention_days" -gt 90 ]; then
        print_error "Invalid retention days: $retention_days (should be between 1 and 90)"
        valid=false
    fi

    # Validate auto concat
    if [ "$auto_concat" != "true" ] && [ "$auto_concat" != "false" ]; then
        print_error "Invalid auto_concat value: $auto_concat (should be true or false)"
        valid=false
    fi

    $valid && return 0 || return 1
}

log_sync_event() {
    local event_type="$1"
    local message="$2"
    local log_file="$CONFIG_DIR/route_sync.log"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] [$event_type] $message" >>"$log_file"

    # Rotate log if it gets too large (keep last 1000 lines)
    if [ -f "$log_file" ] && [ $(wc -l <"$log_file") -gt 1000 ]; then
        tail -n 1000 "$log_file" >"${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
    fi
}

view_sync_logs() {
    local log_file="$CONFIG_DIR/route_sync.log"

    if [ ! -f "$log_file" ]; then
        print_error "No sync logs found"
        return 1
    fi

    clear
    echo "┌───────────────────────────────────────────────"
    echo "│              Route Sync Logs                 "
    echo "├───────────────────────────────────────────────"

    tail -n 50 "$log_file"

    echo "└───────────────────────────────────────────────"
    echo "Showing last 50 log entries"
    pause_for_user
}

init_route_sync_config() {
    # Initialize route sync configuration if it doesn't exist
    local config_file="$CONFIG_DIR/route_sync_config.json"
    if [ ! -f "$config_file" ]; then
        cat >"$config_file" <<EOF
{
    "sync_settings": {
        "startup_delay": $DEFAULT_STARTUP_DELAY,
        "retention_days": $DEFAULT_RETENTION_DAYS,
        "enabled": false,
        "auto_concat": true
    }
}
EOF
    fi
}

get_route_sync_setting() {
    local setting="$1"
    local config_file="$CONFIG_DIR/route_sync_config.json"
    jq -r ".sync_settings.$setting" "$config_file"
}

update_route_sync_setting() {
    local setting="$1"
    local value="$2"
    local config_file="$CONFIG_DIR/route_sync_config.json"
    local temp_file="/tmp/route_sync_config.json"

    jq --arg setting "$setting" --arg value "$value" \
        '.sync_settings[$setting] = $value' "$config_file" >"$temp_file" &&
        mv "$temp_file" "$config_file"
}

configure_route_sync_job() {
    clear
    local config_file="$CONFIG_DIR/route_sync_config.json"

    echo "┌───────────────────────────────────────────────"
    echo "│         Route Sync Job Configuration         "
    echo "├───────────────────────────────────────────────"
    echo "│ Current Settings:"
    echo "│ 1. Startup Delay: $(get_route_sync_setting "startup_delay") seconds"
    echo "│ 2. Retention Period: $(get_route_sync_setting "retention_days") days"
    echo "│ 3. Auto Concatenate: $(get_route_sync_setting "auto_concat")"
    echo "│ 4. Job Status: $(get_route_sync_setting "enabled")"
    echo "│"
    echo "│ 5. Apply Changes and Update Service"
    echo "│ Q. Back"
    echo "└───────────────────────────────────────────────"

    read -p "Enter your choice: " choice
    case $choice in
    1)
        read -p "Enter startup delay in seconds [0-3600]: " delay
        if [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -ge 0 ] && [ "$delay" -le 3600 ]; then
            update_route_sync_setting "startup_delay" "$delay"
            if service_needs_update; then
                update_service
            fi
            print_success "Startup delay updated"
        else
            print_error "Invalid delay value"
        fi
        ;;
    2)
        read -p "Enter retention period in days [1-90]: " days
        if [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -ge 1 ] && [ "$days" -le 90 ]; then
            update_route_sync_setting "retention_days" "$days"
            if service_needs_update; then
                update_service
            fi
            print_success "Retention period updated"
        else
            print_error "Invalid retention period"
        fi
        ;;
    3)
        read -p "Enable auto concatenate? [y/N]: " auto_concat
        if [[ "$auto_concat" =~ ^[Yy]$ ]]; then
            update_route_sync_setting "auto_concat" "true"
        else
            update_route_sync_setting "auto_concat" "false"
        fi
        if service_needs_update; then
            update_service
        fi
        print_success "Auto concatenate setting updated"
        ;;
    4)
        local current_status=$(get_route_sync_setting "enabled")
        if [ "$current_status" = "true" ]; then
            update_route_sync_setting "enabled" "false"
            disable_route_sync_service
            print_success "Route sync service disabled"
        else
            update_route_sync_setting "enabled" "true"
            enable_route_sync_service
            print_success "Route sync service enabled"
        fi
        ;;
    5)
        if [ "$(get_route_sync_setting "enabled")" = "true" ]; then
            if service_needs_update; then
                update_service
                print_success "Service configuration updated"
            else
                print_info "Service configuration is up to date"
            fi
        else
            print_warning "Route sync is disabled. Enable it first."
        fi
        ;;
    [qQ]) return ;;
    *) print_error "Invalid choice" ;;
    esac
    pause_for_user
}

sync_routes() {
    local network_location_id="$1"
    if [ -z "$network_location_id" ]; then
        network_location_id=$(select_network_location_id "route_backup")
        if [ -z "$network_location_id" ]; then
            print_error "No route backup location configured"
            return 1
        fi
    fi

    # Verify network connectivity
    local location=$(get_network_location_by_id "$network_location_id")
    if ! verify_network_connectivity "route_backup" "$location"; then
        print_error "Network location not accessible"
        return 1
    fi

    print_info "Starting route sync operation..."

    # Get sync settings
    local retention_days=$(get_route_sync_setting "retention_days")
    local auto_concat=$(get_route_sync_setting "auto_concat")
    local processed_count=0
    local error_count=0

    # Create temp directory for concatenated routes
    local temp_dir="/tmp/route_sync"
    mkdir -p "$temp_dir"

    # Process each unique route
    while IFS= read -r route_base; do
        route_base="${route_base##*/}"
        route_base="${route_base%%--*}"

        print_info "Processing route: $route_base"

        # Skip if already synced recently
        if check_route_sync_status "$route_base"; then
            print_info "Route $route_base already synced recently, skipping"
            continue
        fi

        # Auto concatenate if enabled
        if [ "$auto_concat" = "true" ]; then
            print_info "Concatenating route files..."
            local concat_dir="$temp_dir/$route_base"
            mkdir -p "$concat_dir"

            if ! concat_route_segments "$route_base" "rlog" "$concat_dir" "true" ||
                ! concat_route_segments "$route_base" "qlog" "$concat_dir" "true" ||
                ! concat_route_segments "$route_base" "video" "$concat_dir" "true"; then
                print_error "Failed to concatenate route $route_base"
                error_count=$((error_count + 1))
                continue
            fi
        fi

        # Sync to network location
        if sync_route_to_network "$route_base" "$network_location_id" "$temp_dir"; then
            processed_count=$((processed_count + 1))
            update_route_sync_status "$route_base"

            # Handle retention if sync successful
            if [ "$retention_days" -gt 0 ]; then
                cleanup_synced_route "$route_base" "$retention_days"
            fi
        else
            error_count=$((error_count + 1))
        fi
    done < <(find "$ROUTES_DIR" -maxdepth 1 -type d -name "*--*" | sort -u)

    # Cleanup
    rm -rf "$temp_dir"

    print_info "Sync operation completed:"
    echo "Successfully processed: $processed_count routes"
    if [ "$error_count" -gt 0 ]; then
        print_error "Failed to process: $error_count routes"
    fi

    return $((error_count > 0))
}

sync_route_to_network() {
    local route_base="$1"
    local location_id="$2"
    local source_dir="$3"
    local location=$(get_network_location_by_id "$location_id")
    local protocol=$(echo "$location" | jq -r .protocol)

    case "$protocol" in
    "smb")
        sync_route_to_smb "$route_base" "$location" "$source_dir"
        return $?
        ;;
    "ssh")
        sync_route_to_ssh "$route_base" "$location" "$source_dir"
        return $?
        ;;
    *)
        print_error "Unsupported protocol: $protocol"
        return 1
        ;;
    esac
}

sync_route_to_smb() {
    local route_base="$1"
    local location="$2"
    local source_dir="$3"

    local server share username path
    server=$(echo "$location" | jq -r .server)
    share=$(echo "$location" | jq -r .share)
    username=$(echo "$location" | jq -r .username)
    path=$(echo "$location" | jq -r .path)

    local password
    password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")
    if [ -z "$password" ]; then
        print_error "Failed to decrypt network credentials"
        return 1
    fi

    # Get dongle-specific backup path
    local remote_path=$(get_network_backup_path "$path/routes/$route_base")

    # Create remote directory structure
    smbclient "//${server}/${share}" -U "${username}%${password}" -c "mkdir \"${remote_path}\"" 2>/dev/null

    # Upload files
    if [ -d "$source_dir/$route_base" ]; then
        for file in "$source_dir/$route_base"/*; do
            if ! smbclient "//${server}/${share}" -U "${username}%${password}" \
                -c "put \"${file}\" \"${remote_path}/$(basename "$file")\""; then
                print_error "Failed to upload $(basename "$file")"
                return 1
            fi
        done
    fi
    return 0
}

sync_route_to_ssh() {
    local route_base="$1"
    local location="$2"
    local source_dir="$3"

    local server port username path auth_type
    server=$(echo "$location" | jq -r .server)
    port=$(echo "$location" | jq -r .port)
    username=$(echo "$location" | jq -r .username)
    path=$(echo "$location" | jq -r .path)
    auth_type=$(echo "$location" | jq -r .auth_type)

    # Get dongle-specific backup path
    local remote_path=$(get_network_backup_path "$path/routes/$route_base")

    # Create remote directory
    if [ "$auth_type" = "password" ]; then
        local password
        password=$(decrypt_credentials "$(echo "$location" | jq -r .credential_file)")
        sshpass -p "$password" ssh -p "$port" "${username}@${server}" "mkdir -p \"${remote_path}\""

        # Upload files using scp
        if [ -d "$source_dir/$route_base" ]; then
            sshpass -p "$password" scp -P "$port" -r "$source_dir/$route_base/"* \
                "${username}@${server}:${remote_path}/"
        fi
    else
        local key_path
        key_path=$(echo "$location" | jq -r .key_path)
        ssh -i "$key_path" -p "$port" "${username}@${server}" "mkdir -p \"${remote_path}\""

        # Upload files using scp
        if [ -d "$source_dir/$route_base" ]; then
            scp -i "$key_path" -P "$port" -r "$source_dir/$route_base/"* \
                "${username}@${server}:${remote_path}/"
        fi
    fi

    return $?
}

check_route_sync_status() {
    local route_base="$1"
    local status_file="$TRANSFER_STATE_DIR/route_sync_status.json"

    if [ ! -f "$status_file" ]; then
        echo "{}" >"$status_file"
        return 1
    fi

    local last_sync
    last_sync=$(jq -r --arg route "$route_base" '.[$route].last_sync' "$status_file")

    if [ "$last_sync" = "null" ] || [ -z "$last_sync" ]; then
        return 1
    fi

    # Check if sync was recent enough (within retention period)
    local retention_days=$(get_route_sync_setting "retention_days")
    local now=$(date +%s)
    local sync_time=$(date -d "$last_sync" +%s)
    local days_diff=$(((now - sync_time) / 86400))

    [ "$days_diff" -lt "$retention_days" ]
}

update_route_sync_status() {
    local route_base="$1"
    local status_file="$TRANSFER_STATE_DIR/route_sync_status.json"
    local temp_file="/tmp/route_sync_status.json"

    if [ ! -f "$status_file" ]; then
        echo "{}" >"$status_file"
    fi

    local current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    jq --arg route "$route_base" \
        --arg time "$current_time" \
        '.[$route] = {"last_sync": $time}' "$status_file" >"$temp_file" &&
        mv "$temp_file" "$status_file"
}

cleanup_synced_route() {
    local route_base="$1"
    local retention_days="$2"

    local status_file="$TRANSFER_STATE_DIR/route_sync_status.json"
    if [ ! -f "$status_file" ]; then
        return 1
    fi

    local last_sync
    last_sync=$(jq -r --arg route "$route_base" '.[$route].last_sync' "$status_file")
    if [ -z "$last_sync" ] || [ "$last_sync" = "null" ]; then
        return 1
    fi

    local sync_time=$(date -d "$last_sync" +%s)
    local now=$(date +%s)
    local days_old=$(((now - sync_time) / 86400))

    if [ "$days_old" -gt "$retention_days" ]; then
        print_info "Cleaning up route $route_base (older than $retention_days days)"
        for segment in "$ROUTES_DIR/$route_base"--*; do
            if [ -d "$segment" ]; then
                rm -rf "$segment"
            fi
        done
        return 0
    fi
    return 1
}
