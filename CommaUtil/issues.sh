#!/bin/bash
###############################################################################
# issues.sh - Device Issue Detection and Resolution for CommaUtility
#
# Version: ISSUES_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script detects and resolves issues on the device.
###############################################################################
readonly ISSUES_SCRIPT_VERSION="3.0.1"
readonly ISSUES_SCRIPT_MODIFIED="2025-02-09"

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

    ###############################################################################
    # SSH Status Checks
    ###############################################################################
    local home_ssh_exists=false
    local usr_ssh_exists=false
    local backup_exists=false
    local permissions_valid=true

    # Check home directory SSH files
    if [ -f "$SSH_HOME_DIR/github" ] && [ -f "$SSH_HOME_DIR/github.pub" ] && [ -f "$SSH_HOME_DIR/config" ]; then
        home_ssh_exists=true
        # Check permissions
        check_file_permissions_owner "$SSH_HOME_DIR/github" "-rw-------" "comma"
        if [ $? -eq 1 ]; then
            permissions_valid=false
        fi
    fi

    # Check persistent storage
    if [ -f "$SSH_USR_DEFAULT_DIR/github" ]; then
        usr_ssh_exists=true
        check_file_permissions_owner "$SSH_USR_DEFAULT_DIR/github" "-rw-------" "comma"
        if [ $? -eq 1 ]; then
            permissions_valid=false
        fi
    fi

    # Check backup
    check_ssh_backup && backup_exists=true

    # Add issues based on checks
    if [ "$home_ssh_exists" = false ] && [ "$usr_ssh_exists" = false ]; then
        issues_found=$((issues_found + 1))
        if [ "$backup_exists" = true ]; then
            ISSUE_FIXES[$issues_found]="restore_ssh"
            ISSUE_DESCRIPTIONS[$issues_found]="SSH keys missing - Backup available for restore"
            ISSUE_PRIORITIES[$issues_found]=1
        else
            ISSUE_FIXES[$issues_found]="repair_create_ssh"
            ISSUE_DESCRIPTIONS[$issues_found]="SSH keys missing - New setup required"
            ISSUE_PRIORITIES[$issues_found]=1
        fi
    elif [ "$home_ssh_exists" = false ] && [ "$usr_ssh_exists" = true ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="copy_ssh_config_and_keys"
        ISSUE_DESCRIPTIONS[$issues_found]="SSH keys missing from home directory but available in persistent storage"
        ISSUE_PRIORITIES[$issues_found]=1
    elif [ "$home_ssh_exists" = true ] && [ "$usr_ssh_exists" = false ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="copy_ssh_config_and_keys"
        ISSUE_DESCRIPTIONS[$issues_found]="SSH keys not synchronized to persistent storage"
        ISSUE_PRIORITIES[$issues_found]=2
    fi

    if [ "$permissions_valid" = false ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="fix_ssh_permissions"
        ISSUE_DESCRIPTIONS[$issues_found]="SSH file permissions need to be fixed"
        ISSUE_PRIORITIES[$issues_found]=2
    fi

    if [ "$home_ssh_exists" = true ] && [ "$backup_exists" = false ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="backup_ssh"
        ISSUE_DESCRIPTIONS[$issues_found]="No SSH backup found - Backup recommended"
        ISSUE_PRIORITIES[$issues_found]=3
    fi

    # Add backup age check
    if [ "$backup_exists" = true ]; then
        local backup_date
        local backup_age
        local backup_days
        backup_date=$(grep "Backup Date:" "$SSH_BACKUP_DIR/metadata.txt" | cut -d: -f2- | xargs)
        if [ -n "$backup_date" ]; then
            backup_age=$(($(date +%s) - $(date -d "$backup_date" +%s)))
            backup_days=$((backup_age / 86400))
            if [ "$backup_days" -gt 30 ]; then
                issues_found=$((issues_found + 1))
                ISSUE_FIXES[$issues_found]="backup_ssh"
                ISSUE_DESCRIPTIONS[$issues_found]="SSH backup is $backup_days days old - Update recommended"
                ISSUE_PRIORITIES[$issues_found]=3
            fi
        fi
    fi

    ###############################################################################
    # Disk Space Checks
    ###############################################################################
    local root_usage
    root_usage=$(check_disk_usage_and_resize)
    if [ "$root_usage" -ge 95 ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="check_root_space"
        ISSUE_DESCRIPTIONS[$issues_found]="Root filesystem critically full ($root_usage%)"
        ISSUE_PRIORITIES[$issues_found]=1
    elif [ "$root_usage" -ge 85 ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="check_root_space"
        ISSUE_DESCRIPTIONS[$issues_found]="Root filesystem running low on space ($root_usage%)"
        ISSUE_PRIORITIES[$issues_found]=2
    fi

    ###############################################################################
    # Git Repository Checks
    ###############################################################################
    if [ -d "/data/openpilot" ]; then
        # Check for uncommitted changes
        if [ -n "$(cd /data/openpilot && git status --porcelain 2>/dev/null)" ]; then
            issues_found=$((issues_found + 1))
            ISSUE_FIXES[$issues_found]="reset_git_changes"
            ISSUE_DESCRIPTIONS[$issues_found]="Git repository has uncommitted changes"
            ISSUE_PRIORITIES[$issues_found]=2
        fi

        # Check for initialized submodules
        if [ -f "/data/openpilot/.gitmodules" ]; then
            if (cd /data/openpilot && git submodule status | grep -q '^-'); then
                issues_found=$((issues_found + 1))
                ISSUE_FIXES[$issues_found]="manage_submodules"
                ISSUE_DESCRIPTIONS[$issues_found]="Git submodules not initialized"
                ISSUE_PRIORITIES[$issues_found]=2
            fi
        fi
    fi
}
