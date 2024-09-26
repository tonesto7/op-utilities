#!/usr/bin/env bash

# Script Version
SCRIPT_VERSION="1.3.0"
SCRIPT_MODIFIED="2021-09-26"

set -e
set -o pipefail # Ensures that the script catches errors in piped commands

reset_variables() {
    SCRIPT_ACTION=""
    REPO=""
    CLONE_BRANCH=""
    BUILD_BRANCH=""
}

# Function to set environment variables
set_env_vars() {
    # Common variables
    OS=$(uname)
    GIT_BP_PUBLIC_REPO="git@github.com:BluePilotDev/bluepilot.git"
    GIT_BP_PRIVATE_REPO="git@github.com:ford-op/sp-dev-c3.git"

    # Determine the build directory based on the OS
    if [ "$OS" = "Darwin" ]; then
        BUILD_DIR="$HOME/Documents/bluepilot-utility/bp-build"
    else
        BUILD_DIR="/data/openpilot"
        # Get the directory where the script is located
        SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
    fi

    # Define the temporary directory for the build
    TMP_DIR="${BUILD_DIR}-build-tmp"
}

# Function to display help
show_help() {
    cat <<EOL
BluePilot Device Script (V$SCRIPT_VERSION) - Last Modified: $SCRIPT_MODIFIED
------------------------------------------------------------

Usage:
  ./build_script.sh [OPTIONS]

Options:
  --dev                             Build BP Internal Dev
  --public                          Build BP Public Experimental
  --clone-public-bp                 Clone BP staging-DONOTUSE Repo on Comma
  --clone-internal-dev-build        Clone bp-internal-dev-build on Comma
  --clone-internal-dev              Clone bp-internal-dev on Comma
  --custom-build                    Perform a custom build
    --repo <repository_name>        Select repository (bluepilotdev or sp-dev-c3)
    --clone-branch <branch_name>    Branch to clone from the selected repository
    --build-branch <branch_name>    Branch name for the build
  --custom-clone                    Perform a custom clone
    --repo <repository_name>        Select repository (bluepilotdev or sp-dev-c3)
    --clone-branch <branch_name>    Branch to clone from the selected repository
  -h, --help                        Show this help message and exit
  --update                          Update the script to the latest version

Examples:
  # Standard build options
  ./build_script.sh --dev
  ./build_script.sh --public

  # Custom build via command line
  ./build_script.sh --custom-build --repo bluepilotdev --clone-branch feature-branch --build-branch build-feature

  # Custom clone via command line
  ./build_script.sh --custom-clone --repo sp-dev-c3 --clone-branch experimental-branch

  # Update the script to the latest version
  ./build_script.sh --update

  # Display help
  ./build_script.sh --help
EOL
}

# Parse command line arguments using getopt
TEMP=$(getopt -o h --long dev,public,clone-public-bp,clone-internal-dev-build,clone-internal-dev,custom-build,custom-clone,repo:,clone-branch:,build-branch:,help -n 'build_script.sh' -- "$@")
if [ $? != 0 ]; then
    echo "Terminating..." >&2
    exit 1
fi

# Note the quotes around `$TEMP`: they are essential!
eval set -- "$TEMP"

# Initialize variables
reset_variables

while true; do
    case "$1" in
    --dev)
        SCRIPT_ACTION="build-dev"
        shift
        ;;
    --public)
        SCRIPT_ACTION="build-public"
        shift
        ;;
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
    --custom-build)
        SCRIPT_ACTION="custom-build"
        shift
        ;;
    --custom-clone)
        SCRIPT_ACTION="custom-clone"
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
    -h | --help)
        show_help
        exit 0
        ;;
    --update)
        update_script
        exit 0
        ;;
    --)
        shift
        break
        ;;
    *)
        echo "Internal error!"
        exit 1
        ;;
    esac
done

