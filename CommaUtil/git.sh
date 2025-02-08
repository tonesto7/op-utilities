#!/bin/bash

###############################################################################
# Global Variables
###############################################################################
readonly GIT_SCRIPT_VERSION="3.0.1"
readonly GIT_SCRIPT_MODIFIED="2025-02-08"

###############################################################################
# Git Status Functions
###############################################################################

display_git_status_short() {
    print_info "│ Openpilot Repository:"
    if [ -d "/data/openpilot" ]; then
        (
            cd "/data/openpilot" 2>/dev/null || {
                echo -e "${RED}| └─ Repository: Access Error${NC}"
                return
            }
            local repo_name branch_name
            repo_name=$(git config --get remote.origin.url 2>/dev/null | awk -F'/' '{print $NF}' | sed 's/.git//' || echo "Unknown")
            branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "Unknown")
            echo "│ ├─ Repository: ${repo_name}"
            echo "│ └─ Branch: ${branch_name}"
        )
    else
        echo -e "${YELLOW}| └─ Repository: Not Installed${NC}"
    fi
}

display_git_status() {
    if [ -d "/data/openpilot" ]; then
        # echo "│ Gathering repository details, please wait..."

        (
            cd "/data/openpilot" || exit 1
            local branch_name
            local repo_url
            local repo_status
            local submodule_status

            branch_name=$(git rev-parse --abbrev-ref HEAD)
            repo_url=$(git config --get remote.origin.url)

            # Check if working directory is clean
            if [ -n "$(git status --porcelain)" ]; then
                repo_status="${RED}Uncommitted changes${NC}"
            else
                repo_status="${GREEN}Clean${NC}"
            fi

            # Check submodule status
            if [ -f ".gitmodules" ]; then
                if git submodule status | grep -q '^-'; then
                    submodule_status="${RED}Not initialized${NC}"
                elif git submodule status | grep -q '^+'; then
                    submodule_status="${YELLOW}Out of date${NC}"
                else
                    submodule_status="${GREEN}Up to date${NC}"
                fi
            else
                submodule_status="No submodules"
            fi

            # clear
            # echo "+----------------------------------------------+"
            echo "│ Openpilot directory: ✅"
            echo "│ ├─ Branch: $branch_name"
            echo "│ ├─ Repo: $repo_url"
            echo -e "│ ├─ Status: $repo_status"
            echo -e "│ └─ Submodules: $submodule_status"
        )
    else
        echo "│ Openpilot directory: ❌"
    fi
}

###############################################################################
# Git Operations
###############################################################################

# Clone and initialize a git repository
# Returns:
# - 0: Success
# - 1: Failure
git_clone_and_init() {
    local repo_url="$1"
    local branch="$2"
    local dest_dir="$3"

    if ! check_network_connectivity "github.com"; then
        print_error "No network connectivity to GitHub. Cannot proceed with clone operation."
        return 1
    fi

    local clone_cmd="git clone --depth 1 -b '$branch' '$repo_url' '$dest_dir'"
    if ! execute_with_network_retry "$clone_cmd" "Failed to clone repository"; then
        return 1
    fi

    cd "$dest_dir" || return 1

    # Check if there are any submodules and .gitmodules file if so, update them
    if [ -f ".gitmodules" ]; then
        local submodule_cmd="git submodule update --init --recursive"
        execute_with_network_retry "$submodule_cmd" "Failed to update submodules"
    fi
}

git_operation_with_timeout() {
    local cmd="$1"
    local timeout="$2"
    timeout "$timeout" $cmd || {
        print_error "Operation timed out after ${timeout} seconds"
        return 1
    }
}

list_git_branches() {
    clear
    echo "+----------------------------------------------+"
    echo "│        Available Branches                    │"
    echo "+----------------------------------------------+"
    if [ -d "/data/openpilot" ]; then
        (
            cd "/data/openpilot" || return
            local branches
            branches=$(git branch --all)
            if [ -n "$branches" ]; then
                echo "$branches"
            else
                echo "No branches found."
            fi
        )
    else
        echo "Openpilot directory does not exist."
    fi
    echo "+----------------------------------------------+"
    pause_for_user
}

