#!/usr/bin/env bash

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

    if ! id_existente=$(ejecutar_sql "SELECT id_producto FROM productos WHERE nombre = $(sql_texto "$nombre") AND id_producto != ${id} LIMIT 1;"); then
        return 1
    fi
    if [[ -n "$id_existente" ]]; then
        printf "Error: ya existe otro producto con el nombre '%s'.\n" "$nombre"
        registrar_error "Edición rechazada: nombre de producto duplicado."
        return 1
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
    local archivo="$REPORT_FILE" filas id nombre centavos nombre_html
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
