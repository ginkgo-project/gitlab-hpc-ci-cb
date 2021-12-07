#!/usr/bin/bash

# Include the slurm utility functions
# shellcheck source=./slurm_utils.sh
source "${BASH_SOURCE[0]%/*}/slurm_utils.sh"

# Do NOT touch these and make sure they are the same as local environment
# variables!! Otherwise, there can be *duplicate* locations and local containers
# will not see the same as gitlab containers!
export CI_WS="${CUSTOM_ENV_CI_WS}"
export LOGFILE="${CI_WS}/gitlab-runner-enroot.log"
export ENROOT_CACHE_PATH="${CI_WS}/ENROOT_CACHE"
export ENROOT_DATA_PATH="${CI_WS}/ENROOT_DATA"
export SLURM_IDS_PATH="${CI_WS}/SLURM_IDS"


# Set a variable CONTAINER_NAME based on the environment variable
# CUSTOM_ENV_USE_NAME
if [[ -z "${CUSTOM_ENV_USE_NAME}" ]]; then
    CONTAINER_NAME="GitLabRunnerEnrootExecutorBuildID${CUSTOM_ENV_CI_BUILD_ID}"
else
    CONTAINER_NAME="${CUSTOM_ENV_USE_NAME}"
fi
export CONTAINER_NAME


# Ccache and volume management
ENROOT_MOUNT_OPTIONS=()
if [[ -n "${CUSTOM_ENV_VOL_NUM}" ]]; then
    for i in $(seq 1 "${CUSTOM_ENV_VOL_NUM}"); do
        VOL_SRC="CUSTOM_ENV_VOL_${i}_SRC"
        VOL_DST="CUSTOM_ENV_VOL_${i}_DST"
        if [[ ! -d "${!VOL_SRC}" ]]; then
            mkdir -p "${!VOL_SRC}"
        fi
        ENROOT_MOUNT_OPTIONS+=("--mount ${!VOL_SRC}:${!VOL_DST}")
    done
fi
export ENROOT_MOUNT_OPTIONS


# Propagate these environment variables to the container
PROPAGATED_ENV_VARIABLES=(BENCHMARK
                          DRY_RUN
                          EXECUTOR
                          REPETITIONS
                          SOLVER_REPETITIONS
                          SEGMENTS
                          SEGMENT_ID
                          PRECONDS
                          FORMATS
                          ELL_IMBALANCE_LIMIT
                          SOLVERS
                          SOLVERS_PRECISION
                          SOLVERS_MAX_ITERATIONS
                          SOLVERS_GMRES_RESTART
                          SYSTEM_NAME
                          DEVICE_ID
                          SOLVERS_JACOBI_MAX_BS
                          BENCHMARK_PRECISION
                          SOLVERS_RHS
                          SOLVERS_RHS_FLAG
                          SOLVERS_INITIAL_GUESS
                          GPU_TIMER
                          DETAILED
                          MATRIX_LIST_FILE
                          NVIDIA_VISIBLE_DEVICES
                          CCACHE_DIR
                          CCACHE_MAXSIZE
                         )
for bench_var in ${PROPAGATED_ENV_VARIABLES[*]}; do
    check_var="CUSTOM_ENV_${bench_var}"
    if [[ -n "${!check_var}" ]]; then
        ENROOT_ENV_CONFIG+=("-e ${bench_var}=${!check_var}")
    fi
done
export ENROOT_ENV_CONFIG

# SLURM configuration variables.
#
# If the user sets any slurm variable or the variable USE_SLURM, this container
# will use slurm job submission
USE_SLURM=${CUSTOM_ENV_USE_SLURM}
if [[ -z "${USE_SLURM}" || ${USE_SLURM} -ne 0 ]]; then
    SUPPORTED_SLURM_VARIABLES=(SLURM_PARTITION
                               SLURM_EXCLUSIVE
                               SLURM_TIME
                               SLURM_GRES
                               SLURM_ACCOUNT
                               SLURM_UPDATE_INTERVAL
                               SLURM_PENDING_LIMIT
                               SLURM_RUNNING_LIMIT
                               USE_SLURM)
    for slurm_var in ${SUPPORTED_SLURM_VARIABLES[*]}; do
        check_var="CUSTOM_ENV_${slurm_var}"
        if [[ -n "${!check_var}" ]]; then
          USE_SLURM=1
        fi
    done
fi
export USE_SLURM
# variables from slurm_utils we need to expose outside
export SLURM_UPDATE_INTERVAL
export SLURM_PENDING_LIMIT
export SLURM_RUNNING_LIMIT
export SLURM_GOOD_COMPLETED_STATUS
export SLURM_GOOD_PENDING_STATUS
export SLURM_BAD_STATUS


function ensure_executable_available() {
    local command=${1}

    if ! type -p "${command}" >/dev/null 2>/dev/null; then
        die "No ${command} executable found"
    fi
}
