# 3. Modificar el código de modo tal que ahora cuando inicie el script aparezcan dos opciones "Iniciar sesión" y "Registrar usuario". 
# La autenticación de usuarios ya no deberá trabajar de forma "hard-codeada" de prueba. El listado de usuarios/contraseñas deberá estar
# en un archivo TSV llamado usuarios.tsv y no podrá exponer las contraseñas de manera abierta. Deberán guardarse de forma cifrada mediante
# cifrado sha256 empleando el comando sha256sum. La funcionalidad de registrar usuario permite dar de alta usuarios solicitando un nombre de
#usuario y contraseña impactando los cambios en el archivo correspondiente. En todos los casos deberá validar de no agregar un usuario ya existente.
# Datos útiles:
# Subcadenas de string:  sub=${ cadena:3:8 }   //Extrae entre el caracter 3 y 8.
# Redirección a buffer/variable:   valor=$(echo "1234")   //Guarda la salida estándar en la variable valor

#!/usr/bin/env bash

declare -r -i MAX=3
declare -A inventario
declare -r ARCHIVO_PERSISTENCIA="productos.tsv"
declare -r ARCHIVO_USUARIOS="usuarios.tsv"

declare -r -i OPCION_ALTA=1
declare -r -i OPCION_BAJA=2
declare -r -i OPCION_MOSTRAR=3
declare -r -i OPCION_REPORTE=4
declare -r -i OPCION_SALIR=5

bienvenida() {
    printf "Bienvenido/a al sistema\n\n"
}

# Genera el hash SHA-256 de una cadena empleando sha256sum y extrayendo la subcadena
generar_hash() {
    declare texto="$1"
    declare salida
    salida=$(echo -n "$texto" | sha256sum)
    # Extrae los primeros 64 caracteres correspondientes al hash
    printf "%s" "${salida:0:64}"
}

# Verifica si un usuario ya existe en usuarios.tsv
existe_usuario() {
    declare usr_buscar="$1"
    if [[ ! -f "$ARCHIVO_USUARIOS" ]]; then
        return 1
    fi

    declare usr hash
    while IFS=$'\t' read -r usr hash; do
        if [[ "$usr" == "$usr_buscar" ]]; then
            return 0 # Existe
        fi
    done < "$ARCHIVO_USUARIOS"

    return 1 # No existe
}

# Permite registrar un nuevo usuario en usuarios.tsv con la contraseña cifrada
registrar_usuario() {
    declare usuario=""
    declare clave=""

    printf "\n--- REGISTRO DE USUARIO ---\n"
    read -rp "Ingrese nombre de usuario: " usuario

    if [[ -z "$usuario" ]]; then 
        printf "Error: El nombre de usuario no puede estar vacio.\n"
        return
    fi

    # Validar que el usuario no exista
    if existe_usuario "$usuario"; then
        printf "Error: El usuario '%s' ya se encuentra registrado.\n" "$usuario"
        return
    fi

    read -sp "Ingrese contraseña: " clave
    printf "\n"

    if [[ -z "$clave" ]]; then
        printf "Error: La contraseña no puede estar vacia.\n"
        return
    fi

    declare hash_clave
    hash_clave=$(generar_hash "$clave")

    # Guardar en usuarios.tsv
    printf "%s\t%s\n" "$usuario" "$hash_clave" >> "$ARCHIVO_USUARIOS"
    printf "Usuario '%s' registrado con exito.\n" "$usuario"
}

# Valida las credenciales ingresadas contra usuarios.tsv
autenticar() {
    if [[ ! -f "$ARCHIVO_USUARIOS" ]]; then
        printf "\nError: No hay usuarios registrados. Por favor registre un usuario primero.\n"
        return 1
    fi

    declare -i intentos=0
    declare usuario=""
    declare clave=""

    printf "\n--- INICIO DE SESIÓN ---\n"
    while (( intentos < 3 )); do
        read -rp "Usuario: " usuario
        read -sp "Contraseña: " clave
        printf "\n"

        declare hash_ingresado
        hash_ingresado=$(generar_hash "$clave")

        declare usr hash_guardado
        declare -i autenticado=0

        while IFS=$'\t' read -r usr hash_guardado; do
            if [[ "$usr" == "$usuario" && "$hash_guardado" == "$hash_ingresado" ]]; then
                autenticado=1
                break
            fi
        done < "$ARCHIVO_USUARIOS" #buscar -z sp rp

        if (( autenticado == 1 )); then
            printf "Acceso concedido. Bienvenido/a, %s.\n" "$usuario"
            return 0
        fi

        intentos=$((intentos + 1))
        printf "Usuario o contraseña incorrectos (%d/3 intentos).\n" "$intentos"
    done

    return 1
}

