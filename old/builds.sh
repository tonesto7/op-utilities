#!/bin/bash
###############################################################################
# builds.sh - Device Build and Management Operations for CommaUtility
#
# Version: BUILDS_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script manages device build operations (Openpilot, BluePilot, etc.)
# including cloning, building, and managing branches.
###############################################################################
readonly BUILDS_SCRIPT_VERSION="3.0.3"
readonly BUILDS_SCRIPT_MODIFIED="2025-02-09"

# Variables from build_bluepilot script
SCRIPT_ACTION=""
REPO=""
CLONE_BRANCH=""
BUILD_BRANCH=""

# ================================
# Build Functions
# ================================

setup_git_env_bp() {
    if [ -f "$BUILD_DIR/release/identity_ford_op.sh" ]; then
        # shellcheck disable=SC1090
        source "$BUILD_DIR/release/identity_ford_op.sh"
    else
        print_error "[-] identity_ford_op.sh not found"
        exit 1
    fi

    if [ -f /data/gitkey ]; then
        export GIT_SSH_COMMAND="ssh -i /data/gitkey"
    elif [ -f ~/.ssh/github ]; then
        export GIT_SSH_COMMAND="ssh -i ~/.ssh/github"
    else
        print_error "[-] No git key found"
        exit 1
    fi
}

build_openpilot_bp() {
    export PYTHONPATH="$BUILD_DIR"
    print_info "[-] Building Openpilot"
    scons -j"$(nproc)"
}

create_prebuilt_marker() {
    touch prebuilt
}

handle_panda_directory() {
    print_info "Creating panda_tmp directory"
    mkdir -p "$BUILD_DIR/panda_tmp/board/obj"
    mkdir -p "$BUILD_DIR/panda_tmp/python"

    cp -f "$BUILD_DIR/panda/board/obj/panda.bin.signed" "$BUILD_DIR/panda_tmp/board/obj/panda.bin.signed" || :
    cp -f "$BUILD_DIR/panda/board/obj/panda_h7.bin.signed" "$BUILD_DIR/panda_tmp/board/obj/panda_h7.bin.signed" || :
    cp -f "$BUILD_DIR/panda/board/obj/bootstub.panda.bin" "$BUILD_DIR/panda_tmp/board/obj/bootstub.panda.bin" || :
    cp -f "$BUILD_DIR/panda/board/obj/bootstub.panda_h7.bin" "$BUILD_DIR/panda_tmp/board/obj/bootstub.panda_h7.bin" || :

    if [ "$OS" = "Darwin" ]; then
        sed -i '' 's/^from .board.jungle import PandaJungle, PandaJungleDFU # noqa: F401/# &/' panda/__init__.py
    else
        sed -i 's/^from .board.jungle import PandaJungle, PandaJungleDFU # noqa: F401/# &/' panda/__init__.py
    fi

    cp -r "$BUILD_DIR/panda/python/." "$BUILD_DIR/panda_tmp/python" || :
    cp -f "$BUILD_DIR/panda/.gitignore" "$BUILD_DIR/panda_tmp/.gitignore" || :
    cp -f "$BUILD_DIR/panda/__init__.py" "$BUILD_DIR/panda_tmp/__init__.py" || :
    cp -f "$BUILD_DIR/panda/mypy.ini" "$BUILD_DIR/panda_tmp/mypy.ini" || :
    cp -f "$BUILD_DIR/panda/panda.png" "$BUILD_DIR/panda_tmp/panda.png" || :
    cp -f "$BUILD_DIR/panda/pyproject.toml" "$BUILD_DIR/panda_tmp/pyproject.toml" || :
    cp -f "$BUILD_DIR/panda/requirements.txt" "$BUILD_DIR/panda_tmp/requirements.txt" || :
    cp -f "$BUILD_DIR/panda/setup.cfg" "$BUILD_DIR/panda_tmp/setup.cfg" || :
    cp -f "$BUILD_DIR/panda/setup.py" "$BUILD_DIR/panda_tmp/setup.py" || :

    rm -rf "$BUILD_DIR/panda"
    mv "$BUILD_DIR/panda_tmp" "$BUILD_DIR/panda"
}

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

