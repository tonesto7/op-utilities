#!/usr/bin/env bash

# Script Version
SCRIPT_VERSION="1.2.0"
SCRIPT_MODIFIED="2021-09-25"

set -e
set -o pipefail # Ensures that the script catches errors in piped commands

# Function to display help
show_help() {
  cat <<EOL
BluePilot Build Script (V$SCRIPT_VERSION) - Last Modified: $SCRIPT_MODIFIED
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

Examples:
  # Standard build options
  ./build_script.sh --dev
  ./build_script.sh --public

  # Custom build via command line
  ./build_script.sh --custom-build --repo bluepilotdev --clone-branch feature-branch --build-branch build-feature

  # Custom clone via command line
  ./build_script.sh --custom-clone --repo sp-dev-c3 --clone-branch experimental-branch

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
BUILD_TYPE=""
REPO=""
CLONE_BRANCH=""
BUILD_BRANCH=""

while true; do
  case "$1" in
    --dev)
      BUILD_TYPE="dev"; shift ;;
    --public)
      BUILD_TYPE="public"; shift ;;
    --clone-public-bp)
      BUILD_TYPE="clone-public-bp"; shift ;;
    --clone-internal-dev-build)
      BUILD_TYPE="clone-internal-dev-build"; shift ;;
    --clone-internal-dev)
      BUILD_TYPE="clone-internal-dev"; shift ;;
    --custom-build)
      BUILD_TYPE="custom-build"; shift ;;
    --custom-clone)
      BUILD_TYPE="custom-clone"; shift ;;
    --repo)
      REPO="$2"; shift 2 ;;
    --clone-branch)
      CLONE_BRANCH="$2"; shift 2 ;;
    --build-branch)
      BUILD_BRANCH="$2"; shift 2 ;;
    -h|--help)
      show_help; exit 0 ;;
    --)
      shift; break ;;
    *)
      echo "Internal error!"; exit 1 ;;
  esac
done

# Validate parameters based on BUILD_TYPE
if [[ "$BUILD_TYPE" == "custom-build" ]]; then
  if [[ -z "$REPO" || -z "$CLONE_BRANCH" || -z "$BUILD_BRANCH" ]]; then
    echo "Error: --custom-build requires --repo, --clone-branch, and --build-branch parameters."
    show_help
    exit 1
  fi
elif [[ "$BUILD_TYPE" == "custom-clone" ]]; then
  if [[ -z "$REPO" || -z "$CLONE_BRANCH" ]]; then
    echo "Error: --custom-clone requires --repo and --clone-branch parameters."
    show_help
    exit 1
  fi
fi

# Function to show menu and get build type
show_menu() {
  while true; do
    clear
    echo "************************************************************"
    echo "BluePilot Build Menu (V$SCRIPT_VERSION) - Last Modified: $SCRIPT_MODIFIED"
    echo "************************************************************"
    echo ""
    echo "Select menu item:"
    echo "1) Build BP Internal Dev"
    echo "2) Build BP Public Experimental"
    echo "3) Custom Build (Select Repository and Branch)"
    echo "4) Clone BP staging-DONOTUSE Repo on Comma"
    echo "5) Clone bp-internal-dev-build on Comma"
    echo "6) Clone bp-internal-dev on Comma"
    echo "7) Custom Clone (Select Repository and Branch)"
    echo "r) Reboot Device"
    echo "h) Show Help"
    echo "q) Quit"
    read -p "Enter your choice: " choice
    case $choice in
    1)
      BUILD_TYPE="dev"
      clear
      return 0
      ;;
    2)
      BUILD_TYPE="public"
      clear
      return 0
      ;;
    3)
      BUILD_TYPE="custom-build"
      select_repository
      clear
      return 0
      ;;
    4)
      BUILD_TYPE="clone-public-bp"
      clear
      return 0
      ;;
    5)
      BUILD_TYPE="clone-internal-dev-build"
      clear
      return 0
      ;;
    6)
      BUILD_TYPE="clone-internal-dev"
      clear
      return 0
      ;;
    7)
      clear
      BUILD_TYPE="custom-clone"
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
    *)
      echo "Invalid choice. Please try again."
      ;;
    esac
  done
}


