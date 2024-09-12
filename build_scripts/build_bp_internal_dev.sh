#!/usr/bin/env bash

set -e

# Parse command line arguments
PUSH=0
USE_CURRENT_DIR=1

while [[ $# -gt 0 ]]; do
  case $1 in
  --push)
    PUSH=1
    shift
    ;;
  *)
    echo "Unknown option: $1"
    exit 1
    ;;
  esac
done

echo "Using current directory: $USE_CURRENT_DIR"
echo "Pushing to remote repository: $PUSH"

# Detect the operating system
OS=$(uname)

# Determine the source and build directories based on the OS
if [ "$OS" == "Darwin" ]; then
  SOURCE_DIR=~/Documents/GitHub/ford-op-sp-dev
  BUILD_DIR=~/Documents/git-test/bp-internal-dev-build
  TMP_DIR=~/Documents/git-test/bp-internal-dev-build-tmp
else
  if [ "$USE_CURRENT_DIR" == "1" ]; then
    BUILD_DIR="/data/openpilot"
  else
    SOURCE_DIR="$(git rev-parse --show-toplevel)"
    BUILD_DIR=/data/openpilot-dev-build
  fi
  TMP_DIR=/data/openpilot-dev-build-tmp
fi

FILES_SRC="release/files_tici"
DEV_BRANCH="bp-internal-dev-build"
GIT_REPO_ORIGIN="git@github.com:ford-op/sp-dev-c3.git"

if [ "$USE_CURRENT_DIR" == "1" ]; then
  echo "[-] Using current directory as build directory"
else
  echo "[-] Setting up target repo T=$SECONDS"
  rm -rf $BUILD_DIR
  echo "[-] Creating build directory $BUILD_DIR"
  mkdir -p $BUILD_DIR
  echo "[-] Copying source files from $SOURCE_DIR to $BUILD_DIR"
  cp -a $SOURCE_DIR/. $BUILD_DIR/
fi
cd $BUILD_DIR

# Set git identity (if necessary)
if [ -f "$BUILD_DIR/release/identity_ford_op.sh" ]; then
  source $BUILD_DIR/release/identity_ford_op.sh
else
  echo "[-] identity_ford_op.sh not found"
  exit 1
fi

# Check if the /data/gitkey file exists and if not, check for ~/.ssh/github and use that for the GIT_SSH_COMMAND
if [ -f /data/gitkey ]; then
  export GIT_SSH_COMMAND="ssh -i /data/gitkey"
elif [ -f ~/.ssh/github ]; then
  export GIT_SSH_COMMAND="ssh -i ~/.ssh/github"
else
  echo "[-] No git key found"
  exit 1
fi

cd $BUILD_DIR

# scons -c
# Build Openpilot
export PYTHONPATH="$BUILD_DIR"
echo "[-] Building Openpilot"
scons -j$(nproc)

# Change back to the root directory
cd $BUILD_DIR

echo "Creating panda_tmp directory"
mkdir -p $BUILD_DIR/panda_tmp/board/obj
mkdir -p $BUILD_DIR/panda_tmp/python

# Copy the required files
cp -f $BUILD_DIR/panda/board/obj/panda.bin.signed $BUILD_DIR/panda_tmp/board/obj/panda.bin.signed || echo "File not found: panda.bin.signed"
cp -f $BUILD_DIR/panda/board/obj/panda_h7.bin.signed $BUILD_DIR/panda_tmp/board/obj/panda_h7.bin.signed || echo "File not found: panda_h7.bin.signed"
cp -f $BUILD_DIR/panda/board/obj/bootstub.panda.bin $BUILD_DIR/panda_tmp/board/obj/bootstub.panda.bin || echo "File not found: bootstub.panda.bin"
cp -f $BUILD_DIR/panda/board/obj/bootstub.panda_h7.bin $BUILD_DIR/panda_tmp/board/obj/bootstub.panda_h7.bin || echo "File not found: bootstub.panda_h7.bin"

