#!/bin/bash
###############################################################################
# utils.sh - Device Utility Functions for CommaUtility
#
# Version: UTILS_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script contains utility functions for the device.
###############################################################################
readonly UTILS_SCRIPT_VERSION="3.0.1"
readonly UTILS_SCRIPT_MODIFIED="2025-02-09"

###############################################################################
# Encryption/Decryption Functions
###############################################################################
encrypt_credentials() {
    local data="$1" output="$2"
    openssl enc -aes-256-cbc -salt -pbkdf2 -in <(echo "$data") -out "$output" -pass file:/data/params/d/GithubSshKeys
}
decrypt_credentials() {
    local input="$1"
    openssl enc -d -aes-256-cbc -pbkdf2 -in "$input" -pass file:/data/params/d/GithubSshKeys
}

###############################################################################
# Time Functions
###############################################################################

format_time_ago() {
    local timestamp="$1"
    local now=$(date +%s)
    local then=$(date -d "$timestamp" +%s)
    local diff=$((now - then))

    if [ $diff -lt 60 ]; then
        echo "just now"
    elif [ $diff -lt 3600 ]; then
        local minutes=$((diff / 60))
        echo "$minutes minute$([ $minutes -ne 1 ] && echo 's') ago"
    elif [ $diff -lt 86400 ]; then
        local hours=$((diff / 3600))
        echo "$hours hour$([ $hours -ne 1 ] && echo 's') ago"
    elif [ $diff -lt 2592000 ]; then
        local days=$((diff / 86400))
        echo "$days day$([ $days -ne 1 ] && echo 's') ago"
    else
        local months=$((diff / 2592000))
        echo "$months month$([ $months -ne 1 ] && echo 's') ago"
    fi
}
