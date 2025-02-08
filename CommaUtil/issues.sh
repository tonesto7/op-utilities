#!/bin/bash

###############################################################################
# Global Variables
###############################################################################
readonly ISSUES_SCRIPT_VERSION="3.0.1"
readonly ISSUES_SCRIPT_MODIFIED="2025-02-08"

# Array-based detection data
declare -A ISSUE_FIXES
declare -A ISSUE_DESCRIPTIONS
declare -A ISSUE_PRIORITIES # 1=Critical, 2=Warning, 3=Recommendation

###############################################################################
# Issue Detection Functions
###############################################################################

detect_issues() {
    ISSUE_FIXES=()
    ISSUE_DESCRIPTIONS=()
    ISSUE_PRIORITIES=() # 1=Critical, 2=Warning, 3=Recommendation
    local issues_found=0

    # Check if device backup exists
    local device_id=$(get_device_id)
    local has_backup=false
    local backup_age_days=0

    # Find most recent backup
    local latest_backup
    latest_backup=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -c "%Y %n" {} \; | sort -nr | head -n1 | cut -d' ' -f2)

    if [ -n "$latest_backup" ] && [ -f "${latest_backup}/${BACKUP_METADATA_FILE}" ]; then
        has_backup=true
        # Try to get timestamp from metadata, fall back to directory stat if fails
        local backup_timestamp
        if backup_timestamp=$(jq -r '.timestamp // empty' "${latest_backup}/${BACKUP_METADATA_FILE}" 2>/dev/null) &&
            [ -n "$backup_timestamp" ] && [ "$backup_timestamp" != "null" ]; then
            backup_age_days=$((($(date +%s) - $(date -d "$backup_timestamp" +%s)) / 86400))
        else
            backup_timestamp=$(stat -c %Y "$latest_backup")
            backup_age_days=$((($(date +%s) - backup_timestamp) / 86400))
        fi
    fi

    # Check SSH files status
    if [ ! -f "/home/comma/.ssh/github" ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="repair_create_ssh"
        ISSUE_DESCRIPTIONS[$issues_found]="SSH keys missing - setup required"
        ISSUE_PRIORITIES[$issues_found]=1
    fi

    # Check persistent storage
    if [ -f "/home/comma/.ssh/github" ] && [ ! -f "/usr/default/home/comma/.ssh/github" ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="copy_ssh_config_and_keys"
        ISSUE_DESCRIPTIONS[$issues_found]="SSH keys not synchronized to persistent storage"
        ISSUE_PRIORITIES[$issues_found]=2
    fi

    # Check device backup status
    if [ "$has_backup" = false ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="backup_device"
        ISSUE_DESCRIPTIONS[$issues_found]="No device backup found"
        ISSUE_PRIORITIES[$issues_found]=2
    elif [ "$backup_age_days" -gt 30 ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="backup_device"
        ISSUE_DESCRIPTIONS[$issues_found]="Device backup is $backup_age_days days old"
        ISSUE_PRIORITIES[$issues_found]=3
    fi

    # Check for old backup format
    if [ -d "/data/ssh_backup" ] && [ -f "/data/ssh_backup/metadata.txt" ]; then
        if [ "$has_backup" = false ]; then
            issues_found=$((issues_found + 1))
            ISSUE_FIXES[$issues_found]="migrate_legacy_backup"
            ISSUE_DESCRIPTIONS[$issues_found]="Legacy backup detected - migration"
            ISSUE_PRIORITIES[$issues_found]=2
        else
            issues_found=$((issues_found + 1))
            ISSUE_FIXES[$issues_found]="remove_legacy_backup"
            ISSUE_DESCRIPTIONS[$issues_found]="Legacy backup detected - removal"
            ISSUE_PRIORITIES[$issues_found]=3
        fi
    fi
}
