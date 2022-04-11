#!/usr/bin/bash
# https://docs.gitlab.com/runner/executors/custom.html#cleanup

# shellcheck source=./include.sh
source "${BASH_SOURCE[0]%/*}/include.sh"


ensure_executable_available enroot


# Take care of slurm cleanup if needed
if [[ -f "${SLURM_IDS_PATH}/${CONTAINER_NAME}.txt" ]]; then
    ensure_executable_available scancel
    ensure_executable_available squeue

    USE_SLURM=1
    JOBID=$(cat "${SLURM_IDS_PATH}/${CONTAINER_NAME}.txt")
    rm "${SLURM_IDS_PATH}/${CONTAINER_NAME}.txt" # not needed anymore
    # If the job isn't finished yet, we still need to cancel it
    scancel --quiet "${JOBID}"
fi

# Somehow, the work dir is leftover, that can indicate a job cancellation.
WORK_DIR="${CI_WS}/${CONTAINER_NAME}"
if [[ -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
fi

# Delete container root filesystems if it isn't asked to be preserved or there
# was an error in one of the previous step.
{
    echo -e "==============================="
    echo -e "Job: ${CUSTOM_ENV_CI_JOB_ID}"
    echo -e "Job started at: ${CUSTOM_ENV_CI_JOB_STARTED_AT}"
    echo -e "Pipeline: ${CUSTOM_ENV_CI_PIPELINE_ID}"
    if [[ -z "${CUSTOM_ENV_KEEP_CONTAINER}" ]]; then
        echo -e "Cleaning up container ${CONTAINER_NAME}"
        enroot remove --force -- "${CONTAINER_NAME}"
    else
        echo -e "Keeping container ${CONTAINER_NAME}"
    fi

    enroot list --fancy
    if [[ "${USE_SLURM}" == 1 ]]; then
        squeue -u "${USER}"
    fi
} >> "${LOGFILE}"
