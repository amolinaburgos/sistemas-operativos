#!/usr/bin/env bash

# Reimplementación de ejercicio-2.sh. Los usuarios y productos ya no se cargan
# ni se guardan en usuarios.tsv/productos.tsv: cada consulta y modificación va
# a SQLite. Los únicos TSV que permanecen son los logs requeridos.

set -u
set -o pipefail

declare -r -i MAX=6
declare -r DB="data.sq3"
declare -r SYSTEM_LOG="system.log"
declare -r ERROR_LOG="error.log"
declare -r SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCHEMA_FILE="${SCRIPT_DIR}/esquema.sql"

declare -r -i OPCION_ALTA=1
declare -r -i OPCION_BAJA=2
declare -r -i OPCION_MOSTRAR=3
declare -r -i OPCION_REPORTE=4
declare -r -i OPCION_SALIR=5

declare ID_USUARIO="-"
declare USUARIO_ACTUAL="-"

registrar_error() {
    local mensaje="$1"
    local fecha
    mensaje=$(limpiar_campo_tsv "$mensaje")
    fecha=$(date '+%Y-%m-%d %H:%M:%S') || fecha="fecha-desconocida"
    if ! printf '%s\t%s\n' "$fecha" "$mensaje" >> "$ERROR_LOG"; then
        printf 'No se pudo escribir en %s: %s\n' "$ERROR_LOG" "$mensaje" >&2
    fi
}

trap 'registrar_error "Fallo inesperado en la línea ${BASH_LINENO[0]}."' ERR

# El escape de comillas simples es necesario porque la CLI sqlite3 no ofrece
# parámetros enlazados al invocarla como proceso desde Bash.
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
    local salida estado

    if ! command -v sqlite3 >/dev/null 2>&1; then
        registrar_error "No se encontró el ejecutable sqlite3."
        printf 'Error: se requiere sqlite3 instalado y disponible en PATH.\n' >&2
        return 1
    fi

    # La ruta de la base sigue siendo relativa al directorio de trabajo, como
    # solicita el ejercicio; el esquema se resuelve junto a este script.
    if [[ ! -f "$DB" ]]; then
        printf 'La base %s no existe; se creará en el directorio actual.\n' "$DB"
    fi

    # El esquema usa CREATE TABLE IF NOT EXISTS, así que también puede aplicarse
    # al iniciar si la base ya existe, sin borrar los datos persistidos.
    if salida=$(sqlite3 -batch -bail "$DB" < "$SCHEMA_FILE" 2>&1); then
        importar_tsv_legacy || return 1
        return 0
    else
        estado=$?
        registrar_error "No se pudo inicializar ${DB}: ${salida//$'\n'/ }"
        printf 'Error al inicializar la base de datos. Consulte %s.\n' "$ERROR_LOG" >&2
        return "$estado"
    fi
}

