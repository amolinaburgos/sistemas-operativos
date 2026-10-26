#!/usr/bin/env bash

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
            3)
                registrar_log "Salir" || return 1
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
        printf '4. Editar producto\n'
        printf '5. Generar reporte HTML\n'
        printf '6. Salir\n'
        read -rp 'Opción: ' opcion || break

        case "$opcion" in
            $OPCION_ALTA_PRODUCTO)
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
            $OPCION_BAJA_PRODUCTO)
                registrar_log "Baja de producto" || return 1
                read -rp "Ingrese ID a eliminar (0-$((MAX - 1))): " id_ingresado || return 1
                if ! id=$(normalizar_id "$id_ingresado"); then
                    printf 'Error: ID inválido.\n'
                    registrar_error "Baja rechazada: formato de ID inválido."
                    continue
                fi
                baja "$id"
                ;;
            $OPCION_MOSTRAR_PRODUCTO)
                registrar_log "Mostrar inventario" || return 1
                mostrar
                ;;
            $OPCION_EDITAR_PRODUCTO)
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
            $OPCION_REPORTE_PRODUCTO)
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
