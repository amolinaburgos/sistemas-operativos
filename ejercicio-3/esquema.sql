-- esquema.sql
-- Esquema de base de datos SQLite compatible con ejercicio-3.sh

PRAGMA foreign_keys = ON;

-- ============================================================================
-- Tabla: usuarios
-- ============================================================================
CREATE TABLE IF NOT EXISTS usuarios (
    id_usuario INTEGER PRIMARY KEY AUTOINCREMENT,
    nombre_usuario TEXT NOT NULL UNIQUE CHECK (length(nombre_usuario) > 0),
    hash_contrasena TEXT NOT NULL CHECK (length(hash_contrasena) = 64)
);

-- ============================================================================
-- Tabla: productos
-- ============================================================================
CREATE TABLE IF NOT EXISTS productos (
    id_producto INTEGER PRIMARY KEY CHECK (id_producto >= 0 AND id_producto <= 5),
    nombre TEXT NOT NULL UNIQUE COLLATE NOCASE CHECK (length(nombre) > 0),
    precio_centavos INTEGER NOT NULL CHECK (precio_centavos >= 0)
);

-- ============================================================================
-- Tabla: migraciones
-- ============================================================================
-- Utiliza los nombres de columna exactos que consulta e inserta ejercicio-3.sh:
-- 'nombre' y 'aplicada_en'
-- ============================================================================
CREATE TABLE IF NOT EXISTS migraciones (
    nombre TEXT PRIMARY KEY,
    aplicada_en DATETIME DEFAULT CURRENT_TIMESTAMP
);