limpiar_campo_tsv() {
    local valor="$1"
    valor=${valor//$'\t'/ }
    valor=${valor//$'\n'/ }
    valor=${valor//$'\r'/ }
    printf '%s' "$valor"
}

importar_tsv_legacy() {
    local aplicada salida estado linea usuario hash nombre_sql hash_sql
    local id resto nombre precio activo id_normalizado centavos precio_sql
    local tiene_archivos=0

    if ! aplicada=$(sqlite3 -batch -noheader "$DB" \
        "SELECT 1 FROM migraciones WHERE nombre = 'importacion_tsv_v1' LIMIT 1;" 2>&1); then
        registrar_error "No se pudo consultar el estado de importación TSV: ${aplicada//$'\n'/ }"
        printf 'Error al comprobar la migración de datos. Consulte %s.\n' "$ERROR_LOG" >&2
        return 1
    fi
    [[ "$aplicada" == "1" ]] && return 0

    [[ -f usuarios.tsv || -f productos.tsv ]] && tiene_archivos=1

    # La migración y su marca se confirman en la misma transacción: si SQLite
    # falla, se revierte la carga y el siguiente inicio puede reintentarla.
    if salida=$(
        {
            printf 'BEGIN IMMEDIATE;\n'

            if [[ -f usuarios.tsv ]]; then
                while IFS= read -r linea || [[ -n "$linea" ]]; do
                    [[ -n "$linea" ]] || continue
                    if [[ "$linea" != *$'\t'* ]]; then
                        registrar_error "Importación TSV: fila de usuario sin separador de tabulación."
                        continue
                    fi
                    usuario="${linea%%$'\t'*}"
                    hash="${linea#*$'\t'}"
                    hash="${hash%$'\r'}"
                    if [[ "$usuario" == *$'\t'* || -z "$usuario" || ! "$hash" =~ ^[[:xdigit:]]{64}$ ]]; then
                        registrar_error "Importación TSV: fila de usuario inválida; se omitió."
                        continue
                    fi
                    nombre_sql=$(sql_texto "$usuario")
                    hash_sql=$(sql_texto "$hash")
                    printf 'INSERT OR IGNORE INTO usuarios (nombre_usuario, hash_contrasena) VALUES (%s, %s);\n' \
                        "$nombre_sql" "$hash_sql"
                done < usuarios.tsv
            fi

            if [[ -f productos.tsv ]]; then
                while IFS= read -r linea || [[ -n "$linea" ]]; do
                    [[ -n "$linea" ]] || continue
                    if [[ "$linea" != *$'\t'* ]]; then
                        registrar_error "Importación TSV: fila de producto sin columnas TSV válidas."
                        continue
                    fi
                    id="${linea%%$'\t'*}"
                    resto="${linea#*$'\t'}"
                    if [[ "$resto" != *$'\t'* ]]; then
                        registrar_error "Importación TSV: fila de producto incompleta; se omitió."
                        continue
                    fi
                    nombre="${resto%%$'\t'*}"
                    resto="${resto#*$'\t'}"
                    if [[ "$resto" != *$'\t'* ]]; then
                        registrar_error "Importación TSV: fila de producto incompleta; se omitió."
                        continue
                    fi
                    precio="${resto%%$'\t'*}"
                    activo="${resto#*$'\t'}"
                    activo="${activo%$'\r'}"
                    if [[ "$activo" == *$'\t'* || "$activo" != "1" ]] ||
                        ! id_normalizado=$(normalizar_id "$id") ||
                        (( id_normalizado < 0 || id_normalizado >= MAX )) ||
                        ! validar_nombre_producto "$nombre"; then
                        registrar_error "Importación TSV: fila de producto inválida o inactiva; se omitió."
                        continue
                    fi
                    if ! centavos=$(convertir_precio_centavos "$precio"); then
                        registrar_error "Importación TSV: precio de producto inválido; se omitió."
                        continue
                    fi
                    nombre_sql=$(sql_texto "$nombre")
                    printf 'INSERT OR IGNORE INTO productos (id_producto, nombre, precio_centavos) VALUES (%d, %s, %d);\n' \
                        "$id_normalizado" "$nombre_sql" "$centavos"
                done < productos.tsv
            fi

            printf "INSERT INTO migraciones (nombre, aplicada_en) VALUES ('importacion_tsv_v1', datetime('now'));\n"
            printf 'COMMIT;\n'
        } | sqlite3 -batch -bail "$DB" 2>&1
    ); then
        if (( tiene_archivos == 1 )); then
            printf 'Importación de usuarios.tsv y productos.tsv completada.\n'
        fi
        return 0
    else
        estado=$?
        registrar_error "Falló la importación de archivos TSV: ${salida//$'\n'/ }"
        printf 'Error al importar los archivos TSV. Consulte %s.\n' "$ERROR_LOG" >&2
        return "$estado"
    fi
}

registrar_accion() {
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

generar_hash() {
    local salida
    salida=$(printf '%s' "$1" | sha256sum) || {
        registrar_error "No se pudo calcular el hash de una contraseña."
        return 1
    }
    printf '%s' "${salida:0:64}"
}

existe_usuario() {
    local nombre_sql resultado
    nombre_sql=$(sql_texto "$1")
    if ! resultado=$(ejecutar_sql "SELECT 1 FROM usuarios WHERE nombre_usuario = ${nombre_sql} LIMIT 1;"); then
        return 2
    fi
    [[ "$resultado" == "1" ]]
}

autenticar() {
    local intentos=0 usuario clave hash nombre_sql resultado id_guardado hash_guardado

    ID_USUARIO="-"
    USUARIO_ACTUAL="-"
    printf '\n--- INICIO DE SESIÓN ---\n'
    while (( intentos < 3 )); do
        read -rp 'Usuario: ' usuario || return 1
        read -rsp 'Contraseña: ' clave || return 1
        printf '\n'

        nombre_sql=$(sql_texto "$usuario")
        if ! resultado=$(ejecutar_sql \
            "SELECT id_usuario || char(9) || hash_contrasena FROM usuarios WHERE nombre_usuario = ${nombre_sql} LIMIT 1;"); then
            ID_USUARIO="-"
            USUARIO_ACTUAL="-"
            return 1
        fi

        # Se registra cada intento sin incluir nunca la contraseña ingresada.
        id_guardado="-"
        hash_guardado=""
        if [[ -n "$resultado" ]]; then
            IFS=$'\t' read -r id_guardado hash_guardado <<< "$resultado"
        fi
        ID_USUARIO="$id_guardado"
        USUARIO_ACTUAL="$usuario"
        if ! registrar_accion "Inicio de sesión"; then
            return 1
        fi

        if ! hash=$(generar_hash "$clave"); then
            ID_USUARIO="-"
            USUARIO_ACTUAL="-"
            return 1
        fi
        clave=""

        if [[ -n "$hash_guardado" && "$hash_guardado" == "$hash" ]]; then
            ID_USUARIO="$id_guardado"
            USUARIO_ACTUAL="$usuario"
            printf 'Acceso concedido. Bienvenido/a, %s.\n' "$usuario"
            return 0
        fi

        registrar_error "Intento de inicio de sesión no válido para el usuario ${usuario}."
        intentos=$((intentos + 1))
        printf 'Usuario o contraseña incorrectos (%d/3 intentos).\n' "$intentos"
    done

    ID_USUARIO="-"
    USUARIO_ACTUAL="-"
    return 1
}

registrar_usuario() {
    local usuario clave hash nombre_sql hash_sql

    printf '\n--- REGISTRO DE USUARIO ---\n'
    read -rp 'Ingrese nombre de usuario: ' usuario || return 1
    ID_USUARIO="-"
    USUARIO_ACTUAL="$usuario"
    if ! registrar_accion "Registro de usuario"; then
        return 1
    fi

    if [[ -z "$usuario" || "$usuario" == *$'\t'* || "$usuario" == *$'\n'* || "$usuario" == *$'\r'* ]]; then
        printf 'Error: el nombre de usuario no puede estar vacío ni contener tabuladores o saltos de línea.\n'
        registrar_error "Registro rechazado: nombre de usuario vacío o con caracteres de control."
        return 1
    fi

    if existe_usuario "$usuario"; then
        printf "Error: el usuario '%s' ya se encuentra registrado.\n" "$usuario"
        registrar_error "Registro rechazado: el nombre de usuario ya existe."
        return 1
    else
        local estado=$?
        if (( estado == 2 )); then
            return 1
        fi
    fi

    read -rsp 'Ingrese contraseña: ' clave || return 1
    printf '\n'
    if [[ -z "$clave" ]]; then
        printf 'Error: la contraseña no puede estar vacía.\n'
        registrar_error "Registro rechazado: contraseña vacía."
        return 1
    fi

    if ! hash=$(generar_hash "$clave"); then
        return 1
    fi
    clave=""
    nombre_sql=$(sql_texto "$usuario")
    hash_sql=$(sql_texto "$hash")
    if ! ejecutar_sql "INSERT INTO usuarios (nombre_usuario, hash_contrasena) VALUES (${nombre_sql}, ${hash_sql});" >/dev/null; then
        return 1
    fi

    printf "Usuario '%s' registrado con éxito.\n" "$usuario"
    ID_USUARIO="-"
    USUARIO_ACTUAL="-"
}

validar_nombre_producto() {
    local nombre="$1"
    [[ -n "$nombre" && "$nombre" != *$'\t'* && "$nombre" != *$'\n'* && "$nombre" != *$'\r'* && "$nombre" =~ [^[:space:]] ]]
}

convertir_precio_centavos() {
    local precio="$1" parte_entera parte_decimal

    if [[ ! "$precio" =~ ^[0-9]{1,15}([.,][0-9]{1,2})?$ ]]; then
        return 1
    fi

    precio="${precio/,/.}"
    parte_entera="${precio%%.*}"
    if [[ "$precio" == *.* ]]; then
        parte_decimal="${precio#*.}"
    else
        parte_decimal="0"
    fi
    if (( ${#parte_decimal} == 1 )); then
        parte_decimal="${parte_decimal}0"
    fi

    printf '%d' "$((10#$parte_entera * 100 + 10#$parte_decimal))"
}

normalizar_id() {
    local valor="$1"
    [[ "$valor" =~ ^[0-9]{1,6}$ ]] || return 1
    printf '%d' "$((10#$valor))"
}

existe_nombre() {
    local nombre_sql resultado
    nombre_sql=$(sql_texto "$1")
    if ! resultado=$(ejecutar_sql "SELECT 1 FROM productos WHERE nombre = ${nombre_sql} LIMIT 1;"); then
        return 2
    fi
    [[ "$resultado" == "1" ]]
}

existe_producto_id() {
    local resultado
    if ! resultado=$(ejecutar_sql "SELECT 1 FROM productos WHERE id_producto = $1 LIMIT 1;"); then
        return 2
    fi
    [[ "$resultado" == "1" ]]
}

alta() {
    local id="$1" nombre="$2" cents="$3" nombre_sql

    if (( id < 0 || id >= MAX )); then
        printf 'Error: ID fuera de rango.\n'
        registrar_error "Alta rechazada: ID fuera de rango."
        return 1
    fi
    if ! validar_nombre_producto "$nombre"; then
        printf 'Error: el nombre no puede estar vacío ni contener tabuladores o saltos de línea.\n'
        registrar_error "Alta rechazada: nombre de producto vacío o con caracteres de control."
        return 1
    fi

    if existe_producto_id "$id"; then
        printf "Error: el ID %d ya está ocupado.\n" "$id"
        registrar_error "Alta rechazada: ID de producto ya ocupado."
        return 1
    else
        local estado=$?
        if (( estado == 2 )); then
            return 1
        fi
    fi

    if existe_nombre "$nombre"; then
        printf "Error: ya existe un producto activo con el nombre '%s'.\n" "$nombre"
        registrar_error "Alta rechazada: nombre de producto duplicado."
        return 1
    else
        local estado=$?
        if (( estado == 2 )); then
            return 1
        fi
    fi

    nombre_sql=$(sql_texto "$nombre")
    if ! ejecutar_sql \
        "INSERT INTO productos (id_producto, nombre, precio_centavos) VALUES (${id}, ${nombre_sql}, ${cents});" >/dev/null; then
        # La clave primaria y UNIQUE de esquema.sql sustituyen las búsquedas
        # sobre el inventario en memoria y el reescrito completo de productos.tsv.
        return 1
    fi

    printf "Producto %d guardado: '%s' con precio $%d.%02d.\n" \
        "$id" "$nombre" "$((cents / 100))" "$((cents % 100))"
}

baja() {
    local id="$1" resultado

    if (( id < 0 || id >= MAX )); then
        printf 'Error: ID fuera de rango.\n'
        registrar_error "Baja rechazada: ID fuera de rango."
        return 1
    fi

    if ! resultado=$(ejecutar_sql "SELECT 1 FROM productos WHERE id_producto = ${id} LIMIT 1;"); then
        return 1
    fi
    if [[ "$resultado" != "1" ]]; then
        printf 'El producto no existe.\n'
        registrar_error "Baja rechazada: no existe un producto con el ID indicado."
        return 1
    fi

    # En el original la baja quitaba el producto al volver a guardar el TSV;
    # ahora se elimina directamente la fila SQL, liberando el ID.
    ejecutar_sql "DELETE FROM productos WHERE id_producto = ${id};" >/dev/null || return 1
    printf 'Producto %d eliminado.\n' "$id"
}

obtener_productos() {
    ejecutar_sql 'SELECT id_producto, nombre, precio_centavos FROM productos ORDER BY id_producto;'
}

formatear_precio() {
    local centavos="$1"
    printf '%d.%02d' "$((centavos / 100))" "$((centavos % 100))"
}

mostrar() {
    local filas id nombre centavos
    if ! filas=$(obtener_productos); then
        return 1
    fi

    printf '\nLISTADO:\n'
    while IFS=$'\t' read -r id nombre centavos; do
        [[ -n "$id" ]] || continue
        printf 'ID %d : %s - $%s\n' "$id" "$nombre" "$(formatear_precio "$centavos")"
    done <<< "$filas"
}

escapar_html() {
    local texto="$1" resultado="" caracter
    local -i i

    for ((i = 0; i < ${#texto}; i++)); do
        caracter="${texto:i:1}"
        case "$caracter" in
            '&') resultado+='&amp;' ;;
            '<') resultado+='&lt;' ;;
            '>') resultado+='&gt;' ;;
            '"') resultado+='&quot;' ;;
            "'") resultado+='&#39;' ;;
            *) resultado+="$caracter" ;;
        esac
    done
    printf '%s' "$resultado"
}

reporte() {
    local archivo="productos.html" filas id nombre centavos nombre_html
    if ! filas=$(obtener_productos); then
        return 1
    fi

    if ! {
        cat <<'HTML'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>Reporte de Productos</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        table { border-collapse: collapse; width: 50%; }
        th, td { border: 1px solid #dddddd; text-align: left; padding: 8px; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <h2>Reporte de Productos en Inventario</h2>
    <table>
        <thead>
            <tr><th>ID</th><th>Nombre</th><th>Precio</th></tr>
        </thead>
        <tbody>
HTML
        while IFS=$'\t' read -r id nombre centavos; do
            [[ -n "$id" ]] || continue
            nombre_html=$(escapar_html "$nombre")
            printf '            <tr><td>%d</td><td>%s</td><td>$%s</td></tr>\n' \
                "$id" "$nombre_html" "$(formatear_precio "$centavos")"
        done <<< "$filas"
        cat <<'HTML'
        </tbody>
    </table>
</body>
</html>
HTML
    } > "$archivo"; then
        registrar_error "No se pudo generar ${archivo}."
        printf 'Error al escribir el reporte. Consulte %s.\n' "$ERROR_LOG" >&2
        return 1
    fi

    printf "\nReporte generado exitosamente en '%s'.\n" "$archivo"
}

menu_acceso() {
    local opcion

    while true; do
        printf '\n--- ACCESO AL SISTEMA ---\n'
        printf '1. Iniciar sesión\n'
        printf '2. Registrar usuario\n'
        printf '3. Mostrar\n'
        printf '4. Reporte\n'
        printf '5. Salir\n'
        read -rp 'Opción: ' opcion || return 1

        case "$opcion" in
            1)
                if autenticar; then
                    return 0
                fi
                ;;
            2)
                registrar_usuario
                ID_USUARIO="-"
                USUARIO_ACTUAL="-"
                ;;
            3)
                registrar_accion "Mostrar inventario (acceso)" || return 1
                mostrar
                ;;
            4)
                registrar_accion "Generar reporte HTML (acceso)" || return 1
                reporte
                ;;
            5)
                registrar_accion "Salir" || return 1
                printf '\nSaliendo del programa...\n'
                exit 0
                ;;
            *)
                registrar_accion "Opción inválida: ${opcion}" || return 1
                printf '\nOpción inválida.\n'
                ;;
        esac
    done
}