# Reusable branch selection function.
# Parameters:
#   $1 - Repository URL (e.g., git@github.com:username/repo.git)
# Returns:
#   Sets SELECTED_BRANCH with the chosen branch name.
select_branch_menu() {
    clear
    local repo_url="$1"
    local remote_branches branch_array branch_count branch_choice
    SELECTED_BRANCH="" # Reset global variable

    # Display placeholder message.
    print_info "Fetching branches from ${repo_url}, please wait..."

    # Fetch branch list using git ls-remote.
    remote_branches=$(git ls-remote --heads "$repo_url" 2>/dev/null | awk '{print $2}' | sed 's#refs/heads/##')
    if [ -z "$remote_branches" ]; then
        print_error "No branches found or failed to contact repository: $repo_url"
        return 1
    fi

    clear
    # Load branches into an array.
    readarray -t branch_array <<<"$remote_branches"
    branch_count=${#branch_array[@]}

    # Display branch menu.
    echo "Available branches from ${repo_url}:"
    for ((i = 0; i < branch_count; i++)); do
        printf "%d) %s\n" $((i + 1)) "${branch_array[i]}"
    done

    # Prompt for selection.
    while true; do
        read -p "Select a branch by number (or 'q' to cancel): " branch_choice
        if [[ "$branch_choice" =~ ^[Qq]$ ]]; then
            print_info "Branch selection canceled."
            return 1
        elif [[ "$branch_choice" =~ ^[0-9]+$ ]] && [ "$branch_choice" -ge 1 ] && [ "$branch_choice" -le "$branch_count" ]; then
            clear
            SELECTED_BRANCH="${branch_array[$((branch_choice - 1))]}"
            print_info "Selected branch: $SELECTED_BRANCH"
            break
        else
            print_error "Invalid choice. Please enter a number between 1 and ${branch_count}."
        fi
    done

    return 0
}

fetch_pull_latest_changes() {
    print_info "Fetching and pulling the latest changes for the current branch..."
    if [ -d "/data/openpilot" ]; then
        (
            cd "/data/openpilot" || return

            if ! git_operation_with_timeout "git fetch" 60; then
                print_error "Failed to fetch latest changes"
                return 1
            fi

            if ! git_operation_with_timeout "git pull" 300; then
                print_error "Failed to pull latest changes"
                return 1
            fi

            print_success "Successfully updated repository"
        )
    else
        print_warning "No openpilot directory found."
    fi
    pause_for_user
}

change_branch() {
    clear
    print_info "Changing the branch of the repository..."

    # Directory check
    if [ ! -d "/data/openpilot" ]; then
        print_error "No openpilot directory found."
        pause_for_user
        return 1
    fi
    cd "/data/openpilot" || {
        print_error "Could not change to openpilot directory"
        pause_for_user
        return 1
    }

    # Working directory check with force options
    if ! check_working_directory; then
        print_warning "Working directory has uncommitted changes."
        echo ""
        echo "Options:"
        echo "1. Stash changes (save them for later)"
        echo "2. Discard changes and force branch switch"
        echo "3. Cancel branch switch"
        echo ""
        read -p "Enter your choice (1-3): " force_choice

        case $force_choice in
        1)
            if ! git stash; then
                print_error "Failed to stash changes"
                pause_for_user
                return 1
            fi
            print_success "Changes stashed successfully"
            ;;
        2)
            print_warning "This will permanently discard all uncommitted changes!"
            read -p "Are you sure? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                print_info "Branch switch cancelled"
                pause_for_user
                return 1
            fi
            ;;
        *)
            print_info "Branch switch cancelled"
            pause_for_user
            return 1
            ;;
        esac
    fi

    # Repository URL
    local repo_url
    repo_url=$(git config --get remote.origin.url)
    if [ -z "$repo_url" ]; then
        print_error "Could not determine repository URL"
        pause_for_user
        return 1
    fi

    # Fetch latest
    print_info "Fetching latest repository information..."
    if ! git fetch; then
        print_error "Failed to fetch latest information"
        pause_for_user
        return 1
    fi

    # Branch selection
    if ! select_branch_menu "$repo_url"; then
        print_error "Branch selection cancelled or failed"
        pause_for_user
        return 1
    fi

    if [ -z "$SELECTED_BRANCH" ]; then
        print_error "No branch was selected"
        pause_for_user
        return 1
    fi

    clear
    print_info "Switching to branch: $SELECTED_BRANCH"

    # If force switch chosen, clean everything
    if [ "$force_choice" = "2" ]; then
        print_info "Cleaning repository and submodules..."

        # Reset main repository
        git reset --hard HEAD

        # Clean untracked files
        git clean -fd
    fi

    # Checkout branch
    if ! git checkout "$SELECTED_BRANCH"; then
        print_error "Failed to checkout branch: $SELECTED_BRANCH"
        pause_for_user
        return 1
    fi

    if [ -f ".gitmodules" ]; then
        # Handle submodules
        print_info "Updating submodules..."

        # First deinitialize all submodules
        git submodule deinit -f .

        # Remove old submodule directories
        local submodules=("msgq_repo" "opendbc_repo" "panda" "rednose_repo" "teleoprtc_repo" "tinygrad_repo")
        for submodule in "${submodules[@]}"; do
            if [ -d "$submodule" ]; then
                print_info "Removing old $submodule directory..."
                rm -rf "$submodule"
                rm -rf ".git/modules/$submodule"
            fi
        done

        # Initialize and update submodules
        print_info "Initializing submodules..."
        if ! git submodule init; then
            print_error "Failed to initialize submodules"
            pause_for_user
            return 1
        fi

        print_info "Updating submodules (this may take a while)..."
        if ! git submodule update --recursive; then
            print_error "Failed to update submodules"
            pause_for_user
            return 1
        fi
    fi

    print_success "Successfully switched to branch: $SELECTED_BRANCH"
    print_success "All submodules have been updated"

    # Handle stashed changes if applicable
    if [ "$force_choice" = "1" ]; then
        echo ""
        read -p "Would you like to reapply your stashed changes? (y/N): " reapply
        if [[ "$reapply" =~ ^[Yy]$ ]]; then
            if ! git stash pop; then
                print_warning "Note: There were conflicts while reapplying changes."
                print_info "Your changes are still saved in the stash."
                print_info "Use 'git stash list' to see them and 'git stash pop' to try again."
            else
                print_success "Stashed changes reapplied successfully"
            fi
        fi
    fi

    pause_for_user
    return 0
}

