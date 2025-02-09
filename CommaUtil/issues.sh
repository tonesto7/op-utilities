#!/bin/bash
###############################################################################
# issues.sh - Device Issue Detection and Resolution for CommaUtility
#
# Version: ISSUES_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script detects and resolves issues on the device.
###############################################################################
readonly ISSUES_SCRIPT_VERSION="3.0.0"
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

    # SSH Status Checks
    local home_ssh_exists=false
    local usr_ssh_exists=false
    local backup_exists=false

    [ -f "/home/comma/.ssh/github" ] && home_ssh_exists=true
    [ -f "/usr/default/home/comma/.ssh/github" ] && usr_ssh_exists=true
    check_ssh_backup && backup_exists=true

    # Scenario 1: Missing from both locations
    if [ "$home_ssh_exists" = false ] && [ "$usr_ssh_exists" = false ]; then
        issues_found=$((issues_found + 1))
        if [ "$backup_exists" = true ]; then
            ISSUE_FIXES[$issues_found]="restore_ssh"
            ISSUE_DESCRIPTIONS[$issues_found]="SSH keys missing from all locations - Backup available for restore"
            ISSUE_PRIORITIES[$issues_found]=1
        else
            ISSUE_FIXES[$issues_found]="repair_create_ssh"
            ISSUE_DESCRIPTIONS[$issues_found]="SSH keys missing from all locations - New setup required"
            ISSUE_PRIORITIES[$issues_found]=1
        fi
    fi

    # Scenario 2: Missing from home but exists in persistent storage
    if [ "$home_ssh_exists" = false ] && [ "$usr_ssh_exists" = true ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="repair_create_ssh"
        ISSUE_DESCRIPTIONS[$issues_found]="SSH keys missing from /home/comma/.ssh/ but available in persistent storage"
        ISSUE_PRIORITIES[$issues_found]=1
    fi

    # Scenario 3: Missing from persistent but exists in home
    if [ "$home_ssh_exists" = true ] && [ "$usr_ssh_exists" = false ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="copy_ssh_config_and_keys"
        ISSUE_DESCRIPTIONS[$issues_found]="SSH keys not synchronized to persistent storage"
        ISSUE_PRIORITIES[$issues_found]=2
    fi

    # Permission checks (only if files exist)
    if [ "$home_ssh_exists" = true ]; then
        check_file_permissions_owner "/home/comma/.ssh/github" "-rw-------" "comma"
        local home_perm_check=$?
        if [ "$home_perm_check" -eq 1 ]; then
            issues_found=$((issues_found + 1))
            ISSUE_FIXES[$issues_found]="repair_create_ssh"
            ISSUE_DESCRIPTIONS[$issues_found]="SSH key permissions/ownership incorrect in home directory"
            ISSUE_PRIORITIES[$issues_found]=2
        fi
    fi

    if [ "$usr_ssh_exists" = true ]; then
        check_file_permissions_owner "/usr/default/home/comma/.ssh/github" "-rw-------" "comma"
        local usr_perm_check=$?
        if [ "$usr_perm_check" -eq 1 ]; then
            issues_found=$((issues_found + 1))
            ISSUE_FIXES[$issues_found]="repair_create_ssh"
            ISSUE_DESCRIPTIONS[$issues_found]="SSH key permissions/ownership incorrect in persistent storage"
            ISSUE_PRIORITIES[$issues_found]=2
        fi
    fi

    # Backup recommendations
    if [ "$home_ssh_exists" = true ] && [ "$backup_exists" = false ]; then
        issues_found=$((issues_found + 1))
        ISSUE_FIXES[$issues_found]="backup_ssh"
        ISSUE_DESCRIPTIONS[$issues_found]="No SSH backup found - Backup recommended"
        ISSUE_PRIORITIES[$issues_found]=3
    fi

    # Check for GitHub's host key in known_hosts
    # if [ -f "/home/comma/.ssh/known_hosts" ]; then
    #     if ! grep -q "ssh.github.com" "/home/comma/.ssh/known_hosts"; then
    #         issues_found=$((issues_found + 1))
    #         ISSUE_FIXES[$issues_found]="check_github_known_hosts"
    #         ISSUE_DESCRIPTIONS[$issues_found]="GitHub's host key not found in known_hosts"
    #         ISSUE_PRIORITIES[$issues_found]=2
    #     fi
    # else
    #     issues_found=$((issues_found + 1))
    #     ISSUE_FIXES[$issues_found]="check_github_known_hosts"
    #     ISSUE_DESCRIPTIONS[$issues_found]="SSH known_hosts file missing"
    #     ISSUE_PRIORITIES[$issues_found]=2
    # fi

    # Check backup age if it exists
    if [ "$backup_exists" = true ] && [ -f "/data/ssh_backup/metadata.txt" ]; then
        local backup_date
        backup_date=$(grep "Backup Date:" /data/ssh_backup/metadata.txt | cut -d: -f2- | xargs)
        if [ -n "$backup_date" ]; then
            local backup_age
            local backup_days
            backup_age=$(($(date +%s) - $(date -d "$backup_date" +%s)))
            backup_days=$((backup_age / 86400))
            if [ "$backup_days" -gt 30 ]; then
                issues_found=$((issues_found + 1))
                ISSUE_FIXES[$issues_found]="backup_ssh"
                ISSUE_DESCRIPTIONS[$issues_found]="SSH backup is $backup_days days old - Consider updating"
                ISSUE_PRIORITIES[$issues_found]=3
            fi
        fi
    fi
}
