#!/bin/bash
###############################################################################
# routes.sh - Device Route Management Functions for CommaUtility
#
# Version: ROUTES_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script manages device route operations (sync, concatenate, etc.)
###############################################################################
readonly ROUTES_SCRIPT_VERSION="3.0.0"
readonly ROUTES_SCRIPT_MODIFIED="2025-02-09"

# Routes Related Constants
readonly ROUTES_DIR="/data/media/0/realdata"
readonly ROUTES_DIR_BACKUP="/data/media/0/realdata_backup"
readonly CONCAT_DIR="/data/tmp/concat_tmp"

###############################################################################
# Existing Route Management Functions
###############################################################################
get_route_path() {
    local route_base="$1"
    find "$ROUTES_DIR" -maxdepth 1 -type d -name "${route_base}--*" | head -n 1
}

verify_route_exists() {
    local route_base="$1"
    local route_path
    route_path=$(get_route_path "$route_base")
    [ -n "$route_path" ] && [ -d "$route_path" ]
}

handle_route_error() {
    local error_msg="$1"
    local error_code="${2:-1}"
    print_error "$error_msg"
    log_error "Route operation failed: $error_msg"
    return "$error_code"
}

is_valid_route() {
    local route="$1"
    [[ -n "$route" && -d "$ROUTES_DIR/$route" ]]
}

format_route_timestamp() {
    local route_dir="$1"
    local first_segment
    first_segment=$(find "$ROUTES_DIR" -maxdepth 1 -name "${route_dir}--*" | sort | head -1)
    if [ -d "$first_segment" ]; then
        stat -c %y "$first_segment" | cut -d. -f1
    else
        echo "Unknown"
    fi
}

cleanup_route_files() {
    local days_old="$1"
    find "$ROUTES_DIR" -maxdepth 1 -type d -name "*--*" -mtime +"$days_old" -exec rm -rf {} \;
}

manage_route_storage() {
    local total_size
    total_size=$(du -s "$ROUTES_DIR" 2>/dev/null | cut -f1)
    local max_size=$((50 * 1024 * 1024)) # 50GB in KB

    if [ "$total_size" -gt "$max_size" ]; then
        print_warning "Route storage exceeds 50GB. Starting cleanup..."
        cleanup_route_files 30 # Remove routes older than 30 days
    fi
}

get_route_duration() {
    local route_base="$1"
    local segments total_duration=0
    segments=$(find "$ROUTES_DIR" -maxdepth 1 -type d -name "${route_base}--*" | wc -l)
    total_duration=$((segments * 60))
    printf "%02d:%02d:%02d" $((total_duration / 3600)) $(((total_duration % 3600) / 60)) $((total_duration % 60))
}

get_segment_count() {
    local route_base="$1"
    find "$ROUTES_DIR" -maxdepth 1 -type d -name "${route_base}--*" | wc -l
}

