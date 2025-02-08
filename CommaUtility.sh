#!/bin/bash
###############################################################################
# CommaUtility.sh - Main Script
#
# Version: MAIN_SCRIPT_VERSION="1.0.0"
# Last Modified: "2025-02-XX"
#
# This script loads all modules, checks for updates and then launches the
# main menu/argument handler.
###############################################################################

###############################################################################
# Global Variables
###############################################################################
readonly SCRIPT_VERSION="3.0.2"
readonly SCRIPT_MODIFIED="2025-02-08"
readonly SCRIPT_BRANCH="test"

# We unify color-coded messages in a single block for consistency:
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Helper functions for colored output
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

# OS checks and directories
readonly OS=$(uname)
readonly GIT_BP_PUBLIC_REPO="git@github.com:BluePilotDev/bluepilot.git"
readonly GIT_BP_PRIVATE_REPO="git@github.com:ford-op/sp-dev-c3.git"
readonly GIT_OP_PRIVATE_FORD_REPO="git@github.com:ford-op/openpilot.git"
readonly GIT_SP_REPO="git@github.com:sunnypilot/sunnypilot.git"
readonly GIT_COMMA_REPO="git@github.com:commaai/openpilot.git"

if [ "$OS" = "Darwin" ]; then
    readonly BUILD_DIR="$HOME/Documents/bluepilot-utility/bp-build"
    readonly SCRIPT_DIR=$(dirname "$0")
else
    readonly BUILD_DIR="/data/openpilot"
    # Get absolute path of script regardless of where it's called from
    readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd || echo "/data")
    if [ "$SCRIPT_DIR" = "" ]; then
        print_error "Error: Could not determine script directory"
        exit 1
    fi
fi

readonly TMP_DIR="${BUILD_DIR}-build-tmp"
readonly CONFIG_DIR="/data/commautil"
readonly NETWORK_CONFIG="$CONFIG_DIR/network_locations.json"
readonly CREDENTIALS_DIR="$CONFIG_DIR/credentials"
readonly TRANSFER_STATE_DIR="$CONFIG_DIR/transfer_state"
readonly LAUNCH_ENV="/data/openpilot/launch_env.sh"

# Module Directory and Modules
readonly MODULE_DIR="$CONFIG_DIR/modules"
readonly MODULES=("backups.sh" "ssh.sh" "transfers.sh" "comma.sh" "storage.sh" "issues.sh" "routes.sh" "git.sh" "builds.sh" "utils.sh" "device.sh")

###############################################################################
# Main Menu Functions
###############################################################################

