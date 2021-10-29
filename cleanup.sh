#!/usr/bin/bash
# https://docs.gitlab.com/runner/executors/custom.html#cleanup

source "${BASH_SOURCE[0]%/*}/include.sh"


ensure_executable_available enroot


# Take care of slurm cleanup if needed
if [[ -f "${SLURM_IDS_PATH}/${CONTAINER_NAME}.txt" ]]; then
    ensure_executable_available scancel
    ensure_executable_available squeue

    USE_SLURM=1
    JOBID=$(cat "${SLURM_IDS_PATH}/${CONTAINER_NAME}.txt")
    JOBSTATUS="$(sacct -bn -j ${JOBID} | head -1 | tr -s ' ' | cut -d' ' -f 2)"
    rm ${SLURM_IDS_PATH}/${CONTAINER_NAME}.txt # not needed anymore
    # If the job isn't finished yet, we still need to cancel it
    scancel --quiet ${JOBID}
fi

# Check for whether we got an error
JOB_FAILED=0
if [[ -f "${CI_WS}/${CUSTOM_ENV_CI_JOB_ID}" ]]; then
    JOB_FAILED=1
    rm "${CI_WS}/${CUSTOM_ENV_CI_JOB_ID}"
fi

# Delete container root filesystems if it isn't asked to be preserved or there
# was an error in one of the previous step.
echo -e "===============================" >> ${LOGFILE}
echo -e "Job: ${CUSTOM_ENV_CI_JOB_ID}" >> ${LOGFILE}
echo -e "Job started at: ${CUSTOM_ENV_CI_JOB_STARTED_AT}" >> ${LOGFILE}
echo -e "Pipeline: ${CUSTOM_ENV_CI_PIPELINE_ID}" >> ${LOGFILE}
if [[ -z "${CUSTOM_ENV_KEEP_CONTAINER}" || ${JOB_FAILED} != 0 ]]; then
    echo -e "Cleaning up container ${CONTAINER_NAME}" >> ${LOGFILE}
    enroot remove --force -- "${CONTAINER_NAME}" >> ${LOGFILE}
else
    echo -e "Keeping container ${CONTAINER_NAME}" >> ${LOGFILE}
fi

enroot list --fancy >> ${LOGFILE}
if [[ "${USE_SLURM}" == 1 ]]; then
    squeue -u ${USER} >> ${LOGFILE}
fi