check_route_status() {
    local route_count=0
    local total_size=0
    local sync_pending=0

    if [ -d "$ROUTES_DIR" ]; then
        route_count=$(find "$ROUTES_DIR" -maxdepth 1 -type d -name "*--*" | wc -l)
        total_size=$(du -sh "$ROUTES_DIR" 2>/dev/null | cut -f1)

        # Check for unsynchronized routes
        if [ -f "$NETWORK_CONFIG" ]; then
            local route_loc
            route_loc=$(jq -r '.locations[] | select(.type == "route_sync")' "$NETWORK_CONFIG")
            if [ -n "$route_loc" ]; then
                sync_pending=$(find "$ROUTES_DIR" -maxdepth 1 -type d -name "*--*" | while read -r route; do
                    local route_base
                    route_base=$(basename "$route" | sed 's/--.*$//')
                    if ! grep -q "$route_base" "$TRANSFER_STATE_DIR"/*; then
                        echo "1"
                        break
                    fi
                done)
            fi
        fi
    fi

    echo "Routes: $route_count | Size: $total_size | Pending Sync: $sync_pending"
}

concat_route_segments() {
    local route_base="$1" concat_type="$2" output_dir="$3" keep_originals="$4"
    mkdir -p "$CONCAT_DIR"
    local total_segments current_segment=0
    total_segments=$(get_segment_count "$route_base")
    case "$concat_type" in
    rlog)
        local output_file="$output_dir/rlog"
        : >"$output_file"
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
        local file_size
        file_size=$(du -h "$output_file" | cut -f1)
        print_success "RLog concatenation completed ($current_segment/$total_segments segments) [$file_size]"
        ;;
    qlog)
        local output_file="$output_dir/qlog"
        : >"$output_file"
        for segment in "$ROUTES_DIR/$route_base"--*; do
            if [ -f "$segment/qlog" ]; then
                current_segment=$((current_segment + 1))
                echo -ne "Processing qlog segment $current_segment/$total_segments\r"
                cat "$segment/qlog" >>"$output_file"
            fi
        done
        local file_size
        file_size=$(du -h "$output_file" | cut -f1)
        print_success "QLog concatenation completed ($current_segment/$total_segments segments) [$file_size]"
        ;;
    video)
        if ! command -v ffmpeg >/dev/null 2>&1; then
            print_error "ffmpeg not found. Cannot concatenate video files."
            return 1
        fi
        local cameras=("dcamera" "ecamera" "fcamera" "qcamera")
        local extensions=("hevc" "hevc" "hevc" "ts")
        for i in "${!cameras[@]}"; do
            local camera="${cameras[$i]}" ext="${extensions[$i]}"
            local output_file="$output_dir/${camera}.${ext}"
            [ -f "$output_file" ] && {
                print_info "Removing existing output file: $output_file"
                rm -f "$output_file"
            }
            local concat_list="$CONCAT_DIR/${camera}_concat_list.txt"
            : >"$concat_list"
            local total_camera_segments=0 cam_segment=0
            for segment in "$ROUTES_DIR/$route_base"--*; do
                [ -f "$segment/$camera.$ext" ] && total_camera_segments=$((total_camera_segments + 1))
            done
            [ "$total_camera_segments" -eq 0 ] && {
                print_info "No segments for $camera, skipping."
                continue
            }
            for segment in "$ROUTES_DIR/$route_base"--*; do
                if [ -f "$segment/$camera.$ext" ]; then
                    cam_segment=$((cam_segment + 1))
                    printf "\rProcessing %s segment %d/%d" "$camera" "$cam_segment" "$total_camera_segments"
                    echo "file '$segment/$camera.$ext'" >>"$concat_list"
                fi
            done
            printf "\r\033[K"
            print_info "Concatenating $camera videos..."
            [ ! -s "$concat_list" ] && {
                print_error "No video segments found for $camera."
                continue
            }
            ffmpeg -nostdin -y -f concat -safe 0 -i "$concat_list" -c copy -fflags +genpts "$output_file" -progress pipe:1 2>&1 |
                while read -r line; do
                    if [[ $line =~ time=([0-9:.]+) ]]; then
                        printf "\r\033[KProgress: %s" "${BASH_REMATCH[1]}"
                    fi
                done
            ret=${PIPESTATUS[0]}
            printf "\r\033[K"
            [ $ret -ne 0 ] && {
                print_error "Failed to concatenate $camera videos"
                return 1
            }
            local file_size
            file_size=$(du -h "$output_file" | cut -f1)
            print_success "$camera concatenation completed ($total_camera_segments segments) [$file_size]"
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
    local route_base="$1" output_dir="$ROUTES_DIR/concatenated"
    mkdir -p "$output_dir"
    while true; do
        clear
        echo "+----------------------------------------------+"
        echo "│            Concatenate Route Files           │"
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

###############################################################################
# Overhauled view_routes_menu and supporting functions
###############################################################################

display_routes_table() {
    echo "+-------------------------------------------------------"
    echo "│ Gathering Route Statistics..."
    local stats
    stats=$(display_route_stats)
    # Remove the "Gathering" message by clearing the previous line
    tput cuu1 && tput el
    echo "$stats"

    # Collect unique route bases.
    local routes=() seen_routes=()
    while IFS= read -r dir; do
        local route_base="${dir##*/}"
        route_base="${route_base%%--*}"
        if [[ ! " ${seen_routes[*]} " =~ " ${route_base} " ]]; then
            routes+=("$route_base")
            seen_routes+=("$route_base")
        fi
    done < <(find "$ROUTES_DIR" -maxdepth 1 -type d -name "*--*" | sort -r)

    # Check if no routes were found.
    if [ ${#routes[@]} -eq 0 ]; then
        echo "+------------------------------------------------------+"
        echo "│                 No routes available                  │"
        echo "+------------------------------------------------------+"
        return 0
    fi

    echo "│ Available Routes (newest first):"
    echo "+-------------------------------------------------------"
    # Table header
    printf "│%-4s | %-17s | %-8s | %-6s | %-6s |\n" "#" "Date & Time" "Duration" "Segs" "Size"
    echo "+-------------------------------------------------------"

    local count=1
    for route in "${routes[@]}"; do
        local segments timestamp friendly_date duration duration_short size
        segments=$(find "$ROUTES_DIR" -maxdepth 1 -type d -name "${route}--*" | wc -l)
        timestamp=$(format_route_timestamp "$route")
        friendly_date=$(date -d "$timestamp" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$timestamp")
        duration=$(get_route_duration "$route")
        duration_short=$(echo "$duration" | sed 's/^00://')
        size=$(du -sh "$ROUTES_DIR"/${route}--* 2>/dev/null | head -1 | awk '{print $1}')
        local line
        line=$(printf "│%3d. | %-17s | %8s | %6d | %6s │" "$count" "$friendly_date" "$duration_short" "$segments" "$size")
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

    echo "+-------------------------------------------------------"
    echo "│ Legend:"
    echo -e "│ ${GREEN}■${NC} Long trips (>20 segments)"
    echo -e "│ ${BLUE}■${NC} Medium trips (11-20 segments)"
    echo -e "│ ${YELLOW}■${NC} Single segment trips"
    echo -e "│ ${NC}■${NC} Short trips (2-10 segments)"
    echo "+-------------------------------------------------------"
}

view_routes_menu() {
    while true; do
        clear
        update_route_cache
        display_routes_table

        echo "│"
        echo "│ Available Options:"
        echo "│ 1. View route details"
        echo "│ 2. Remove a single route"
        echo "│ 3. Remove ALL routes"
        echo "│ 4. Sync a single route"
        echo "│ 5. Sync ALL routes"
        echo "│ 6. Manage Network Locations"
        echo "│ Q. Back to Main Menu"
        echo "+-------------------------------------------------------"

        read -p "Select an option: " choice
        case "$choice" in
        1) view_route_details_interactive ;;
        2) remove_single_route_interactive ;;
        3) remove_all_routes_interactive ;;
        4) sync_single_route_interactive ;;
        5) sync_all_routes_interactive ;;
        6) manage_network_locations_menu ;;
        [qQ]) return ;;
        *)
            print_error "Invalid choice."
            pause_for_user
            ;;
        esac
    done
}