display_main_menu() {
    clear
    echo "┌────────────────────────────────────────────────────"
    echo "│             CommaUtility Script v$SCRIPT_VERSION"
    echo "│             (Last Modified: $SCRIPT_MODIFIED)"
    echo "└────────────────────────────────────────────────────"

    display_os_info_short
    display_backup_status_short
    display_git_status_short
    display_disk_space_status_short
    display_ssh_status_short

    # Detect and categorize issues
    detect_issues

    # Display Critical Issues
    local critical_found=false
    for i in "${!ISSUE_PRIORITIES[@]}"; do
        if [ "${ISSUE_PRIORITIES[$i]}" -eq 1 ]; then
            if [ "$critical_found" = false ]; then
                echo "│────────────────────────────────────────────────────"
                echo -e "│ ${RED}Critical Issues:${NC}"
                critical_found=true
            fi
            echo -e "│ ❌ ${ISSUE_DESCRIPTIONS[$i]}"
        fi
    done

    # Display Warnings
    local warnings_found=false
    for i in "${!ISSUE_PRIORITIES[@]}"; do
        if [ "${ISSUE_PRIORITIES[$i]}" -eq 2 ]; then
            if [ "$warnings_found" = false ]; then
                echo "│────────────────────────────────────────────────────"
                echo -e "│ ${YELLOW}Warnings:${NC}"
                warnings_found=true
            fi
            echo -e "│ ⚠️  ${ISSUE_DESCRIPTIONS[$i]}"
        fi
    done

    # Display Recommendations
    local recommendations_found=false
    for i in "${!ISSUE_PRIORITIES[@]}"; do
        if [ "${ISSUE_PRIORITIES[$i]}" -eq 3 ]; then
            if [ "$recommendations_found" = false ]; then
                echo "│────────────────────────────────────────────────────"
                echo -e "│ ${BLUE}Recommendations:${NC}"
                recommendations_found=true
            fi
            echo -e "│ → ${ISSUE_DESCRIPTIONS[$i]}"
        fi
    done

    # Close with a consistent bottom divider
    echo "├────────────────────────────────────────────────────"

    # Display Main Menu Options
    echo "│"
    echo -e "│${GREEN} Available Actions:${NC}"
    echo "│ 1. SSH Key Management"
    echo "│ 2. Device Backup"
    echo "│ 3. Repository & Build Tools"
    echo "│ 4. View Logs"
    echo "│ 5. View Recent Error"
    echo "│ 6. System Statistics"
    echo "│ 7. Device Controls"
    echo "│ 8. Modify Boot Icon/Logo"
    echo "│ 9. Route & Transfer Management"

    # Dynamic fix options
    local fix_number=10 # Start from 6 because we already have 5 options
    for i in "${!ISSUE_FIXES[@]}"; do
        local color=""
        case "${ISSUE_PRIORITIES[$i]}" in
        1) color="$RED" ;;
        2) color="$YELLOW" ;;
        3) color="$BLUE" ;;
        *) color="$NC" ;;
        esac
        echo -e "│ ${fix_number}. ${color}Fix: ${ISSUE_DESCRIPTIONS[$i]}${NC}"
        fix_number=$((fix_number + 1))
    done

    echo "│ R. Reboot Device"
    echo "│ S. Shutdown Device"
    echo "│ U. Update Script"
    echo "│ Q. Exit"
    echo "└────────────────────────────────────────────────────"
}

handle_main_menu_input() {
    read -p "Enter your choice: " main_choice
    case $main_choice in
    1) ssh_menu ;;
    2) backup_menu ;;
    3) repo_build_and_management_menu ;;
    4) display_logs ;;
    5) view_error_log ;;
    6) system_statistics_menu ;;
    7) device_controls_menu ;;
    8) toggle_boot_logo ;;
    9) view_routes_menu ;;
    [0-9] | [0-9][0-9])
        # Calculate array index by adjusting for the 8 standard menu items
        local fix_index=$((main_choice - 10))
        # Get all indices of the associative arrays
        local indices=(${!ISSUE_FIXES[@]})
        if [ "$fix_index" -ge 0 ] && [ "$fix_index" -lt "${#indices[@]}" ]; then
            # Get the actual index from the array of indices
            local actual_index=${indices[$fix_index]}
            ${ISSUE_FIXES[$actual_index]}
        else
            print_error "Invalid option"
            pause_for_user
        fi
        ;;
    [uU]) update_script ;;
    [rR]) reboot_device ;;
    [sS]) shutdown_device ;;
    [qQ])
        print_info "Exiting..."
        exit 0
        ;;
    *)
        print_error "Invalid choice."
        pause_for_user
        ;;
    esac
}

###############################################################################
# Script/Module Update Logic
###############################################################################
function compare_versions() {
    # compare_versions() - compare semantic versions v1 and v2
    local ver1="${1#v}"
    local ver2="${2#v}"
    IFS='.' read -ra a1 <<<"$ver1"
    IFS='.' read -ra a2 <<<"$ver2"
    for i in 0 1 2; do
        local n1=${a1[i]:-0}
        local n2=${a2[i]:-0}
        if ((n1 > n2)); then
            echo 1
            return
        elif ((n1 < n2)); then
            echo -1
            return
        fi
    done
    echo 0
}

