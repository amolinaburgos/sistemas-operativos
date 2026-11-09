#!/bin/bash

# Constantes HTTP
declare HTTP_SERVER_PORT="8081"
declare HTTP_STATIC_PATH="./static"
declare HTTP_DEFAULT_PATH="index.html"
declare HTTP_MAX_REQUEST_BODY_SIZE="524288" # 512 KB (512 * 1024 bytes)
declare SERVER_VERSION="v1.0.0"

# Variables para alojar los datos correspondientes a la petición de entrada al servidor
declare -Ag HTTP_REQUEST_HEADERS
declare HTTP_REQUEST_METHOD
declare HTTP_REQUEST_PATH
declare HTTP_REQUEST_PROTOCOL
declare HTTP_REQUEST_BODY
declare HTTP_REQUEST_FILEPATH

# Variables para alojar los datos correspondientes a la respuesta de salida del servidor
declare HTTP_RESPONSE_STATUS
declare -Ag HTTP_RESPONSE_HEADERS
declare HTTP_RESPONSE_BODY
declare HTTP_RESPONSE_IS_PATH=false

# Variables de control de Handlers RPC
declare -A RPC_PUBLIC_HANDLER
declare -A RPC_PRIVATE_HANDLER

# Variables desglosadas para la Petición RPC (Request)
declare RPC_REQUEST_OBJECT
declare RPC_REQUEST_ID="null"
declare RPC_REQUEST_METHOD
declare RPC_REQUEST_PARAMS="null"
declare RPC_JSONRPC

# Variables desglosadas para la Respuesta RPC (Response)
declare RPC_RESPONSE_OBJECT
declare RPC_RESPONSE_ID="null"
declare RPC_RESPONSE_RESULT
declare RPC_RESPONSE_JSONRPC="2.0"
declare RPC_RESPONSE_ERROR

# --- Funciones de Utilidad HTTP ---

function http_set_status() {
    local code="$1"
    HTTP_RESPONSE_STATUS="HTTP/1.1 $code"
}

function http_set_header() {
    local name="$1"
    local value="$2"
    HTTP_RESPONSE_HEADERS["$name"]="$value"
}

function http_set_body() {
    if [[ "$1" == "--path" ]]; then
        HTTP_RESPONSE_BODY="${2:-$HTTP_REQUEST_FILEPATH}"
        HTTP_RESPONSE_IS_PATH=true
    else
        HTTP_RESPONSE_BODY="$1"
        HTTP_RESPONSE_IS_PATH=false
    fi
}