###############################################################################
# Display detailed info for a selected route.
view_route_details_interactive() {
    clear
    local route
    route=$(select_single_route) || return
    view_route_details "$route"
    pause_for_user
}

###############################################################################
# Remove a single route (all its segments) after confirmation.
remove_single_route_interactive() {
    clear
    local route
    route=$(select_single_route) || return
    read -p "Are you sure you want to remove route '$route'? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for dir in "$ROUTES_DIR"/"${route}"--*; do
            rm -rf "$dir"
        done
        print_success "Route '$route' removed."
    else
        print_info "Removal canceled."
    fi
    update_route_cache
    pause_for_user
}

###############################################################################
# Bulk removal of all routes.
remove_all_routes_interactive() {
    clear
    read -p "Are you sure you want to remove ALL routes? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for dir in "$ROUTES_DIR"/*--*; do
            rm -rf "$dir"
        done
        print_success "All routes removed."
    else
        print_info "Bulk removal canceled."
    fi
    update_route_cache
    pause_for_user
}

###############################################################################
# Sync a single route (select route, then select network location)
sync_single_route_interactive() {
    clear
    local route
    route=$(select_single_route) || return
    local net_info
    net_info=$(select_network_location) || return
    IFS=' ' read -r type json_location <<<"$net_info"
    # Verify connectivity using the helper
    if ! verify_network_connectivity "$type" "$json_location"; then
        print_error "Network location not reachable."
        pause_for_user
        return
    fi
    transfer_route "$route" "$json_location" "$type"
    pause_for_user
}

