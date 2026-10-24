#!/usr/bin/env bash

# declare/typeset -r (read.only) -i (integer)

declare -r -i MAX_PRODUCTO=10
declare -A inventario
#-A (Associative): Le indica a la shell que el arreglo inventario no va a usar índices numéricos
#secuenciales tradicionales (0, 1, 2...), sino claves de texto (strings).

declare -r -i OPCION_ALTA_PRODUCTO=1
declare -r -i OPCION_BAJA_PRODUCTO=2
declare -r -i OPCION_MOSTRAR_PRODUCTO=3
declare -r -i OPCION_EDITAR_PRODUCTO=4
declare -r -i OPCION_SALIR=5

bienvenida() {
    printf "Bienvenido/a al sistema\n\n"
}

autenticar() {
    declare -i intentos=0
    declare clave=""

#-rp (-p (Prompt / Mensaje): Permite mostrar un mensaje de aviso directamente en la consola
#todo en la misma línea y sin necesidad de usar un echo previo.

    while (( intentos < 3 )); do
        read -rp "Ingrese clave (1234): " clave

        if [[ "$clave" == "1234" ]]; then
            printf "Acceso concedido.\n"
            return 0
        fi

        intentos=$((intentos + 1))
        printf "Clave incorrecta (%d/3 intentos).\n" "$intentos"
    done

    return 1
}

alta() {
    declare -i id=$1
    declare -n prod_ref=$2

    if (( id < 0 || id >= MAX_PRODUCTO )); then
        printf "Error: ID fuera de rango.\n"
        return
    fi

    inventario[$id,precio]=${prod_ref[precio]}
    inventario[$id,activo]=${prod_ref[activo]}


# $%.2f.   doble/float
    printf "Producto %d guardado con precio $%.2f.\n" "$id" "${prod_ref[precio]}"
}

baja() {
    declare -i id=$1

    if (( id < 0 || id >= MAX_PRODUCTO )); then
        printf "Error: ID fuera de rango.\n"
        return
    fi

    if [[ ${inventario[$id,activo]} -eq 1 ]]; then
        inventario[$id,activo]=0
        printf "Producto %d eliminado.\n" "$id"
    else
        printf "El producto no existe.\n"
    fi
}

editar() {
    declare -i id=$1
    declare -n prod_ref=$2

    if (( id < 0 || id >= MAX_PRODUCTO )); then
        printf "Error: ID fuera de rango.\n"
        return
    fi

    # Validación adicional: no se puede editar un producto que no existe
    if [[ ${inventario[$id,activo]} -eq 0 ]]; then
        printf "Error: El producto no existe o está dado de baja.\n"
        return
    fi

    inventario[$id,precio]=${prod_ref[precio]}
    printf "Producto %d actualizado con nuevo precio $%.2f.\n" "$id" "${prod_ref[precio]}"
}

mostrar() {
    declare -i i=0

    printf "\nLISTADO:\n"
    for ((i=0; i<MAX_PRODUCTO; i++)); do
        if [[ ${inventario[$i,activo]} -eq 1 ]]; then
            printf "ID %d : $%.2f\n" "$i" "${inventario[$i,precio]}"
#  %d: decimal entero.
        fi
    done
}

main() {
    declare -i i=0

    for ((i=0; i<MAX_PRODUCTO; i++)); do
        inventario[$i,activo]=0
        inventario[$i,precio]=0
    done

    bienvenida

    if ! autenticar; then
        printf "\nAcceso denegado.\n"
        return 1
    fi

    declare opcion=0
    declare -i id=0
    declare -A p_temp

    while [[ "$opcion" != "$OPCION_SALIR" ]]; do
        printf "\nACCIONES:\n"
        printf "1. Alta producto (ID 0 a %d)\n" $((MAX - 1))
        printf "2. Baja producto\n"
        printf "3. Mostrar inventario\n"
        printf "4. Editar producto\n"
        printf "5. Salir\n"
        read -rp "Opcion: " opcion

        case $opcion in
            $OPCION_ALTA_PRODUCTO)
                read -rp "Ingrese ID (0-$((MAX - 1))): " id
                read -rp "Ingrese Precio: " p_temp[precio]
                p_temp[activo]=1
                alta "$id" p_temp
                ;;
            $OPCION_BAJA_PRODUCTO)
                read -rp "Ingrese ID a eliminar (0-$((MAX - 1))): " id
                baja "$id"
                ;;
            $OPCION_MOSTRAR_PRODUCTO)
                mostrar
                ;;
            $OPCION_EDITAR_PRODUCTO)
                read -rp "Ingrese ID a editar (0-$((MAX - 1))): " id
                read -rp "Ingrese nuevo Precio: " p_temp[precio]
                editar "$id" p_temp
                ;;
            $OPCION_SALIR)
                printf "\nSaliendo del programa...\n"
                ;;
            *)
                printf "\nOpcion invalida.\n"
                ;;
        esac
    done

    return 0
}

main
