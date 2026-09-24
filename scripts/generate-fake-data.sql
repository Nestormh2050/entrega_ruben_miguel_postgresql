-- =============================================================================
-- DBA - Prueba técnica Neology | Sistema de control de acceso vehicular
-- Generación automatizada de datos masivos para pruebas de rendimiento
-- (scripts/generate-fake-data.sql)  [EXTRA]
-- -----------------------------------------------------------------------------
-- Propósito: poblar la base con millones de estancias, decenas de miles de
-- vehículos y miles de residentes para poder medir EXPLAIN ANALYZE con datos
-- realistas (ver docs/performance-analysis.md).
--
-- Requiere haberse cargado primero database/schema.sql y database/data.sql
-- (los catálogos de ejemplo proveen los tipos/tarifas base).
--
-- Detalles técnicos:
--   * Los triggers de auditoría y de periodo se deshabilitan durante la carga
--     (la auditoría de millones de filas de prueba no aporta; se re-habilitan
--     al final). El periodo se calcula explícitamente.
--   * Uso de setseed() para resultados reproducibles.
--   * Las estancias generadas están FINALIZADAS y distribuidas en los últimos
--     12 meses; al final se abren ~50 estancias para pruebas en vivo.
--   * Los registros de prueba se pueden identificar por placa 'GEN-*'.
--
-- Parámetros ajustables (valores usados en la evidencia):
--   \set n_vehiculos 60000
--   \set n_estancias 3000000
-- =============================================================================

SET client_encoding = 'UTF8';
\set n_vehiculos 60000
\set n_estancias 3000000

-- Vehículos de prueba
INSERT INTO parking.vehiculo (placa, tipo_vehiculo_id, marca, modelo, color, observaciones)
SELECT 'GEN-' || lpad(gs::text, 7, '0'),
       (ARRAY[1,2,3])[1 + (gs % 3)],          -- 1 OFICIAL, 2 RESIDENTE, 3 VISITANTE
       'Marca-' || (gs % 47),
       'Modelo-' || (gs % 23),
       'GEN',
       'Carga masiva de prueba'
FROM generate_series(1, :n_vehiculos) AS gs;

-- Residentes de prueba (vehículos tipo RESIDENTE)
WITH residentes AS (
    SELECT v.id, v.placa
    FROM parking.vehiculo v
    JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
    WHERE tv.requiere_residente
      AND v.placa LIKE 'GEN-%'
    ORDER BY v.id
    LIMIT 18000
)
INSERT INTO parking.residente (vehiculo_id, nombre, apellidos, telefono, email, tarjeta_acceso, activo, vigencia_desde)
SELECT id,
       'Nombre' || id,
       'Apellido' || id,
       '555000' || lpad((id % 10000)::text, 4, '0'),
       'res' || id || '@correo.test',
       'TAC-' || lpad((id % 99999)::text, 5, '0'),
       true,
       '2025-01-01'
FROM residentes;

-- SELECT count(*) FROM parking.vehiculo;

-- Estancias masivas (finalizadas, últimos 12 meses)
\echo 'Iniciando carga masiva de estancias...'

SET application_name = 'carga_masiva';
ALTER TABLE parking.estancia DISABLE TRIGGER ALL;

SELECT setseed(0.42);

WITH serie AS (
    SELECT gs AS i
    FROM generate_series(1, :n_estancias) AS gs
),
tarifas AS (
    SELECT tv.id AS tipo_id,
           min(t.id)              AS tarifa_id,
           min(t.precio_minuto)   AS precio
    FROM parking.tipo_vehiculo tv
    JOIN parking.tarifa t ON t.tipo_vehiculo_id = tv.id AND t.activa
    GROUP BY tv.id
),
-- NOTA: la ventana de entradas va de hace 13 hasta hace 2 meses (relativo al
-- mes actual), es decir NUNCA toca el "mes anterior" ($-1) que el demo de
-- cierre mensual (database/monthly-close.sql) cierra automáticamente. Así la
-- cadena completa queda sin estancias "huérfanas" sobre un mes ya cerrado.
datos AS (
    SELECT v.id                                     AS vehiculo_id,
           t.tarifa_id,
           t.precio,
(date_trunc('month', now())
                - (2 + ((i - 1) % 12)) * interval '1 month'
                + ((i - 1) / 12 % 28) * interval '1 day'
                + (8 + ((i - 1) / (12*28) % 13)) * interval '1 hour'
                + ((i - 1) % 60)   * interval '1 minute') AS entrada,
           (15 + ((i - 1) / 17) % 570)              AS dur_min
    FROM serie
    JOIN parking.vehiculo v ON v.id = 1 + ((i - 1) % :n_vehiculos)
    JOIN tarifas t          ON t.tipo_id = v.tipo_vehiculo_id
)
INSERT INTO parking.estancia
    (vehiculo_id, entrada_en, salida_en, tarifa_id, periodo, duracion_minutos, cargo)
SELECT vehiculo_id,
       entrada,
       entrada + dur_min * interval '1 minute',
       tarifa_id,
       -- periodo = mes de la entrada según la ZONA DE NEGOCIO (coherente con
       -- la restricción chk_estancia_periodo)
       date_trunc('month', entrada AT TIME ZONE 'America/Mexico_City')::date AS periodo,
       dur_min,
       round(dur_min * precio, 2)
FROM datos;

-- Estancias ABIERTAS actuales de prueba (vehículos GEN aún sin estancia abierta)
INSERT INTO parking.estancia (vehiculo_id, entrada_en, tarifa_id, periodo)
SELECT v.id,
       now() - (gs * interval '3 minutes'),
       (SELECT min(t.id) FROM parking.tarifa t WHERE t.tipo_vehiculo_id = v.tipo_vehiculo_id),
       date_trunc('month', now() AT TIME ZONE 'America/Mexico_City')::date
FROM generate_series(1, 60) AS gs
JOIN parking.vehiculo v
     ON v.id = 1 + (gs * 977)                    -- vehículos distintos
WHERE v.placa LIKE 'GEN-%'
  AND NOT EXISTS (SELECT 1 FROM parking.estancia e
                  WHERE e.vehiculo_id = v.id AND e.salida_en IS NULL);

ALTER TABLE parking.estancia ENABLE TRIGGER ALL;

-- Estadísticas actualizadas para el optimizador
ANALYZE parking.vehiculo;
ANALYZE parking.residente;
ANALYZE parking.tarifa;
ANALYZE parking.tipo_vehiculo;
ANALYZE parking.estancia;

-- Reporte final
SELECT 'estancias' AS concepto, count(*) AS total FROM parking.estancia
UNION ALL SELECT 'estancias abiertas', count(*) FROM parking.estancia WHERE salida_en IS NULL
UNION ALL SELECT 'vehículos', count(*) FROM parking.vehiculo
UNION ALL SELECT 'residentes', count(*) FROM parking.residente;