reset_git_changes() {
    clear
    if [ ! -d "/data/openpilot" ]; then
        print_error "Openpilot directory does not exist."
        pause_for_user
        return 1
    fi

    cd "/data/openpilot" || return 1

    echo "This will reset all uncommitted changes in the repository."
    echo "Options:"
    echo "1. Soft reset (preserve changes but unstage them)"
    echo "2. Hard reset (discard all changes)"
    echo "3. Clean (remove untracked files)"
    echo "4. Hard reset and clean (complete reset)"
    echo "Q. Cancel"

    read -p "Enter your choice: " reset_choice

    case $reset_choice in
    1)
        git reset HEAD
        print_success "Soft reset completed."
        ;;
    2)
        git reset --hard HEAD
        print_success "Hard reset completed."
        ;;
    3)
        read -p "Remove untracked files? This cannot be undone. (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            git clean -fd
            print_success "Repository cleaned."
        fi
        ;;
    4)
        read -p "This will remove ALL changes and untracked files. Continue? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            git reset --hard HEAD
            git clean -fd
            print_success "Repository reset and cleaned."
        fi
        ;;
    [qQ]) return 0 ;;
    *) print_error "Invalid choice." ;;
    esac
    pause_for_user
}

manage_submodules() {
    clear
    if [ ! -d "/data/openpilot" ]; then
        print_error "Openpilot directory does not exist."
        pause_for_user
        return 1
    fi

    cd "/data/openpilot" || return 1

    echo "Submodule Management:"
    echo "1. Initialize submodules"
    echo "2. Update submodules"
    echo "3. Reset submodules"
    echo "4. Status check"
    echo "5. Full reset (initialize, update, and reset)"
    echo "Q. Cancel"

    read -p "Enter your choice: " submodule_choice

    case $submodule_choice in
    1)
        print_info "Initializing submodules..."
        git submodule init
        print_success "Submodules initialized."
        ;;
    2)
        print_info "Updating submodules..."
        git submodule update
        print_success "Submodules updated."
        ;;
    3)
        print_info "Resetting submodules..."
        git submodule foreach --recursive 'git reset --hard HEAD'
        print_success "Submodules reset."
        ;;
    4)
        print_info "Submodule status:"
        git submodule status
        ;;
    5)
        print_info "Performing full submodule reset..."
        git submodule update --init --recursive
        git submodule foreach --recursive 'git reset --hard HEAD'
        print_success "Full submodule reset completed."
        ;;
    [qQ]) return 0 ;;
    *) print_error "Invalid choice." ;;
    esac
    pause_for_user
}

# Clone the Openpilot repository
clone_openpilot_repo() {
    local shallow="${1:-true}"

    # Check available disk space first
    verify_disk_space 2000 || {
        print_error "Insufficient space for repository clone"
        return 1
    }

    read -p "Enter the branch name: " branch_name
    read -p "Enter the GitHub repository (e.g., ford-op/openpilot): " github_repo
    cd /data || return
    rm -rf ./openpilot

    if [ "$shallow" = true ]; then
        if ! git_operation_with_timeout "git clone -b $branch_name --depth 1 git@github.com:$github_repo openpilot" 300; then
            print_error "Failed to clone repository"
            return 1
        fi
        (
            cd openpilot || return
            if [ -f ".gitmodules" ]; then
                if ! git_operation_with_timeout "git submodule update --init --recursive" 300; then
                    print_error "Failed to update submodules"
                    return 1
                fi
            fi
        )
    else
        if ! git_operation_with_timeout "git clone -b $branch_name git@github.com:$github_repo openpilot" 300; then
            print_error "Failed to clone repository"
            return 1
        fi
        (
            cd openpilot || return
            if [ -f ".gitmodules" ]; then
                if ! git_operation_with_timeout "git submodule update --init --recursive" 300; then
                    print_error "Failed to update submodules"
                    return 1
                fi
            fi
        )
    fi
    pause_for_user
}

reset_openpilot_repo() {
    read -p "Are you sure you want to reset the Openpilot repository? This will remove the current repository and clone a new one. (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Removing the Openpilot repository..."
        cd /data || return
        rm -rf openpilot
        clone_openpilot_repo "true"
    else
        print_info "Reset cancelled."
    fi
}