# Patch the __init__.py file
if [ "$OS" == "Darwin" ]; then
  sed -i '' 's/^from .board.jungle import PandaJungle, PandaJungleDFU # noqa: F401/# &/' panda/__init__.py
else
  sed -i 's/^from .board.jungle import PandaJungle, PandaJungleDFU # noqa: F401/# &/' panda/__init__.py
fi

# Move the panda/python directory to panda_tmp/python
cp -r $BUILD_DIR/panda/python/. $BUILD_DIR/panda_tmp/python || echo "Directory not found: panda/python"
cp -f $BUILD_DIR/panda/.gitignore $BUILD_DIR/panda_tmp/.gitignore || echo "File not found: .gitignore"
cp -f $BUILD_DIR/panda/__init__.py $BUILD_DIR/panda_tmp/__init__.py || echo "File not found: __init__.py"
cp -f $BUILD_DIR/panda/mypy.ini $BUILD_DIR/panda_tmp/mypy.ini || echo "File not found: mypi.ini"
cp -f $BUILD_DIR/panda/panda.png $BUILD_DIR/panda_tmp/panda.png || echo "File not found: panda.png"
cp -f $BUILD_DIR/panda/pyproject.toml $BUILD_DIR/panda_tmp/pyproject.toml || echo "File not found: pyproject.toml"
cp -f $BUILD_DIR/panda/requirements.txt $BUILD_DIR/panda_tmp/requirements.txt || echo "File not found: requirements.txt"
cp -f $BUILD_DIR/panda/setup.cfg $BUILD_DIR/panda_tmp/setup.cfg || echo "File not found: setup.cfg"
cp -f $BUILD_DIR/panda/setup.py $BUILD_DIR/panda_tmp/setup.py || echo "File not found: setup.py"

# remove the panda directory
rm -rf $BUILD_DIR/panda

# Move the panda_tmp directory to panda
mv $BUILD_DIR/panda_tmp $BUILD_DIR/panda

# Ensure that the `cd` command is correct
cd $BUILD_DIR

# Create an array of the submodule directories
SUBMODULES=("msgq_repo" "opendbc" "rednose_repo" "panda" "tinygrad_repo" "teleoprtc_repo")

# Loop through the submodules and process each one
for SUBMODULE in "${SUBMODULES[@]}"; do
  echo "[-] Creating _tmp $SUBMODULE directory"
  mkdir -p $BUILD_DIR/$SUBMODULE"_tmp"

  echo "[-] Copying $SUBMODULE files to $SUBMODULE"_tmp""
  cp -r $BUILD_DIR/$SUBMODULE/. $BUILD_DIR/$SUBMODULE"_tmp" || echo "Directory not found: $SUBMODULE"

  echo "[-] Deinitializing $SUBMODULE"
  git submodule deinit -f $SUBMODULE

  # Remove the submodule references
  echo "[-] Removing $SUBMODULE from the index"
  git rm -rf --cached $SUBMODULE

  # Remove the actual submodule directory
  echo "[-] Removing $SUBMODULE directory"
  rm -rf $BUILD_DIR/$SUBMODULE

  # Move the copied files back into place
  mv $BUILD_DIR/$SUBMODULE"_tmp" $BUILD_DIR/$SUBMODULE

  # Remove the submodule's .git/modules entry
  echo "[-] Cleaning up .git/modules for $SUBMODULE"
  rm -rf .git/modules/$SUBMODULE

  # Add the files back to the git index as regular files
  echo "[-] Adding $SUBMODULE files to the repository"
  git add -f $SUBMODULE
done

# If .git/modules/opendbc_repo exists, remove it
if [ -d .git/modules/opendbc_repo ]; then
  echo "[-] Cleaning up .git/modules for opendbc_repo"
  rm -rf .git/modules/opendbc_repo
fi

# create a .gitignore file for the opendbc_repo with the following contents
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


# Path to your .gitignore file
GITIGNORE_PATH=".gitignore"

# Lines to remove
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

