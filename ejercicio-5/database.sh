#!/usr/bin/env bash

sql_texto() {
    local texto="$1"
    texto=${texto//\'/\'\'}
    printf "'%s'" "$texto"
}

ejecutar_sql() {
    local sentencia="$1"
    local salida estado

    if salida=$(sqlite3 -batch -bail -noheader -separator $'\t' "$DB" "$sentencia" 2>&1); then
        printf '%s' "$salida"
        return 0
    else
        estado=$?
        registrar_error "SQLite: ${salida//$'\n'/ }"
        printf 'Error al acceder a la base de datos. Consulte %s.\n' "$ERROR_LOG" >&2
        return "$estado"
    fi
}

inicializar_base_datos() {
    if ! command -v sqlite3 >/dev/null 2>&1; then
        registrar_error "No se encontró el ejecutable sqlite3."
        printf 'Error: se requiere sqlite3 instalado y disponible en PATH.\n' >&2
        return 1
    fi

    if [[ ! -f "$DB" ]]; then
        printf 'La base %s no existe; se creará en el directorio del ejercicio.\n' "$DB"
    fi

    if ! sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS usuarios (
    id_usuario INTEGER PRIMARY KEY AUTOINCREMENT,
    nombre_usuario TEXT UNIQUE NOT NULL,
    hash_contrasena TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS productos (
    id_producto INTEGER PRIMARY KEY,
    nombre TEXT UNIQUE NOT NULL,
    precio_centavos INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS migraciones (
    nombre TEXT PRIMARY KEY,
    aplicada_en TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sesiones_web (
    token TEXT PRIMARY KEY,
    csrf_token TEXT NOT NULL,
    id_usuario INTEGER REFERENCES usuarios(id_usuario),
    creada_en TEXT NOT NULL DEFAULT (datetime('now'))
);
SQL
    then
        registrar_error "No se pudo crear o comprobar la estructura de la base de datos."
        printf 'Error al inicializar la base de datos. Consulte %s.\n' "$ERROR_LOG" >&2
        return 1
    fi

    if [[ -f "$SCHEMA_FILE" ]] && ! sqlite3 -batch -bail "$DB" < "$SCHEMA_FILE" 2>&1; then
        registrar_error "No se pudo aplicar el archivo de esquema externo."
        printf 'Error al aplicar el esquema. Consulte %s.\n' "$ERROR_LOG" >&2
        return 1
    fi

    importar_tsv_legacy
}

importar_tsv_legacy() {
    local aplicada salida estado linea usuario hash nombre_sql hash_sql
    local id resto nombre precio activo id_normalizado centavos
    local tiene_archivos=0

    if ! aplicada=$(sqlite3 -batch -noheader "$DB" \
        "SELECT 1 FROM migraciones WHERE nombre = 'importacion_tsv_v1' LIMIT 1;" 2>&1); then
        registrar_error "No se pudo consultar el estado de importación TSV: ${aplicada//$'\n'/ }"
        printf 'Error al comprobar la migración de datos. Consulte %s.\n' "$ERROR_LOG" >&2
        return 1
    fi
    [[ "$aplicada" == "1" ]] && return 0

    [[ -f "$ARCHIVO_USUARIOS_TSV" || -f "$ARCHIVO_PRODUCTOS_TSV" ]] && tiene_archivos=1

    if salida=$(
        {
            printf 'BEGIN IMMEDIATE;\n'

            if [[ -f "$ARCHIVO_USUARIOS_TSV" ]]; then
                while IFS= read -r linea || [[ -n "$linea" ]]; do
                    [[ -n "$linea" ]] || continue
                    [[ "$linea" == *$'\t'* ]] || continue
                    usuario="${linea%%$'\t'*}"
                    hash="${linea#*$'\t'}"
                    hash="${hash%$'\r'}"
                    if [[ "$usuario" == *$'\t'* || -z "$usuario" || ! "$hash" =~ ^[[:xdigit:]]{64}$ ]]; then
                        continue
                    fi
                    nombre_sql=$(sql_texto "$usuario")
                    hash_sql=$(sql_texto "$hash")
                    printf 'INSERT OR IGNORE INTO usuarios (nombre_usuario, hash_contrasena) VALUES (%s, %s);\n' \
                        "$nombre_sql" "$hash_sql"
                done < "$ARCHIVO_USUARIOS_TSV"
            fi

            if [[ -f "$ARCHIVO_PRODUCTOS_TSV" ]]; then
                while IFS= read -r linea || [[ -n "$linea" ]]; do
                    [[ -n "$linea" ]] || continue
                    
                    [[ "$linea" == *$'\t'* ]] || continue
                    id="${linea%%$'\t'*}"
                    resto="${linea#*$'\t'}"
                    
                    [[ "$resto" == *$'\t'* ]] || continue
                    nombre="${resto%%$'\t'*}"
                    resto="${resto#*$'\t'}"
                    
                    [[ "$resto" == *$'\t'* ]] || continue
                    precio="${resto%%$'\t'*}"
                    activo="${resto#*$'\t'}"
                    activo="${activo%$'\r'}"
                    if [[ "$activo" == *$'\t'* || "$activo" != "1" ]] ||
                        ! id_normalizado=$(normalizar_id "$id") ||
                        (( id_normalizado < 0 || id_normalizado >= MAX_PRODUCTO )) ||
                        ! validar_nombre_producto "$nombre"; then
                        continue
                    fi
                    if ! centavos=$(convertir_precio_centavos "$precio"); then
                        continue
                    fi
                    nombre_sql=$(sql_texto "$nombre")
                    printf 'INSERT OR IGNORE INTO productos (id_producto, nombre, precio_centavos) VALUES (%d, %s, %d);\n' \
                        "$id_normalizado" "$nombre_sql" "$centavos"
                done < "$ARCHIVO_PRODUCTOS_TSV"
            fi

            printf "INSERT INTO migraciones (nombre, aplicada_en) VALUES ('importacion_tsv_v1', datetime('now'));\n"
            printf 'COMMIT;\n'
        } | sqlite3 -batch -bail "$DB" 2>&1
    ); then
        if (( tiene_archivos == 1 )); then
            if [[ -f "$ARCHIVO_USUARIOS_TSV" ]] &&
                ! mv -- "$ARCHIVO_USUARIOS_TSV" "$ARCHIVO_USUARIOS_CARGADOS"; then
                registrar_error "No se pudo archivar ${ARCHIVO_USUARIOS_TSV}."
                printf 'La migración terminó, pero no se pudo archivar %s.\n' "$ARCHIVO_USUARIOS_TSV" >&2
                return 1
            fi
            if [[ -f "$ARCHIVO_PRODUCTOS_TSV" ]] &&
                ! mv -- "$ARCHIVO_PRODUCTOS_TSV" "$ARCHIVO_PRODUCTOS_CARGADOS"; then
                registrar_error "No se pudo archivar ${ARCHIVO_PRODUCTOS_TSV}."
                printf 'La migración terminó, pero no se pudo archivar %s.\n' "$ARCHIVO_PRODUCTOS_TSV" >&2
                return 1
            fi
            printf 'Importación de archivos TSV legacy completada y archivos renombrados.\n'
        fi
        return 0
    else
        estado=$?
        registrar_error "Falló la importación de archivos TSV: ${salida//$'\n'/ }"
        printf 'Error al importar los archivos TSV. Consulte %s.\n' "$ERROR_LOG" >&2
        return "$estado"
    fi
}