function update_main_script() {
    local script_path
    script_path=$(realpath "$0")
    local tmp_file="${script_path}.tmp"

    # Transient message: checking for update
    echo -ne "│ Checking Script for Updates...\r\033[K"

    if wget --timeout=10 -q -O "$tmp_file" "https://raw.githubusercontent.com/tonesto7/op-utilities/$SCRIPT_BRANCH/CommaUtility.sh"; then
        local latest_version
        latest_version=$(grep "^readonly MAIN_SCRIPT_VERSION=" "$tmp_file" | cut -d'"' -f2)
        if [ -n "$latest_version" ]; then
            local cmp
            cmp=$(compare_versions "$latest_version" "$MAIN_SCRIPT_VERSION")
            if [ "$cmp" -eq 1 ]; then
                # Transient message: update available
                echo -ne "│ New Script Version ($latest_version) Available. Updating...\r\033[K"
                mv "$tmp_file" "$script_path"
                chmod +x "$script_path"
                echo "│ Script Updated. Restarting..."
                exec "$script_path" "$@"
            else
                rm -f "$tmp_file"
            fi
        else
            rm -f "$tmp_file"
        fi
        echo "│ Script Up to Date. No Updates Available."
    else
        echo -e "│${RED} Main script update check failed.${NC}"
    fi
}

function load_modules() {
    mkdir -p "$MODULE_DIR"

    # Transient message: loading modules
    echo -ne "│ Loading Modules...\r\033[K"

    for module in "${MODULES[@]}"; do
        # Generate uppercase module name (strip .sh)
        module_var=$(echo "$module" | tr '[:lower:]' '[:upper:]' | sed 's/\.SH$//')
        if [ ! -f "$MODULE_DIR/$module" ]; then
            # Transient: module not found → downloading
            echo -ne "│ Module [$module_var] Not Found. Downloading...\r\033[K"
            if wget -q -O "$MODULE_DIR/$module" "https://raw.githubusercontent.com/tonesto7/op-utilities/$SCRIPT_BRANCH/CommaUtil/$module"; then
                module_version=$(grep "^readonly ${module_var}_SCRIPT_VERSION=" "$MODULE_DIR/$module" | cut -d'"' -f2)
                # Transient: download complete
                echo -ne "│ Module [$module_var] Downloaded (v$module_version)\r\033[K"
                chmod +x "$MODULE_DIR/$module"
                source "$MODULE_DIR/$module"
                echo "│ Module [$module_var] Up to Date (v$module_version)"
            else
                echo -e "${RED}| Failed to Download Module [$module_var]${NC}"
                exit 1
            fi
        else
            # Transient: module found, checking for updates
            echo -ne "│ Module [$module_var] Found. Checking for Updates...\r\033[K"
            current_version=$(grep "^readonly ${module_var}_SCRIPT_VERSION=" "$MODULE_DIR/$module" | cut -d'"' -f2)
            online_version=$(wget --timeout=10 -qO- "https://raw.githubusercontent.com/tonesto7/op-utilities/$SCRIPT_BRANCH/CommaUtil/$module" | grep "^readonly ${module_var}_SCRIPT_VERSION=" | cut -d'"' -f2)
            if [ -n "$online_version" ]; then
                cmp=$(compare_versions "$online_version" "$current_version")
                if [ "$cmp" -eq 1 ]; then
                    # Transient: update available
                    echo -ne "│ Module [$module_var] Update Available (v$online_version). Updating...\r\033[K"
                    if wget -q -O "$MODULE_DIR/$module" "https://raw.githubusercontent.com/tonesto7/op-utilities/$SCRIPT_BRANCH/CommaUtil/$module"; then
                        chmod +x "$MODULE_DIR/$module"
                        source "$MODULE_DIR/$module"
                        echo "│ Module [$module_var] Updated (v$online_version)"
                    else
                        echo -e "${RED}| Failed to Update Module [$module_var]${NC}"
                        exit 1
                    fi
                else
                    echo "│ Module [$module_var] Up to Date (v$current_version)"
                    source "$MODULE_DIR/$module"
                fi
            else
                echo "│ Module [$module_var] Up to Date (v$current_version)"
                source "$MODULE_DIR/$module"
            fi
        fi
    done
}

