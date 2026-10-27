#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/database.sh"
source "${SCRIPT_DIR}/auth.sh"
source "${SCRIPT_DIR}/productos.sh"

if ! command -v socat >/dev/null 2>&1; then
    printf 'Error: se requiere socat instalado y disponible en PATH.\n' >&2
    registrar_error "No se encontró el ejecutable socat."
    exit 1
fi

WEB_PORT="${WEB_PORT:-8080}"
if [[ ! "$WEB_PORT" =~ ^[0-9]{1,5}$ ]] || (( WEB_PORT < 1024 || WEB_PORT > 65535 )); then
    printf 'Error: WEB_PORT debe ser un puerto numérico entre 1024 y 65535.\n' >&2
    exit 1
fi

inicializar_base_datos || exit 1
printf 'Servidor web local en http://127.0.0.1:%s (Ctrl+C para detenerlo).\n' "$WEB_PORT"
exec socat -T 15 \
    "TCP-LISTEN:${WEB_PORT},bind=127.0.0.1,reuseaddr,fork" \
    "EXEC:${SCRIPT_DIR}/web-handler.sh"
