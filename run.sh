#!/usr/bin/bash
# https://docs.gitlab.com/runner/executors/custom.html#run


# shellcheck source=./include.sh
source "${BASH_SOURCE[0]%/*}/include.sh"


ensure_executable_available enroot


# External args
# Last argument is always the step name. The one before last is the step script
before_last=$(($#-1))
STEP_NAME_ARG="${!#}"
STEP_SCRIPT_ARG="${!before_last}"

if [[ "${STEP_NAME_ARG}" == "step_script" || "${STEP_NAME_ARG}" == "build_script"  ]]; then
    echo -e "VOLUMES configuration:"
    printf "\t%s\n" "${ENROOT_MOUNT_OPTIONS[@]}"
    echo -e "\n"
fi

# No slurm requested or required, directly use the login node
if [[ -z "${USE_SLURM}" || ${USE_SLURM} -eq 0 ||
          # All scripts from after_script onward are executed on the login node
          # see https://docs.gitlab.com/runner/executors/custom.html#run
          "${STEP_NAME_ARG}" == "after_script" ||
          "${STEP_NAME_ARG}" == "cleanup_file_variables" ||
          "${STEP_NAME_ARG}" == *"archive"* ||
          "${STEP_NAME_ARG}" == *"upload_artifacts"* ]]; then
    # Enroot fails when quoting anything or splitting this command. Leave it in
    # this format.
    #
    # shellcheck disable=SC2206
    COMMAND=(enroot start ${ENROOT_MOUNT_OPTIONS[*]} --rw ${ENROOT_ENV_CONFIG[*]} -e "NVIDIA_VISIBLE_DEVICES=void" ${CONTAINER_NAME} /bin/bash)
    "${COMMAND[@]}" < "${STEP_SCRIPT_ARG}" || die "Command: ${COMMAND[*]} failed with exit code ${?}"
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
    WORK_DIR="${CI_WS}/${CONTAINER_NAME}"
    STEP_SCRIPT_DIR="${WORK_DIR}/step_scripts"
    if [[ ! -d "${WORK_DIR}" ]]; then
        mkdir -p "${WORK_DIR}"
    fi
    if [[ ! -d "${STEP_SCRIPT_DIR}" ]]; then
        mkdir -p "${STEP_SCRIPT_DIR}"
    fi
    NUM_SCRIPTS="$(find "${STEP_SCRIPT_DIR}" -maxdepth 1 -type f | wc -l)"
    STEP_SCRIPT="${STEP_SCRIPT_DIR}/${NUM_SCRIPTS}"
    touch "${STEP_SCRIPT}"
    JOB_SCRIPT=$(mktemp -p "${WORK_DIR}")

    # Save the step script
    cp "${STEP_SCRIPT_ARG}" "${STEP_SCRIPT}"

    # Only store the gitlab scripts until we reach the main {build,step}_script
    if [[ ! "${STEP_NAME_ARG}" =~ ^[bs].*"_script" ]]; then
        echo -e "Storing the script for step ${STEP_NAME_ARG} for bulk submission."
        exit
    fi

    # We finally reached the main script, prepare the SLURM job
    JOB_LOG=$(mktemp -p "${WORK_DIR}")
    JOB_ERR=$(mktemp -p "${WORK_DIR}")
    SLURM_CONFIG=("--job-name=${CONTAINER_NAME}")
    SLURM_CONFIG+=("--output=${JOB_LOG}")
    SLURM_CONFIG+=("--error=${JOB_ERR}")
    SLURM_CONFIG+=("--chdir=${WORK_DIR}")
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
    if [[ -n "${CUSTOM_ENV_SLURM_ACCOUNT}" ]]; then
        SLURM_CONFIG+=("--account=${CUSTOM_ENV_SLURM_ACCOUNT}")
    fi

    # Log the configuration
    echo -e "SLURM configuration:"
    printf "\t%s\n" "${SLURM_CONFIG[@]}"
    echo -e "\n"
    echo -e "ENROOT environment configuration:"
    printf "\t%s\n" "${ENROOT_ENV_CONFIG[@]}"
    echo -e "\n"


    # Launch the container through slurm
    # Somehow, this script doesn't like if the variables are surrounded by "
    echo -e "#!/bin/bash

for scriptnum in \$(ls -1v ${STEP_SCRIPT_DIR}); do
    srun enroot start ${ENROOT_MOUNT_OPTIONS[*]} --rw ${ENROOT_ENV_CONFIG[*]} \
        ${CONTAINER_NAME} /bin/bash < ${STEP_SCRIPT_DIR}/\${scriptnum}
done
" > "${JOB_SCRIPT}"
    chmod +x "${JOB_SCRIPT}"


    # Submission
    # shellcheck disable=SC2206
    COMMAND=(sbatch --parsable ${SLURM_CONFIG[*]} ${JOB_SCRIPT})
    JOB_ID=$("${COMMAND[@]}") || \
        die "Command: ${COMMAND[*]} failed with exit code ${?}" "${WORK_DIR}"
    echo -e "Job submitted and pending with ID: ${JOB_ID}."
    squeue -u "${USER}"

    # Store the JOB_ID so `cleanup.sh` can read it and cancel the job if running
    # (e.g., when pressing the cancel button on gitlab). We consider that the
    # CONTAINER_NAME is unique at a given time, so we don't use locking or a list
    # of ids.
    echo "${JOB_ID}" > "${SLURM_IDS_PATH}/${CONTAINER_NAME}.txt"

    slurm_wait_for_status "${JOB_ID}" "${SLURM_PENDING_LIMIT}" \
        "${SLURM_GOOD_PENDING_STATUS}" || die "encountered an error while waiting" \
        "${WORK_DIR}" "${JOB_ID}" "${JOB_LOG}" "${JOB_ERR}"

    echo -e "Job ${JOB_ID} started execution."
    slurm_wait_for_status "${JOB_ID}" "${SLURM_RUNNING_LIMIT}" \
        "${SLURM_GOOD_COMPLETED_STATUS}" || die "encountered an error while waiting" \
        "${WORK_DIR}" "${JOB_ID}" "${JOB_LOG}" "${JOB_ERR}"

    test -f "${JOB_ERR}" && test "$(cat "${JOB_ERR}")"  != "" && \
        die "encountered an error during execution" "${WORK_DIR}" "${JOB_ID}" "${JOB_LOG}" "${JOB_ERR}"

    echo -e "Job ${JOB_ID} completed."
    slurm_print_output "${JOB_ID}" "Log" "${JOB_LOG}" /dev/stdout
    slurm_print_output "${JOB_ID}" "Errors" "${JOB_ERR}" /dev/stdout

    # Cleanup the workdir
    rm -rf "${WORK_DIR}"
fi
