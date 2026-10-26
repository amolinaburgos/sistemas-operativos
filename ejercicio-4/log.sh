#!/usr/bin/env bash

# Reduce los caracteres de control para conservar el formato TSV de los logs.
limpiar_campo_tsv() {
    local valor="$1"
    valor=${valor//$'\t'/ }
    valor=${valor//$'\n'/ }
    valor=${valor//$'\r'/ }
    printf '%s' "$valor"
}

registrar_error() {
    local mensaje="$1"
    local fecha

    mensaje=$(limpiar_campo_tsv "$mensaje")
    fecha=$(date '+%Y-%m-%d %H:%M:%S') || fecha="fecha-desconocida"

    if ! printf '%s\t%s\n' "$fecha" "$mensaje" >> "$ERROR_LOG"; then
        printf 'No se pudo escribir en %s: %s\n' "$ERROR_LOG" "$mensaje" >&2
    fi
}

registrar_log() {
    local accion="$1"
    local id nombre fecha

    id=$(limpiar_campo_tsv "$ID_USUARIO")
    nombre=$(limpiar_campo_tsv "$USUARIO_ACTUAL")
    accion=$(limpiar_campo_tsv "$accion")
    fecha=$(date '+%Y-%m-%d %H:%M:%S') || {
        registrar_error "No se pudo obtener fecha/hora para system.log."
        return 1
    }

    if ! printf '%s\t%s\t%s\t%s\n' "$fecha" "$id" "$nombre" "$accion" >> "$SYSTEM_LOG"; then
        registrar_error "No se pudo escribir la acción en ${SYSTEM_LOG}."
        printf 'Error al registrar la acción. Consulte %s.\n' "$ERROR_LOG" >&2
        return 1
    fi
}

bienvenida() {
    printf 'Bienvenido/a al sistema\n\n'
}