# Function to set environment variables
set_env_vars() {
  # Common variables
  OS=$(uname)

  # Determine the build directory based on the OS
  if [ "$OS" = "Darwin" ]; then
    BUILD_DIR="$HOME/Documents/git-test/bp-${BUILD_TYPE}-build"
  else
    BUILD_DIR="/data/openpilot"
   # Get the directory where the script is located
   SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
  fi

  # Define the temporary directory for the build   
  TMP_DIR="${BUILD_DIR}-build-tmp"
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

  # Remove specific file types
  find . -name '*.a' -exec rm -f {} +
  find . -name '*.o' -exec rm -f {} +
  find . -name '*.os' -exec rm -f {} +
  find . -name '*.pyc' -exec rm -f {} +
  find . -name 'moc_*' -exec rm -f {} +
  find . -name '*.cc' -exec rm -f {} +
  find . -name '__pycache__' -exec rm -rf {} +
  find . -name '.DS_Store' -exec rm -f {} +

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

# Function to handle cloning the public BluePilot on Comma
clone_public_bluepilot() {
  echo "[-] Cloning the public BluePilot on Comma..."
  d /data || { echo "[-] Failed to change directory to /data"; exit 1; }
  rm -rf openpilot || { echo "[-] Failed to remove existing openpilot directory"; exit 1; }
  git clone git@github.com:BluePilotDev/bluepilot.git -b staging-DONOTUSE openpilot || {
    echo "[-] Failed to clone BluePilotDev/bluepilot repository."
    exit 1
  }
  cd openpilot || { echo "[-] Failed to change directory to openpilot"; exit 1; }
  reboot_device
}

# Function to handle cloning bp-internal-dev-build on Comma
clone_internal_dev_build() {
  echo "[-] Cloning bp-internal-dev-build on Comma..."
  cd /data || { echo "[-] Failed to change directory to /data"; exit 1; }
  rm -rf openpilot || { echo "[-] Failed to remove existing openpilot directory"; exit 1; }
  git clone --recurse-submodules --depth 1 git@github.com:ford-op/sp-dev-c3.git -b bp-internal-dev-build openpilot || {
    echo "[-] Failed to clone ford-op/sp-dev-c3 repository."
    exit 1
  }
  cd openpilot || { echo "[-] Failed to change directory to openpilot"; exit 1; }
  scons -j"$(nproc)" || { echo "[-] SCons build failed."; exit 1; }
  reboot_device
}

# Function to handle cloning bp-internal-dev on Comma
clone_internal_dev() {
  echo "[-] Cloning bp-internal-dev on Comma..."
  cd /data || { echo "[-] Failed to change directory to /data"; exit 1; }
  rm -rf openpilot || { echo "[-] Failed to remove existing openpilot directory"; exit 1; }
  git clone --recurse-submodules --depth 1 git@github.com:ford-op/sp-dev-c3.git -b bp-internal-dev openpilot || {
    echo "[-] Failed to clone ford-op/sp-dev-c3 repository."
    exit 1
  }
  cd openpilot || { echo "[-] Failed to change directory to openpilot"; exit 1; }
  scons -j"$(nproc)" || { echo "[-] SCons build failed."; exit 1; }
  reboot_device
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

# Function for custom repo clone
clone_custom_repo_branch() {
  if [[ -n "$REPO" && -n "$CLONE_BRANCH" ]]; then
    echo "[-] Performing custom clone with provided parameters:"
    echo "     Repository: $REPO"
    echo "     Clone Branch: $CLONE_BRANCH"
  else
    echo "[-] Custom Clone Option Selected"
    echo "Select Repository to Clone:"
    echo "1) BluePilotDev/bluepilot"
    echo "2) ford-op/sp-dev-c3"
    echo "c) Cancel and return to main menu"
    read -p "Enter your choice: " repo_choice
    case $repo_choice in
    1)
      REPO="bluepilotdev"
      GIT_REPO_ORIGIN="git@github.com:BluePilotDev/bluepilot.git"
      ;;
    2)
      REPO="sp-dev-c3"
      GIT_REPO_ORIGIN="git@github.com:ford-op/sp-dev-c3.git"
      ;;
    C | c)
      echo "Returning to main menu."
      BUILD_TYPE=""
      show_menu
      ;;
    *)
      echo "Invalid choice. Returning to main menu."
      BUILD_TYPE=""
      return
      ;;
    esac

    # Fetch branches
    clear
    echo "[-] Fetching list of branches from $GIT_REPO_ORIGIN..."
    REMOTE_BRANCHES=$(git ls-remote --heads "$GIT_REPO_ORIGIN" 2>&1)

    if [ $? -ne 0 ]; then
      echo "[-] Failed to fetch branches from $GIT_REPO_ORIGIN."
      echo "Error: $REMOTE_BRANCHES"
      BUILD_TYPE=""
      return
    fi

    REMOTE_BRANCHES=$(echo "$REMOTE_BRANCHES" | awk '{print $2}' | sed 's#refs/heads/##')
    readarray -t BRANCH_ARRAY <<<"$REMOTE_BRANCHES"

    if [ ${#BRANCH_ARRAY[@]} -eq 0 ]; then
      echo "[-] No branches found in the repository."
      BUILD_TYPE=""
      return
    fi

    echo "Available branches in $REPO:"
    for i in "${!BRANCH_ARRAY[@]}"; do
      printf "%d) %s\n" $((i + 1)) "${BRANCH_ARRAY[i]}"
    done

    read -p "Select a branch by number: " branch_choice
    if [[ "$branch_choice" =~ ^[0-9]+$ ]] && [ "$branch_choice" -ge 1 ] && [ "$branch_choice" -le "${#BRANCH_ARRAY[@]}" ]; then
      SELECTED_BRANCH="${BRANCH_ARRAY[$((branch_choice - 1))]}"
      CLONE_BRANCH="$SELECTED_BRANCH"
      BUILD_BRANCH="${CLONE_BRANCH}-build"

      clear
      echo "Selected branch: $CLONE_BRANCH"
      echo "Build branch will be: $BUILD_BRANCH"
    else
      echo "Invalid branch selection."
      BUILD_TYPE=""
      return
    fi
  fi

  # Proceed with cloning using REPO and CLONE_BRANCH
  echo "[-] Cloning repository '$REPO' with branch '$CLONE_BRANCH'..."
  cd /data
  echo "[-] Removing existing openpilot directory"
  rm -rf openpilot
  GIT_REPO_ORIGIN="git@github.com:ford-op/$REPO.git"

  if [[ "$CLONE_BRANCH" == *-build ]]; then
    git clone "git@github.com:ford-op/$REPO.git" -b "$CLONE_BRANCH" "$BUILD_DIR" || {
      echo "[-] Failed to clone repository."
      exit 1
    }
  else
    git clone --recurse-submodules "git@github.com:ford-op/$REPO.git" -b "$CLONE_BRANCH" "$BUILD_DIR" || {
      echo "[-] Failed to clone repository."
      exit 1
    }
  fi

  cd /data/openpilot
  scons -j"$(nproc)" || {
    echo "[-] Build failed."
    exit 1
  }
  reboot_device
}

# Function to select repository and branch for custom build
select_repository() {
  clear
  while true; do
    echo ""
    echo "Select Repository for Custom Build:"
    echo "1) BluePilotDev/bluepilot"
    echo "2) ford-op/sp-dev-c3"
    echo "c) Cancel and return to main menu"
    read -p "Enter your choice: " repo_choice
    case $repo_choice in
    1)
      REPO="bluepilotdev"
      GIT_REPO_ORIGIN="git@github.com:BluePilotDev/bluepilot.git"
      break
      ;;
    2)
      REPO="sp-dev-c3"
      GIT_REPO_ORIGIN="git@github.com:ford-op/sp-dev-c3.git"
      break
      ;;
    C | c)
      echo "Returning to main menu."
      BUILD_TYPE=""
      show_menu
      ;;
    *)
      echo "Invalid choice. Please try again."
      ;;
    esac
  done

  # Fetch the list of remote branches
  clear
  echo "[-] Fetching list of branches from $GIT_REPO_ORIGIN..."
  REMOTE_BRANCHES=$(git ls-remote --heads "$GIT_REPO_ORIGIN" 2>&1)

  # Check if git ls-remote command succeeded
  if [ $? -ne 0 ]; then
    echo "[-] Failed to fetch branches from $GIT_REPO_ORIGIN."
    echo "Error: $REMOTE_BRANCHES"
    BUILD_TYPE=""
    return
  fi

  # Process the branches
  REMOTE_BRANCHES=$(echo "$REMOTE_BRANCHES" | awk '{print $2}' | sed 's#refs/heads/##')

  # Convert branches to an array using readarray
  readarray -t BRANCH_ARRAY <<<"$REMOTE_BRANCHES"

  if [ ${#BRANCH_ARRAY[@]} -eq 0 ]; then
    echo "[-] No branches found in the repository."
    BUILD_TYPE=""
    return
  fi

  # Display branches to the user
  clear
  echo ""
  echo "Available branches in $REPO:"
  for i in "${!BRANCH_ARRAY[@]}"; do
    printf "%d) %s\n" $((i + 1)) "${BRANCH_ARRAY[i]}"
  done

  # Prompt user to select a branch
  while true; do
    read -p "Select a branch by number (or 'c' to cancel): " branch_choice
    if [[ "$branch_choice" == "c" || "$branch_choice" == "C" ]]; then
      echo "Returning to main menu."
      BUILD_TYPE=""
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

  local GIT_REPO_ORIGIN="git@github.com:ford-op/$REPO.git"
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
  git checkout --orphan temp_branch

  # Add all files
  git add -A >/dev/null 2>&1

  # Commit with the desired message
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
    echo "[-] Deleting Local branch: $BUILD_BRANCH T=$SECONDS"
    git branch -D "$BUILD_BRANCH" || {
      echo "[-] Failed to delete local branch $BUILD_BRANCH"
      exit 1
    }
  else
    echo "[-] Local branch $BUILD_BRANCH does not exist. Skipping deletion."
  fi

  # Check if the remote build branch exists before attempting to delete
  if git ls-remote --heads "$ORIGIN_REPO" "$BUILD_BRANCH" | grep "$BUILD_BRANCH" >/dev/null 2>&1; then
    echo "[-] Deleting Remote branch: $BUILD_BRANCH T=$SECONDS"
    git push "$ORIGIN_REPO" --delete "$BUILD_BRANCH" || {
      echo "[-] Failed to delete remote branch $BUILD_BRANCH"
      exit 1
    }
  else
    echo "[-] Remote branch $BUILD_BRANCH does not exist. Skipping deletion."
  fi

  # Rename the temp branch to the desired build branch
  echo "[-] Renaming temp_branch to $BUILD_BRANCH T=$SECONDS"
  git branch -m "$BUILD_BRANCH"

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
    if [ -z "$BUILD_TYPE" ]; then
      show_menu
      continue
    fi

    case "$BUILD_TYPE" in
    public)
      build_cross_repo_branch "bp-public-experimental" "staging-DONOTUSE" "bluepilot experimental" "git@github.com:ford-op/sp-dev-c3.git" "git@github.com:BluePilotDev/bluepilot.git"
      ;;
    dev)
      build_repo_branch "bp-internal-dev" "bp-internal-dev-build" "bluepilot internal dev" "git@github.com:ford-op/sp-dev-c3.git"
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
      clone_custom_repo_branch
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

    BUILD_TYPE=""
    REPO=""
    CLONE_BRANCH=""
    BUILD_BRANCH=""

    # Add this line to break the loop after a successful build
    break
  done
}

# Show menu if BUILD_TYPE is not set via command line
if [ -z "$BUILD_TYPE" ]; then
  show_menu
fi

# Set environment variables
set_env_vars

# Run the main function
main
