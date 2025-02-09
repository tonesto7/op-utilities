#!/bin/bash
###############################################################################
# utils.sh - Device Utility Functions for CommaUtility
#
# Version: UTILS_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script contains utility functions for the device.
###############################################################################
readonly UTILS_SCRIPT_VERSION="3.0.0"
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