function file_mimetype() {
    local filepath="$1"
    local mime_type

    # Mapeo explícito de tipos MIME de archivos binarios comunes para la web
    case "$filepath" in
	*.html|*.htm) echo "text/html" && return ;;
        *.css)        echo "text/css" && return ;;
        *.js|*.mjs)   echo "application/javascript" && return ;;
        *.json)       echo "application/json" && return ;;
        *.xml)        echo "application/xml" && return ;;
        *.svg)        echo "image/svg+xml" && return ;;
        *.ico)        echo "image/x-icon" && return ;;
        *.png)        echo "image/png" && return ;;
        *.jpg|*.jpeg) echo "image/jpeg" && return ;;
        *.gif)        echo "image/gif" && return ;;
        *.webp)       echo "image/webp" && return ;;
	#agregue casos para que me funcione
    esac

    # Obtención del tipo MIME base mediante xdg-mime para el resto de archivos
    mime_type=$(xdg-mime query filetype "$filepath" 2>/dev/null || echo "application/octet-stream")

    # Garantizar charset=utf-8 en tipos textuales y formatos basados en texto
    case "$mime_type" in
        text/*|application/javascript|application/json|application/xml|image/svg+xml)
            if [[ "$mime_type" != *"; charset="* ]]; then
                mime_type="${mime_type}; charset=utf-8"
            fi
            ;;
    esac

    echo "$mime_type"
}

# --- Respuestas API JSON-RPC (POST) ---

function rpc_success() {
    local data="$1"
    local req_id="${2:-$RPC_REQUEST_ID}"

    [[ -z "$req_id" ]] && req_id="null"

    if ! jq . >/dev/null 2>&1 <<< "$data"; then
        data=$(jq -nc --arg d "$data" '$d')
    fi

    RPC_RESPONSE_ID="$req_id"
    RPC_RESPONSE_JSONRPC="2.0"
    RPC_RESPONSE_RESULT="$data"
    RPC_RESPONSE_ERROR=""
}

function rpc_error() {
    local code=$1
    local message="$2"
    local details="${3:-null}"
    local req_id="${4:-$RPC_REQUEST_ID}"

    [[ -z "$req_id" ]] && req_id="null"

    if [[ "$details" != "null" ]] && ! jq . >/dev/null 2>&1 <<< "$details"; then
        details=$(jq -nc --arg d "$details" '$d')
    fi

    RPC_RESPONSE_ID="$req_id"
    RPC_RESPONSE_JSONRPC="2.0"
    RPC_RESPONSE_RESULT=""
    RPC_RESPONSE_ERROR=$(jq -nc \
        --argjson code "$code" \
        --arg msg "$message" \
        --argjson data "$details" \
        '{code: $code, message: $msg, data: $data}')
}

# --- Respuestas Servidor Estático de Archivos (GET) ---

function http_not_found() {
    http_set_status 404
    http_set_header "Content-Type" "text/plain; charset=utf-8"
    local body="404 Not Found: El archivo solicitado no existe."
    http_set_header "Content-Length" "${#body}"
    http_set_body "$body"
}

# --- Controladores de Errores RPC Estándar ---

function rpc_bad_request() {
    rpc_error -32600 "Invalid Request" "Missing RPC method"
}

function rpc_not_found() {
    rpc_error -32601 "Method not found" "RPC method not found"
}

function rpc_not_allowed() {
    rpc_error -32005 "Method Not Allowed" "The requested HTTP method is not supported."
}

# --- Registro de Handlers RPC ---

function rpc_load_registry()
{
    RPC_PUBLIC_HANDLER['saludar']='saludar'
}

function saludar()
{
    rpc_success "Saludos desde el servidor en bash!"
}

# --- Ciclo de Procesamiento (Flujo Main) ---

function http_load_headers()
{
    unset HTTP_REQUEST_HEADERS
    declare -gA HTTP_REQUEST_HEADERS 2>/dev/null || declare -A HTTP_REQUEST_HEADERS

    HTTP_RESPONSE_BODY=""
    HTTP_RESPONSE_STATUS=""
    HTTP_RESPONSE_IS_PATH=false
    HTTP_REQUEST_METHOD=""
    HTTP_REQUEST_PATH=""
    HTTP_REQUEST_PROTOCOL=""
    HTTP_REQUEST_FILEPATH=""

    read -r HTTP_REQUEST_METHOD HTTP_REQUEST_PATH HTTP_REQUEST_PROTOCOL
    HTTP_REQUEST_PROTOCOL="${HTTP_REQUEST_PROTOCOL%$'\r'}"

    local line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && break

        local key="${line%%:*}"
        key="${key^^}"
        local value="${line#*: }"
        HTTP_REQUEST_HEADERS["$key"]="$value"
    done
}

function http_load_request()
{
    HTTP_REQUEST_BODY=""
    local length="${HTTP_REQUEST_HEADERS[CONTENT-LENGTH]:-0}"

    if [[ "$length" -gt 0 ]]; then
        if [[ "$length" -gt "$HTTP_MAX_REQUEST_BODY_SIZE" ]]; then
            read -N "$HTTP_MAX_REQUEST_BODY_SIZE" -r HTTP_REQUEST_BODY
        else
            read -N "$length" -r HTTP_REQUEST_BODY
        fi
    fi
}

function rpc_load_request()
{
    RPC_REQUEST_OBJECT=""
    RPC_REQUEST_ID="null"
    RPC_REQUEST_METHOD=""
    RPC_REQUEST_PARAMS="null"
    RPC_JSONRPC=""

    RPC_RESPONSE_OBJECT=""
    RPC_RESPONSE_ID="null"
    RPC_RESPONSE_RESULT=""
    RPC_RESPONSE_JSONRPC="2.0"
    RPC_RESPONSE_ERROR=""

    if [[ "$HTTP_REQUEST_METHOD" == "POST" && -n "$HTTP_REQUEST_BODY" ]]; then
        if jq . >/dev/null 2>&1 <<< "$HTTP_REQUEST_BODY"; then
            RPC_REQUEST_OBJECT="$HTTP_REQUEST_BODY"
            RPC_JSONRPC=$(jq -r '.jsonrpc // ""' <<< "$RPC_REQUEST_OBJECT" 2>/dev/null)
            RPC_REQUEST_METHOD=$(jq -r '.method // ""' <<< "$RPC_REQUEST_OBJECT" 2>/dev/null)
            RPC_REQUEST_ID=$(jq -c '.id // null' <<< "$RPC_REQUEST_OBJECT" 2>/dev/null)
            RPC_REQUEST_PARAMS=$(jq -c '.params // null' <<< "$RPC_REQUEST_OBJECT" 2>/dev/null)
        fi
    fi
}

function http_process_request()
{
    if [[ "$HTTP_REQUEST_METHOD" == "GET" ]]; then
        local req_path="$HTTP_REQUEST_PATH"
        
        [[ "$req_path" == "/" ]] && req_path="/${HTTP_DEFAULT_PATH#/}"

        local target_file="${HTTP_STATIC_PATH}${req_path}"

        # Prevención de Path Traversal
        local canonical_file
        canonical_file=$(realpath -m "$target_file" 2>/dev/null)
        local canonical_root
        canonical_root=$(realpath -m "$HTTP_STATIC_PATH" 2>/dev/null)

        if [[ -f "$canonical_file" && "$canonical_file" == "$canonical_root"* ]]; then
            HTTP_REQUEST_FILEPATH="$canonical_file"

            local mime_type
            mime_type=$(file_mimetype "$HTTP_REQUEST_FILEPATH")
            http_set_header "Content-Type" "$mime_type"

            # Calcular tamaño de archivo estático
            local file_size
            file_size=$(stat -c%s "$HTTP_REQUEST_FILEPATH" 2>/dev/null || wc -c < "$HTTP_REQUEST_FILEPATH")
            http_set_header "Content-Length" "$file_size"

            http_set_status 200
            http_set_body --path "$HTTP_REQUEST_FILEPATH"
        else
            http_not_found
        fi
    fi
}

function rpc_process_request()
{
    if [[ "$HTTP_REQUEST_METHOD" == "POST" ]]; then
        if [[ -z "$RPC_REQUEST_METHOD" ]]; then
            rpc_bad_request
            return
        fi

        local handler="${RPC_PUBLIC_HANDLER[$RPC_REQUEST_METHOD]:-}"
        if [[ -n "$handler" ]]; then
            "$handler"
            return
        fi

        handler="${RPC_PRIVATE_HANDLER[$RPC_REQUEST_METHOD]:-}"
        if [[ -n "$handler" ]]; then
            "$handler"
            return
        fi

        rpc_not_found
        return
    fi

    if [[ "$HTTP_REQUEST_METHOD" != "GET" && "$HTTP_REQUEST_METHOD" != "POST" ]]; then
        rpc_not_allowed
    fi
}

function rpc_load_response()
{
    if [[ -n "$RPC_RESPONSE_RESULT" || -n "$RPC_RESPONSE_ERROR" ]]; then
        http_set_status 200
        http_set_header "Content-Type" "application/json"

        local req_id="${RPC_RESPONSE_ID:-null}"
        local jsonrpc="${RPC_RESPONSE_JSONRPC:-2.0}"

        if [[ -n "$RPC_RESPONSE_ERROR" ]]; then
            RPC_RESPONSE_OBJECT=$(jq -nc \
                --arg jsonrpc "$jsonrpc" \
                --argjson error "$RPC_RESPONSE_ERROR" \
                --argjson id "$req_id" \
                '{jsonrpc: $jsonrpc, error: $error, id: $id}')
        else
            RPC_RESPONSE_OBJECT=$(jq -nc \
                --arg jsonrpc "$jsonrpc" \
                --argjson result "$RPC_RESPONSE_RESULT" \
                --argjson id "$req_id" \
                '{jsonrpc: $jsonrpc, result: $result, id: $id}')
        fi

        http_set_header "Content-Length" "${#RPC_RESPONSE_OBJECT}"
        http_set_body "$RPC_RESPONSE_OBJECT"
    fi
}

function http_send_headers()
{
    # Centralización de cierre de conexión socket para socat
    http_set_header "Connection" "close"

    printf "%s\r\n" "$HTTP_RESPONSE_STATUS"

    local key
    for key in "${!HTTP_RESPONSE_HEADERS[@]}"; do
        printf "%s: %s\r\n" "$key" "${HTTP_RESPONSE_HEADERS[$key]}"
    done
    printf "\r\n"
}

function http_send_response()
{
    if [[ "$HTTP_RESPONSE_IS_PATH" == true && -f "$HTTP_RESPONSE_BODY" ]]; then
        cat "$HTTP_RESPONSE_BODY"
    else
        printf "%s" "$HTTP_RESPONSE_BODY"
    fi
}

# --- Gestión de Ayuda y Dependencias CLI ---

function main_show_help() {
    echo "Uso: $0 [OPCIONES]"
    echo ""
    echo "Opciones disponibles:"
    echo "  --check            Verifica si las dependencias requeridas están instaladas."
    echo "  --handle-request   Ejecuta el manejador de petición solicitado. (Sólo para pruebas)."
    echo "  -h, --help         Muestra esta ayuda."
    echo "  -v, --version      Muestra la versión del servidor."
    echo ""
    echo "Default: El servidor se inicia en modo escucha en http://localhost:$HTTP_SERVER_PORT"
}

function main_check_dependencies() {
    local deps=("socat" "jq" "xdg-mime" "realpath")
    local cmd

    echo "Verificando dependencias del servidor:"
    for cmd in "${deps[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            printf "  - %-10s (OK)\n" "$cmd"
        else
            printf "  - %-10s (No encontrada)\n" "$cmd"
        fi
    done
}

# --- Dispatcher Principal ---

function main_dispatch() {
    rpc_load_registry

    if [[ $# -eq 0 ]]; then
        printf "Sistemas Operativos (ISFT Nº 151) %s\n" "$SERVER_VERSION"
        printf "JSON/RPC 2.0 WebAPI escuchando en http://localhost:%s...\n" "$HTTP_SERVER_PORT"
        socat TCP-LISTEN:"$HTTP_SERVER_PORT",reuseaddr,fork EXEC:"$0 --handle-request"
        return
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --handle-request)
                http_load_headers
                http_load_request
                rpc_load_request
                http_process_request
                rpc_process_request
                rpc_load_response
                http_send_headers
                http_send_response
                exit 0
                ;;
            --check)
                main_check_dependencies
                exit 0
                ;;
            -h|--help)
                main_show_help
                exit 0
                ;;
            -v|--version)
                echo "$SERVER_VERSION"
                exit 0
                ;;
            *)
                echo "Opción desconocida: $1"
                exit 1
                ;;
        esac
        shift
    done
}

main_dispatch "$@"
