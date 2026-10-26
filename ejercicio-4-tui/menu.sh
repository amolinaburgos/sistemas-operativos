#!/usr/bin/env bash

TUI_TITLE="Sistema de inventario"

tui_mensaje() {
    local mensaje="$1" estado

    if whiptail --title "$TUI_TITLE" --msgbox "$mensaje" 10 70; then
        return 0
    else
        estado=$?
        if (( estado == 255 )); then
            return 0
        fi
        return "$estado"
    fi
}

tui_confirmar() {
    local mensaje="$1" estado

    if whiptail --title "$TUI_TITLE" --yesno "$mensaje" 10 70; then
        return 0
    else
        estado=$?
        case "$estado" in
            1|255) return 1 ;;
            *) return "$estado" ;;
        esac
    fi
}

tui_menu_acceso() {
    local opcion usuario clave respuesta intentos estado

    while true; do
        if opcion=$(whiptail --title "$TUI_TITLE" \
            --menu "Seleccione una opción para continuar:" 14 70 3 \
            "1" "Iniciar sesión" \
            "2" "Registrar usuario" \
            "3" "Salir" \
            3>&1 1>&2 2>&3); then
            :
        else
            estado=$?
            case "$estado" in
                1|255) return 10 ;;
                *) return "$estado" ;;
            esac
        fi

        case "$opcion" in
            1)
                for ((intentos = 1; intentos <= 3; intentos++)); do
                    if ! usuario=$(whiptail --title "$TUI_TITLE" \
                        --inputbox "Ingrese su nombre de usuario:" 10 70 \
                        3>&1 1>&2 2>&3); then
                        break
                    fi
                    if ! clave=$(whiptail --title "$TUI_TITLE" \
                        --passwordbox "Ingrese la contraseña de $usuario:" 10 70 \
                        3>&1 1>&2 2>&3); then
                        break
                    fi

                    if autenticar "$usuario" "$clave" >/dev/null; then
                        tui_mensaje "Acceso concedido. Bienvenido/a, $usuario." || return 1
                        return 0
                    fi
                    clave=""
                    tui_mensaje "Usuario o contraseña incorrectos. Intento ${intentos} de 3." || return 1
                done
                ;;
            2)
                if ! usuario=$(whiptail --title "$TUI_TITLE" \
                    --inputbox "Elija un nombre de usuario:" 10 70 \
                    3>&1 1>&2 2>&3); then
                    continue
                fi
                if ! clave=$(whiptail --title "$TUI_TITLE" \
                    --passwordbox "Elija una contraseña para $usuario:" 10 70 \
                    3>&1 1>&2 2>&3); then
                    continue
                fi

                if respuesta=$(registrar_usuario "$usuario" "$clave" 2>&1); then
                    tui_mensaje "$respuesta" || return 1
                else
                    tui_mensaje "$respuesta" || return 1
                fi
                clave=""
                ID_USUARIO="-"
                USUARIO_ACTUAL="-"
                ;;
            3)
                registrar_log "Salir" || return 1
                tui_mensaje "Saliendo del programa..." || return 1
                return 10
                ;;
        esac
    done
}

tui_obtener_filas() {
    ejecutar_sql 'SELECT id_producto, nombre, precio_centavos FROM productos ORDER BY id_producto;'
}