# Iterate over the lines and remove them from the .gitignore file
for LINE in "${LINES_TO_REMOVE[@]}"; do
    # Using sed to remove the line
    if [ "$OS" == "Darwin" ]; then
      sed -i '' "/^${LINE//\//\\/}$/d" "$GITIGNORE_PATH"
    else
      sed -i "/^${LINE//\//\\/}$/d" "$GITIGNORE_PATH"
    fi
done

echo "Specified lines removed from .gitignore"


# # Remove specific files forcefully without prompt
echo "[-] Cleaning up unnecessary files T=$SECONDS"
find . -name '*.a' -exec rm -f {} +
find . -name '*.o' -exec rm -f {} +
find . -name '*.os' -exec rm -f {} +
find . -name '*.pyc' -exec rm -f {} +
find . -name 'moc_*' -exec rm -f {} +
find . -name '*.cc' -exec rm -f {} +
find . -name '__pycache__' -exec rm -rf {} +
find . -name '.DS_Store' -exec rm -f {} +
find . -name '.pre-commit-config.yaml' -exec rm -f {} +
find . -name 'Dockerfile' -exec rm -f {} +
find . -name 'Dockerfile.*' -exec rm -f {} +
find . -name 'codecov.yml' -exec rm -f {} +
find . -name '.github' -exec rm -rf {} +
find . -name '.clang-tidy' -exec rm -f {} +
find . -name '.dockerignore' -exec rm -f {} +
find . -name '.editorconfig' -exec rm -f {} +
find . -name 'Jenkinsfile' -exec rm -f {} +
find . -name 'LICENSE*' -exec rm -rf {} +
find . -name 'SConstruct' -exec rm -f {} +
find . -name 'SConscript' -exec rm -f {} +

# Remove specific folders and files
rm -rf .sconsign.dblite
rm -rf .venv
rm -rf .devcontainer .idea .mypy_cache .run .vscode
rm -f .clang-tidy .env .gitmodules .gitattributes
rm -rf teleoprtc_repo teleoprtc
rm -rf release