# Validate parameters based on SCRIPT_ACTION
if [[ "$SCRIPT_ACTION" == "custom-build" ]]; then
    if [[ -z "$REPO" || -z "$CLONE_BRANCH" || -z "$BUILD_BRANCH" ]]; then
        echo "Error: --custom-build requires --repo, --clone-branch, and --build-branch parameters."
        show_help
        exit 1
    fi
elif [[ "$SCRIPT_ACTION" == "custom-clone" ]]; then
    if [[ -z "$REPO" || -z "$CLONE_BRANCH" ]]; then
        echo "Error: --custom-clone requires --repo and --clone-branch parameters."
        show_help
        exit 1
    fi
fi

# Function to show menu and get build type
show_menu() {
    local allow_reload=$1

    if [ "$allow_reload" = true ]; then
        exec "$0" "$@"
    fi

    # Clear variables at the start of the menu
    reset_variables

    while true; do
        clear
        echo "************************************************************"
        echo "BluePilot Device Menu (v$SCRIPT_VERSION) - Last Modified: $SCRIPT_MODIFIED"
        echo "************************************************************"
        echo ""
        echo "Select menu item:"
        echo "1) Build BP Internal Dev"
        echo "2) Build BP Public Experimental"
        echo "3) Select a Branch to Build"
        echo "4) Clone BP staging-DONOTUSE Repo on Comma"
        echo "5) Clone bp-internal-dev-build on Comma"
        echo "6) Clone bp-internal-dev on Comma"
        echo "7) Clone a Branch from repo"
        echo "r) Reboot Device"
        echo "u) Update this Script"
        echo "h) Show Help"
        echo "q) Quit"
        read -p "Enter your choice: " choice
        case $choice in
        1)
            SCRIPT_ACTION="build-dev"
            clear
            return 0
            ;;
        2)
            SCRIPT_ACTION="build-public"
            clear
            return 0
            ;;
        3)
            SCRIPT_ACTION="custom-build"
            select_custom_build_repo
            clear
            return 0
            ;;
        4)
            SCRIPT_ACTION="clone-public-bp"
            clear
            return 0
            ;;
        5)
            SCRIPT_ACTION="clone-internal-dev-build"
            clear
            return 0
            ;;
        6)
            SCRIPT_ACTION="clone-internal-dev"
            clear
            return 0
            ;;
        7)
            clear
            SCRIPT_ACTION="custom-clone"
            return 0
            ;;
        R | r)
            sudo reboot
            ;;
        H | h | help)
            show_help
            ;;
        Q | q)
            exit 0
            ;;
        u | U) update_script ;;
        *)
            echo "Invalid choice. Please try again."
            ;;
        esac
    done
}

# Function to set up git identity and SSH command
setup_git_env() {
    if [ -f "$BUILD_DIR/release/identity_ford_op.sh" ]; then
        source "$BUILD_DIR/release/identity_ford_op.sh"
    else
        echo "[-] identity_ford_op.sh not found"
        exit 1
    fi

    if [ -f /data/gitkey ]; then
        export GIT_SSH_COMMAND="ssh -i /data/gitkey"
    elif [ -f ~/.ssh/github ]; then
        export GIT_SSH_COMMAND="ssh -i ~/.ssh/github"
    else
        echo "[-] No git key found"
        exit 1
    fi
}

# Function to remove the $BUILD_DIR
clear_build_dir() {
    echo "[-] Removing existing BUILD_DIR"
    rm -rf "$BUILD_DIR"
}

# Function to build OpenPilot
build_openpilot() {
    export PYTHONPATH="$BUILD_DIR"
    echo "[-] Building Openpilot"
    scons -j"$(nproc)"
}

create_prebuilt_marker() {
    # Mark as prebuilt release
    touch prebuilt
}

update_script() {
    echo "Downloading the latest version of the bluepilot utility script..."
    wget https://raw.githubusercontent.com/tonesto7/op-utilities/main/build_scripts/build_bluepilot.sh -O build_bluepilot.sh
    chmod +x build_bluepilot.sh

    # Exit the script after updating and run the updated script
    echo "Script updated successfully. Reloading the new version."
    exec /data/build_bluepilot.sh
}

