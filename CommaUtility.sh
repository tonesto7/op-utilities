#!/bin/bash
###############################################################################
# CommaUtility.sh - Main Script
#
#
# This script loads all modules, checks for updates and then launches the
# main menu/argument handler.
###############################################################################

###############################################################################
# Global Variables
###############################################################################
readonly SCRIPT_VERSION="3.1.0"
readonly SCRIPT_MODIFIED="2025-05-08"
readonly SCRIPT_BRANCH="main"

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

# A convenient prompt-pause function to unify "Press Enter" prompts:
pause_for_user() {
    read -p "Press enter to continue..."
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
readonly LAUNCH_ENV_FILE="/data/openpilot/launch_env.sh"

# Backup Variables
readonly SSH_BACKUP_DIR="$CONFIG_DIR/backups/ssh"

# Module Directory and Modules
readonly MODULE_DIR="$CONFIG_DIR/modules"
readonly MODULES=("backups.sh" "device.sh" "issues.sh" "jobs.sh" "network.sh" "repo.sh" "routes.sh" "service.sh" "ssh.sh" "storage.sh" "transfers.sh" "utils.sh")
SKIP_UPDATE=false

###############################################################################
# Main Menu
###############################################################################

display_main_menu() {
    clear
    echo "┌────────────────────────────────────────────────────"
    echo "│             CommaUtility Script (v$SCRIPT_VERSION)"
    echo "│                [Modified: $SCRIPT_MODIFIED]"
    echo "├────────────────────────────────────────────────────"

    display_os_info_short
    echo "│"
    display_git_status_short
    echo "│"
    display_disk_space_status_short
    echo "│"
    display_ssh_status_short

    # Detect and categorize issues
    detect_issues

    # Display Critical Issues
    local critical_found=false
    for i in "${!ISSUE_PRIORITIES[@]}"; do
        if [ "${ISSUE_PRIORITIES[$i]}" -eq 1 ]; then
            if [ "$critical_found" = false ]; then
                echo "│"
                echo "├────────────────────────────────────────────────────"
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
                echo "│"
                echo "├────────────────────────────────────────────────────"
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
                echo "│"
                echo "├────────────────────────────────────────────────────"
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
    echo "│ 1. SSH Management"
    echo "│ 2. Repository & Build Tools"
    echo "│ 3. View Logs"
    echo "│ 4. View Recent Error"
    echo "│ 5. System Statistics"
    echo "│ 6. Device Controls"
    echo "│ 7. Modify Boot Icon/Logo"
    echo "│ 8. Route & Transfer Management"

    # Dynamic fix options
    local fix_number=9 # Start from 6 because we already have 5 options
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
    2) repo_build_and_management_menu ;;
    3) display_logs ;;
    4) view_error_log ;;
    5) system_statistics_menu ;;
    6) device_controls_menu ;;
    7) toggle_boot_logo ;;
    8) view_routes_menu ;;
    [0-9] | [0-9][0-9])
        # Calculate array index by adjusting for the 8 standard menu items
        local fix_index=$((main_choice - 9))
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
        # pause_for_user
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
        latest_version=$(grep "^readonly SCRIPT_VERSION=" "$tmp_file" | cut -d'"' -f2)
        if [ -n "$latest_version" ]; then
            local cmp
            cmp=$(compare_versions "$latest_version" "$SCRIPT_VERSION")
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
    local throttle_period=60
    local last_check_file="$CONFIG_DIR/module_update_last_check"
    local current_time=$(date +%s)
    local check_updates=false

    # Transient message: loading modules
    echo -ne "│ Loading Modules...\r\033[K"

    # Determine if update check is allowed
    if [ ! -f "$last_check_file" ] || [ $((current_time - $(cat "$last_check_file" 2>/dev/null || echo 0))) -ge $throttle_period ]; then
        check_updates=true
        echo "$current_time" >"$last_check_file"
    fi

    for module in "${MODULES[@]}"; do
        load_module "$module" "$check_updates" || exit 1
    done
}