tui_seleccionar_producto() {
    local filas id nombre centavos
    local -a opciones=()

    if ! filas=$(tui_obtener_filas); then
        return 2
    fi

    while IFS=$'\t' read -r id nombre centavos; do
        [[ -n "$id" ]] || continue
        opciones+=("$id" "$nombre - \$$(formatear_precio "$centavos")")
    done <<< "$filas"

    if (( ${#opciones[@]} == 0 )); then
        tui_mensaje "No hay productos en el inventario."
        return 1
    fi

    if TUI_PRODUCTO_ID=$(whiptail --title "$TUI_TITLE" \
        --menu "Seleccione un producto:" 20 76 12 \
        "${opciones[@]}" 3>&1 1>&2 2>&3); then
        return 0
    else
        return $?
    fi
}

tui_mostrar_inventario() {
    local filas id nombre centavos listado linea
    local hay_productos=0

    if ! filas=$(tui_obtener_filas); then
        return 1
    fi

    printf -v listado '%-5s %-28s %10s\n' "ID" "PRODUCTO" "PRECIO"
    listado+="------------------------------------------------"$'\n'
    while IFS=$'\t' read -r id nombre centavos; do
        [[ -n "$id" ]] || continue
        printf -v linea '%-5s %-28s $%10s' \
            "$id" "$nombre" "$(formatear_precio "$centavos")"
        listado+="${linea}"$'\n'
        hay_productos=1
    done <<< "$filas"

    if (( hay_productos == 0 )); then
        listado+="(No hay productos cargados.)"
    fi
    tui_mensaje "$listado"
}

tui_alta_producto() {
    local id_ingresado id nombre precio centavos respuesta

    if ! id_ingresado=$(whiptail --title "$TUI_TITLE" \
        --inputbox "Ingrese un ID entre 0 y $((MAX - 1)):" 10 70 \
        3>&1 1>&2 2>&3); then
        return 0
    fi
    if ! nombre=$(whiptail --title "$TUI_TITLE" \
        --inputbox "Ingrese el nombre del producto:" 10 70 \
        3>&1 1>&2 2>&3); then
        return 0
    fi
    if ! precio=$(whiptail --title "$TUI_TITLE" \
        --inputbox "Ingrese el precio (por ejemplo, 10.50 o 10,50):" 10 70 \
        3>&1 1>&2 2>&3); then
        return 0
    fi

    if ! id=$(normalizar_id "$id_ingresado"); then
        registrar_error "Alta rechazada: formato de ID inválido."
        tui_mensaje "Error: el ID ingresado no es válido."
        return
    fi
    if ! centavos=$(convertir_precio_centavos "$precio"); then
        registrar_error "Alta rechazada: precio inválido."
        tui_mensaje "Error: ingrese un precio no negativo con hasta dos decimales."
        return
    fi

    if respuesta=$(alta "$id" "$nombre" "$centavos"); then
        tui_mensaje "$respuesta"
    else
        tui_mensaje "$respuesta"
    fi
}

tui_baja_producto() {
    local id respuesta estado

    if tui_seleccionar_producto; then
        :
    else
        estado=$?
        (( estado == 2 )) && return 1
        return 0
    fi
    id="$TUI_PRODUCTO_ID"

    if tui_confirmar "¿Desea eliminar el producto con ID $id?"; then
        :
    else
        estado=$?
        (( estado > 1 )) && return "$estado"
        return 0
    fi

    registrar_log "Baja de producto" || return 1
    if respuesta=$(baja "$id"); then
        tui_mensaje "$respuesta"
    else
        tui_mensaje "$respuesta"
    fi
}

tui_editar_producto() {
    local id fila nombre_actual centavos_actual nombre precio centavos respuesta estado

    if tui_seleccionar_producto; then
        :
    else
        estado=$?
        (( estado == 2 )) && return 1
        return 0
    fi
    id="$TUI_PRODUCTO_ID"

    if ! fila=$(ejecutar_sql \
        "SELECT nombre || char(9) || precio_centavos FROM productos WHERE id_producto = ${id};"); then
        return 1
    fi
    IFS=$'\t' read -r nombre_actual centavos_actual <<< "$fila"

    if ! nombre=$(whiptail --title "$TUI_TITLE" \
        --inputbox "Ingrese el nuevo nombre:" 10 70 "$nombre_actual" \
        3>&1 1>&2 2>&3); then
        return 0
    fi
    if ! precio=$(whiptail --title "$TUI_TITLE" \
        --inputbox "Ingrese el nuevo precio:" 10 70 "$(formatear_precio "$centavos_actual")" \
        3>&1 1>&2 2>&3); then
        return 0
    fi
    if ! centavos=$(convertir_precio_centavos "$precio"); then
        registrar_error "Edición rechazada: precio inválido."
        tui_mensaje "Error: ingrese un precio no negativo con hasta dos decimales."
        return
    fi

    registrar_log "Edición de producto" || return 1
    if respuesta=$(editar "$id" "$nombre" "$centavos"); then
        tui_mensaje "$respuesta"
    else
        tui_mensaje "$respuesta"
    fi
}

tui_generar_reporte() {
    local respuesta

    registrar_log "Generar reporte HTML" || return 1
    if respuesta=$(reporte); then
        tui_mensaje "$respuesta"
    else
        tui_mensaje "$respuesta"
    fi
}

menu_inventario() {
    local opcion estado

    while true; do
        if opcion=$(whiptail --title "$TUI_TITLE" \
            --menu "Bienvenido/a, $USUARIO_ACTUAL. Seleccione una operación:" 18 76 6 \
            "1" "Alta de producto" \
            "2" "Baja de producto" \
            "3" "Mostrar inventario" \
            "4" "Editar producto" \
            "5" "Generar reporte HTML" \
            "6" "Cerrar sesión y salir" \
            3>&1 1>&2 2>&3); then
            :
        else
            estado=$?
            case "$estado" in
                1|255)
                    registrar_log "Salir" || return 1
                    tui_mensaje "Saliendo del programa..." || return 1
                    return 0
                    ;;
                *) return "$estado" ;;
            esac
        fi

        case "$opcion" in
            1) registrar_log "Alta de producto" || return 1; tui_alta_producto ;;
            2) tui_baja_producto ;;
            3) registrar_log "Mostrar inventario" || return 1; tui_mostrar_inventario ;;
            4) tui_editar_producto ;;
            5) tui_generar_reporte ;;
            6)
                registrar_log "Salir" || return 1
                tui_mensaje "Saliendo del programa..."
                return 0
                ;;
        esac
    done
}

main() {
    if ! command -v whiptail >/dev/null 2>&1; then
        printf 'Error: la interfaz TUI requiere whiptail instalado y disponible en PATH.\n' >&2
        registrar_error "No se encontró el ejecutable whiptail."
        return 1
    fi
    if [[ ! -t 0 || ! -t 1 || ! -t 2 ]]; then
        printf 'Error: ejecute el programa desde una terminal interactiva.\n' >&2
        registrar_error "La interfaz TUI requiere una terminal interactiva."
        return 1
    fi

    inicializar_base_datos || return 1
    if tui_mensaje "Bienvenido/a al sistema de inventario."; then
        :
    else
        return 1
    fi

    if tui_menu_acceso; then
        menu_inventario
    else
        local estado=$?
        if (( estado == 10 )); then
            return 0
        fi
        return "$estado"
    fi
}