# Function to handle the panda directory
handle_panda_directory() {
    echo "Creating panda_tmp directory"
    mkdir -p "$BUILD_DIR/panda_tmp/board/obj"
    mkdir -p "$BUILD_DIR/panda_tmp/python"

    # Copy the required files
    cp -f "$BUILD_DIR/panda/board/obj/panda.bin.signed" "$BUILD_DIR/panda_tmp/board/obj/panda.bin.signed" || echo "File not found: panda.bin.signed"
    cp -f "$BUILD_DIR/panda/board/obj/panda_h7.bin.signed" "$BUILD_DIR/panda_tmp/board/obj/panda_h7.bin.signed" || echo "File not found: panda_h7.bin.signed"
    cp -f "$BUILD_DIR/panda/board/obj/bootstub.panda.bin" "$BUILD_DIR/panda_tmp/board/obj/bootstub.panda.bin" || echo "File not found: bootstub.panda.bin"
    cp -f "$BUILD_DIR/panda/board/obj/bootstub.panda_h7.bin" "$BUILD_DIR/panda_tmp/board/obj/bootstub.panda_h7.bin" || echo "File not found: bootstub.panda_h7.bin"

    # Patch the __init__.py file
    if [ "$OS" = "Darwin" ]; then
        sed -i '' 's/^from .board.jungle import PandaJungle, PandaJungleDFU # noqa: F401/# &/' panda/__init__.py
    else
        sed -i 's/^from .board.jungle import PandaJungle, PandaJungleDFU # noqa: F401/# &/' panda/__init__.py
    fi

    # Move the panda/python directory to panda_tmp/python
    cp -r "$BUILD_DIR/panda/python/." "$BUILD_DIR/panda_tmp/python" || echo "Directory not found: panda/python"
    cp -f "$BUILD_DIR/panda/.gitignore" "$BUILD_DIR/panda_tmp/.gitignore" || echo "File not found: .gitignore"
    cp -f "$BUILD_DIR/panda/__init__.py" "$BUILD_DIR/panda_tmp/__init__.py" || echo "File not found: __init__.py"
    cp -f "$BUILD_DIR/panda/mypy.ini" "$BUILD_DIR/panda_tmp/mypy.ini" || echo "File not found: mypy.ini"
    cp -f "$BUILD_DIR/panda/panda.png" "$BUILD_DIR/panda_tmp/panda.png" || echo "File not found: panda.png"
    cp -f "$BUILD_DIR/panda/pyproject.toml" "$BUILD_DIR/panda_tmp/pyproject.toml" || echo "File not found: pyproject.toml"
    cp -f "$BUILD_DIR/panda/requirements.txt" "$BUILD_DIR/panda_tmp/requirements.txt" || echo "File not found: requirements.txt"
    cp -f "$BUILD_DIR/panda/setup.cfg" "$BUILD_DIR/panda_tmp/setup.cfg" || echo "File not found: setup.cfg"
    cp -f "$BUILD_DIR/panda/setup.py" "$BUILD_DIR/panda_tmp/setup.py" || echo "File not found: setup.py"

    # Remove the panda directory and move the panda_tmp directory to panda
    rm -rf "$BUILD_DIR/panda"
    mv "$BUILD_DIR/panda_tmp" "$BUILD_DIR/panda"
}