check_prerequisites() {
    local errors=0
    echo -e "│ Checking Prerequisites..."

    # Check required commands
    for cmd in jq rsync smbclient tar wget; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -ne "│ ${YELLOW}smbclient is not installed${NC} | Installing (might take a moment)...\r\033[K"
            # Quietly install smbclient
            sudo apt update && sudo apt install -y "$cmd" >/dev/null 2>&1
            if ! command -v "$cmd" >/dev/null 2>&1; then
                echo -e "│ ${RED}Failed to install $cmd${NC}"
                errors=$((errors + 1))
            else
                echo -e "│ ${GREEN}$cmd Installed Successfully${NC}"
            fi
        fi
    done

    # Check disk space in /data
    local available_space
    available_space=$(df -m /data | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 1000 ]; then
        echo -e "│ ${YELLOW}Low disk space on /data: ${available_space}MB available${NC} | Free up space."
        errors=$((errors + 1))
    fi

    # Check network connectivity
    if ! ping -c 1 github.com >/dev/null 2>&1; then
        echo -e "│ ${RED}No network connectivity to GitHub${NC}"
        errors=$((errors + 1))
    fi

    # Check write permissions
    if [ ! -w "$CONFIG_DIR" ]; then
        echo -e "│ ${RED}No write permission for $CONFIG_DIR${NC}"
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        echo -e "│ ${YELLOW}Some prerequisites checks failed. Some features may not work correctly.${NC}"
        pause_for_user
    fi

    # Make sure important directories exist and are created
    mkdir -p "$BACKUP_BASE_DIR" "$CONFIG_DIR" "$CREDENTIALS_DIR" "$TRANSFER_STATE_DIR"

    return $errors
}

###############################################################################
# BluePilot Utility Functions (from build_bluepilot)
###############################################################################

show_help() {
    cat <<EOL
CommaUtility Script (V$SCRIPT_VERSION) - Last Modified: $SCRIPT_MODIFIED
------------------------------------------------------------

Usage: ./CommaUtility.sh [OPTION] [PARAMETERS]

Device Backup Operations:
  --backup                      Create device backup
    --network <location_id>     Network location ID for backup
    --auto-sync                 Auto-sync to configured locations
  --restore-device              Restore from device backup
  --set-backup-location         Configure preferred network backup location
  --migrate-backup              Migrate from old backup format to new format
  --fetch-backup <dir>          Fetch backup from network location
    --network <location_id>     Network location ID to fetch from

SSH Operations:
  --test-ssh                    Test SSH connection to GitHub
  --reset-ssh                   Reset SSH configuration and create new keys
  --copy-ssh-persist           Copy SSH config to persistent storage

Build Operations:
  --build-dev                   Build BluePilot internal dev
  --build-public                Build BluePilot public experimental
  --custom-build                Perform a custom build
    --repo <repository>         Select repository (bluepilotdev, sp-dev-c3, sunnypilot, or commaai)
    --clone-branch <branch>     Branch to clone
    --build-branch <branch>     Branch name for build

Route Operations:
  --route-sync                  Sync all routes to network location
    --network <location_id>     Network location ID for sync
  --sync-single-route <route>   Sync a single route
    --network <location_id>     Network location ID for sync
  --view-routes                 View available routes

Network Operations:
  --manage-locations            Manage network locations
  --manage-jobs                 Manage auto sync/backup jobs

System Operations:
  --update                      Update this script to latest version
  --reboot                      Reboot the device
  --shutdown                    Shutdown the device
  --view-logs                   View system logs

Git Operations:
  --git-pull                    Fetch and pull latest changes
  --git-status                  Show Git repository status
  --git-branch <branch>         Switch to specified branch

General:
  -h, --help                    Show this help message

Examples:
  # Create device backup
  ./CommaUtility.sh --backup
  ./CommaUtility.sh --backup --network <location_id>

  # Restore from backup
  ./CommaUtility.sh --restore-device

  # Configure backup location
  ./CommaUtility.sh --set-backup-location

  # Build operations
  ./CommaUtility.sh --custom-build --repo bluepilotdev --clone-branch dev --build-branch build

  # Route operations
  ./CommaUtility.sh --route-sync --network <location_id>
  ./CommaUtility.sh --sync-single-route <route> --network <location_id>

  # Network management
  ./CommaUtility.sh --manage-locations
  ./CommaUtility.sh --manage-jobs

Note: When no options are provided, the script will launch in interactive menu mode.
EOL
}