###############################################################################
# Bulk sync of all routes.
sync_all_routes_interactive() {
    clear
    local net_info
    net_info=$(select_network_location) || return
    IFS=' ' read -r type json_location <<<"$net_info"
    if ! verify_network_connectivity "$type" "$json_location"; then
        print_error "Network location not reachable."
        pause_for_user
        return
    fi
    local routes=()
    while IFS= read -r dir; do
        local route_base="${dir##*/}"
        route_base="${route_base%%--*}"
        # Avoid duplicates
        if [[ ! " ${routes[*]} " =~ " ${route_base} " ]]; then
            routes+=("$route_base")
        fi
    done < <(find "$ROUTES_DIR" -maxdepth 1 -type d -name "*--*")
    for route in "${routes[@]}"; do
        transfer_route "$route" "$json_location" "$type"
    done
    pause_for_user
}

###############################################################################
# Route Cache and Viewing Functions
###############################################################################
update_route_cache() {
    local cache_file="$CONFIG_DIR/route_cache.json" cache_duration=300 now
    now=$(date +%s)
    if [ -f "$cache_file" ]; then
        local last_modified
        last_modified=$(stat -c %Y "$cache_file")
        ((now - last_modified < cache_duration)) && return 0
    fi
    local routes=()
    while IFS= read -r dir; do
        local base_name route_base="${dir##*/}"
        route_base="${route_base%%--*}"
        [[ " ${routes[*]} " =~ " ${route_base} " ]] || routes+=("$route_base")
    done < <(find "$ROUTES_DIR" -maxdepth 1 -type d -name "*--*")
    local routes_details=()
    for route in "${routes[@]}"; do
        local segments timestamp duration size
        segments=$(find "$ROUTES_DIR" -maxdepth 1 -type d -name "${route}--*" | wc -l)
        timestamp=$(format_route_timestamp "$route")
        duration=$(get_route_duration "$route")
        size=$(du -sh "$ROUTES_DIR"/${route}--* 2>/dev/null | head -1 | awk '{print $1}')
        local details
        details=$(jq -n --arg route "$route" --arg timestamp "$timestamp" --arg duration "$duration" --arg segments "$segments" --arg size "$size" \
            '{route: $route, timestamp: $timestamp, duration: $duration, segments: $segments, size: $size}')
        routes_details+=("$details")
    done
    printf '%s\n' "${routes_details[@]}" | jq -s '.' >"$cache_file"
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
        echo "│             Select a Route to Transfer             │"
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
    jq -r ".[$idx].route" "$cache_file"
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
    local route_base="$1" segments
    segments=$(get_segment_count "$route_base")
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
    local route_base="$1" segment="0"
    if [ ! -f "$ROUTES_DIR/${route_base}--${segment}/fcamera.hevc" ]; then
        print_error "Video file not found."
        return 1
    fi
    if command -v ffplay >/dev/null 2>&1; then
        ffplay "$ROUTES_DIR/${route_base}--${segment}/fcamera.hevc"
    else
        print_error "ffplay not installed."
    fi
    pause_for_user
}

view_route_details() {
    local route_base="$1"
    update_route_cache
    local cache_file="$CONFIG_DIR/route_cache.json" route_detail
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
        echo "│                Route Details                 │"
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
        echo "4. Play Video"
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

display_route_stats() {
    update_route_cache
    local cache_file="$CONFIG_DIR/route_cache.json"
    local total_routes total_segments total_size_bytes total_size
    total_routes=$(jq 'length' "$cache_file")
    total_segments=$(jq '[.[].segments | tonumber] | add' "$cache_file")
    total_size_bytes=$(find "$ROUTES_DIR" -maxdepth 1 -name "*--*" -type d -exec du -b {} + | awk '{sum += $1} END {print sum}')
    total_size=$(numfmt --to=iec-i --suffix=B "$total_size_bytes")
    echo "│ Routes: $total_routes | Segments: $total_segments"
    echo "│ Total Size: $total_size"
    echo "+------------------------------------------------------+"
}
