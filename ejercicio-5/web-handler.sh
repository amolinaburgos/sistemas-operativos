#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/database.sh"
source "${SCRIPT_DIR}/auth.sh"
source "${SCRIPT_DIR}/productos.sh"

declare -A FORM=()
REQUEST_METHOD=""
REQUEST_PATH=""
REQUEST_BODY=""
COOKIE_HEADER=""
HTTP_STATUS="200 OK"
RESPONSE_COOKIE=""
SESSION_TOKEN=""
CSRF_TOKEN=""
SESSION_USER_ID=""
SESSION_USERNAME=""
FLASH_MESSAGE=""
FLASH_KIND="success"

html_escape() {
    local value="$1"
    value=${value//&/\&amp;}
    value=${value//</\&lt;}
    value=${value//>/\&gt;}
    value=${value//\"/\&quot;}
    value=${value//\'/\&#39;}
    printf '%s' "$value"
}

url_decode() {
    local input="$1" output="" char hex
    local -i index=0

    while (( index < ${#input} )); do
        char="${input:index:1}"
        case "$char" in
            +) output+=" " ;;
            %)
                if (( index + 2 >= ${#input} )) ||
                    [[ ! "${input:index+1:2}" =~ ^[[:xdigit:]]{2}$ ]]; then
                    return 1
                fi
                hex="${input:index+1:2}"
                [[ "$hex" != "00" ]] || return 1
                printf -v char '%b' "\\x${hex}"
                output+="$char"
                index=$((index + 2))
                ;;
            *) output+="$char" ;;
        esac
        index=$((index + 1))
    done
    printf '%s' "$output"
}

parse_form() {
    local body="$1" pair key value

    FORM=()
    while [[ -n "$body" ]]; do
        pair="${body%%&*}"
        if [[ "$body" == *"&"* ]]; then
            body="${body#*&}"
        else
            body=""
        fi
        key="${pair%%=*}"
        value=""
        [[ "$pair" == *=* ]] && value="${pair#*=}"
        key=$(url_decode "$key") || return 1
        value=$(url_decode "$value") || return 1
        case "$key" in
            accion|csrf|usuario|clave|id|nombre|precio) FORM["$key"]="$value" ;;
        esac
    done
}

read_request() {
    local request_line header lowered content_length="" transfer_encoding="" content_type=""

    IFS= read -r request_line || return 1
    request_line="${request_line%$'\r'}"
    read -r REQUEST_METHOD REQUEST_PATH _ <<< "$request_line"
    [[ "$REQUEST_METHOD" == GET || "$REQUEST_METHOD" == POST ]] || return 2
    REQUEST_PATH="${REQUEST_PATH%%\?*}"

    while IFS= read -r header; do
        header="${header%$'\r'}"
        [[ -n "$header" ]] || break
        lowered="${header,,}"
        case "$lowered" in
            content-length:*)
                content_length="${header#*:}"
                content_length="${content_length//[[:space:]]/}"
                ;;
            transfer-encoding:*)
                transfer_encoding="${lowered#*:}"
                transfer_encoding="${transfer_encoding//[[:space:]]/}"
                ;;
            content-type:*)
                content_type="${lowered#*:}"
                content_type="${content_type# }"
                ;;
            cookie:*)
                COOKIE_HEADER="${header#*:}"
                COOKIE_HEADER="${COOKIE_HEADER# }"
                ;;
        esac
    done

    [[ -z "$transfer_encoding" || "$transfer_encoding" == identity ]] || return 3
    if [[ "$REQUEST_METHOD" == POST ]]; then
        [[ "$content_type" == application/x-www-form-urlencoded* ]] || return 3
        [[ "$content_length" =~ ^[0-9]{1,4}$ ]] || return 3
        (( content_length <= 8192 )) || return 3
        if (( content_length > 0 )); then
            IFS= read -r -N "$content_length" REQUEST_BODY || return 3
        fi
        parse_form "$REQUEST_BODY" || return 3
    fi
}

new_token() {
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

load_session() {
    local pair candidate session_data

    IFS=';' read -ra cookie_parts <<< "$COOKIE_HEADER"
    for pair in "${cookie_parts[@]}"; do
        pair="${pair#"${pair%%[![:space:]]*}"}"
        if [[ "$pair" == inventario_session=* ]]; then
            candidate="${pair#inventario_session=}"
            [[ "$candidate" =~ ^[[:xdigit:]]{64}$ ]] && SESSION_TOKEN="$candidate"
        fi
    done

    if [[ -n "$SESSION_TOKEN" ]]; then
        session_data=$(ejecutar_sql \
            "SELECT csrf_token || char(9) || COALESCE(id_usuario, '') FROM sesiones_web WHERE token = '${SESSION_TOKEN}' AND creada_en > datetime('now', '-8 hours') LIMIT 1;" 2>/dev/null) || session_data=""
        if [[ -n "$session_data" ]]; then
            IFS=$'\t' read -r CSRF_TOKEN SESSION_USER_ID <<< "$session_data"
        else
            SESSION_TOKEN=""
        fi
    fi

    if [[ -z "$SESSION_TOKEN" ]]; then
        SESSION_TOKEN=$(new_token) || return 1
        CSRF_TOKEN=$(new_token) || return 1
        [[ "$SESSION_TOKEN" =~ ^[[:xdigit:]]{64}$ && "$CSRF_TOKEN" =~ ^[[:xdigit:]]{64}$ ]] || return 1
        ejecutar_sql "INSERT INTO sesiones_web (token, csrf_token) VALUES ('${SESSION_TOKEN}', '${CSRF_TOKEN}');" >/dev/null || return 1
        RESPONSE_COOKIE="inventario_session=${SESSION_TOKEN}; Path=/; HttpOnly; SameSite=Strict"
    fi

    if [[ "$SESSION_USER_ID" =~ ^[0-9]+$ ]]; then
        SESSION_USERNAME=$(ejecutar_sql \
            "SELECT nombre_usuario FROM usuarios WHERE id_usuario = ${SESSION_USER_ID} LIMIT 1;" 2>/dev/null) || SESSION_USERNAME=""
        [[ -n "$SESSION_USERNAME" ]] || SESSION_USER_ID=""
    else
        SESSION_USER_ID=""
    fi
}

rotate_session() {
    local old_token="$SESSION_TOKEN" new_session_token new_csrf_token

    new_session_token=$(new_token) || return 1
    new_csrf_token=$(new_token) || return 1
    [[ "$new_session_token" =~ ^[[:xdigit:]]{64}$ && "$new_csrf_token" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    ejecutar_sql \
        "UPDATE sesiones_web SET token = '${new_session_token}', csrf_token = '${new_csrf_token}', creada_en = datetime('now') WHERE token = '${old_token}';" \
        >/dev/null || return 1
    SESSION_TOKEN="$new_session_token"
    CSRF_TOKEN="$new_csrf_token"
    RESPONSE_COOKIE="inventario_session=${SESSION_TOKEN}; Path=/; HttpOnly; SameSite=Strict"
}

render_header() {
    cat <<'HTML'
<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Inventario</title>
  <style>
    :root { font-family: system-ui, sans-serif; background: #f3f5f7; color: #17212b; }
    body { max-width: 1000px; margin: 2rem auto; padding: 0 1rem; }
    header, section, .card { background: white; border: 1px solid #dce2e7; border-radius: 10px; padding: 1.2rem; margin-bottom: 1rem; }
    h1, h2 { margin-top: 0; } h1 { color: #164e63; }
    form { display: grid; gap: .65rem; margin: .5rem 0; }
    label { font-weight: 600; } input { padding: .6rem; border: 1px solid #aeb9c2; border-radius: 5px; }
    button { padding: .65rem .9rem; border: 0; border-radius: 5px; background: #0e7490; color: white; font-weight: 700; cursor: pointer; }
    button.danger { background: #b42318; } .inline { display: inline-block; vertical-align: middle; margin-right: .4rem; }
    .inline form { display: flex; flex-wrap: wrap; align-items: end; } .inline input { width: 9rem; }
    .notice { padding: .8rem; border-radius: 5px; background: #e6f4ea; margin-bottom: 1rem; }
    .error { background: #fde8e7; } table { width: 100%; border-collapse: collapse; } th, td { padding: .65rem; border-bottom: 1px solid #dce2e7; text-align: left; }
    td.actions { min-width: 300px; } .muted { color: #52616b; }
  </style>
</head>
<body>
<header><h1>Sistema de inventario</h1><p class="muted">Gestión de productos mediante interfaz web.</p></header>
HTML
    if [[ -n "$FLASH_MESSAGE" ]]; then
        printf '<div class="notice %s">%s</div>\n' "$FLASH_KIND" "$(html_escape "$FLASH_MESSAGE")"
    fi
}

render_footer() {
    printf '</body>\n</html>\n'
}

render_login() {
    render_header
    printf '<main class="card"><h2>Iniciar sesión</h2><form method="post" action="/">'
    printf '<input type="hidden" name="csrf" value="%s"><input type="hidden" name="accion" value="login">' "$CSRF_TOKEN"
    cat <<'HTML'
<label for="usuario">Usuario</label>
<input id="usuario" name="usuario" maxlength="80" required autocomplete="username">
<label for="clave">Contraseña</label>
<input id="clave" type="password" name="clave" maxlength="256" required autocomplete="current-password">
<button type="submit">Ingresar</button></form></main>
<main class="card"><h2>Crear usuario</h2><form method="post" action="/">
HTML
    printf '<input type="hidden" name="csrf" value="%s"><input type="hidden" name="accion" value="registro">' "$CSRF_TOKEN"
    cat <<'HTML'
<label for="nuevo-usuario">Nombre de usuario</label>
<input id="nuevo-usuario" name="usuario" maxlength="80" required autocomplete="username">
<label for="nueva-clave">Contraseña</label>
<input id="nueva-clave" type="password" name="clave" maxlength="256" required autocomplete="new-password">
<button type="submit">Crear cuenta</button></form></main>
HTML
    render_footer
}

render_inventory() {
    local filas id nombre centavos

    render_header
    printf '<section><p>Sesión iniciada como <strong>%s</strong>.</p>\n' "$(html_escape "$SESSION_USERNAME")"
    printf '<form method="post" action="/" class="inline"><input type="hidden" name="csrf" value="%s"><input type="hidden" name="accion" value="logout"><button type="submit">Cerrar sesión</button></form></section>\n' "$CSRF_TOKEN"
    cat <<'HTML'
<section><h2>Agregar producto</h2><form method="post" action="/">
HTML
    printf '<input type="hidden" name="csrf" value="%s"><input type="hidden" name="accion" value="alta">' "$CSRF_TOKEN"
    cat <<HTML
<label for="id">ID (0–$((MAX_PRODUCTO- 1)))</label><input id="id" name="id" inputmode="numeric" required>
<label for="nombre">Nombre</label><input id="nombre" name="nombre" maxlength="120" required>
<label for="precio">Precio (ejemplo: 10.50)</label><input id="precio" name="precio" inputmode="decimal" required>
<button type="submit">Agregar</button></form></section>
<section><h2>Inventario</h2><table><thead><tr><th>ID</th><th>Producto</th><th>Precio</th><th>Acciones</th></tr></thead><tbody>
HTML
    if ! filas=$(obtener_productos); then
        printf '<tr><td colspan="4">No se pudo consultar el inventario.</td></tr>\n'
    elif [[ -z "$filas" ]]; then
        printf '<tr><td colspan="4">No hay productos cargados.</td></tr>\n'
    else
        while IFS=$'\t' read -r id nombre centavos; do
            [[ -n "$id" ]] || continue
            printf '<tr><td>%s</td><td>%s</td><td>$%s</td><td class="actions">\n' \
                "$id" "$(html_escape "$nombre")" "$(formatear_precio "$centavos")"
            printf '<form method="post" action="/" class="inline"><input type="hidden" name="csrf" value="%s"><input type="hidden" name="accion" value="editar"><input type="hidden" name="id" value="%s"><input name="nombre" value="%s" maxlength="120" aria-label="Nuevo nombre" required><input name="precio" value="%s" inputmode="decimal" aria-label="Nuevo precio" required><button type="submit">Guardar</button></form>\n' \
                "$CSRF_TOKEN" "$id" "$(html_escape "$nombre")" "$(formatear_precio "$centavos")"
            printf '<form method="post" action="/" class="inline"><input type="hidden" name="csrf" value="%s"><input type="hidden" name="accion" value="baja"><input type="hidden" name="id" value="%s"><button class="danger" type="submit">Eliminar</button></form>\n' "$CSRF_TOKEN" "$id"
            printf '</td></tr>\n'
        done <<< "$filas"
    fi
    printf '</tbody></table></section>\n'
    printf '<section><h2>Reporte</h2><form method="post" action="/">'
    printf '<input type="hidden" name="csrf" value="%s"><input type="hidden" name="accion" value="reporte"><button type="submit">Generar reporte HTML</button></form>' "$CSRF_TOKEN"
    printf '<p><a href="/productos.html">Ver reporte generado</a></p></section>\n'
    render_footer
}

respond() {
    local status="$1" body="$2" content_length
    content_length=$(printf '%s' "$body" | wc -c)
    printf 'HTTP/1.1 %s\r\nContent-Type: text/html; charset=utf-8\r\n' "$status"
    printf 'Content-Length: %s\r\nConnection: close\r\nCache-Control: no-store\r\n' "$content_length"
    printf "X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n"
    printf "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'\r\n"
    [[ -z "$RESPONSE_COOKIE" ]] || printf 'Set-Cookie: %s\r\n' "$RESPONSE_COOKIE"
    printf '\r\n%s' "$body"
}

set_notice() {
    FLASH_MESSAGE="$1"
    FLASH_KIND="$2"
}

process_login() {
    local usuario="${FORM[usuario]:-}" clave="${FORM[clave]:-}" sql_user result hash stored_id stored_hash

    if [[ -z "$usuario" || -z "$clave" || ${#usuario} -gt 80 || ${#clave} -gt 256 ]]; then
        set_notice "Ingrese un usuario y contraseña válidos." error
        return 1
    fi
    sql_user=$(sql_texto "$usuario")
    if ! result=$(ejecutar_sql "SELECT id_usuario || char(9) || hash_contrasena FROM usuarios WHERE nombre_usuario = ${sql_user} LIMIT 1;"); then
        set_notice "No se pudo validar el acceso. Intente nuevamente." error
        return 1
    fi
    IFS=$'\t' read -r stored_id stored_hash <<< "$result"
    if ! hash=$(generar_hash "$clave"); then
        set_notice "No se pudo validar el acceso. Intente nuevamente." error
        return 1
    fi
    clave=""
    if [[ -z "$stored_hash" || "$stored_hash" != "$hash" ]]; then
        registrar_error "Intento de inicio de sesión no válido para el usuario ${usuario}."
        ID_USUARIO="-"
        USUARIO_ACTUAL="$usuario"
        registrar_log "Inicio de sesión fallido" || true
        set_notice "Usuario o contraseña incorrectos." error
        return 1
    fi
    if ! rotate_session; then
        set_notice "No se pudo crear la sesión. Intente nuevamente." error
        return 1
    fi
    ejecutar_sql "UPDATE sesiones_web SET id_usuario = ${stored_id} WHERE token = '${SESSION_TOKEN}';" >/dev/null || return 1
    ID_USUARIO="$stored_id"
    USUARIO_ACTUAL="$usuario"
    registrar_log "Inicio de sesión web" || return 1
    SESSION_USER_ID="$stored_id"
    SESSION_USERNAME="$usuario"
}

process_registration() {
    local usuario="${FORM[usuario]:-}" clave="${FORM[clave]:-}" nombre_sql hash hash_sql estado stored_id

    if [[ -z "$usuario" || "$usuario" == *$'\t'* || "$usuario" == *$'\r'* || "$usuario" == *$'\n'* ||
        ${#usuario} -gt 80 || -z "$clave" || ${#clave} -gt 256 ]]; then
        set_notice "El nombre o la contraseña no cumplen los requisitos." error
        return 1
    fi
    if existe_usuario "$usuario"; then
        set_notice "Ese nombre de usuario ya está registrado." error
        return 1
    else
        estado=$?
        if (( estado == 2 )); then
            set_notice "No se pudo comprobar el usuario. Intente nuevamente." error
            return 1
        fi
    fi
    hash=$(generar_hash "$clave") || {
        set_notice "No se pudo crear la cuenta. Intente nuevamente." error
        return 1
    }
    nombre_sql=$(sql_texto "$usuario")
    hash_sql=$(sql_texto "$hash")
    ejecutar_sql "INSERT INTO usuarios (nombre_usuario, hash_contrasena) VALUES (${nombre_sql}, ${hash_sql});" >/dev/null || {
        set_notice "No se pudo crear la cuenta. Intente nuevamente." error
        return 1
    }
    stored_id=$(ejecutar_sql "SELECT id_usuario FROM usuarios WHERE nombre_usuario = ${nombre_sql} LIMIT 1;") || return 1
    if ! rotate_session; then
        set_notice "La cuenta se creó, pero no se pudo iniciar la sesión." error
        return 1
    fi
    ejecutar_sql "UPDATE sesiones_web SET id_usuario = ${stored_id} WHERE token = '${SESSION_TOKEN}';" >/dev/null || return 1
    ID_USUARIO="$stored_id"
    USUARIO_ACTUAL="$usuario"
    registrar_log "Registro de usuario web" || return 1
    SESSION_USER_ID="$stored_id"
    SESSION_USERNAME="$usuario"
    set_notice "Cuenta creada correctamente." success
}

process_product_action() {
    local action="${FORM[accion]:-}" id_input="${FORM[id]:-}"
    local id nombre="${FORM[nombre]:-}" precio="${FORM[precio]:-}" cents message

    ID_USUARIO="$SESSION_USER_ID"
    USUARIO_ACTUAL="$SESSION_USERNAME"
    case "$action" in
        alta|editar)
            if ! id=$(normalizar_id "$id_input"); then
                registrar_error "${action} web rechazado: formato de ID inválido."
                set_notice "El ID debe ser un número entero entre 0 y $((MAX - 1))." error
                return 1
            fi
            if ! cents=$(convertir_precio_centavos "$precio"); then
                registrar_error "${action} web rechazado: precio inválido."
                set_notice "El precio debe ser no negativo y tener hasta dos decimales." error
                return 1
            fi
            registrar_log "$([[ "$action" == alta ]] && printf 'Alta' || printf 'Edición') de producto web" || return 1
            if [[ "$action" == alta ]]; then
                message=$(alta "$id" "$nombre" "$cents") && set_notice "$message" success || {
                    set_notice "$message" error
                    return 1
                }
            else
                message=$(editar "$id" "$nombre" "$cents") && set_notice "$message" success || {
                    set_notice "$message" error
                    return 1
                }
            fi
            ;;
        baja)
            if ! id=$(normalizar_id "$id_input"); then
                registrar_error "Baja web rechazada: formato de ID inválido."
                set_notice "El ID indicado no es válido." error
                return 1
            fi
            registrar_log "Baja de producto web" || return 1
            message=$(baja "$id") && set_notice "$message" success || {
                set_notice "$message" error
                return 1
            }
            ;;
        reporte)
            registrar_log "Generar reporte HTML web" || return 1
            message=$(reporte) && set_notice "$message" success || {
                set_notice "$message" error
                return 1
            }
            ;;
        *)
            HTTP_STATUS="400 Bad Request"
            set_notice "La operación solicitada no es válida." error
            return 1
            ;;
    esac
}

main() {
    local status body action

    if read_request; then
        :
    else
        status=$?
        case "$status" in
            2) HTTP_STATUS="405 Method Not Allowed" ;;
            *) HTTP_STATUS="400 Bad Request" ;;
        esac
        body=$(render_header; printf '<main class="card"><h2>Solicitud no válida</h2><p>El método o el tamaño no están permitidos.</p></main>\n'; render_footer)
        respond "$HTTP_STATUS" "$body"
        return 0
    fi
    if [[ "$REQUEST_PATH" != "/" && "$REQUEST_PATH" != "/productos.html" ]]; then
        body=$(render_header; printf '<main class="card"><h2>No encontrado</h2></main>\n'; render_footer)
        respond "404 Not Found" "$body"
        return 0
    fi

    if ! load_session; then
        body=$(render_header; printf '<main class="card"><h2>Error interno</h2><p>No se pudo inicializar la sesión.</p></main>\n'; render_footer)
        respond "500 Internal Server Error" "$body"
        return 1
    fi

    if [[ "$REQUEST_METHOD" == POST ]]; then
        if [[ "${FORM[csrf]:-}" != "$CSRF_TOKEN" ]]; then
            HTTP_STATUS="403 Forbidden"
            set_notice "La solicitud expiró o no es válida. Recargue la página." error
        else
            action="${FORM[accion]:-}"
            case "$action" in
                login)
                    if [[ -n "$SESSION_USER_ID" ]]; then
                        set_notice "Ya hay una sesión iniciada." error
                    else
                        process_login || true
                    fi
                    ;;
                registro)
                    if [[ -n "$SESSION_USER_ID" ]]; then
                        set_notice "Cierre la sesión antes de registrar otro usuario." error
                    else
                        process_registration || true
                    fi
                    ;;
                logout)
                    if [[ -n "$SESSION_USER_ID" ]]; then
                        ID_USUARIO="$SESSION_USER_ID"
                        USUARIO_ACTUAL="$SESSION_USERNAME"
                        registrar_log "Cerrar sesión web" || true
                    fi
                    ejecutar_sql "DELETE FROM sesiones_web WHERE token = '${SESSION_TOKEN}';" >/dev/null || true
                    SESSION_USER_ID=""
                    RESPONSE_COOKIE="inventario_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
                    set_notice "Sesión cerrada." success
                    ;;
                *)
                    if [[ -z "$SESSION_USER_ID" ]]; then
                        HTTP_STATUS="401 Unauthorized"
                        set_notice "Inicie sesión para operar con el inventario." error
                    else
                        process_product_action || true
                    fi
                    ;;
            esac
        fi
    fi

    if [[ "$REQUEST_PATH" == "/productos.html" ]]; then
        if [[ -z "$SESSION_USER_ID" ]]; then
            body=$(render_login)
            respond "401 Unauthorized" "$body"
        elif [[ -f "$REPORT_FILE" ]]; then
            body=$(<"$REPORT_FILE")
            respond "200 OK" "$body"
        else
            set_notice "Todavía no se generó el reporte." error
            body=$(render_inventory)
            respond "404 Not Found" "$body"
        fi
    elif [[ -n "$SESSION_USER_ID" ]]; then
        body=$(render_inventory)
        respond "$HTTP_STATUS" "$body"
    else
        body=$(render_login)
        respond "$HTTP_STATUS" "$body"
    fi
}

main