# Menú de entrada previo al acceso al sistema de productos
menu_acceso() {
    declare opcion=0

    while true; do
        printf "\n--- ACCESO AL SISTEMA ---\n"
        printf "1. Iniciar sesion\n"
        printf "2. Registrar usuario\n"
        printf "3. Mostrar\n"
	printf "4. Reporte\n"
	printf "5. Salir\n"
        read -rp "Opcion: " opcion

        case $opcion in
            1)
                if autenticar; then
                    return 0 # Login exitoso, se procede al inventario
                fi
                ;;
            2)
                registrar_usuario
                ;;
	    3)
		mostrar
                ;;
            4)
                reporte
                ;;
            5)
                printf "\nSaliendo del programa...\n"
                exit 0
                ;;
            *)
                printf "\nOpcion invalida.\n"
                ;;
        esac
    done
}

cargar_desde_tsv() {
    if [[ ! -f "$ARCHIVO_PERSISTENCIA" ]]; then
        touch "$ARCHIVO_PERSISTENCIA"
        return
    fi

    declare id nombre precio activo

    while IFS=$'\t' read -r id nombre precio activo; do
        if [[ -n "$id" && "$id" =~ ^[0-9]+$ ]] && (( id >= 0 && id < MAX )); then
            inventario[$id,nombre]="$nombre"
            inventario[$id,precio]="$precio"
            inventario[$id,activo]="$activo"
        fi
    done < "$ARCHIVO_PERSISTENCIA"
}

guardar_en_tsv() {
    declare -i i=0

    {
        for ((i=0; i<MAX; i++)); do
            if [[ ${inventario[$i,activo]} -eq 1 ]]; then
                printf "%d\t%s\t%.2f\t%d\n" "$i" "${inventario[$i,nombre]}" "${inventario[$i,precio]}" "${inventario[$i,activo]}"
            fi
        done
    } > "$ARCHIVO_PERSISTENCIA"
}

existe_nombre() {
    declare nombre_buscar="$1"
    declare -i i=0

    for ((i=0; i<MAX; i++)); do
        if [[ ${inventario[$i,activo]} -eq 1 ]]; then
            if [[ "${inventario[$i,nombre],,}" == "${nombre_buscar,,}" ]]; then
                return 0
            fi
        fi
    done
    return 1
}

alta() {
    declare -i id=$1
    declare -n prod_ref=$2

    if (( id < 0 || id >= MAX )); then
        printf "Error: ID fuera de rango.\n"
        return
    fi

    if [[ ${inventario[$id,activo]} -eq 1 ]]; then
        printf "Error: El ID %d ya esta ocupado por '%s'.\n" "$id" "${inventario[$id,nombre]}"
        return
    fi

    if existe_nombre "${prod_ref[nombre]}"; then
        printf "Error: Ya existe un producto activo registrado con el nombre '%s'.\n" "${prod_ref[nombre]}"
        return
    fi

    inventario[$id,nombre]=${prod_ref[nombre]}
    inventario[$id,precio]=${prod_ref[precio]}
    inventario[$id,activo]=${prod_ref[activo]}

    guardar_en_tsv

    printf "Producto %d guardado: '%s' con precio $%.2f.\n" "$id" "${prod_ref[nombre]}" "${prod_ref[precio]}"
}

baja() {
    declare -i id=$1

    if (( id < 0 || id >= MAX )); then
        printf "Error: ID fuera de rango.\n"
        return
    fi

    if [[ ${inventario[$id,activo]} -eq 1 ]]; then
        inventario[$id,activo]=0
        inventario[$id,nombre]=""
        inventario[$id,precio]=0

        guardar_en_tsv

        printf "Producto %d eliminado.\n" "$id"
    else
        printf "El producto no existe.\n"
    fi
}

