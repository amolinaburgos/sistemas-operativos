# Ejercicio 4: inventario modular en Bash

Esta carpeta parte del ejercicio 3 y conserva sus datos y reglas de negocio. El
código se separó en archivos por responsabilidad para que sea más sencillo
seguir el flujo del programa y mantener cada parte.

## Requisitos y ejecución

- Bash.
- `sqlite3`, disponible en el `PATH`.
- `sha256sum`, provisto habitualmente por GNU Coreutils.

Desde esta carpeta, iniciar el programa con:

```bash
./run.sh
```

También se puede ejecutar `./ejercicio-3.sh`; ese archivo ahora es un lanzador
de compatibilidad que delega en `run.sh`. Los scripts no dependen del directorio
desde el que se invoquen: la base de datos, los logs, las entradas de migración
y el reporte se resuelven dentro de esta carpeta.

## Archivos de código

- `config.sh`: rutas locales, límite de IDs, opciones del menú y datos de la
  sesión actual.
- `log.sh`: limpieza de campos TSV, registro de errores y auditoría de acciones.
- `database.sh`: escape de texto SQL, ejecución de consultas, creación del
  esquema e importación transaccional de archivos TSV heredados.
- `auth.sh`: cálculo de hash SHA-256, registro de usuarios e inicio de sesión
  con hasta tres intentos.
- `products.sh`: validaciones y operaciones de alta, baja, edición y listado;
  también construye el reporte HTML.
- `menu.sh`: menús de acceso e inventario, y coordinación del flujo principal.
- `run.sh`: punto de entrada; carga los módulos en orden, configura Bash y activa
  el registro de errores inesperados.
- `ejercicio-3.sh`: lanzador de compatibilidad que ejecuta `run.sh`.

Los módulos declaran funciones y configuración; `run.sh` es el único archivo
que inicia el flujo interactivo al ser ejecutado.

## Flujo general

1. `run.sh` carga configuración, registro, persistencia, autenticación, productos
   y menús.
2. `main` verifica `sqlite3`, crea las tablas si hacen falta y comprueba si hay
   datos TSV pendientes de importar.
3. El menú de acceso permite iniciar sesión, registrar un usuario o salir.
   Las contraseñas se almacenan como hash SHA-256, nunca en texto plano.
4. Tras iniciar sesión, el menú permite operar sobre productos con IDs de
   `0` a `19`, generar un reporte o salir.
5. Las acciones y los errores se anotan por separado en los archivos de log.

## Base de datos y migración TSV

`data.sq3` es la base SQLite copiada desde el ejercicio 3. Contiene las tablas
`usuarios`, `productos` y `migraciones`. Si la base no existe, se crea al
iniciar. Si se incorpora `esquema.sql`, `database.sh` lo aplica después de
crear las tablas básicas.

La importación heredada busca `usuarios.tsv` y `productos.tsv` en esta carpeta.
Se ejecuta dentro de una transacción y se marca como `importacion_tsv_v1` en la
tabla `migraciones`. Los usuarios deben tener un hash hexadecimal de 64
caracteres; los productos deben estar activos, tener un ID dentro del rango y
un precio válido. Al completar la migración, los TSV de entrada se renombran
como `usuarios_cargados.tsv` y `productos_cargados.tsv`.

Los archivos `*_cargados.tsv` que ya estaban en la copia son respaldos de la
migración previa, no entradas para volver a importar. El precio se guarda como
un entero de centavos para evitar errores de punto flotante.

## Datos y archivos generados

- `data.sq3`: usuarios, productos y registro de migraciones.
- `system.log`: fecha, usuario y acción, en formato TSV.
- `error.log`: fecha y detalle de errores.
- `productos.html`: reporte del inventario; los nombres se escapan antes de
  insertarse en el HTML.
- `usuarios.tsv` y `productos.tsv`: entradas heredadas opcionales que se
  consumen en la primera migración.
- `usuarios_cargados.tsv` y `productos_cargados.tsv`: archivos heredados
  archivados y conservados como referencia.

## Funciones de inventario

- **Alta:** ID de `0` a `19`, nombre no vacío y único, precio no negativo con
  hasta dos decimales.
- **Baja:** elimina físicamente el producto seleccionado.
- **Mostrar:** lista todos los productos por ID.
- **Editar:** actualiza nombre y precio de un producto existente sin duplicar
  nombres.
- **Reporte:** genera la tabla HTML `productos.html`.

Los precios aceptan punto o coma decimal (por ejemplo, `10.50` o `10,50`).


ORDEN DE CONSTRUCCION
config.sh
   ↓
log.sh y database.sh
   ↓
auth.sh y products.sh
   ↓
menu.sh
   ↓
run.sh