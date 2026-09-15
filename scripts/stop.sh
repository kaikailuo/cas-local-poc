#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command docker
compose down --remove-orphans
printf 'CAS local POC stopped. Runtime certificates and logs were preserved.\n'

