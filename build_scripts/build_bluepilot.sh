#!/usr/bin/env bash

set -e
set -o pipefail # Ensures that the script catches errors in piped commands

# Parse command line arguments
BUILD_TYPE=""
CLONE_ACTION=""

while [[ $# -gt 0 ]]; do
  case $1 in
  --dev)
    BUILD_TYPE="dev"
    shift
    ;;
  --public)
    BUILD_TYPE="public"
    shift
    ;;
  --clone-public-bp)
    BUILD_TYPE="clone-public-bp"
    shift
    ;;
  --clone-internal-dev-build)
    BUILD_TYPE="clone-internal-dev-build"
    shift
    ;;
  --clone-internal-dev)
    BUILD_TYPE="clone-internal-dev"
    shift
    ;;
  *)
    echo "Unknown option: $1"
    exit 1
    ;;
  esac
done

# Function to show menu and get build type
show_menu() {
  while true; do
    echo "********************"
    echo "BluePilot Build Menu"
    echo "********************"
    echo ""
    echo "Select menu item:"
    echo "1) Build BP Internal Dev"
    echo "2) Build BP Public Experimental"
    echo "3) Clone BP staging-DONOTUSE Repo on Comma"
    echo "4) Clone bp-internal-dev-build on Comma"
    echo "5) Clone bp-internal-dev on Comma"
    echo "r) Reboot Device"
    echo "q) Quit"
    read -p "Enter your choice: " choice
    case $choice in
    1)
      BUILD_TYPE="dev"
      return 0
      ;;
    2)
      BUILD_TYPE="public"
      return 0
      ;;
    3)
      BUILD_TYPE="clone-public-bp"
      return 0
      ;;
    4)
      BUILD_TYPE="clone-internal-dev-build"
      return 0
      ;;
    5)
      BUILD_TYPE="clone-internal-dev"
      return 0
      ;;
    R | r)
      sudo reboot
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

# Show menu if BUILD_TYPE is not set
if [ -z "$BUILD_TYPE" ]; then
  show_menu
fi

# Common variables
OS=$(uname)

# Determine the build directory based on the OS
if [ "$OS" = "Darwin" ]; then
  BUILD_DIR="~/Documents/git-test/bp-${BUILD_TYPE}-build"
else
  BUILD_DIR="/data/openpilot"
  # Get the directory where the script is located
  SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
fi

TMP_DIR="${BUILD_DIR}-build-tmp"

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
  cp -f "$BUILD_DIR/panda/mypy.ini" "$BUILD_DIR/panda_tmp/mypy.ini" || echo "File not found: mypi.ini"
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
  cd /data
  rm -rf openpilot
  git clone git@github.com:BluePilotDev/bluepilot.git -b staging-DONOTUSE openpilot
  cd openpilot
  sudo reboot
}

# Function to handle cloning bp-internal-dev-build on Comma
clone_internal_dev_build() {
  echo "[-] Cloning bp-internal-dev-build on Comma..."
  cd /data
  rm -rf openpilot
  git clone --recurse-submodules --depth 1 git@github.com:ford-op/sp-dev-c3.git -b bp-internal-dev-build openpilot
  cd openpilot
  scons -j"$(nproc)"
  sudo reboot
}

# Function to handle cloning bp-internal-dev on Comma
clone_internal_dev() {
  echo "[-] Cloning bp-internal-dev on Comma..."
  cd /data
  rm -rf openpilot
  git clone --recurse-submodules --depth 1 git@github.com:ford-op/sp-dev-c3.git -b bp-internal-dev openpilot
  cd openpilot
  scons -j"$(nproc)"
  sudo reboot
}

# Function to process submodules (existing function retained)

# Function for public experimental build process
public_build_process() {
  local CLONE_BRANCH="bp-public-experimental"
  local BUILD_BRANCH="staging-DONOTUSE"
  local COMMIT_DESC_HEADER="bluepilot experimental"
  local GIT_REPO_ORIGIN="git@github.com:ford-op/sp-dev-c3.git"
  local GIT_PUBLIC_REPO_ORIGIN="git@github.com:BluePilotDev/bluepilot.git"

  echo "[-] Starting public experimental build process"

  # Clear build directory
  echo "[-] Removing existing BUILD_DIR"
  rm -rf "$BUILD_DIR"
  rm -rf "$TMP_DIR"

  echo "[-] Cloning $BUILD_BRANCH branch into $BUILD_DIR"
  git clone --single-branch --branch "$BUILD_BRANCH" "$GIT_PUBLIC_REPO_ORIGIN" "$BUILD_DIR"

  cd "$BUILD_DIR"

  echo "[-] Removing all files from cloned repo except .git"
  find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +

  # Clone main repo
  echo "[-] Cloning $GIT_REPO_ORIGIN Repo to $TMP_DIR"
  git clone --recurse-submodules --depth 1 "$GIT_REPO_ORIGIN" -b "$CLONE_BRANCH" "$TMP_DIR"

  # Change to the TMP_DIR
  cd "$TMP_DIR"

  process_submodules "$TMP_DIR"

  cd "$BUILD_DIR"

  echo "[-] Copying files from TMP_DIR to BUILD_DIR"
  rsync -a --exclude='.git' "$TMP_DIR/" "$BUILD_DIR/"

  # Remove the TMP_DIR
  rm -rf "$TMP_DIR"

  setup_git_env
  build_openpilot
  handle_panda_directory
  create_opendbc_gitignore
  update_main_gitignore
  cleanup_files

  create_prebuilt_marker

  # Prepare and push commit
  prepare_commit_push "$COMMIT_DESC_HEADER" "$GIT_PUBLIC_REPO_ORIGIN" "$BUILD_BRANCH"
}

# Function for internal dev build process
internal_dev_build_process() {
  local CLONE_BRANCH="bp-internal-dev"
  local BUILD_BRANCH="bp-internal-dev-build"
  local COMMIT_DESC_HEADER="bluepilot internal dev"
  local GIT_REPO_ORIGIN="git@github.com:ford-op/sp-dev-c3.git"

  echo "[-] Starting internal dev build process"

  echo "[-] Cleaning Build Directories"
  rm -rf "$BUILD_DIR"
  rm -rf "$TMP_DIR"

  # Clone repo
  git clone --recurse-submodules "$GIT_REPO_ORIGIN" -b "$CLONE_BRANCH" "$BUILD_DIR"
  cd "$BUILD_DIR"

  # Define git identity and ssh variables
  setup_git_env

  # Build and process
  build_openpilot
  handle_panda_directory
  process_submodules "$BUILD_DIR"
  create_opendbc_gitignore
  update_main_gitignore
  cleanup_files

  create_prebuilt_marker

  # Prepare and push commit
  prepare_commit_push "$COMMIT_DESC_HEADER" "$GIT_REPO_ORIGIN" "$BUILD_BRANCH"
}

# Function to prepare the commit
prepare_commit_push() {
  local COMMIT_DESC_HEADER=$1
  local ORIGIN_REPO=$2
  local BUILD_BRANCH=$3
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
  echo "[-] Force pushing to $BUILD_BRANCH branch of remote repo $ORIGIN_REPO T=$SECONDS"
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
    fi

    case "$BUILD_TYPE" in
    public)
      public_build_process
      ;;
    dev)
      internal_dev_build_process
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
    *)
      echo "Invalid build type. Exiting."
      exit 1
      ;;
    esac

    echo "[-] Action completed successfully T=$SECONDS"

    # Reset BUILD_TYPE to show menu again
    BUILD_TYPE=""
  done
}

# Run the main function
main
