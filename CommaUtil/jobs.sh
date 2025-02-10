#!/bin/bash
###############################################################################
# jobs.sh - Device Job Management for CommaUtility
#
# Version: JOBS_SCRIPT_VERSION="3.0.3"
# Last Modified: 2025-02-09
#
# This script manages device jobs for CommaUtility.
###############################################################################
readonly JOBS_SCRIPT_VERSION="3.0.0"
readonly JOBS_SCRIPT_MODIFIED="2025-02-10"

###############################################################################
# Job Management Functions
###############################################################################
update_job_in_launch_env() {
    local job_type="$1"
    local saved_network_location_id="$2"
    local start_marker end_marker command

    if [ "$job_type" = "backup" ]; then
        start_marker="### Start CommaUtility Backup"
        end_marker="### End CommaUtility Backup"
        command="/data/CommaUtility.sh -network ${saved_network_location_id}"
    elif [ "$job_type" = "route_sync" ]; then
        start_marker="### Start CommaUtilityRoute Sync"
        end_marker="### End CommaUtilityRoute Sync"
        command="/data/CommaUtilityRoutes.sh -network ${saved_network_location_id}"
    else
        print_error "Invalid job type: $job_type"
        return 1
    fi

    # Remove any existing block from LAUNCH_ENV_FILE.
    sed -i "/^${start_marker}/,/^${end_marker}/d" "$LAUNCH_ENV_FILE"

    # Append the new block at the end of the file.
    cat <<EOF >>"$LAUNCH_ENV_FILE"
${start_marker}
${command}
${end_marker}
EOF
    print_success "Updated ${job_type} job in ${LAUNCH_ENV_FILE}"
}

remove_job_block() {
    # clear
    local job_type="$1"
    local start_marker end_marker

    if [ "$job_type" = "backup" ]; then
        start_marker="### Start CommaUtility Backup"
        end_marker="### End CommaUtility Backup"
    elif [ "$job_type" = "route_sync" ]; then
        start_marker="### Start CommaUtilityRoute Sync"
        end_marker="### End CommaUtilityRoute Sync"
    else
        print_error "Invalid job type: $job_type"
        return 1
    fi

    sed -i "/^${start_marker}/,/^${end_marker}/d" "$LAUNCH_ENV_FILE"
    print_success "${job_type} job removed from ${LAUNCH_ENV_FILE}"
    pause_for_user
}