function load_module() {
    local module="$1"
    local check_updates="$2"
    local module_var=$(echo "$module" | tr '[:lower:]' '[:upper:]' | sed 's/\.SH$//')
    local module_path="$MODULE_DIR/$module"

    # Download if missing
    if [ ! -f "$module_path" ]; then
        # Transient: module not found → downloading
        echo -ne "│ Module [$module_var] Not Found. Downloading...\r\033[K"
        if ! wget -q -O "$module_path" "https://raw.githubusercontent.com/tonesto7/op-utilities/$SCRIPT_BRANCH/CommaUtil/$module"; then
            echo -e "${RED}| Failed to Download Module [$module_var]${NC}"
            return 1
        fi
        chmod +x "$module_path"
        local version=$(grep "^readonly ${module_var}_SCRIPT_VERSION=" "$module_path" | cut -d'"' -f2)
        echo "│ Module [$module_var] Downloaded (v$version)"
    fi

    # Check for updates if allowed
    if [ "$check_updates" = "true" ]; then
        echo -ne "│ Module [$module_var] Found. Checking for Updates...\r\033[K"
        local current_version=$(grep "^readonly ${module_var}_SCRIPT_VERSION=" "$module_path" | cut -d'"' -f2)
        local online_version=$(wget --timeout=10 -qO- "https://raw.githubusercontent.com/tonesto7/op-utilities/$SCRIPT_BRANCH/CommaUtil/$module" | grep "^readonly ${module_var}_SCRIPT_VERSION=" | cut -d'"' -f2)

        if [ -n "$online_version" ] && [ "$online_version" != "$current_version" ]; then
            echo -ne "│ Module [$module_var] Update Available (v$online_version). Updating...\r\033[K"
            if ! wget -q -O "$module_path" "https://raw.githubusercontent.com/tonesto7/op-utilities/$SCRIPT_BRANCH/CommaUtil/$module"; then
                echo -e "${RED}| Failed to Update Module [$module_var]${NC}"
                return 1
            fi
            chmod +x "$module_path"
            echo "│ Module [$module_var] Updated (v$online_version)"
        else
            echo "│ Module [$module_var] Up to Date (v$current_version)"
        fi
    else
        # Skip update check; simply load the existing module
        local current_version=$(grep "^readonly ${module_var}_SCRIPT_VERSION=" "$module_path" | cut -d'"' -f2)
        echo "│ Module [$module_var] Loaded (v$current_version)"
    fi

    # Source the module
    source "$module_path"
    return 0
}

check_prerequisites() {
    local errors=0
    echo -ne "│ Checking Prerequisites...\r\033[K"

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

    if [ $errors -gt 0 ]; then
        echo -e "│ ${YELLOW}Some prerequisites checks failed. Some features may not work correctly.${NC}"
        pause_for_user
    fi

    # Make sure important directories exist and are created
    mkdir -p "$CONFIG_DIR" "$CREDENTIALS_DIR" "$TRANSFER_STATE_DIR"

    # Check CONFIG_DIR for route_sync_config.json
    if [ ! -f "$CONFIG_DIR/route_sync_config.json" ]; then
        init_route_sync_config
    fi

    return $errors
}

###############################################################################
# Help Menu and Command Line Arguments
###############################################################################

