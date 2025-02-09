###############################################################################
# backups.sh - Device Backup and Restore Operations for CommaUtility
#
# Version: BACKUPS_SCRIPT_VERSION="3.0.2"
# Last Modified: 2025-02-08
#
# This script manages device backup operations (SSH, persist, params,
# commautil) including creation, selective backup, restoration (local or
# network), legacy migration and removal.
###############################################################################

###############################################################################
# Global Variables
###############################################################################
readonly BACKUPS_SCRIPT_VERSION="3.0.0"
readonly BACKUPS_SCRIPT_MODIFIED="2025-02-08"

readonly BACKUP_BASE_DIR="/data/device_backup"
readonly BACKUP_METADATA_FILE="metadata.json"
readonly BACKUP_CHECKSUM_FILE="checksum.sha256"

###############################################################################
# Backup Operations
###############################################################################

save_backup_metadata() {
    local backup_time
    backup_time=$(date '+%Y-%m-%d %H:%M:%S')
    cat >/data/ssh_backup/metadata.txt <<EOF
Backup Date: $backup_time
Last SSH Test: $backup_time
EOF
}

get_backup_metadata() {
    if [ -f "/data/ssh_backup/metadata.txt" ]; then
        cat /data/ssh_backup/metadata.txt
    else
        print_warning "No backup metadata found"
    fi
}
