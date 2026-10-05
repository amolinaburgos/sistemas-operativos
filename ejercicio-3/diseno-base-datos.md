# Diseño de la base de datos

Este diseño se basa en las entidades y reglas que utiliza `ejercicio-2.sh`.
La base SQLite se llamará `data.sq3` y reemplazará la persistencia de usuarios
y productos en `usuarios.tsv` y `productos.tsv`.

## Estructura propuesta

El archivo [`esquema.sql`](./esquema.sql) crea las tablas `usuarios` y
`productos`.

### `usuarios`

| Columna | Tipo | Regla | Uso |
| --- | --- | --- | --- |
| `id_usuario` | `INTEGER` | Clave primaria | Identificador interno del usuario. SQLite asigna el valor si se omite. |
| `nombre_usuario` | `TEXT` | Obligatorio, único (distingue mayúsculas/minúsculas) y no vacío | Nombre usado para el registro e inicio de sesión. Mantiene la comparación exacta del script. |
| `hash_contrasena` | `TEXT` | Obligatorio, exactamente 64 caracteres | Hash hexadecimal SHA-256 de la contraseña; nunca se almacena la contraseña en claro. |

### `productos`

| Columna | Tipo | Regla | Uso |
| --- | --- | --- | --- |
| `id_producto` | `INTEGER` | Clave primaria entre `0` y `5` | Conserva el rango definido por `MAX=6` y el ID ingresado manualmente. |
| `nombre` | `TEXT` | Obligatorio, único sin distinguir mayúsculas/minúsculas y no vacío | Nombre del producto; evita nombres duplicados activos, como hace `existe_nombre`. |
| `precio_centavos` | `INTEGER` | Obligatorio y no negativo | Precio expresado en centavos para evitar errores de redondeo de punto flotante. Por ejemplo, `$12.34` se guarda como `1234`. |

## Decisiones de modelado

- No se agrega una columna `activo`: el script solo persiste productos activos
  y `baja` elimina el producto. Por lo tanto, la ausencia de una fila representa
  un ID disponible y conserva el comportamiento original.
- Los productos no tienen una clave foránea a `usuarios`: el inventario del
  script es compartido y no registra qué usuario creó cada producto.
- La auditoría de las acciones se mantiene fuera de esta base, en
  `system.log`, según el requisito de registrar ese archivo como TSV. Los
  errores de ejecución también quedan fuera del esquema, en `error.log`.
- La unicidad de `nombre` con `COLLATE NOCASE` reproduce la comparación de
  nombres de productos sin distinguir mayúsculas/minúsculas para caracteres
  ASCII. Los nombres de usuario, en cambio, mantienen comparación sensible a
  mayúsculas/minúsculas como en la autenticación original.
- Si se cambia el valor de `MAX` en el script, también debe actualizarse el
  límite de `id_producto` en `esquema.sql`.

## Inicialización

Desde el directorio `sistemas-operativos/ejercicio-3/`, crear la base y aplicar
el esquema con:

```bash
sqlite3 data.sq3 < esquema.sql
```

`CREATE TABLE IF NOT EXISTS` hace que el esquema pueda aplicarse nuevamente sin
recrear ni borrar los datos existentes. La inicialización del programa debe
comprobar primero si existe `data.sq3`; si no existe, puede ejecutar ese mismo
esquema para crearla.

Al inicializar, `ejercicio-3.sh` revisa además la tabla `migraciones`. Si no
existe la marca `importacion_tsv_v1`, lee `usuarios.tsv` y `productos.tsv` del
directorio de trabajo e importa sus filas válidas dentro de una transacción.
Los productos inactivos del TSV se omiten, porque el esquema actual solo
almacena productos activos. Se aceptan precios heredados con punto o coma
decimal. Las filas inválidas se omiten y se informan en `error.log`.

La marca se guarda en la misma transacción que los datos; por eso la importación
se hace una sola vez y una falla permite reintentar al próximo inicio. Los TSV
originales no se eliminan ni se modifican. Si ya se ejecutó la versión del
programa que no importaba datos, pero todavía no se creó la marca de migración,
el siguiente inicio importará los archivos que sigan en el directorio de
trabajo. Una vez registrada la marca, los cambios posteriores en los TSV no se
vuelven a importar.

## Correspondencia con las operaciones del script

- **Registro de usuario:** calcular el hash SHA-256 y ejecutar un `INSERT` en
  `usuarios`. La restricción `UNIQUE` impide registrar dos veces el mismo
  nombre exacto.
- **Autenticación:** consultar `usuarios` por `nombre_usuario` y comparar el
  hash guardado con el calculado a partir de la contraseña ingresada.
- **Alta de producto:** validar que el ID esté entre `0` y `5`, convertir el
  precio a centavos y ejecutar un `INSERT` en `productos`. Las claves primaria
  y única impiden reutilizar un ID ocupado o duplicar un nombre activo.
- **Baja de producto:** ejecutar `DELETE FROM productos WHERE id_producto = ?`.
  La fila eliminada deja disponible el ID, tal como sucede al reescribir el
  TSV sin el producto.
- **Mostrar y reporte HTML:** consultar los productos ordenados por
  `id_producto`; convertir los centavos a unidades monetarias al presentarlos.

La CLI `sqlite3` se invoca desde Bash como un proceso externo y no expone
parámetros enlazados a las sentencias del programa. Por eso el script escapa
las comillas simples de cada texto antes de construir la sentencia y valida
los valores numéricos antes de incorporarlos. Esto permite nombres con
apóstrofes sin interpretar el texto ingresado como código SQL.

## Script reimplementado

El nuevo archivo [`ejercicio-3.sh`](./ejercicio-3.sh) conserva las operaciones
y menús del original, pero ya no utiliza `usuarios.tsv`, `productos.tsv` ni el
inventario asociativo en memoria como persistencia:

- `inicializar_base_datos` crea `data.sq3` en el directorio de trabajo si falta,
  aplica `esquema.sql` de forma idempotente e importa una vez los TSV
  heredados mediante la marca en `migraciones`.
- `existe_usuario`, `autenticar` y `registrar_usuario` consultan o insertan
  filas en `usuarios`.
- `alta`, `baja`, `mostrar` y `reporte` insertan, eliminan o consultan filas
  de `productos`.
- Los precios se convierten a centavos al almacenarse y se formatean al
  mostrarse o exportarse al HTML.
- Cada selección de acción se registra en `system.log` como TSV con fecha/hora,
  ID de usuario, nombre y acción. Los errores se registran en `error.log`.

El script requiere Bash, `sqlite3` y `sha256sum`. Debe ejecutarse desde el
directorio en el que se desea crear o utilizar `data.sq3`; el esquema se busca
en el directorio donde se encuentra el propio script.
