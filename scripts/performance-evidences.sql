-- =============================================================================
-- DBA - Prueba técnica Neology
-- Captura de EXPLAIN ANALYZE para la Parte 4 (scripts/performance-evidences.sql)
-- -----------------------------------------------------------------------------
-- Se ejecuta DOS veces con distinta etiqueta:
--   1) psql -v etiqueta=ANTES   (sin índices de optimización)
--   2) psql -v etiqueta=DESPUES (con database/indexes.sql aplicado)
-- Resultados: evidencias/performance-before.out y evidencias/performance-after.out
--
-- Consultas medidas:
--   Q8-ORIGINAL   Vehículos con mayor tiempo acumulado en el mes (forma original)
--   Q8-OPTIMIZADO Ídem, pero agregando primero por vehículo (explota el índice
--                 cubriente ix_estancia_periodo_cerrada_cov; reduce el join
--                 de 250k filas a ~5k grupos).
--   Q4            Ingresos por día y tipo, versión operativa con un rango de
--                 7 días DENTRO del mes de medición (se beneficia del índice
--                 parcial ix_estancia_salida_cerrada).
--
-- NOTA: la medición se hace sobre el MES MÁS POBLADO del dataset generado
-- (dos meses atrás, 250k filas), no sobre el mes corriente (casi vacío), para
-- que las diferencias ANTES/DESPUÉS sean representativas del volumen.
-- =============================================================================

\set QUIET off
\timing on
SELECT (date_trunc('month', now() AT TIME ZONE 'America/Mexico_City')
        - interval '2 months')::date AS mes_med \gset

\echo '############################################################'
\echo '## ESCENARIO:' :etiqueta
\echo '## Mes de medición:' :mes_med
\echo '############################################################'

\echo
\echo '============= Q8 ORIGINAL: Mayor tiempo acumulado (join directo) ============='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT v.placa,
       tv.nombre AS tipo,
       count(e.id)                AS estancias_cerradas,
       sum(e.duracion_minutos)    AS minutos_acumulados,
       round(sum(e.cargo), 2)     AS importe_acumulado
FROM parking.estancia e
JOIN parking.vehiculo      v  ON v.id = e.vehiculo_id
JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
WHERE e.salida_en IS NOT NULL
  AND e.periodo = :'mes_med'::date
GROUP BY v.placa, tv.nombre
ORDER BY minutos_acumulados DESC
LIMIT 15;

\echo
\echo '============= Q8 OPTIMIZADO: agregar por vehículo, luego unir catálogos ============='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT v.placa,
       tv.nombre AS tipo,
       a.estancias_cerradas,
       a.minutos_acumulados,
       round(a.importe_acumulado, 2) AS importe_acumulado
FROM (
    SELECT e.vehiculo_id,
           count(*)             AS estancias_cerradas,
           sum(e.duracion_minutos) AS minutos_acumulados,
           sum(e.cargo)         AS importe_acumulado
    FROM parking.estancia e
    WHERE e.salida_en IS NOT NULL
      AND e.periodo = :'mes_med'::date
    GROUP BY e.vehiculo_id
) a
JOIN parking.vehiculo      v  ON v.id   = a.vehiculo_id
JOIN parking.tipo_vehiculo tv ON tv.id  = v.tipo_vehiculo_id
ORDER BY a.minutos_acumulados DESC
LIMIT 15;

\echo
\echo '============= Q4: Ingresos por día y tipo (rango 7 días) ============='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT (e.salida_en AT TIME ZONE 'America/Mexico_City')::date AS dia,
       tv.codigo AS tipo_vehiculo,
       count(e.id)            AS estancias,
       round(sum(e.cargo), 2) AS ingresos
FROM parking.estancia e
JOIN parking.vehiculo      v  ON v.id = e.vehiculo_id
JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
WHERE e.salida_en IS NOT NULL
  AND e.salida_en >= (:'mes_med'::date + 12) AT TIME ZONE 'America/Mexico_City'
  AND e.salida_en <  (:'mes_med'::date + 19) AT TIME ZONE 'America/Mexico_City'
  AND e.cargo > 0
GROUP BY dia, tv.codigo
ORDER BY dia DESC, tv.codigo;