# Remove additional specific files and directories forcefully
rm -f selfdrive/modeld/models/supercombo.onnx
rm -rf selfdrive/ui/replay/
rm -rf tools/cabana tools/camerastream tools/car_porting tools/joystick tools/latencylogger tools/plotjuggler tools/profiling
rm -rf tools/replay tools/rerun tools/scripts tools/serial tools/sim tools/tuning tools/webcam
rm -f tools/*.py tools/*.sh tools/*.md
rm -f conftest.py SECURITY.md uv.lock

# Additional cereal cleanup
find cereal/ -name '*tests*' -exec rm -rf {} +
find cereal/ -name '*.md' -exec rm -f {} +

# Additional common cleanup
find common/ -name '*tests*' -exec rm -rf {} +
find common/ -name '*.md' -exec rm -f {} +

# Additional msgq_repo cleanup
find msgq_repo/ -name '*tests*' -exec rm -rf {} +
find msgq_repo/ -name '*.md' -exec rm -f {} +
find msgq_repo/ -name '.git*' -exec rm -rf {} +

# Additional opendbc_repo cleanup
find opendbc_repo/ -name '*tests*' -exec rm -rf {} +
find opendbc_repo/ -name '*.md' -exec rm -f {} +
find opendbc_repo/ -name '.git*' -exec rm -rf {} +
find opendbc_repo/ -name 'LICENSE' -exec rm -f {} +

# Additional rednose_repo cleanup
find rednose_repo/ -name '*tests*' -exec rm -rf {} +
find rednose_repo/ -name '*.md' -exec rm -f {} +
find rednose_repo/ -name '.git*' -exec rm -rf {} +
find rednose_repo/ -name 'LICENSE' -exec rm -f {} +

# Additional selfdrive cleanup
find selfdrive/ui -name '*.h' -exec rm -f {} +
find selfdrive/ -name '*.md' -exec rm -f {} +
# find selfdrive/ -name '*tests*' -exec rm -rf {} +
find selfdrive/ -name '*test*' -exec rm -rf {} +

# Additional system cleanup
find system/ -name '*tests*' -exec rm -rf {} +
find system/ -name '*.md' -exec rm -f {} +

# Additional third_party cleanup
# find third_party/ -name '*x86*' -exec rm -r {} +
find third_party/ -name '*Darwin*' -exec rm -rf {} +
find third_party/ -name 'LICENSE' -exec rm -f {} +
find third_party/ -name 'README.md' -exec rm -f {} +

# Additional tinygrad_repo cleanup
rm -rf tinygrad_repo/cache tinygrad_repo/disassemblers tinygrad_repo/docs tinygrad_repo/examples
rm -rf tinygrad_repo/models tinygrad_repo/test tinygrad_repo/weights tinygrad_repo/extra/accel
rm -rf tinygrad_repo/extra/assembly tinygrad_repo/extra/dataset tinygrad_repo/extra/disk tinygrad_repo/extra/dist
rm -rf tinygrad_repo/extra/fastvits tinygrad_repo/extra/intel tinygrad_repo/extra/optimization tinygrad_repo/extra/ptx
rm -rf tinygrad_repo/extra/rocm tinygrad_repo/extra/triton

# remove all .py files that don't start with onnx, thneed, or utils
find tinygrad_repo/extra -maxdepth 1 -type f -name '*.py' ! -name 'onnx*.py' ! -name 'thneed*.py' ! -name 'utils*.py' -exec rm -f {} +
rm -rf tinygrad_repo/extra/datasets tinygrad_repo/extra/gemm
find tinygrad_repo/ -name '*tests*' -exec rm -rf {} +
find tinygrad_repo/ -name '.git*' -exec rm -rf {} +
find tinygrad_repo/ -name '*.md' -exec rm -f {} +
rm -f tinygrad_repo/.flake8 tinygrad_repo/.pylintrc tinygrad_repo/.tokeignore tinygrad_repo/*.sh tinygrad_repo/*.ini tinygrad_repo/*.toml tinygrad_repo/*.py

git checkout third_party/

# Mark as prebuilt release by creating a prebuilt file in the root directory
touch prebuilt

if git show-ref --verify --quiet refs/heads/$DEV_BRANCH; then
  git checkout $DEV_BRANCH
else
  git checkout -b $DEV_BRANCH
fi

# Copy all files and folders (including hidden ones) except the .git directory to the temp directory
echo "[-] Copying files to temporary directory"
rsync -a --exclude='.git' $BUILD_DIR/ $TMP_DIR/

# Remove all files and folders from BUILD_DIR except .git
echo "[-] Removing all files from build directory except"
# remove all files and folders except .git
rm -rf $BUILD_DIR/*

# Stage the changes
echo "[-] Staging changes for commit"
cd $BUILD_DIR
git add --all

# Create a commit with all files removed
echo "[-] Creating commit for removed files"
git commit -m "Removed all files from build directory temporarily"

# Move files and folders back from the temp directory to the build directory
echo "[-] Moving files back to build directory"
rsync -a $TMP_DIR/ $BUILD_DIR/

# Clean up: Remove the temporary directory
echo "[-] Cleaning up temporary directory"
rm -rf $TMP_DIR

# Include source commit hash and build date in commit
VERSION=$(date '+%Y.%m.%d')
TIME_CODE=$(date +"%H%M")
GIT_HASH=$(git --git-dir=$BUILD_DIR/.git rev-parse HEAD)
DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
SP_VERSION=$(cat $BUILD_DIR/common/version.h | awk -F\" '{print $2}')

echo "#define COMMA_VERSION \"$VERSION-$TIME_CODE\"" >$BUILD_DIR/common/version.h
echo "[-] committing version $VERSION-$TIME_CODE T=$SECONDS"

# # Add built files to git and amend the commit
git add -f .
git commit --amend -m "bluepilot internal dev | v$VERSION-$TIME_CODE
version: bluepilot internal dev v$SP_VERSION release
date: $DATETIME
master commit: $GIT_HASH
"

# Force push the changes to the remote repository
if [ ! -z "$PUSH" ]; then
  echo "[-] pushing T=$SECONDS"
  git push -f origin $DEV_BRANCH
fi

echo "[-] done T=$SECONDS"
