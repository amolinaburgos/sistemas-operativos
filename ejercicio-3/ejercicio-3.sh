#!/usr/bin/env bash

# Configuración del intérprete Bash para prevenir errores silenciosos
set -u          # Trata variables no definidas como error (evita fallos por tipeo)
set -o pipefail # Asegura que si falla un comando en una tubería (pipe), falle todo el conjunto

# Declaración de constantes globales de control y rutas de archivos
declare -r -i MAX=20                        
declare -r DB="data.sq3"                      
declare -r SYSTEM_LOG="system.log"            
declare -r ERROR_LOG="error.log"              
declare -r ARCHIVO_USUARIOS_TSV="usuarios.tsv"          
declare -r ARCHIVO_PRODUCTOS_TSV="productos.tsv"        
declare -r ARCHIVO_USUARIOS_CARGADOS="usuarios_cargados.tsv"
declare -r ARCHIVO_PRODUCTOS_CARGADOS="productos_cargados.tsv"

# Obtención robusta de la ruta absoluta del directorio del script actual
declare -r SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCHEMA_FILE="${SCRIPT_DIR}/esquema.sql" # Ruta opcional hacia un esquema SQL externo

# Definición de constantes numéricas para las opciones del menú principal
declare -r -i OPCION_ALTA=1
declare -r -i OPCION_BAJA=2
declare -r -i OPCION_MOSTRAR=3
declare -r -i OPCION_EDITAR=4
declare -r -i OPCION_REPORTE=5
declare -r -i OPCION_SALIR=6

# Variables de estado mutables para el seguimiento de la sesión actual del usuario
declare ID_USUARIO="-"
declare USUARIO_ACTUAL="-"


# ==============================================================================
# MÓDULO DE REGISTRO Y AUDITORÍA (LOGS)
# ==============================================================================

# Función: registrar_error
# Propósito: Captura y almacena mensajes de error con marca de tiempo en formato TSV.
registrar_error() {
    local mensaje="$1"
    local fecha
    
    mensaje=$(limpiar_campo_tsv "$mensaje") # Sanitiza el texto para evitar romper columnas TSV
    fecha=$(date '+%Y-%m-%d %H:%M:%S') || fecha="fecha-desconocida" # Obtiene timestamp seguro

    # Anexa el registro de error al archivo correspondiente
    if ! printf '%s\t%s\n' "$fecha" "$mensaje" >> "$ERROR_LOG"; then
        printf 'No se pudo escribir en %s: %s\n' "$ERROR_LOG" "$mensaje" >&2
    fi
}

# Configuración de trampa global (trap): Atrapa cualquier error inesperado en tiempo de ejecución
trap 'registrar_error "Fallo inesperado en la línea ${BASH_LINENO[0]}."' ERR


# ==============================================================================
# MÓDULO DE INTERACCIÓN Y SEGURIDAD CON SQLITE
# ==============================================================================

