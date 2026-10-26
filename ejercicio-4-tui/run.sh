#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/database.sh"
source "${SCRIPT_DIR}/auth.sh"
source "${SCRIPT_DIR}/products.sh"
source "${SCRIPT_DIR}/menu.sh"

trap 'registrar_error "Fallo inesperado en la línea ${BASH_LINENO[0]}."' ERR

main "$@"