update_main_gitignore() {
    local GITIGNORE_PATH=".gitignore"
    local LINES_TO_REMOVE=(
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

    # local LINES_TO_ADD=(
    #     "selfdrive/controls/lib/lateral_mpc_lib/acados_ocp_lat.json"
    #     "selfdrive/controls/lib/longitudinal_mpc_lib/acados_ocp_long.json"
    # )

    # # Add the following lines to the gitignore file
    # for LINE in "${LINES_TO_ADD[@]}"; do
    #     echo "$LINE" >>"$GITIGNORE_PATH"
    # done

    for LINE in "${LINES_TO_REMOVE[@]}"; do
        if [ "$OS" = "Darwin" ]; then
            sed -i '' "/^${LINE//\//\\/}$/d" "$GITIGNORE_PATH"
        else
            sed -i "/^${LINE//\//\\/}$/d" "$GITIGNORE_PATH"
        fi
    done
}

cleanup_files() {
    local CURRENT_DIR
    CURRENT_DIR=$(pwd)
    ensure_directory "$BUILD_DIR" || return 1

    # Remove compiled artifacts
    find . \( -name '*.a' -o -name '*.o' -o -name '*.os' -o -name '*.pyc' -o -name 'moc_*' -o -name '*.cc' -o -name '__pycache__' -o -name '.DS_Store' \) -exec rm -rf {} +
    rm -rf .sconsign.dblite .venv .devcontainer .idea .mypy_cache .run .vscode
    rm -f .clang-tidy .env .gitmodules .gitattributes
    rm -rf teleoprtc_repo teleoprtc release
    rm -f selfdrive/modeld/models/supercombo.onnx
    rm -rf selfdrive/ui/replay/
    rm -rf tools/cabana tools/camerastream tools/car_porting tools/joystick tools/latencylogger tools/plotjuggler tools/profiling
    rm -rf tools/replay tools/rerun tools/scripts tools/serial tools/sim tools/tuning tools/webcam
    rm -f tools/*.py tools/*.sh tools/*.md
    rm -f conftest.py SECURITY.md uv.lock
    rm -f selfdrive/controls/lib/lateral_mpc_lib/.gitignore selfdrive/controls/lib/longitudinal_mpc_lib/.gitignore

    cleanup_directory "$BUILD_DIR/cereal" "*tests* *.md"
    cleanup_directory "$BUILD_DIR/common" "*tests* *.md"
    cleanup_directory "$BUILD_DIR/msgq_repo" "*tests* *.md .git*"
    cleanup_directory "$BUILD_DIR/opendbc_repo" "*tests* *.md .git* LICENSE"
    cleanup_directory "$BUILD_DIR/rednose_repo" "*tests* *.md .git* LICENSE"
    cleanup_directory "$BUILD_DIR/selfdrive" "*.h *.md *test*"
    cleanup_directory "$BUILD_DIR/system" "*tests* *.md"
    cleanup_directory "$BUILD_DIR/third_party" "*Darwin* LICENSE README.md"

    cleanup_tinygrad_repo
    cd "$CURRENT_DIR" || return 1
}

cleanup_directory() {
    local dir="$1"
    local patterns="$2"
    for pattern in $patterns; do
        find "$dir/" -name "$pattern" -exec rm -rf {} +
    done
}

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

prepare_commit_push() {
    local COMMIT_DESC_HEADER=$1
    local ORIGIN_REPO=$2
    local BUILD_BRANCH=$3
    local PUSH_REPO=${4:-$ORIGIN_REPO} # Use alternative repo if provided, otherwise use origin

    if [ ! -f "$BUILD_DIR/common/version.h" ]; then
        print_error "Error: $BUILD_DIR/common/version.h not found."
        exit 1
    fi

    local VERSION
    VERSION=$(date '+%Y.%m.%d')
    local TIME_CODE
    TIME_CODE=$(date +"%H%M")
    local GIT_HASH
    GIT_HASH=$(git rev-parse HEAD)
    local DATETIME
    DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
    local SP_VERSION
    SP_VERSION=$(awk -F\" '{print $2}' "$BUILD_DIR/common/version.h")

    echo "#define COMMA_VERSION \"$VERSION-$TIME_CODE\"" >"$BUILD_DIR/common/version.h"
    create_prebuilt_marker

    git checkout --orphan temp_branch --quiet

    git add -f -A >/dev/null 2>&1
    git commit -m "$COMMIT_DESC_HEADER | v$VERSION-$TIME_CODE
version: $COMMIT_DESC_HEADER v$SP_VERSION release
date: $DATETIME
master commit: $GIT_HASH
" || {
        print_error "[-] Commit failed"
        exit 1
    }

    if git show-ref --verify --quiet "refs/heads/$BUILD_BRANCH"; then
        git branch -D "$BUILD_BRANCH" || exit 1
    fi
    if git ls-remote --heads "$PUSH_REPO" "$BUILD_BRANCH" | grep "$BUILD_BRANCH" >/dev/null 2>&1; then
        git push "$PUSH_REPO" --delete "$BUILD_BRANCH" || exit 1
    fi

    git branch -m "$BUILD_BRANCH" >/dev/null 2>&1 || exit 1
    git push -f "$PUSH_REPO" "$BUILD_BRANCH" || exit 1
}

build_repo_branch() {
    local CLONE_BRANCH="$1"
    local BUILD_BRANCH="$2"
    local COMMIT_DESC_HEADER="$3"
    local GIT_REPO_ORIGIN="$4"
    local PUSH_REPO="$5" # Optional alternative push repository

    # Check available disk space first.
    verify_disk_space 5000 || {
        print_error "Insufficient disk space for build operation"
        return 1
    }

    local CURRENT_DIR
    CURRENT_DIR=$(pwd)

    rm -rf "$BUILD_DIR" "$TMP_DIR"
    if ! git_operation_with_timeout "git clone $GIT_REPO_ORIGIN -b $CLONE_BRANCH $BUILD_DIR" 300; then
        print_error "Failed to clone repository"
        return 1
    fi

    cd "$BUILD_DIR" || exit 1

    # Update submodules if any.
    if [ -f ".gitmodules" ]; then
        if ! git_operation_with_timeout "git submodule update --init --recursive" 300; then
            print_error "Failed to update submodules"
            return 1
        fi
    fi

    setup_git_env_bp
    build_openpilot_bp
    handle_panda_directory

    # Convert all submodules into plain directories.
    process_submodules "$BUILD_DIR"

    create_opendbc_gitignore
    update_main_gitignore
    cleanup_files
    create_prebuilt_marker

    if [ -n "$PUSH_REPO" ]; then
        prepare_commit_push "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN" "$BUILD_BRANCH" "$PUSH_REPO"
    else
        prepare_commit_push "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN" "$BUILD_BRANCH"
    fi

    cd "$CURRENT_DIR" || exit 1
}

process_submodules() {
    local mod_dir="$1"
    local submodules=("msgq_repo" "opendbc_repo" "rednose_repo" "panda" "tinygrad_repo" "teleoprtc_repo")

    for sub in "${submodules[@]}"; do
        if [ -d "${mod_dir}/${sub}" ]; then
            # Create a temporary copy preserving all attributes.
            local tmp_dir="${mod_dir}/${sub}_tmp"
            rm -rf "$tmp_dir"
            cp -a "${mod_dir}/${sub}" "$tmp_dir"

            # Remove any .git folder inside the copied submodule so that files are tracked as normal files.
            rm -rf "$tmp_dir/.git"

            # Remove the submodule from git’s index.
            git rm -rf --cached "$sub" 2>/dev/null

            # Remove the original submodule directory.
            rm -rf "${mod_dir}/${sub}"

            # Rename the temporary directory to the original name.
            mv "$tmp_dir" "${mod_dir}/${sub}"

            # Remove any leftover git metadata from the main repository.
            rm -rf "${mod_dir}/.git/modules/${sub}"

            # Force add the now-converted directory.
            git add "$sub"
        fi
    done
}

clone_repo_bp() {
    local description="$1"
    local repo_url="$2"
    local branch="$3"
    local build="$4"
    local skip_reboot="${5:-no}"

    local CURRENT_DIR
    CURRENT_DIR=$(pwd)

    cd "/data" || exit 1
    rm -rf openpilot
    git clone --depth 1 "${repo_url}" -b "${branch}" openpilot || exit 1
    cd openpilot || exit 1

    # Check if there are any submodules and if so, update them
    if [ -f ".gitmodules" ]; then
        git submodule update --init --recursive
    fi

    if [ "$build" == "yes" ]; then
        scons -j"$(nproc)" || exit 1
    fi

    if [ "$skip_reboot" == "yes" ]; then
        cd "$CURRENT_DIR" || exit 1
    else
        reboot_device
    fi
}

clone_public_bluepilot() {
    clone_repo_bp "the public BluePilot" "$GIT_BP_PUBLIC_REPO" "staging-DONOTUSE" "no"
}

clone_internal_dev_build() {
    clone_repo_bp "bp-internal-dev-build" "$GIT_BP_PRIVATE_REPO" "bp-internal-dev-build" "no"
}

clone_internal_dev() {
    clone_repo_bp "bp-internal-dev" "$GIT_BP_PRIVATE_REPO" "bp-internal-dev" "yes"
}

reboot_device_bp() {
    read -p "Would you like to reboot the Comma device? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sudo reboot
    else
        print_info "Reboot canceled."
    fi
}

choose_repository_and_branch() {
    clear
    local action="$1"

    # First, select repository.
    while true; do
        echo ""
        echo "Select Repository:"
        echo "1) BluePilotDev/bluepilot"
        echo "2) ford-op/sp-dev-c3"
        echo "3) sunnypilot/sunnypilot"
        echo "4) commaai/openpilot"
        echo "c) Cancel"
        read -p "Enter your choice: " repo_choice
        case $repo_choice in
        1)
            REPO="bluepilotdev"
            GIT_REPO_ORIGIN="$GIT_BP_PUBLIC_REPO"
            break
            ;;
        2)
            REPO="sp-dev-c3"
            GIT_REPO_ORIGIN="$GIT_BP_PRIVATE_REPO"
            break
            ;;
        3)
            REPO="sunnypilot"
            GIT_REPO_ORIGIN="$GIT_SP_REPO"
            break
            ;;
        4)
            REPO="commaai"
            GIT_REPO_ORIGIN="$GIT_COMMA_REPO"
            break
            ;;
        [cC])
            return 1
            ;;
        *)
            print_error "Invalid choice. Please try again."
            ;;
        esac
    done

    clear
    # Use reusable branch selection to choose the branch.
    if ! select_branch_menu "$GIT_REPO_ORIGIN"; then
        return 1
    fi

    # Set the chosen branch to both CLONE_BRANCH and (optionally) BUILD_BRANCH.
    CLONE_BRANCH="$SELECTED_BRANCH"
    BUILD_BRANCH="${CLONE_BRANCH}-build"

    # print_info "Selected branch: $CLONE_BRANCH"
    # print_info "Build branch would be: $BUILD_BRANCH"
    return 0
}

clone_custom_repo() {
    if ! choose_repository_and_branch "clone"; then
        return
    fi

    case "$REPO" in
    bluepilotdev) GIT_REPO_URL="$GIT_BP_PUBLIC_REPO" ;;
    sp-dev-c3) GIT_REPO_URL="$GIT_BP_PRIVATE_REPO" ;;
    sunnypilot) GIT_REPO_URL="$GIT_SP_REPO" ;;
    commaai) GIT_REPO_URL="$GIT_COMMA_REPO" ;;
    *)
        print_error "[-] Unknown repository: $REPO"
        return
        ;;
    esac

    clone_repo_bp "repository '$REPO' with branch '$CLONE_BRANCH'" "$GIT_REPO_URL" "$CLONE_BRANCH" "no" "yes"
    if [ ! -f "/data/openpilot/prebuilt" ]; then
        print_warning "[-] No prebuilt marker found. Might need to compile."
        read -p "Compile now? (y/N): " compile_confirm
        if [[ "$compile_confirm" =~ ^[Yy]$ ]]; then
            print_info "[-] Running scons..."
            cd "/data/openpilot" || exit 1
            scons -j"$(nproc)" || {
                print_error "[-] SCons failed."
                exit 1
            }
            print_success "[-] Compilation completed."
        fi
    fi

    reboot_device_bp
}

custom_build_process() {
    if ! choose_repository_and_branch "build"; then
        return
    fi
    if [ "$REPO" = "bluepilotdev" ]; then
        GIT_REPO_ORIGIN="$GIT_BP_PUBLIC_REPO"
    elif [ "$REPO" = "sp-dev-c3" ]; then
        GIT_REPO_ORIGIN="$GIT_BP_PRIVATE_REPO"
    elif [ "$REPO" = "sunnypilot" ]; then
        GIT_REPO_ORIGIN="$GIT_SP_REPO"
    elif [ "$REPO" = "commaai" ]; then
        GIT_REPO_ORIGIN="$GIT_COMMA_REPO"
    else
        print_error "Invalid repository selected"
        return
    fi

    print_info "Building branch: $CLONE_BRANCH"
    print_info "Build branch would be: $BUILD_BRANCH"
    local COMMIT_DESC_HEADER="Custom Build"
    build_repo_branch "$CLONE_BRANCH" "$BUILD_BRANCH" "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN"
    print_success "[-] Action completed successfully"
}

repo_build_and_management_menu() {
    while true; do
        clear
        echo "┌──────────────────────────────────────────────"
        echo "│        Repository Build & Management         "
        echo "└──────────────────────────────────────────────"
        display_git_status
        echo "┌──────────────────────────────────────────────"
        echo "│"
        echo "├ Repository Operations:"
        echo "│ 1. Fetch and pull latest changes"
        echo "│ 2. Change current branch"
        echo "│ 3. List available branches"
        echo "│ 4. Reset/clean repository"
        echo "│ 5. Manage submodules"
        echo "│"
        echo "├ Clone Operations:"
        echo "│ 6. Clone a branch by name"
        echo "│ 7. Clone a repository and branch from list"
        echo "│ 8. Clone BluePilot public branch"
        echo "│ 9. Clone BluePilot internal dev branch"
        echo "│"
        echo "├ Build Operations:"
        echo "│ 10. Run SCONS on current branch"
        echo "│ 11. Build BluePilot internal dev"
        echo "│ 12. Build BluePilot public experimental"
        echo "│ 13. Custom build from any branch"
        echo "│"
        echo "├ Reset Operations:"
        echo "│ 14. Remove and Re-clone repository"
        echo "│"
        echo "│ Q. Back to Main Menu"
        echo "└──────────────────────────────────────────────"
        read -p "Enter your choice: " choice
        case $choice in
        1) fetch_pull_latest_changes ;;
        2) change_branch ;;
        3) list_git_branches ;;
        4) reset_git_changes ;;
        5) manage_submodules ;;
        6) clone_openpilot_repo "true" ;;
        7) clone_custom_repo ;;
        8) clone_public_bluepilot ;;
        9) clone_internal_dev ;;
        10)
            clear
            cd "/data/openpilot" || return
            scons -j"$(nproc)"
            pause_for_user
            ;;
        11)
            clear
            build_repo_branch "bp-internal-dev" "bp-internal-dev-build" "bluepilot internal dev" "$GIT_BP_PRIVATE_REPO"
            pause_for_user
            ;;
        12)
            clear
            build_repo_branch "bp-public-experimental" "staging-DONOTUSE" "bluepilot experimental" "$GIT_BP_PRIVATE_REPO" "$GIT_BP_PUBLIC_REPO"
            pause_for_user
            ;;
        13)
            clear
            custom_build_process
            pause_for_user
            ;;
        14)
            clear
            reset_openpilot_repo
            pause_for_user
            ;;
        [qQ]) break ;;
        *) print_error "Invalid choice." ;;
        esac
    done
}

reset_variables() {
    SCRIPT_ACTION=""
    REPO=""
    CLONE_BRANCH=""
    BUILD_BRANCH=""
}