# Function to process submodules
process_submodules() {
    local MOD_DIR="$1"
    if [ -z "$MOD_DIR" ]; then
        echo "Error: MOD_DIR not provided to process_submodules()"
        return 1
    fi

    SUBMODULES=("msgq_repo" "opendbc" "rednose_repo" "panda" "tinygrad_repo" "teleoprtc_repo")

    for SUBMODULE in "${SUBMODULES[@]}"; do
        echo "[-] Processing submodule: $SUBMODULE"
        mkdir -p "${MOD_DIR}/${SUBMODULE}_tmp"
        cp -r "${MOD_DIR}/$SUBMODULE/." "${MOD_DIR}/${SUBMODULE}_tmp" || echo "Directory not found: $SUBMODULE"
        git submodule deinit -f "$SUBMODULE"
        git rm -rf --cached "$SUBMODULE"
        rm -rf "${MOD_DIR}/$SUBMODULE"
        mv "${MOD_DIR}/${SUBMODULE}_tmp" "${MOD_DIR}/$SUBMODULE"
        rm -rf "${MOD_DIR}/.git/modules/$SUBMODULE"
        git add -f "$SUBMODULE"
    done

    # Special handling for opendbc_repo
    if [ -d "${MOD_DIR}/.git/modules/opendbc_repo" ]; then
        echo "[-] Cleaning up .git/modules for opendbc_repo"
        rm -rf "${MOD_DIR}/.git/modules/opendbc_repo"
    fi
}

