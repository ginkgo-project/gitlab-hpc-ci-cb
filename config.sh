#!/usr/bin/bash
# https://docs.gitlab.com/runner/executors/custom.html#config

# shellcheck source=./include.sh
source "${BASH_SOURCE[0]%/*}/include.sh"

# Sometimes you might want to set some settings during execution time.
# For example settings a build directory depending on the project ID.
# config_exec reads from STDOUT and expects a valid JSON string with specific keys.

cat <<'EOF'
{
  "driver": {
    "name": "ENROOT (SLURM) driver",
    "version": "v1.0.0"
  }
}
EOF
