#!/usr/bin/env bash

# Compatibilidad con el nombre del ejecutable original; el código está modularizado.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/run.sh" "$@"