# Function to create .gitignore for opendbc_repo
create_opendbc_gitignore() {
    cat >opendbc_repo/.gitignore <<EOL
.mypy_cache/
*.pyc
*.os
*.o
*.tmp
*.dylib
.*.swp
.DS_Store
.sconsign.dblite

opendbc/can/*.so
opendbc/can/*.a
opendbc/can/build/
opendbc/can/obj/
opendbc/can/packer_pyx.cpp
opendbc/can/parser_pyx.cpp
opendbc/can/packer_pyx.html
opendbc/can/parser_pyx.html
EOL
}

# Function to update main .gitignore
update_main_gitignore() {
    GITIGNORE_PATH=".gitignore"
    LINES_TO_REMOVE=(
        "*.dylib"
        "*.so"
        "selfdrive/pandad/pandad"
        "cereal/messaging/bridge"
        "selfdrive/logcatd/logcatd"
        "system/camerad/camerad"
        "selfdrive/modeld/_modeld"
        "selfdrive/modeld/_navmodeld"
        "selfdrive/modeld/_dmonitoringmodeld"
    )

    for LINE in "${LINES_TO_REMOVE[@]}"; do
        if [ "$OS" = "Darwin" ]; then
            sed -i '' "/^${LINE//\//\\/}$/d" "$GITIGNORE_PATH"
        else
            sed -i "/^${LINE//\//\\/}$/d" "$GITIGNORE_PATH"
        fi
    done

    echo "Specified lines removed from .gitignore"
}

# Function to clean up unnecessary files
cleanup_files() {
    echo "[-] Cleaning up unnecessary files T=$SECONDS"

    # Remove specific file types using a single find command
    find . \( -name '*.a' -o -name '*.o' -o -name '*.os' -o -name '*.pyc' -o -name 'moc_*' -o -name '*.cc' -o -name '__pycache__' -o -name '.DS_Store' \) -exec rm -rf {} +

    # Remove specific files and directories
    rm -rf .sconsign.dblite .venv .devcontainer .idea .mypy_cache .run .vscode
    rm -f .clang-tidy .env .gitmodules .gitattributes
    rm -rf teleoprtc_repo teleoprtc release
    rm -f selfdrive/modeld/models/supercombo.onnx
    rm -rf selfdrive/ui/replay/
    rm -rf tools/cabana tools/camerastream tools/car_porting tools/joystick tools/latencylogger tools/plotjuggler tools/profiling
    rm -rf tools/replay tools/rerun tools/scripts tools/serial tools/sim tools/tuning tools/webcam
    rm -f tools/*.py tools/*.sh tools/*.md
    rm -f conftest.py SECURITY.md uv.lock

    # Clean up specific directories
    cleanup_directory "cereal" "*tests* *.md"
    cleanup_directory "common" "*tests* *.md"
    cleanup_directory "msgq_repo" "*tests* *.md .git*"
    cleanup_directory "opendbc_repo" "*tests* *.md .git* LICENSE"
    cleanup_directory "rednose_repo" "*tests* *.md .git* LICENSE"
    cleanup_directory "selfdrive" "*.h *.md *test*"
    cleanup_directory "system" "*tests* *.md"
    cleanup_directory "third_party" "*Darwin* LICENSE README.md"

    # Clean up tinygrad_repo
    cleanup_tinygrad_repo
}

# Helper function to clean up specific directories
cleanup_directory() {
    local dir=$1
    local patterns=$2
    for pattern in $patterns; do
        find "$dir/" -name "$pattern" -exec rm -rf {} +
    done
}

# Function to clean up tinygrad_repo
cleanup_tinygrad_repo() {
    rm -rf tinygrad_repo/{cache,disassemblers,docs,examples,models,test,weights}
    rm -rf tinygrad_repo/extra/{accel,assembly,dataset,disk,dist,fastvits,intel,optimization,ptx,rocm,triton}
    find tinygrad_repo/extra -maxdepth 1 -type f -name '*.py' ! -name 'onnx*.py' ! -name 'thneed*.py' ! -name 'utils*.py' -exec rm -f {} +
    rm -rf tinygrad_repo/extra/{datasets,gemm}
    find tinygrad_repo/ -name '*tests*' -exec rm -rf {} +
    find tinygrad_repo/ -name '.git*' -exec rm -rf {} +
    find tinygrad_repo/ -name '*.md' -exec rm -f {} +
    rm -f tinygrad_repo/{.flake8,.pylintrc,.tokeignore,*.sh,*.ini,*.toml,*.py}
}

clone_repo() {
    local description="$1"
    local repo_url="$2"
    local branch="$3"
    local build="$4" # "yes" or "no"

    echo "[-] Cloning $description on Comma..."
    cd /data || {
        echo "[-] Failed to change directory to /data"
        exit 1
    }
    rm -rf openpilot || {
        echo "[-] Failed to remove existing openpilot directory"
        exit 1
    }

    if [[ "$branch" != *-build* ]]; then
        git clone --recurse-submodules --depth 1 "${repo_url}" -b "${branch}" openpilot || {
            echo "[-] Failed to clone repository."
            exit 1
        }
    else
        # Fixed --depth option to use a numerical value
        git clone --depth 1 "${repo_url}" -b "${branch}" openpilot || {
            echo "[-] Failed to clone repository."
            exit 1
        }
    fi

    cd openpilot || {
        echo "[-] Failed to change directory to openpilot"
        exit 1
    }

    if [ "$build" == "yes" ]; then
        scons -j"$(nproc)" || {
            echo "[-] SCons build failed."
            exit 1
        }
    fi
    reboot_device
}

clone_public_bluepilot() {
    clone_repo "the public BluePilot" "$GIT_BP_PUBLIC_REPO" "staging-DONOTUSE" "no"
}

# Modify clone_internal_dev_build to use clone_repo with build
clone_internal_dev_build() {
    clone_repo "bp-internal-dev-build" "$GIT_BP_PRIVATE_REPO" "bp-internal-dev-build" "no"
}

# Modify clone_internal_dev to use clone_repo with build
clone_internal_dev() {
    clone_repo "bp-internal-dev" "$GIT_BP_PRIVATE_REPO" "bp-internal-dev" "yes"
}

reboot_device() {
    read -p "Would you like to reboot the Comma device? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "[-] Rebooting Comma device..."
        sudo reboot
    else
        echo "Reboot canceled."
    fi
}

choose_repository_and_branch() {
    local action="$1" # "build" or "clone"

    while true; do
        echo ""
        echo "Select Repository:"
        echo "1) BluePilotDev/bluepilot"
        echo "2) ford-op/sp-dev-c3"
        echo "c) Cancel and return to main menu"
        read -p "Enter your choice: " repo_choice
        case $repo_choice in
        1)
            REPO="bluepilotdev"
            GIT_REPO_ORIGIN="$GIT_BP_PUBLIC_REPO"
            ;;
        2)
            REPO="sp-dev-c3"
            GIT_REPO_ORIGIN="$GIT_BP_PRIVATE_REPO"
            ;;
        C | c)
            echo "Returning to main menu."
            show_menu true
            ;;
        *)
            echo "Invalid choice. Please try again."
            continue
            ;;
        esac
        break
    done

    # Fetch the list of remote branches
    clear
    echo "[-] Fetching list of branches from $GIT_REPO_ORIGIN..."
    REMOTE_BRANCHES=$(git ls-remote --heads "$GIT_REPO_ORIGIN" 2>&1)

    if [ $? -ne 0 ]; then
        echo "[-] Failed to fetch branches from $GIT_REPO_ORIGIN."
        echo "Error: $REMOTE_BRANCHES"
        SCRIPT_ACTION=""
        return
    fi

    REMOTE_BRANCHES=$(echo "$REMOTE_BRANCHES" | awk '{print $2}' | sed 's#refs/heads/##')

    # Filter out branches ending with "-build" if action is "build"
    if [ "$action" = "build" ]; then
        REMOTE_BRANCHES=$(echo "$REMOTE_BRANCHES" | grep -v -- "-build")
    fi

    readarray -t BRANCH_ARRAY <<<"$REMOTE_BRANCHES"

    if [ ${#BRANCH_ARRAY[@]} -eq 0 ]; then
        echo "[-] No branches found in the repository."
        SCRIPT_ACTION=""
        return
    fi

    echo "Available branches in $REPO:"
    for i in "${!BRANCH_ARRAY[@]}"; do
        printf "%d) %s\n" $((i + 1)) "${BRANCH_ARRAY[i]}"
    done

    while true; do
        read -p "Select a branch by number (or 'c' to cancel): " branch_choice
        if [[ "$branch_choice" == "c" || "$branch_choice" == "C" ]]; then
            echo "Returning to main menu."
            clear
            show_menu true
            return
        elif [[ "$branch_choice" =~ ^[0-9]+$ ]] && [ "$branch_choice" -ge 1 ] && [ "$branch_choice" -le "${#BRANCH_ARRAY[@]}" ]; then
            SELECTED_BRANCH="${BRANCH_ARRAY[$((branch_choice - 1))]}"
            CLONE_BRANCH="$SELECTED_BRANCH"
            BUILD_BRANCH="${CLONE_BRANCH}-build"
            clear
            echo "Selected branch: $CLONE_BRANCH"
            echo "Build branch will be: $BUILD_BRANCH"
            break
        else
            echo "Invalid choice. Please enter a valid number or 'c' to cancel."
        fi
    done
}

clone_custom_repo() {
    if [[ -n "$REPO" && -n "$CLONE_BRANCH" ]]; then
        echo "[-] Performing custom clone with provided parameters:"
        echo "     Repository: $REPO"
        echo "     Clone Branch: $CLONE_BRANCH"
        if [[ "$CLONE_BRANCH" != *-build* ]]; then
            BUILD_FLAG="yes"
        else
            BUILD_FLAG="no"
        fi
    else
        echo "[-] Custom Clone Option Selected"
        choose_repository_and_branch "clone"
    fi

    # Determine the correct repository URL based on the selected repository
    case "$REPO" in
    bluepilotdev)
        GIT_REPO_URL="$GIT_BP_PUBLIC_REPO"
        ;;
    sp-dev-c3)
        GIT_REPO_URL="$GIT_BP_PRIVATE_REPO"
        ;;
    *)
        echo "[-] Unknown repository: $REPO"
        exit 1
        ;;
    esac

    # Proceed with cloning using clone_repo function
    clone_repo "repository '$REPO' with branch '$CLONE_BRANCH'" "$GIT_REPO_URL" "$CLONE_BRANCH" "$BUILD_FLAG"
}

# Function to select repository and branch for custom build
select_custom_build_repo() {
    clear
    echo "[-] Custom Build Option Selected"
    choose_repository_and_branch "build"
}

# Function for cross-repo branch build process
build_cross_repo_branch() {
    local CLONE_BRANCH="$1"
    local BUILD_BRANCH="$2"
    local COMMIT_DESC_HEADER="$3"
    local GIT_REPO_ORIGIN="$4"
    local GIT_PUBLIC_REPO_ORIGIN="$5"

    echo "[-] Starting cross-repo branch build process"
    echo "[-] Cloning $GIT_REPO_ORIGIN | Branch: $CLONE_BRANCH"

    echo "[-] Removing existing directories"
    rm -rf "$BUILD_DIR" "$TMP_DIR"

    echo "[-] Cloning $GIT_PUBLIC_REPO_ORIGIN Repo to $BUILD_DIR"
    git clone --single-branch --branch "$BUILD_BRANCH" "$GIT_PUBLIC_REPO_ORIGIN" "$BUILD_DIR"

    cd "$BUILD_DIR"

    echo "[-] Removing all files from cloned repo except .git"
    find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +

    # Clone main repo
    echo "[-] Cloning $GIT_REPO_ORIGIN Repo to $TMP_DIR"
    git clone --recurse-submodules --depth 1 "$GIT_REPO_ORIGIN" -b "$CLONE_BRANCH" "$TMP_DIR"

    cd "$TMP_DIR"

    echo "[-] Processing submodules in TMP_DIR"
    process_submodules "$TMP_DIR"

    cd "$BUILD_DIR"

    echo "[-] Copying files from TMP_DIR to BUILD_DIR"
    rsync -a --exclude='.git' "$TMP_DIR/" "$BUILD_DIR/"

    # Remove the TMP_DIR
    echo "[-] Removing TMP_DIR"
    rm -rf "$TMP_DIR"

    setup_git_env
    build_openpilot
    handle_panda_directory
    create_opendbc_gitignore
    update_main_gitignore
    cleanup_files

    create_prebuilt_marker

    prepare_commit_push "$COMMIT_DESC_HEADER" "$GIT_PUBLIC_REPO_ORIGIN" "$BUILD_BRANCH"
}

# Function for single-repo branch build process
build_repo_branch() {
    local CLONE_BRANCH="$1"
    local BUILD_BRANCH="$2"
    local COMMIT_DESC_HEADER="$3"
    local GIT_REPO_ORIGIN="$4"

    echo "[-] Starting single-repo branch build process"
    echo "[-] Cloning $GIT_REPO_ORIGIN | Branch: $CLONE_BRANCH"

    echo "[-] Removing existing directories"
    rm -rf "$BUILD_DIR" "$TMP_DIR"

    echo "[-] Cloning $GIT_REPO_ORIGIN Repo to $BUILD_DIR"
    git clone --recurse-submodules "$GIT_REPO_ORIGIN" -b "$CLONE_BRANCH" "$BUILD_DIR"
    cd "$BUILD_DIR"

    setup_git_env

    build_openpilot
    handle_panda_directory
    process_submodules "$BUILD_DIR"
    create_opendbc_gitignore
    update_main_gitignore
    cleanup_files

    create_prebuilt_marker

    prepare_commit_push "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN" "$BUILD_BRANCH"
}

# Function for custom build process
custom_build_process() {
    if [ -z "$REPO" ] || [ -z "$CLONE_BRANCH" ] || [ -z "$BUILD_BRANCH" ]; then
        echo "Error: --custom-build requires --repo, --clone-branch, and --build-branch parameters."
        show_help
        exit 1
    fi

    #   echo "[-] Starting custom build process for repository '$REPO' with clone branch '$CLONE_BRANCH' and build branch '$BUILD_BRANCH'"

    local GIT_REPO_ORIGIN="$REPO"
    local COMMIT_DESC_HEADER="Custom Build"

    build_repo_branch "$CLONE_BRANCH" "$BUILD_BRANCH" "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN"
}

# Function to prepare the commit
prepare_commit_push() {
    local COMMIT_DESC_HEADER=$1
    local ORIGIN_REPO=$2
    local BUILD_BRANCH=$3

    # Ensure version.h exists
    if [ ! -f "$BUILD_DIR/common/version.h" ]; then
        echo "Error: $BUILD_DIR/common/version.h not found."
        exit 1
    fi

    VERSION=$(date '+%Y.%m.%d')
    TIME_CODE=$(date +"%H%M")
    GIT_HASH=$(git rev-parse HEAD)
    DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
    SP_VERSION=$(cat $BUILD_DIR/common/version.h | awk -F\" '{print $2}')

    echo "#define COMMA_VERSION \"$VERSION-$TIME_CODE\"" >"$BUILD_DIR/common/version.h"
    echo "[-] Preparing commit for version $VERSION-$TIME_CODE T=$SECONDS"

    create_prebuilt_marker

    # Create a new orphan branch
    echo "[-] Creating orphan branch temp_branch T=$SECONDS"
    git checkout --orphan temp_branch --quiet

    # Add all files
    echo "[-] Adding all files to commit T=$SECONDS"
    git add -A >/dev/null 2>&1

    # Commit with the desired message
    echo "[-] Committing changes T=$SECONDS"
    git commit -m "$COMMIT_DESC_HEADER | v$VERSION-$TIME_CODE
version: $COMMIT_DESC_HEADER v$SP_VERSION release
date: $DATETIME
master commit: $GIT_HASH
" || {
        echo "[-] Commit failed"
        exit 1
    }

    # Check if the local build branch exists and delete it
    if git show-ref --verify --quiet "refs/heads/$BUILD_BRANCH"; then
        echo "[-] Deleting Local Branch: $BUILD_BRANCH T=$SECONDS"
        git branch -D "$BUILD_BRANCH" || {
            echo "[-] Failed to delete local branch $BUILD_BRANCH"
            exit 1
        }
    else
        echo "[-] Local branch $BUILD_BRANCH does not exist. Skipping deletion. (The next step might take awhile before it shows any output.)"
    fi
    # Check if the remote build branch exists before attempting to delete
    if git ls-remote --heads "$ORIGIN_REPO" "$BUILD_BRANCH" | grep "$BUILD_BRANCH" >/dev/null 2>&1; then
        echo "[-] Deleting Remote Branch: $BUILD_BRANCH T=$SECONDS"
        git push "$ORIGIN_REPO" --delete "$BUILD_BRANCH" || {
            echo "[-] Failed to delete remote branch $BUILD_BRANCH"
            exit 1
        }
    else
        echo "[-] Remote branch $BUILD_BRANCH does not exist. Skipping deletion."
    fi

    # Rename the temp branch to the desired build branch
    echo "[-] Renaming temp_branch to $BUILD_BRANCH T=$SECONDS"
    git branch -m "$BUILD_BRANCH" >/dev/null 2>&1 || {
        echo "[-] Failed to rename branch"
        exit 1
    }

    # Force push the new build branch to the remote repository
    echo "[-] Force pushing to $BUILD_BRANCH branch to remote repo $ORIGIN_REPO T=$SECONDS"
    git push -f "$ORIGIN_REPO" "$BUILD_BRANCH" || {
        echo "[-] Failed to push to remote branch $BUILD_BRANCH"
        exit 1
    }

    echo "[-] Branch $BUILD_BRANCH has been reset and force pushed T=$SECONDS"
}

# Main execution flow
main() {
    while true; do
        if [ -z "$SCRIPT_ACTION" ]; then
            show_menu
            continue
        fi

        case "$SCRIPT_ACTION" in
        build-public)
            build_cross_repo_branch "bp-public-experimental" "staging-DONOTUSE" "bluepilot experimental" "$GIT_BP_PUBLIC_REPO" "$GIT_BP_PUBLIC_REPO"
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
            clone_custom_repo
            ;;
        custom-build)
            custom_build_process
            ;;
        *)
            echo "Invalid build type. Exiting."
            exit 1
            ;;
        esac

        echo "[-] Action completed successfully T=$SECONDS"

        reset_variables

        # Add this line to break the loop after a successful build
        break
    done
}

# Show menu if SCRIPT_ACTION is not set via command line
if [ -z "$SCRIPT_ACTION" ]; then
    show_menu
fi

# Set environment variables
set_env_vars

# Run the main function
main