show_help() {
    cat <<EOL
CommaUtility Script (V$SCRIPT_VERSION) - Last Modified: $SCRIPT_MODIFIED
------------------------------------------------------------

Usage: ./CommaUtility.sh [OPTION] [PARAMETERS]

SSH Operations:
  --import-ssh                      Import SSH keys from files
    --private-key-file <path>       Path to private key file
    --public-key-file <path>        Path to public key file
  --test-ssh                        Test SSH connection to GitHub
  --backup-ssh                      Backup SSH files
  --restore-ssh                     Restore SSH files from backup
  --reset-ssh                       Reset SSH configuration

Build Operations:
  --build-dev                       Build BluePilot internal dev
  --build-public                    Build BluePilot public experimental
  --custom-build                    Perform a custom build
    --repo <repository>             Select repository (bluepilotdev, sp-dev-c3, sunnypilot, or commaai)
    --clone-branch <branch>         Branch to clone
    --build-branch <branch>         Branch name for build
    --push-repo <repository>        Repository to push build to (optional, defaults to clone repo)

Clone Operations:
  --clone-public-bp                 Clone BluePilot staging branch
  --clone-internal-dev-build        Clone BluePilot internal dev build
  --clone-internal-dev              Clone BluePilot internal dev
  --custom-clone                    Clone a specific repository/branch
    --repo <repository>             Repository to clone from
    --clone-branch <branch>         Branch to clone

System Operations:
  --update                          Update this script to latest version
  --skip-update                     Skip update check
  --reboot                          Reboot the device
  --shutdown                        Shutdown the device
  --view-logs                       View system logs

Git Operations:
  --git-pull                        Fetch and pull latest changes
  --git-status                      Show Git repository status
  --git-branch <branch>             Switch to specified branch

Route Operations:
  --route-sync                      Execute route sync job
    --startup-delay <seconds>       Delay before starting sync (300-3600)
    --retention-days <days>         Days to retain routes after sync (1-90)
    --auto-concat <true/false>      Auto concatenate routes before sync
  --enable-route-sync               Enable route sync job
  --disable-route-sync              Disable route sync job

Service Operations:
  --service-status <service>        Show status of specified service
  --restart-service <service>       Restart specified service
  --update-route-sync              Update route sync service configuration
    --network <location_id>        Network location ID for sync
    --retention-days <days>        Days to keep routes after sync (1-90)
    --auto-concat <true/false>     Auto concatenate routes before sync
    --startup-delay <seconds>      Delay before starting sync (0-3600)

General:
  -h, --help                        Show this help message

Examples:
  # SSH operations
  ./CommaUtility.sh --import-ssh --private-key-file /path/to/key --public-key-file /path/to/key.pub
  ./CommaUtility.sh --test-ssh

  # Build operations
  ./CommaUtility.sh --custom-build --repo bluepilotdev --clone-branch dev --build-branch build

  # Clone operations
  ./CommaUtility.sh --custom-clone --repo sunnypilot --clone-branch master

  # System operations
  ./CommaUtility.sh --update
  ./CommaUtility.sh --reboot

  # Git operations
  ./CommaUtility.sh --git-branch master

Note: When no options are provided, the script will launch in interactive menu mode.
EOL
}
# Parse Command Line Arguments
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --import-ssh)
            SCRIPT_ACTION="import-ssh"
            shift
            ;;
        --private-key-file)
            PRIVATE_KEY_FILE="$2"
            shift 2
            ;;
        --public-key-file)
            PUBLIC_KEY_FILE="$2"
            shift 2
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
        --push-repo)
            PUSH_REPO="$2"
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
        # Clone operations
        --clone-public-bp)
            SCRIPT_ACTION="clone-public-bp"
            shift
            ;;
        --clone-internal-dev-build)
            SCRIPT_ACTION="clone-internal-dev-build"
            shift
            ;;
        --clone-internal-dev)
            SCRIPT_ACTION="clone-internal-dev"
            shift
            ;;
        --custom-clone)
            SCRIPT_ACTION="custom-clone"
            shift
            ;;
        # System operations
        --update)
            SCRIPT_ACTION="update"
            shift
            ;;
        --skip-update)
            SKIP_UPDATE=true
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
        # SSH operations
        --test-ssh)
            SCRIPT_ACTION="test-ssh"
            shift
            ;;
        --backup-ssh)
            SCRIPT_ACTION="backup-ssh"
            shift
            ;;
        --restore-ssh)
            SCRIPT_ACTION="restore-ssh"
            shift
            ;;
        --reset-ssh)
            SCRIPT_ACTION="reset-ssh"
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

        # Route sync operations
        --route-sync)
            SCRIPT_ACTION="route-sync"
            shift
            ;;
        --startup-delay)
            STARTUP_DELAY="$2"
            shift 2
            ;;
        --retention-days)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        --auto-concat)
            AUTO_CONCAT="$2"
            shift 2
            ;;
        --enable-route-sync)
            SCRIPT_ACTION="enable-route-sync"
            shift
            ;;
        --disable-route-sync)
            SCRIPT_ACTION="disable-route-sync"
            shift
            ;;
        --network)
            NETWORK_LOCATION_ID="$2"
            shift 2
            ;;

        --service-status)
            SCRIPT_ACTION="service-status"
            SERVICE_NAME="$2"
            shift 2
            ;;
        --restart-service)
            SCRIPT_ACTION="restart-service"
            SERVICE_NAME="$2"
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
    while true; do
        if [ -z "$SCRIPT_ACTION" ]; then
            # No arguments or no action set by arguments: show main menu
            display_main_menu
            handle_main_menu_input
        else
            # SCRIPT_ACTION is set from arguments, run corresponding logic
            case "$SCRIPT_ACTION" in
            build-public)
                build_repo_branch "bp-public-experimental" "staging-DONOTUSE" "bluepilot experimental" "$GIT_BP_PRIVATE_REPO" "$GIT_BP_PUBLIC_REPO"
                ;;
            build-dev)
                build_repo_branch "bp-internal-dev" "bp-internal-dev-build" "bluepilot internal dev" "$GIT_BP_PRIVATE_REPO"
                ;;
            clone-public-bp)
                clone_public_bluepilot
                ;;
            clone-internal-dev-build)
                clone_internal_dev_build
                ;;
            clone-internal-dev)
                clone_internal_dev
                ;;
            custom-clone)
                if [ -z "$REPO" ] || [ -z "$CLONE_BRANCH" ]; then
                    print_error "Error: --custom-clone requires --repo and --clone-branch parameters."
                    show_help
                    exit 1
                fi
                case "$REPO" in
                bluepilotdev) GIT_REPO_URL="$GIT_BP_PUBLIC_REPO" ;;
                sp-dev-c3) GIT_REPO_URL="$GIT_BP_PRIVATE_REPO" ;;
                sunnypilot) GIT_REPO_URL="$GIT_SP_REPO" ;;
                commaai) GIT_REPO_URL="$GIT_COMMA_REPO" ;;
                *)
                    print_error "[-] Unknown repository: $REPO"
                    exit 1
                    ;;
                esac
                clone_repo_bp "repository '$REPO' with branch '$CLONE_BRANCH'" "$GIT_REPO_URL" "$CLONE_BRANCH" "no" "yes"
                if [ ! -f "/data/openpilot/prebuilt" ]; then
                    print_warning "[-] No prebuilt marker found. Might need to compile."
                    read -p "Compile now? (y/N): " compile_confirm
                    if [[ "$compile_confirm" =~ ^[Yy]$ ]]; then
                        print_info "[-] Running scons..."
                        cd /data/openpilot
                        scons -j"$(nproc)" || {
                            print_error "[-] SCons failed."
                            exit 1
                        }
                        print_success "[-] Compilation completed."
                    fi
                fi
                reboot_device_bp
                ;;
            custom-build)
                if [ -z "$REPO" ] || [ -z "$CLONE_BRANCH" ] || [ -z "$BUILD_BRANCH" ]; then
                    print_error "Error: --custom-build requires --repo, --clone-branch, and --build-branch."
                    show_help
                    exit 1
                fi
                case "$REPO" in
                bluepilotdev) GIT_REPO_URL="$GIT_BP_PUBLIC_REPO" ;;
                sp-dev-c3) GIT_REPO_URL="$GIT_BP_PRIVATE_REPO" ;;
                sunnypilot) GIT_REPO_URL="$GIT_SP_REPO" ;;
                commaai) GIT_REPO_URL="$GIT_COMMA_REPO" ;;
                *)
                    print_error "[-] Unknown repository: $REPO"
                    exit 1
                    ;;
                esac
                # Determine push repo - either specified or same as clone repo
                local PUSH_REPO_URL="${PUSH_REPO:-$GIT_REPO_URL}"

                local COMMIT_DESC_HEADER="Custom Build"
                build_repo_branch "$CLONE_BRANCH" "$BUILD_BRANCH" "$COMMIT_DESC_HEADER" "$GIT_REPO_URL" "$PUSH_REPO_URL"
                print_success "[-] Action completed successfully"
                ;;
            update) update_script ;;
            reboot) reboot_device ;;
            shutdown) shutdown_device ;;
            view-logs) display_logs ;;
            test-ssh) test_ssh_connection ;;
            backup-ssh) backup_ssh ;;
            restore-ssh) restore_ssh ;;
            reset-ssh) reset_ssh ;;
            import-ssh) import_ssh_keys $PRIVATE_KEY_FILE $PUBLIC_KEY_FILE ;;
            git-pull) fetch_pull_latest_changes ;;
            git-status) display_git_status ;;
            git-branch)
                if [ -n "$NEW_BRANCH" ]; then
                    cd /data/openpilot && git checkout "$NEW_BRANCH"
                else
                    print_error "Error: Branch name required"
                    exit 1
                fi
                ;;

            route-sync)
                # Initialize route sync configuration
                init_route_sync_config

                # Validate and update settings if provided
                if [ -n "$STARTUP_DELAY" ]; then
                    if [[ "$STARTUP_DELAY" =~ ^[0-9]+$ ]] && [ "$STARTUP_DELAY" -ge 300 ] && [ "$STARTUP_DELAY" -le 3600 ]; then
                        update_route_sync_setting "startup_delay" "$STARTUP_DELAY"
                    else
                        print_error "Invalid startup delay value"
                        exit 1
                    fi
                fi
                if [ -n "$RETENTION_DAYS" ]; then
                    if [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && [ "$RETENTION_DAYS" -ge 1 ] && [ "$RETENTION_DAYS" -le 90 ]; then
                        update_route_sync_setting "retention_days" "$RETENTION_DAYS"
                    else
                        print_error "Invalid retention days value"
                        exit 1
                    fi
                fi
                if [ -n "$AUTO_CONCAT" ]; then
                    if [[ "$AUTO_CONCAT" =~ ^(true|false)$ ]]; then
                        update_route_sync_setting "auto_concat" "$AUTO_CONCAT"
                    else
                        print_error "Invalid auto concat value"
                        exit 1
                    fi
                fi
                # Execute route sync with network location if provided
                if [ -n "$NETWORK_LOCATION_ID" ]; then
                    sync_routes "$NETWORK_LOCATION_ID"
                else
                    sync_routes
                fi

                ;;
            enable-route-sync)
                update_route_sync_setting "enabled" "true"
                local delay=$(get_route_sync_setting "startup_delay")
                update_job_in_launch_env "route_sync" "$delay"
                print_success "Route sync job enabled"
                ;;
            disable-route-sync)
                update_route_sync_setting "enabled" "false"
                remove_job_block "route_sync"
                print_success "Route sync job disabled"
                ;;
            service-status)
                get_service_status "$SERVICE_NAME"
                ;;
            restart-service)
                restart_service "$SERVICE_NAME"
                ;;
            *)
                print_error "Invalid build type. Exiting."
                exit 1
                ;;
            esac
            exit 0
        fi
    done
}

###############################################################################
# Run the script
###############################################################################
run_script() {

    echo -e "┌──────────────────────────────────────────"
    # Check if update should be skipped
    if [ "$SKIP_UPDATE" = "true" ]; then
        echo -e "│ Update check skipped by user."
    else
        # Update the main script to the latest version
        update_main_script
    fi
    echo -e "├──────────────────────────────────────────"
    # Load all modules and check for updates
    load_modules
    echo -e "├──────────────────────────────────────────"
    # Check for prerequisites
    if ! check_prerequisites; then
        print_error "Prerequisite Checks Failed.\nPlease fix the above errors."
        exit 1
    else
        echo -e "│ ${GREEN}All prerequisites checks passed.${NC}"
    fi
    echo -e "├──────────────────────────────────────────"

    # Initialize the network location config
    init_network_config

    echo -e "│ Initialization complete..."
    echo -e "│ Showing Main Menu..."
    echo -e "└──────────────────────────────────────────"

    # Wait for 10 seconds before continuing
    sleep 3

    # Run the main script
    main
}

run_script
exit 0