###############################################################################
# Parse Command Line Arguments
###############################################################################
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
        # Backup operations
        --backup)
            SCRIPT_ACTION="backup"
            shift
            ;;
        --network)
            NETWORK_ID="$2"
            shift 2
            ;;
        --auto-sync)
            AUTO_SYNC="true"
            shift
            ;;
        --restore-device)
            SCRIPT_ACTION="restore_device"
            shift
            ;;
        --migrate-backup)
            SCRIPT_ACTION="migrate_backup"
            shift
            ;;

        # SSH operations
        --test-ssh)
            SCRIPT_ACTION="test_ssh"
            shift
            ;;
        --reset-ssh)
            SCRIPT_ACTION="reset_ssh"
            shift
            ;;
        --copy-ssh-persist)
            SCRIPT_ACTION="copy_ssh_persist"
            shift
            ;;

        # Network management
        --manage-locations)
            SCRIPT_ACTION="manage_locations"
            shift
            ;;
        --manage-jobs)
            SCRIPT_ACTION="manage_jobs"
            shift
            ;;

        # Build operations
        --build-dev)
            SCRIPT_ACTION="build-dev"
            shift
            ;;
        --build-public)
            SCRIPT_ACTION="build-public"
            shift
            ;;
        --custom-build)
            SCRIPT_ACTION="custom-build"
            shift
            ;;
        --repo)
            REPO="$2"
            shift 2
            ;;
        --clone-branch)
            CLONE_BRANCH="$2"
            shift 2
            ;;
        --build-branch)
            BUILD_BRANCH="$2"
            shift 2
            ;;

        # Route operations
        --route-sync)
            SCRIPT_ACTION="route_sync"
            shift
            ;;
        --sync-single-route)
            SCRIPT_ACTION="sync_single_route"
            ROUTE_BASE="$2"
            shift 2
            ;;
        --view-routes)
            SCRIPT_ACTION="view_routes"
            shift
            ;;
        --cleanup-routes)
            SCRIPT_ACTION="cleanup_routes"
            CLEANUP_DAYS="$2"
            shift 2
            ;;

        # System operations
        --update)
            SCRIPT_ACTION="update"
            shift
            ;;
        --reboot)
            SCRIPT_ACTION="reboot"
            shift
            ;;
        --shutdown)
            SCRIPT_ACTION="shutdown"
            shift
            ;;
        --view-logs)
            SCRIPT_ACTION="view-logs"
            shift
            ;;

        # Git operations
        --git-pull)
            SCRIPT_ACTION="git-pull"
            shift
            ;;
        --git-status)
            SCRIPT_ACTION="git-status"
            shift
            ;;
        --git-branch)
            SCRIPT_ACTION="git-branch"
            NEW_BRANCH="$2"
            shift 2
            ;;

        # Help
        -h | --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        esac
    done
}