main() {
    local opcion id_ingresado id nombre precio centavos

    inicializar_base_datos || return 1
    bienvenida
    menu_acceso || return 1

    while true; do
        printf '\nACCIONES:\n'
        printf '1. Alta producto (ID 0 a %d)\n' "$((MAX - 1))"
        printf '2. Baja producto\n'
        printf '3. Mostrar inventario\n'
        printf '4. Generar reporte HTML\n'
        printf '5. Salir\n'
        read -rp 'Opción: ' opcion || break

        case "$opcion" in
            1)
                registrar_accion "Alta de producto" || return 1
                read -rp "Ingrese ID (0-$((MAX - 1))): " id_ingresado || return 1
                read -rp 'Ingrese Nombre: ' nombre || return 1
                read -rp 'Ingrese Precio: ' precio || return 1
                if ! id=$(normalizar_id "$id_ingresado"); then
                    printf 'Error: ID inválido.\n'
                    registrar_error "Alta rechazada: formato de ID inválido."
                    continue
                fi
                if ! centavos=$(convertir_precio_centavos "$precio"); then
                    printf 'Error: ingrese un precio no negativo con hasta dos decimales.\n'
                    registrar_error "Alta rechazada: precio inválido."
                    continue
                fi
                alta "$id" "$nombre" "$centavos"
                ;;
            2)
                registrar_accion "Baja de producto" || return 1
                read -rp "Ingrese ID a eliminar (0-$((MAX - 1))): " id_ingresado || return 1
                if ! id=$(normalizar_id "$id_ingresado"); then
                    printf 'Error: ID inválido.\n'
                    registrar_error "Baja rechazada: formato de ID inválido."
                    continue
                fi
                baja "$id"
                ;;
            3)
                registrar_accion "Mostrar inventario" || return 1
                mostrar
                ;;
            4)
                registrar_accion "Generar reporte HTML" || return 1
                reporte
                ;;
            5)
                registrar_accion "Salir" || return 1
                printf '\nSaliendo del programa...\n'
                return 0
                ;;
            *)
                registrar_accion "Opción inválida: ${opcion}" || return 1
                printf '\nOpción inválida.\n'
                ;;
        esac
    done
}

main "$@"