reporte() {
    declare -r archivo="productos.html"
    declare -i i=0

    {
        cat <<EOF
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
            <tr>
                <th>ID</th>
                <th>Nombre</th>
                <th>Precio</th>
            </tr>
        </thead>
        <tbody>
EOF

        for ((i=0; i<MAX; i++)); do
            if [[ ${inventario[$i,activo]} -eq 1 ]]; then
                printf "            <tr>\n"
                printf "                <td>%d</td>\n" "$i"
                printf "                <td>%s</td>\n" "${inventario[$i,nombre]}"
                printf "                <td>$%.2f</td>\n" "${inventario[$i,precio]}"
                printf "            </tr>\n"
            fi
        done

        cat <<EOF
        </tbody>
    </table>
</body>
</html>
EOF
    } > "$archivo"

    printf "\nReporte generado exitosamente en '%s'.\n" "$archivo"
}

mostrar() {
    declare -i i=0

    printf "\nLISTADO:\n"
    for ((i=0; i<MAX; i++)); do
        if [[ ${inventario[$i,activo]} -eq 1 ]]; then
            printf "ID %d : %s - $%.2f\n" "$i" "${inventario[$i,nombre]}" "${inventario[$i,precio]}"
        fi
    done
}

main() {
    declare -i i=0

    # Inicialización de la estructura en memoria
    for ((i=0; i<MAX; i++)); do
        inventario[$i,activo]=0
        inventario[$i,precio]=0
        inventario[$i,nombre]=""
    done

    cargar_desde_tsv
    bienvenida

    # Menú de inicio (Iniciar sesión / Registrar usuario)
    menu_acceso

    declare opcion=0
    declare -i id=0
    declare -A p_temp

    # Menú principal de gestión de inventario
    while [[ "$opcion" != "$OPCION_SALIR" ]]; do
        printf "\nACCIONES:\n"
        printf "1. Alta producto (ID 0 a %d)\n" $((MAX - 1))
        printf "2. Baja producto\n"
        printf "3. Mostrar inventario\n"
        printf "4. Generar reporte HTML\n"
        printf "5. Salir\n"
        read -rp "Opcion: " opcion

        case $opcion in
            $OPCION_ALTA)
                read -rp "Ingrese ID (0-$((MAX - 1))): " id
                read -rp "Ingrese Nombre: " p_temp[nombre]
                read -rp "Ingrese Precio: " p_temp[precio]
                p_temp[activo]=1
                alta "$id" p_temp
                ;;
            $OPCION_BAJA)
                read -rp "Ingrese ID a eliminar (0-$((MAX - 1))): " id
                baja "$id"
                ;;
            $OPCION_MOSTRAR)
                mostrar
                ;;
            $OPCION_REPORTE)
                reporte
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




# Para implementar el sistema de autenticación dinámico con persistencia y encriptación SHA-256 en usuarios.tsv, se incorporan los siguientes componentes:

#     Generación de Hash con sha256sum: La función generar_hash utiliza la sintaxis $(...) para capturar la salida de sha256sum y extrae los primeros 64 caracteres de la representación hexadecimal mediante la subcadena ${salida:0:64}.

#     Registro de Usuarios (registrar_usuario): Solicita credenciales, verifica mediante existe_usuario que el nombre de usuario no esté registrado y guarda la tupla usuario\thash en usuarios.tsv.

#     Autenticación (autenticar): Lee línea por línea el archivo usuarios.tsv con IFS=$'\t' y compara el hash de la contraseña ingresada contra el hash almacenado.

#     Menú de Acceso Inicial (menu_acceso): Se presenta al iniciar el script permitiendo elegir entre iniciar sesión, registrar usuario o salir.




# Detalles claves de la solución

#     Obtención del hash SHA-256:
#     El comando sha256sum devuelve una línea con el hash seguido del separador de entrada (p. ej. hash  -). La función generar_hash captura esta salida en salida y aplica ${salida:0:64} para tomar únicamente los 64 caracteres hexadecimales del digest SHA-256.

#     Ocultación de clave en terminal:
#     Se utiliza read -sp durante la captura de contraseña para evitar que los caracteres ingresados se muestren en la consola.

#     Manejo de flujo con menu_acceso:
#     Separa el proceso de acceso de la lógica de inventario. Si no existen usuarios registrados en usuarios.tsv, el intento de inicio de sesión informa el error y devuelve al menú para permitir el registro de un primer usuario.