# Función: sql_texto
# Propósito: Sanitiza cadenas de texto reemplazando comillas simples para evitar inyección SQL.
sql_texto() {
    local texto="$1"
    texto=${texto//\'/\'\'} # Escapa las comillas simples duplicándolas (' -> '')
    printf "'%s'" "$texto"
}

# Función: ejecutar_sql
# Propósito: Envuelve la ejecución de comandos `sqlite3` controlando salidas y errores.
ejecutar_sql() {
    local sentencia="$1"
    local salida estado

    # Ejecuta SQLite en modo batch, sin cabeceras, usando tabuladores como separadores
    if salida=$(sqlite3 -batch -bail -noheader -separator $'\t' "$DB" "$sentencia" 2>&1); then
        printf '%s' "$salida"
        return 0
    else
        estado=$?
        registrar_error "SQLite: ${salida//$'\n'/ }" # Registra el error devuelto por la base de datos
        printf 'Error al acceder a la base de datos. Consulte %s.\n' "$ERROR_LOG" >&2
        return "$estado"
    fi
}


# ==============================================================================
# MÓDULO DE INICIALIZACIÓN Y MIGRACIÓN DE DATOS (LEGACY TSV)
# ==============================================================================

# Función: inicializar_base_datos
# Propósito: Comprueba dependencias, crea la estructura de la base de datos y ejecuta la migración TSV.
inicializar_base_datos() {
    local salida estado

    # Valida que la herramienta sqlite3 esté instalada en el sistema
    if ! command -v sqlite3 >/dev/null 2>&1; then
        registrar_error "No se encontró el ejecutable sqlite3."
        printf 'Error: se requiere sqlite3 instalado y disponible en PATH.\n' >&2
        return 1
    fi

    # Notifica si la base de datos es nueva
    if [[ ! -f "$DB" ]]; then
        printf 'La base %s no existe; se creará en el directorio actual.\n' "$DB"
    fi

    # Se ejecutan siempre los comandos para garantizar que todas las tablas existan
    sqlite3 "$DB" <<EOF
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
EOF

    # Si existe un archivo de esquema externo adicional, se aplica
    if [[ -f "$SCHEMA_FILE" ]]; then
        if ! sqlite3 -batch -bail "$DB" < "$SCHEMA_FILE" 2>&1; then
            registrar_error "No se pudo aplicar el archivo de esquema externo."
        fi
    fi

    # Llama a la función encargada de migrar los archivos TSV antiguos
    importar_tsv_legacy || return 1
    return 0
}

# Función: limpiar_campo_tsv
# Propósito: Elimina caracteres de control (tabuladores, saltos de línea) para proteger la estructura TSV.
limpiar_campo_tsv() {
    local valor="$1"
    valor=${valor//$'\t'/ }
    valor=${valor//$'\n'/ }
    valor=${valor//$'\r'/ }
    printf '%s' "$valor"
}

# Función: importar_tsv_legacy
# Propósito: Lee los archivos .tsv antiguos, los inserta en SQLite de forma atómica y los renombra.
importar_tsv_legacy() {
    local aplicada salida estado linea usuario hash nombre_sql hash_sql
    local id resto nombre precio activo id_normalizado centavos
    local tiene_archivos=0

    # Verifica si la migración ya fue aplicada previamente consultando la tabla de control
    if ! aplicada=$(sqlite3 -batch -noheader "$DB" \
        "SELECT 1 FROM migraciones WHERE nombre = 'importacion_tsv_v1' LIMIT 1;" 2>&1); then
        registrar_error "No se pudo consultar el estado de importación TSV: ${aplicada//$'\n'/ }"
        printf 'Error al comprobar la migración de datos. Consulte %s.\n' "$ERROR_LOG" >&2
        return 1
    fi
    [[ "$aplicada" == "1" ]] && return 0

    # Detecta si existen los archivos legacy en el directorio
    [[ -f "$ARCHIVO_USUARIOS_TSV" || -f "$ARCHIVO_PRODUCTOS_TSV" ]] && tiene_archivos=1

    # Ejecuta la inserción masiva dentro de una transacción atómica de SQLite (BEGIN IMMEDIATE)
    if salida=$(
        {
            printf 'BEGIN IMMEDIATE;\n'

            # Migración de usuarios desde usuarios.tsv
            if [[ -f "$ARCHIVO_USUARIOS_TSV" ]]; then
                while IFS= read -r linea || [[ -n "$linea" ]]; do
                    [[ -n "$linea" ]] || continue
                    if [[ "$linea" != *$'\t'* ]]; then continue; fi
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

            # Migración de productos desde productos.tsv
            if [[ -f "$ARCHIVO_PRODUCTOS_TSV" ]]; then
                while IFS= read -r linea || [[ -n "$linea" ]]; do
                    [[ -n "$linea" ]] || continue
                    if [[ "$linea" != *$'\t'* ]]; then continue; fi
                    id="${linea%%$'\t'*}"
                    resto="${linea#*$'\t'}"
                    if [[ "$resto" != *$'\t'* ]]; then continue; fi
                    nombre="${resto%%$'\t'*}"
                    resto="${resto#*$'\t'}"
                    if [[ "$resto" != *$'\t'* ]]; then continue; fi
                    precio="${resto%%$'\t'*}"
                    activo="${resto#*$'\t'}"
                    activo="${activo%$'\r'}"
                    if [[ "$activo" == *$'\t'* || "$activo" != "1" ]] ||
                        ! id_normalizado=$(normalizar_id "$id") ||
                        (( id_normalizado < 0 || id_normalizado >= MAX )) ||
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

            # Registra que la migración se completó con éxito
            printf "INSERT INTO migraciones (nombre, aplicada_en) VALUES ('importacion_tsv_v1', datetime('now'));\n"
            printf 'COMMIT;\n'
        } | sqlite3 -batch -bail "$DB" 2>&1
    ); then
        if (( tiene_archivos == 1 )); then
            # Renombra los archivos originales para evitar reprocesarlos en futuras ejecuciones
            [[ -f "$ARCHIVO_USUARIOS_TSV" ]] && mv "$ARCHIVO_USUARIOS_TSV" "$ARCHIVO_USUARIOS_CARGADOS"
            [[ -f "$ARCHIVO_PRODUCTOS_TSV" ]] && mv "$ARCHIVO_PRODUCTOS_TSV" "$ARCHIVO_PRODUCTOS_CARGADOS"
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

# Función: registrar_log
# Propósito: Guarda un registro de auditoría en `system.log` detallando la acción realizada por el usuario.
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


# ==============================================================================
# MÓDULO DE AUTENTICACIÓN Y GESTIÓN DE USUARIOS
# ==============================================================================

# Función: generar_hash
# Propósito: Aplica cifrado SHA-256 a una cadena de texto (contraseñas).
generar_hash() {
    local salida
    salida=$(printf '%s' "$1" | sha256sum) || {
        registrar_error "No se pudo calcular el hash de una contraseña."
        return 1
    }
    printf '%s' "${salida:0:64}" # Extrae exactamente los primeros 64 caracteres del hash hexadecimal
}

# Función: existe_usuario
# Propósito: Consulta en SQLite si un nombre de usuario ya se encuentra registrado.
existe_usuario() {
    local nombre_sql resultado
    nombre_sql=$(sql_texto "$1")
    if ! resultado=$(ejecutar_sql "SELECT 1 FROM usuarios WHERE nombre_usuario = ${nombre_sql} LIMIT 1;"); then
        return 2
    fi
    [[ "$resultado" == "1" ]]
}

# Función: autenticar
# Propósito: Valida las credenciales de acceso del usuario permitiendo hasta 3 intentos.
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

        id_guardado="-"
        hash_guardado=""
        if [[ -n "$resultado" ]]; then
            IFS=$'\t' read -r id_guardado hash_guardado <<< "$resultado"
        fi
        ID_USUARIO="$id_guardado"
        USUARIO_ACTUAL="$usuario"
        if ! registrar_log "Inicio de sesión"; then
            return 1
        fi

        if ! hash=$(generar_hash "$clave"); then
            ID_USUARIO="-"
            USUARIO_ACTUAL="-"
            return 1
        fi
        clave="" # Limpia la contraseña en memoria por seguridad

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

# Función: registrar_usuario
# Propósito: Da de alta un nuevo usuario aplicando hash a su contraseña y guardándolo en SQLite.
registrar_usuario() {
    local usuario clave hash nombre_sql hash_sql

    printf '\n--- REGISTRO DE USUARIO ---\n'
    read -rp 'Ingrese nombre de usuario: ' usuario || return 1
    ID_USUARIO="-"
    USUARIO_ACTUAL="$usuario"
    if ! registrar_log "Registro de usuario"; then
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
        if (( estado == 2 )); then return 1; fi
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


# ==============================================================================
# MÓDULO DE GESTIÓN DE PRODUCTOS E INVENTARIO
# ==============================================================================

validar_nombre_producto() {
    local nombre="$1"
    [[ -n "$nombre" && "$nombre" != *$'\t'* && "$nombre" != *$'\n'* && "$nombre" != *$'\r'* && "$nombre" =~ [^[:space:]] ]]
}

# Función: convertir_precio_centavos
# Propósito: Convierte montos decimales (ej. 10.50) a enteros (1050) para evitar errores de punto flotante en dinero.
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

# Función: alta
# Propósito: Inserta un nuevo producto validando restricciones de ID único, rango y nombre.
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
        if (( estado == 2 )); then return 1; fi
    fi

    if existe_nombre "$nombre"; then
        printf "Error: ya existe un producto activo con el nombre '%s'.\n" "$nombre"
        registrar_error "Alta rechazada: nombre de producto duplicado."
        return 1
    else
        local estado=$?
        if (( estado == 2 )); then return 1; fi
    fi

    nombre_sql=$(sql_texto "$nombre")
    if ! ejecutar_sql \
        "INSERT INTO productos (id_producto, nombre, precio_centavos) VALUES (${id}, ${nombre_sql}, ${cents});" >/dev/null; then
        return 1
    fi

    printf "Producto %d guardado: '%s' con precio $%d.%02d.\n" \
        "$id" "$nombre" "$((cents / 100))" "$((cents % 100))"
}

# Función: baja
# Propósito: Elimina físicamente un producto de la base de datos a partir de su ID.
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

    ejecutar_sql "DELETE FROM productos WHERE id_producto = ${id};" >/dev/null || return 1
    printf 'Producto %d eliminado.\n' "$id"
}

# Función: editar
# Propósito: Actualiza los datos de un producto existente (nombre y/o precio) en SQLite.
editar() {
    local id="$1" nombre="$2" cents="$3" nombre_sql resultado id_existente

    if (( id < 0 || id >= MAX )); then
        printf 'Error: ID fuera de rango.\n'
        registrar_error "Edición rechazada: ID fuera de rango."
        return 1
    fi
    if ! validar_nombre_producto "$nombre"; then
        printf 'Error: el nombre no puede estar vacío ni contener tabuladores o saltos de línea.\n'
        registrar_error "Edición rechazada: nombre de producto vacío o con caracteres de control."
        return 1
    fi

    if ! resultado=$(ejecutar_sql "SELECT 1 FROM productos WHERE id_producto = ${id} LIMIT 1;"); then
        return 1
    fi
    if [[ "$resultado" != "1" ]]; then
        printf 'Error: el producto no existe o está dado de baja.\n'
        registrar_error "Edición rechazada: el producto no existe en el ID ${id}."
        return 1
    fi

    if id_existente=$(ejecutar_sql "SELECT id_producto FROM productos WHERE nombre = $(sql_texto "$nombre") AND id_producto != ${id} LIMIT 1;"); then
        if [[ -n "$id_existente" ]]; then
            printf "Error: ya existe otro producto con el nombre '%s'.\n" "$nombre"
            registrar_error "Edición rechazada: nombre de producto duplicado."
            return 1
        fi
    fi

    nombre_sql=$(sql_texto "$nombre")
    if ! ejecutar_sql "UPDATE productos SET nombre = ${nombre_sql}, precio_centavos = ${cents} WHERE id_producto = ${id};" >/dev/null; then
        return 1
    fi

    printf "Producto %d actualizado: '%s' con precio $%d.%02d.\n" \
        "$id" "$nombre" "$((cents / 100))" "$((cents % 100))"
    registrar_log "Edición de producto ID $id"
}

obtener_productos() {
    ejecutar_sql 'SELECT id_producto, nombre, precio_centavos FROM productos ORDER BY id_producto;'
}

formatear_precio() {
    local centavos="$1"
    printf '%d.%02d' "$((centavos / 100))" "$((centavos % 100))"
}

# Función: mostrar
# Propósito: Imprime en consola el listado completo de productos ordenados por ID.
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

# Función: reporte
# Propósito: Genera un archivo de reporte en formato HTML (`productos.html`) sanitizando texto.
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


# ==============================================================================
# MÓDULOS DE MENÚS Y FLUJO PRINCIPAL
# ==============================================================================

# Función: menu_acceso
# Propósito: Muestra el menú de autenticación previo antes de permitir acceder al inventario.
menu_acceso() {
    clear
    local opcion

    while true; do
        printf '\n--- ACCESO AL SISTEMA ---\n'
        printf '1. Iniciar sesión\n'
        printf '2. Registrar usuario\n'
        printf '3. Salir\n'
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
            3)  registrar_log "Salir" || return 1
                printf '\nSaliendo del programa...\n'
                exit 0
                ;;
            *)
                registrar_log "Opción inválida: ${opcion}" || return 1
                printf '\nOpción inválida.\n'
                ;;
        esac
    done
}

# Función: main
# Propósito: Orquesta la ejecución inicial, despliega el menú interactivo principal de operaciones.
main() {
    local opcion id_ingresado id nombre precio centavos

    inicializar_base_datos || return 1 # Inicializa DB y migra archivos legacy
    bienvenida                         # Mensaje de bienvenida
    menu_acceso || return 1            # Control de sesión de usuario

    # Bucle infinito del menú de gestión de inventario post-autenticación
    while true; do
        printf '\nACCIONES:\n'
        printf '1. Alta producto (ID 0 a %d)\n' "$((MAX - 1))"
        printf '2. Baja producto\n'
        printf '3. Mostrar inventario\n'
        printf '4. Editar producto\n'
        printf '5. Generar reporte HTML\n'
        printf '6. Salir\n'
        read -rp 'Opción: ' opcion || break

        case "$opcion" in
            $OPCION_ALTA)
                registrar_log "Alta de producto" || return 1
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
            $OPCION_BAJA)
                registrar_log "Baja de producto" || return 1
                read -rp "Ingrese ID a eliminar (0-$((MAX - 1))): " id_ingresado || return 1
                if ! id=$(normalizar_id "$id_ingresado"); then
                    printf 'Error: ID inválido.\n'
                    registrar_error "Baja rechazada: formato de ID inválido."
                    continue
                fi
                baja "$id"
                ;;
            $OPCION_MOSTRAR)
                registrar_log "Mostrar inventario" || return 1
                mostrar
                ;;
            $OPCION_EDITAR)
                registrar_log "Edición de producto" || return 1
                read -rp "Ingrese ID a editar (0-$((MAX - 1))): " id_ingresado || return 1
                read -rp 'Ingrese nuevo Nombre: ' nombre || return 1
                read -rp 'Ingrese nuevo Precio: ' precio || return 1
                if ! id=$(normalizar_id "$id_ingresado"); then
                    printf 'Error: ID inválido.\n'
                    registrar_error "Edición rechazada: formato de ID inválido."
                    continue
                fi
                if ! centavos=$(convertir_precio_centavos "$precio"); then
                    printf 'Error: ingrese un precio no negativo con hasta dos decimales.\n'
                    registrar_error "Edición rechazada: precio inválido."
                    continue
                fi
                editar "$id" "$nombre" "$centavos"
                ;;
            $OPCION_REPORTE)
                registrar_log "Generar reporte HTML" || return 1
                reporte
                ;;
            $OPCION_SALIR)
                registrar_log "Salir" || return 1
                printf '\nSaliendo del programa...\n'
                return 0
                ;;
            *)
                registrar_log "Opción inválida: ${opcion}" || return 1
                printf '\nOpción inválida.\n'
                ;;
        esac
    done
}

# Ejecución de la función principal pasando los argumentos de línea de comandos
main "$@"