# Only parse arguments if any were provided
if [ $# -gt 0 ]; then
    parse_arguments "$@"
fi

###############################################################################
# Main Execution
###############################################################################
main() {
    # Handle script actions
    if [ -z "$SCRIPT_ACTION" ]; then
        # No arguments provided - show main menu
        while true; do
            display_main_menu
            handle_main_menu_input
        done
    else
        case "$SCRIPT_ACTION" in
        # Backup operations
        backup)
            if [ -n "$NETWORK_ID" ]; then
                perform_automated_backup "$NETWORK_ID"
            else
                backup_device
            fi
            ;;
        restore_device)
            restore_backup
            ;;
        migrate_backup)
            migrate_legacy_backup
            ;;

        # SSH operations
        test_ssh)
            test_ssh_connection
            ;;
        reset_ssh)
            reset_ssh
            ;;
        copy_ssh_persist)
            copy_ssh_config_and_keys
            ;;

        # Network operations
        manage_locations)
            manage_network_locations_menu
            ;;
        manage_jobs)
            manage_auto_sync_and_backup_jobs
            ;;

        # Build operations
        build-dev)
            build_repo_branch "bp-internal-dev" "bp-internal-dev-build" "bluepilot internal dev" "$GIT_BP_PRIVATE_REPO"
            ;;
        build-public)
            build_repo_branch "bp-public-experimental" "staging-DONOTUSE" "bluepilot experimental" "$GIT_BP_PRIVATE_REPO" "$GIT_BP_PUBLIC_REPO"
            ;;
        custom-build)
            if [ -z "$REPO" ] || [ -z "$CLONE_BRANCH" ] || [ -z "$BUILD_BRANCH" ]; then
                print_error "Error: --custom-build requires --repo, --clone-branch, and --build-branch."
                show_help
                exit 1
            fi
            custom_build_process
            ;;

        # Route operations
        route_sync)
            if [ -n "$NETWORK_ID" ]; then
                sync_all_routes "$NETWORK_ID"
            else
                sync_routes_menu
            fi
            ;;
        sync_single_route)
            if [ -z "$ROUTE_BASE" ]; then
                print_error "Route base name required"
                exit 1
            fi
            if [ -n "$NETWORK_ID" ]; then
                sync_single_route "$ROUTE_BASE" "$NETWORK_ID"
            else
                sync_single_route_interactive "$ROUTE_BASE"
            fi
            ;;
        view_routes)
            view_routes_menu
            ;;
        cleanup_routes)
            if [ -n "$CLEANUP_DAYS" ]; then
                cleanup_route_files "$CLEANUP_DAYS"
            else
                manage_route_storage
            fi
            ;;

        # System operations
        update)
            update_script
            ;;
        reboot)
            reboot_device
            ;;
        shutdown)
            shutdown_device
            ;;
        view-logs)
            display_logs
            ;;

        # Git operations
        git-pull)
            fetch_pull_latest_changes
            ;;
        git-status)
            display_git_status
            ;;
        git-branch)
            if [ -n "$NEW_BRANCH" ]; then
                cd /data/openpilot && git checkout "$NEW_BRANCH"
            else
                print_error "Error: Branch name required"
                exit 1
            fi
            ;;
        *)
            print_error "Invalid build type. Exiting."
            exit 1
            ;;
        esac
        exit 0
    fi
}

###############################################################################
# Run the script
###############################################################################
run_script() {

    echo -e "┌────────────────────────────────────────────────────"
    # Update the main script to the latest version
    update_main_script
    echo -e "├────────────────────────────────────────────────────"
    # Load all modules and check for updates
    load_modules
    echo -e "├────────────────────────────────────────────────────"
    # Check for prerequisites
    if ! check_prerequisites; then
        print_error "Prerequisite Checks Failed.\nPlease fix the above errors."
        exit 1
    else
        echo -e "│ ${GREEN}All prerequisites checks passed.${NC}"
    fi
    echo -e "├────────────────────────────────────────────────────"

    # Initialize the network location config
    init_network_config

    echo -e "│ Initialization complete.  Showing main menu..."
    echo -e "└────────────────────────────────────────────────────"

    # Wait for 10 seconds before continuing
    sleep 3

    # Run the main script
    main
}

run_script
exit 0
