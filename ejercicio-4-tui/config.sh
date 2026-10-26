#!/usr/bin/env bash

# Configuración compartida y rutas locales a esta copia del ejercicio.
declare -r SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -r -i MAX=20
declare -r DB="${SCRIPT_DIR}/data.sq3"
declare -r SYSTEM_LOG="${SCRIPT_DIR}/system.log"
declare -r ERROR_LOG="${SCRIPT_DIR}/error.log"
declare -r ARCHIVO_USUARIOS_TSV="${SCRIPT_DIR}/usuarios.tsv"
declare -r ARCHIVO_PRODUCTOS_TSV="${SCRIPT_DIR}/productos.tsv"
declare -r ARCHIVO_USUARIOS_CARGADOS="${SCRIPT_DIR}/usuarios_cargados.tsv"
declare -r ARCHIVO_PRODUCTOS_CARGADOS="${SCRIPT_DIR}/productos_cargados.tsv"
declare -r SCHEMA_FILE="${SCRIPT_DIR}/esquema.sql"
declare -r REPORT_FILE="${SCRIPT_DIR}/productos.html"

declare -r -i OPCION_ALTA_PRODUCTO=1
declare -r -i OPCION_BAJA_PRODUCTO=2
declare -r -i OPCION_MOSTRAR_PRODUCTO=3
declare -r -i OPCION_EDITAR_PRODUCTO=4
declare -r -i OPCION_REPORTE_PRODUCTO=5
declare -r -i OPCION_SALIR=6

ID_USUARIO="-"
USUARIO_ACTUAL="-"
