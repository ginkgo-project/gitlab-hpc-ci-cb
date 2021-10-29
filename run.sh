#!/usr/bin/bash
# https://docs.gitlab.com/runner/executors/custom.html#run

source "${BASH_SOURCE[0]%/*}/include.sh"


ensure_executable_available enroot


# External args
# Last argument is always the step name. The one before last is the step script
before_last=$(($#-1))
STEP_NAME_ARG="${!#}"
STEP_SCRIPT_ARG="${!before_last}"


# No slurm requested, directly use the login node
if [[ -z "${USE_SLURM}" ]]; then
    COMMAND=(enroot start ${MOUNT_OPTIONS[@]} --rw ${ENROOT_ENV_CONFIG[*]} -e NVIDIA_VISIBLE_DEVICES=void ${CONTAINER_NAME} /bin/bash)
    "${COMMAND[@]}" < "${1}" || die "Command: ${COMMAND[@]} failed with exit code ${?}"
else # SLURM usage requested
    ensure_executable_available sacct
    ensure_executable_available scancel
    ensure_executable_available sbatch
    ensure_executable_available srun
    ensure_executable_available squeue
    ensure_executable_available wc
    ensure_executable_available awk

    # We need to create the temporary files in a directory with filesystem
    # access on all nodes. Because we consider ${CONTAINER_NAME} to be unique,
    # we use it as storage for this job.
    WORKDIR="${CI_WS}/${CONTAINER_NAME}"
    STEPSCRIPTDIR="${WORKDIR}/step_scripts"
    if [[ ! -d "${WORKDIR}" ]]; then
        mkdir -p "${WORKDIR}"
    fi
    if [[ ! -d "${STEPSCRIPTDIR}" ]]; then
        mkdir -p "${STEPSCRIPTDIR}"
    fi
    STEPSCRIPT="${STEPSCRIPTDIR}/$(ls ${STEPSCRIPTDIR} | wc -l)"
    touch "${STEPSCRIPT}"
    JOBSCRIPT=$(mktemp -p ${WORKDIR})

    # Save the step script
    cp "${STEP_SCRIPT_ARG}" "${STEPSCRIPT}"

    # Only store the gitlab scripts until we reach the last cleanup one
    if [[ "${STEP_NAME_ARG}" != "cleanup_file_variables" ]]; then
        echo -e "Storing the script for step ${STEP_NAME_ARG} for bulk submission."
        exit
    fi

    # This is the last step cleanup_file_variables, prepare the SLURM job
    JOBLOG=$(mktemp -p ${WORKDIR})
    JOBERR=$(mktemp -p ${WORKDIR})
    SLURM_CONFIG=("--job-name=${CONTAINER_NAME}")
    SLURM_CONFIG+=("--error=${JOBERR}")
    SLURM_CONFIG+=("--output=${JOBLOG}")
    SLURM_CONFIG+=("--chdir=${WORKDIR}")
    if [[ -n "${CUSTOM_ENV_SLURM_PARTITION}" ]]; then
        SLURM_CONFIG+=("--partition=${CUSTOM_ENV_SLURM_PARTITION}")
    fi
    if [[ -n "${CUSTOM_ENV_SLURM_EXCLUSIVE}" ]]; then
        SLURM_CONFIG+=("--exclusive")
    fi
    if [[ -n "${CUSTOM_ENV_SLURM_TIME}" ]]; then
        SLURM_CONFIG+=("--time=${CUSTOM_ENV_SLURM_TIME}")
    fi
    if [[ -n "${CUSTOM_ENV_SLURM_GRES}" ]]; then
        SLURM_CONFIG+=("--gres=${CUSTOM_ENV_SLURM_GRES}")
    fi

    # Log the configuration
    echo -e "SLURM configuration:"
    printf "\t%s\n" ${SLURM_CONFIG[@]}
    echo -e "\n"
    echo -e "ENROOT environment configuration:"
    printf "\t%s\n" ${ENROOT_ENV_CONFIG[@]}
    echo -e "\n"


    # Launch the container through slurm
    # Somehow, this script doesn't like if the variables are surrounded by "
    echo -e "#!/bin/bash

for scriptnum in \$(ls -1v ${STEPSCRIPTDIR}); do
    srun enroot start ${MOUNT_OPTIONS[@]} --rw ${ENROOT_ENV_CONFIG[*]} \
        ${CONTAINER_NAME} /bin/bash < ${STEPSCRIPTDIR}/\${scriptnum}
done
" > ${JOBSCRIPT}
    chmod +x ${JOBSCRIPT}


    # Submission
    COMMAND=(sbatch --parsable ${SLURM_CONFIG[*]} ${JOBSCRIPT})
    JOBID=$("${COMMAND[@]}" || \
        die "Command: ${COMMAND[@]} failed with exit code ${EXIT_CODE}" "${WORKDIR}")
    echo -e "Job submitted and pending with ID: ${JOBID}."
    squeue -u ${USER}

    # Store the JOBID so `cleanup.sh` can read it and cancel the job if running
    # (e.g., when pressing the cancel button on gitlab). We consider that the
    # CONTAINER_NAME is unique at a given time, so we don't use locking or a list
    # of ids.
    echo "${JOBID}" > "${SLURM_IDS_PATH}/${CONTAINER_NAME}.txt"

    slurm_wait_for_status "${JOBID}" "${SLURM_PENDING_LIMIT}" \
        "${SLURM_GOOD_PENDING_STATUS}" || die "encountered an error while waiting" \
        "${WORKDIR}" ${JOBID} "${JOBLOG}" "${JOBERR}"

    echo -e "Job ${JOBID} started execution."
    slurm_wait_for_status "${JOBID}" "${SLURM_RUNNING_LIMIT}" \
        "${SLURM_GOOD_COMPLETED_STATUS}" || die "encountered an error while waiting" \
        "${WORKDIR}" ${JOBID} "${JOBLOG}" "${JOBERR}"

    echo -e "Job ${JOBID} completed."
    slurm_print_output "${JOBID}" "Log" "${JOBLOG}" /dev/stdout
    slurm_print_output "${JOBID}" "Errors" "${JOBERR}" /dev/stdout

    # Cleanup the workdir
    rm -rf ${WORKDIR}
fi
