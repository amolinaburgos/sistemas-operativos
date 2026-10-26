#!/usr/bin/env bash

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
