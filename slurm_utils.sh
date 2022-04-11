#!/usr/bin/env bash
# Sections:
# 1. General standalone utility functions
# 2. SLURM variables management (requires previous utility functions)
# 3. Main SLURM loop waiting function (relies on all utilities)


#####
## 1. Standalone utility functions
#####

# Convenient exit function
# This has multiple modes builtin depending on the arguments given:
# + No argument: only exit, no message or anything printed
# + One argument: exit with a message
# + Two argument: exit with message and deletes temporary workdir (useful for
#   intermediate SLURM code)
# + More arguments: Full SLURM management, cancels any ongoing job, print job logs, ...
function die() {
    # External arguments
    local msg="${1}"
    # Extra arguments in the SLURM cases
    local workdir="${2}"
    local jobid=${3}
    local joblog="${4}"
    local joberr="${5}"

    if [[ -n "${jobid}" ]]; then
        msg="${jobid}: ${msg}"
    fi
    test -n "${msg}" && echo -e "${msg}" > /dev/stderr
    test -n "${jobid}" && scancel --quiet "${jobid}"
    test -n "${joblog}" && slurm_print_output "${jobid}" "Log" "${joblog}" /dev/stderr
    test -n "${joberr}" && slurm_print_output "${jobid}" "Errors" "${joberr}" /dev/stderr
    test -n "${workdir}" && test -d "${workdir}" && rm -rf "${workdir}"
    # Inform cleanup.sh that we encountered an error
    # touch "${CUSTOM_ENV_CI_WS}/${CUSTOM_ENV_CI_JOB_ID}"
    exit "${BUILD_FAILURE_EXIT_CODE}"
}


# Prints a SLURM job output file to $output
# Does nothing if the file is empty
function slurm_print_output() {
    # External arguments
    local jobid=${1}
    local logtype="${2}"
    local slurmlogfile="${3}"
    local output=${4}

    if [[ ! -f "${slurmlogfile}" || "$(cat "${slurmlogfile}")" == "" ]]; then
        return 0
    fi
    {
        echo -e "== SLURM Job ${jobid} ${logtype}"
        echo -e "============================"
        cat "${slurmlogfile}"
    } >> "${output}"
}


# Uses awk to convert a string of the form d-hh:min:s and all combinations to
# seconds.
# The result is return as simple echo.
function slurm_time_to_seconds() {
    # Parameters
    local slurm_time="$1"

    # Local variables
    local num_colons="${slurm_time//[!:]/}"
    local num_dashes="${slurm_time//[!-]/}"
    num_colons=${#num_colons}
    num_dashes=${#num_dashes}
    local running_limit=0
    # We use awk to split the string into sub components. The fields are
    # available in $1 to $<n>. If $3, e.g. doesn't exist, its value is 0 so
    # optional components at the end of the expression are taken care of
    # naturally. We need different cases for optional components at the
    # beginning of the expression.
    if [[ ${num_dashes} == 1 ]]; then # Suppose d-hh(:min(:s)) where parenthesis show optional components
        running_limit=$(echo "${slurm_time}" | awk -F[-:] '{ print ($1 * 86400) + ($2 * 3600) + ($3 * 60) + $4 }')
    elif [[ ${num_colons} == 2 ]]; then # Suppose hh:min:s
        running_limit=$(echo "${slurm_time}" | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }')
    elif [[ ${num_colons} == 1 || ${num_colons} == 0 ]]; then # Suppose min(:s)
        running_limit=$(echo "${slurm_time}" | awk -F: '{ print ($1 * 60) + $2 }')
    else
        return 1
    fi
    echo "${running_limit}"
}


#####
## 2. Variables which control the SLURM waiting loop's behavior
#####
export SLURM_GOOD_COMPLETED_STATUS="COMPLETED"
export SLURM_GOOD_PENDING_STATUS="@(COMPLETED|COMPLETING|RUNNING)*"
export SLURM_BAD_STATUS="@(FAILED|TIMEOUT|OUT_OF_MEMORY|REVOKED|NODE_FAIL|CANCELLED|BOOT_FAIL)*"

export SLURM_UPDATE_INTERVAL=${CUSTOM_ENV_SLURM_UPDATE_INTERVAL:-120} # 2 minutes
export SLURM_PENDING_LIMIT=${CUSTOM_ENV_SLURM_PENDING_LIMIT:-43200} # 12 hours
SLURM_RUNNING_LIMIT=86400 # 24 hours
if [[ -n ${CUSTOM_ENV_SLURM_TIME} ]]; then
    SLURM_RUNNING_LIMIT=$(slurm_time_to_seconds "${CUSTOM_ENV_SLURM_TIME}" || \
        die "Couldn't understand the time format ${CUSTOM_ENV_SLURM_TIME}.")
fi
export SLURM_RUNNING_LIMIT


#####
## 3. SLURM waiting loop function
#####

# A simple waiting loop for a specific SLURM job based on its status.
# Error conditions:
# 1. We waited past the waiting limit
# 2. The job status is one of ${SLURM_BAD_STATUS}.
function slurm_wait_for_status() {
    # Get External params
    local jobid=${1}
    local waiting_limit=${2}
    local good_status_expr="${3}"

    # Internal variables
    local keep_waiting=1
    local waiting_time=0
    local jobstatus=""

    echo -e ""
    while [[ $keep_waiting == 1 ]]; do
        jobstatus="$(sacct -bn -j "${jobid}" | head -1 | tr -s ' ' | cut -d' ' -f 2)"
        if [[ $waiting_time -gt $waiting_limit ]]; then
            echo -e "\nJob ${jobid} has exceeded the waiting limit\
                of ${waiting_limit}." > /dev/stderr
            return 1
        fi
        # We need extglob for the expression variable based cases to work
        shopt -s extglob
        # shellcheck disable=SC2254
        case ${jobstatus} in
            ${good_status_expr})
                keep_waiting=0
                ;;
            ${SLURM_BAD_STATUS})
                echo -e ""
                return 1
                ;;
            *)
                echo -n "."
                sleep "$SLURM_UPDATE_INTERVAL"
                waiting_time=$((waiting_time + SLURM_UPDATE_INTERVAL))
                ;;
        esac
        shopt -u extglob
    done
    echo -e ""
}
