#!/bin/bash
###############################################################################
# systemd.sh - Systemd Service Management Functions for CommaUtility
#
# Version: SYSTEMD_SCRIPT_VERSION="3.0.0"
# Last Modified: 2025-02-10
#
# This script manages systemd services for route syncing and other tasks
###############################################################################

readonly SYSTEMD_SERVICE_DIR="/etc/systemd/system"
readonly ROUTE_SYNC_SERVICE="comma-route-sync.service"

create_route_sync_service() {
    local service_path="$SYSTEMD_SERVICE_DIR/$ROUTE_SYNC_SERVICE"
    local location_id="$1"

    # Get all sync settings
    local startup_delay=$(get_route_sync_setting "startup_delay")
    local retention_days=$(get_route_sync_setting "retention_days")
    local auto_concat=$(get_route_sync_setting "auto_concat")

    # Validate location ID
    if [ -z "$location_id" ]; then
        local network_location
        network_location=$(jq -r '.locations[] | select(.type == "route_backup")' "$NETWORK_CONFIG")
        if [ -n "$network_location" ]; then
            location_id=$(echo "$network_location" | jq -r .location_id)
        else
            print_error "No route backup location configured"
            return 1
        fi
    fi

    mount_partition_rw "/"

    # Create service file with all parameters
    sudo cat >"$service_path" <<EOF
[Unit]
Description=Comma Route Sync Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=comma
Environment=PYTHONPATH=/data/openpilot
# Store all sync parameters in systemd environment
Environment=ROUTE_SYNC_LOCATION_ID=${location_id}
Environment=ROUTE_SYNC_RETENTION_DAYS=${retention_days}
Environment=ROUTE_SYNC_AUTO_CONCAT=${auto_concat}
ExecStartPre=/bin/sleep ${startup_delay}
ExecStart=/data/CommaUtility.sh --route-sync \
    --network ${location_id} \
    --retention-days ${retention_days} \
    --auto-concat ${auto_concat}
Restart=on-failure
RestartSec=60

# Add service configuration metadata for easier management
Environment=ROUTE_SYNC_CONFIG_VERSION=1
Environment=ROUTE_SYNC_LAST_UPDATE=$(date +%s)

[Install]
WantedBy=multi-user.target
EOF

    # Set correct permissions
    sudo chmod 644 "$service_path"

    # Reload systemd daemon
    sudo systemctl daemon-reload

    mount_partition_ro "/"
}

get_service_config() {
    if [ -f "$SYSTEMD_SERVICE_DIR/$ROUTE_SYNC_SERVICE" ]; then
        local config_json
        config_json=$(grep "^Environment=" "$SYSTEMD_SERVICE_DIR/$ROUTE_SYNC_SERVICE" | grep "ROUTE_SYNC_" | sed 's/^Environment=//' | jq -R 'split("=") | {(.[0]): .[1]}' | jq -s 'add')
        echo "$config_json"
    fi
}

service_needs_update() {
    local current_config
    current_config=$(get_service_config)

    if [ -z "$current_config" ]; then
        return 0
    fi

    local current_retention=$(echo "$current_config" | jq -r '.ROUTE_SYNC_RETENTION_DAYS // empty')
    local current_concat=$(echo "$current_config" | jq -r '.ROUTE_SYNC_AUTO_CONCAT // empty')
    local current_location=$(echo "$current_config" | jq -r '.ROUTE_SYNC_LOCATION_ID // empty')

    local new_retention=$(get_route_sync_setting "retention_days")
    local new_concat=$(get_route_sync_setting "auto_concat")
    local new_location=$(jq -r '.locations[] | select(.type == "route_backup") | .location_id' "$NETWORK_CONFIG")

    if [ "$current_retention" != "$new_retention" ] ||
        [ "$current_concat" != "$new_concat" ] ||
        [ "$current_location" != "$new_location" ] ||
        [ -z "$current_location" ]; then
        return 0
    fi

    return 1
}

update_service() {
    local location_id="$1"

    if check_service_active "$ROUTE_SYNC_SERVICE"; then
        sudo systemctl stop "$ROUTE_SYNC_SERVICE"
    fi

    create_route_sync_service "$location_id"

    if sudo systemctl is-enabled "$ROUTE_SYNC_SERVICE" >/dev/null 2>&1; then
        sudo systemctl start "$ROUTE_SYNC_SERVICE"
    fi
}

enable_route_sync_service() {
    local location_id="$1"

    if [ ! -f "$SYSTEMD_SERVICE_DIR/$ROUTE_SYNC_SERVICE" ] || service_needs_update; then
        create_route_sync_service "$location_id"
    fi

    sudo systemctl enable "$ROUTE_SYNC_SERVICE"
    sudo systemctl start "$ROUTE_SYNC_SERVICE"
    print_success "Route sync service enabled and started"
}

disable_route_sync_service() {
    sudo systemctl stop "$ROUTE_SYNC_SERVICE"
    sudo systemctl disable "$ROUTE_SYNC_SERVICE"
    print_success "Route sync service disabled and stopped"
}

get_service_status() {
    local service_name="$1"
    sudo systemctl status "$service_name"
}

restart_service() {
    local service_name="$1"
    sudo systemctl restart "$service_name"
}

check_service_exists() {
    local service_name="$1"
    [ -f "$SYSTEMD_SERVICE_DIR/$service_name" ]
}

check_service_active() {
    local service_name="$1"
    sudo systemctl is-active "$service_name" >/dev/null 2>&1
}

display_service_status() {
    if check_service_exists "$ROUTE_SYNC_SERVICE"; then
        local config
        config=$(get_service_config)

        if [ -n "$config" ]; then
            local location_id=$(echo "$config" | jq -r '.ROUTE_SYNC_LOCATION_ID')
            local retention_days=$(echo "$config" | jq -r '.ROUTE_SYNC_RETENTION_DAYS')
            local auto_concat=$(echo "$config" | jq -r '.ROUTE_SYNC_AUTO_CONCAT')
            local last_update=$(echo "$config" | jq -r '.ROUTE_SYNC_LAST_UPDATE')
            local location_label=$(get_location_label "$location_id")

            if check_service_active "$ROUTE_SYNC_SERVICE"; then
                echo -e "│ Service Status: ${GREEN}Active${NC}"
            else
                echo -e "│ Service Status: ${RED}Inactive${NC}"
            fi

            echo "│ Configuration:"
            echo "│ • Sync Target: $location_label"
            echo "│ • Retention Period: $retention_days days"
            echo "│ • Auto Concatenate: $auto_concat"
            [ -n "$last_update" ] && echo "│ • Last Updated: $(date -d "@$last_update" "+%Y-%m-%d %H:%M:%S")"

            if service_needs_update; then
                echo -e "│ ${YELLOW}Note: Service configuration needs update${NC}"
            fi
        else
            echo -e "│ Service Status: ${RED}Invalid Configuration${NC}"
        fi
    else
        echo -e "│ Service Status: ${YELLOW}Not Installed${NC}"
    fi
}
