#!/usr/bin/bash
# https://docs.gitlab.com/runner/executors/custom.html#prepare

# shellcheck source=./include.sh
source "${BASH_SOURCE[0]%/*}/include.sh"


ensure_executable_available enroot
ensure_executable_available flock
ensure_executable_available grep


# Create CI WorkSpace paths if they don't exist
if [[ ! -d "${ENROOT_CACHE_PATH}" ]]; then
    mkdir -p "${ENROOT_CACHE_PATH}"
fi

if [[ ! -d "${ENROOT_DATA_PATH}" ]]; then
    mkdir -p "${ENROOT_DATA_PATH}"
fi

if [[ ! -d "${SLURM_IDS_PATH}" ]]; then
    mkdir -p "${SLURM_IDS_PATH}"
fi


# Reuse a container if it exists
# shellcheck disable=SC2143
if ! [[ $(enroot list | grep "${CONTAINER_NAME}") ]]; then
    echo -e "Preparing the container ${CONTAINER_NAME}."

    # Check if CI job image: is set
    if [[ -z "${CUSTOM_ENV_CI_JOB_IMAGE}" ]]; then
        die "No CI job image specified"
    fi

    # Import a container image from a specific location to enroot image dir
    # Scheme: docker://[USER@][REGISTRY#]IMAGE[:TAG]
    IMAGE_DIR="${ENROOT_DATA_PATH}"
    URL="docker://${CUSTOM_ENV_CI_JOB_IMAGE}"
    IMAGE_NAME="${CUSTOM_ENV_CI_JOB_IMAGE//[:@#.\/]/-}"
    # Utility timestamp and lock files
    IMAGE_TIMESTAMP_FILE=${IMAGE_DIR}/TIMESTAMP_${IMAGE_NAME}
    IMAGE_LOCK_FILE=${IMAGE_DIR}/LOCK_${IMAGE_NAME}

    # Update the image once every 3 hours. Use a lock to prevent conflicts
    exec 100<>"${IMAGE_LOCK_FILE}"
    flock -w 120 100
    if [[ ! -f ${IMAGE_TIMESTAMP_FILE} ||
              ($(cat "${IMAGE_TIMESTAMP_FILE}") -le $(date +%s -d '-3 hours')) ]]; then
        IMAGE_FILE="${IMAGE_DIR}/${IMAGE_NAME}.sqsh"
        if [[ -f ${IMAGE_FILE} ]]; then
            rm "${IMAGE_DIR}/${IMAGE_NAME}.sqsh"
        fi

        COMMAND=(enroot import \
            --output "${IMAGE_DIR}/${IMAGE_NAME}.sqsh" \
            -- "${URL}")

        "${COMMAND[@]}" || die "Command: ${COMMAND[*]} failed with exit code ${?}"
        date +%s > "${IMAGE_TIMESTAMP_FILE}"
    fi
    flock -u 100

    # Create a container root filesystem from a container image
    COMMAND=(
        enroot create \
            --name "${CONTAINER_NAME}" \
            -- "${IMAGE_DIR}/${IMAGE_NAME}.sqsh"
    )
    "${COMMAND[@]}" || die "Command: ${COMMAND[*]} failed with exit code ${?}"
else
    echo -e "Reusing container ${CONTAINER_NAME}"
fi


# List all the container root filesystems on the system.
enroot list --fancy
