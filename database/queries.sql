-- =============================================================================
-- DBA - Prueba tÃ©cnica Neology | Sistema de control de acceso vehicular
-- Parte 2: Consultas de negocio (database/queries.sql)
-- -----------------------------------------------------------------------------
-- Uso:
--   docker compose exec db psql -U park_superuser -d estacionamiento \
--        -v ON_ERROR_STOP=1 -f database/queries.sql
--
-- Notas:
--   * Los cÃ¡lculos usan la tarifa capturada en cada estancia (cargo/duracion)
--     y las funciones de negocio parking.fn_duracion_minutos().
--   * "Mes de negocio" = primer dÃ­a del mes segÃºn la zona America/Mexico_City
--     (columna estancia.periodo).
-- =============================================================================

\set QUIET off

-- Mes que se usarÃ¡ para reportes mensuales. Por defecto el mes ANTERIOR (que
-- siempre contiene datos de ejemplo). Para probar el mes actual cambie:
--   \set mes_cierre = (current_date)::text
SELECT to_char(date_trunc('month', now()) - interval '1 month', 'YYYY-MM-DD') AS mes_cierre \gset
\echo '>> Mes de referencia para reportes mensuales:' :mes_cierre

-- =============================================================================
-- CONSULTA 1. VehÃ­culos actualmente dentro del estacionamiento
-- =============================================================================
\echo '== CONSULTA 1: VehÃ­culos actualmente dentro =='
SELECT v.placa,
       tv.nombre        AS tipo,
       v.marca,
       v.modelo,
       e.entrada_en,
       round(EXTRACT(EPOCH FROM (now() - e.entrada_en)) / 60)::integer AS minutos_dentro
FROM parking.estancia e
JOIN parking.vehiculo    v  ON v.id = e.vehiculo_id
JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
WHERE e.salida_en IS NULL
ORDER BY e.entrada_en;

-- =============================================================================
-- CONSULTA 2. DuraciÃ³n e importe de una estancia
-- -----------------------------------------------------------------------------
-- Toma automÃ¡ticamente una estancia finalizada de ejemplo. Para una estancia
-- concreta, cambie el valor con:  \set estancia_demo 7
-- =============================================================================
\echo '== CONSULTA 2: DuraciÃ³n e importe de una estancia =='
SELECT e.id AS estancia_demo
FROM parking.estancia e
WHERE e.salida_en IS NOT NULL
ORDER BY e.id
LIMIT 1 \gset

SELECT e.id,
       v.placa,
       tv.nombre                                        AS tipo,
       t.nombre                                         AS tarifa,
       t.precio_minuto,
       e.entrada_en,
       e.salida_en,
       parking.fn_duracion_minutos(e.entrada_en, e.salida_en) AS duracion_minutos,
       round(parking.fn_duracion_minutos(e.entrada_en, e.salida_en) * t.precio_minuto, 2) AS importe_calculado,
       e.duracion_minutos                               AS duracion_stored,
       e.cargo                                          AS importe_stored
FROM parking.estancia e
JOIN parking.vehiculo     v  ON v.id = e.vehiculo_id
JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
JOIN parking.tarifa       t  ON t.id = e.tarifa_id
WHERE e.id = :estancia_demo;

-- =============================================================================
-- CONSULTA 3. Reporte mensual de residentes
-- -----------------------------------------------------------------------------
-- Muestra todos los residentes activos (incluso sin estancias) con el total de
-- minutos e importe del mes de referencia (:mes_cierre).
-- =============================================================================
\echo '== CONSULTA 3: Reporte mensual de residentes =='
SELECT r.id            AS residente_id,
       r.nombre,
       r.apellidos,
       v.placa,
       r.tarjeta_acceso,
       :'mes_cierre'::date AS mes,
       count(e.id)     AS estancias,
       COALESCE(sum(e.duracion_minutos), 0) AS minutos_total,
       COALESCE(round(sum(e.cargo), 2), 0)  AS importe_total
FROM parking.residente r
JOIN parking.vehiculo v     ON v.id = r.vehiculo_id
LEFT JOIN parking.estancia e ON e.vehiculo_id = v.id
     AND e.salida_en IS NOT NULL
     AND e.periodo = :'mes_cierre'::date
WHERE r.activo
GROUP BY r.id, r.nombre, r.apellidos, v.placa, r.tarjeta_acceso
ORDER BY minutos_total DESC, apellidos;

-- =============================================================================
-- CONSULTA 4. Ingresos por dÃ­a y por tipo de vehÃ­culo
-- -----------------------------------------------------------------------------
-- Ingresos generados (cargos de estancia) agrupados por dÃ­a de salida y tipo.
-- =============================================================================
\echo '== CONSULTA 4: Ingresos por dÃ­a y tipo de vehÃ­culo =='
SELECT (e.salida_en AT TIME ZONE parking.zona_negocio())::date AS dia,
       tv.codigo   AS tipo_vehiculo,
       count(e.id) AS estancias,
       round(sum(e.cargo), 2) AS ingresos
FROM parking.estancia e
JOIN parking.vehiculo      v ON v.id = e.vehiculo_id
JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
WHERE e.salida_en IS NOT NULL
  AND e.cargo > 0
GROUP BY dia, tv.codigo
ORDER BY dia DESC, tv.codigo;

-- =============================================================================
-- CONSULTA 5. Promedio de permanencia por tipo de vehÃ­culo
-- =============================================================================
\echo '== CONSULTA 5: Promedio de permanencia por tipo de vehÃ­culo =='
SELECT tv.codigo,
       tv.nombre,
       count(e.id)                    AS estancias_cerradas,
       round(avg(e.duracion_minutos), 2) AS promedio_min,
       round(avg(NULLIF(e.duracion_minutos,0))::numeric, 2) AS promedio_min_sin_cero
FROM parking.estancia e
JOIN parking.vehiculo      v  ON v.id = e.vehiculo_id
JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
WHERE e.salida_en IS NOT NULL
GROUP BY tv.codigo, tv.nombre
ORDER BY promedio_min DESC;

-- =============================================================================
-- CONSULTA 6. VehÃ­culos con mÃ¡s de una estancia abierta
-- -----------------------------------------------------------------------------
-- El modelo lo impide con el Ã­ndice Ãºnico parcial
-- uq_estancia_abierta_por_vehiculo. Esta consulta es de VERIFICACIÃ“N: si llega
-- a devolver filas, existe una inconsistencia grave que investigar.
-- =============================================================================
\echo '== CONSULTA 6: VehÃ­culos con mÃ¡s de una estancia abierta (esperado: 0 filas) =='
SELECT e.vehiculo_id,
       v.placa,
       count(*) AS estancias_abiertas,
       string_agg(e.id::text, ', ' ORDER BY e.entrada_en) AS ids_estancias
FROM parking.estancia e
JOIN parking.vehiculo v ON v.id = e.vehiculo_id
WHERE e.salida_en IS NULL
GROUP BY e.vehiculo_id, v.placa
HAVING count(*) > 1;

-- =============================================================================
-- CONSULTA 7. DetecciÃ³n de registros con fechas inconsistentes
-- -----------------------------------------------------------------------------
-- a) Salidas anteriores/iguales a la entrada (el CHECK chk_estancia_salida_posterior
--    lo impide, pero se incluye el diagnÃ³stico).
-- b) DuraciÃ³n almacenada distinta a la recalculada (validaciÃ³n de coherencia).
-- c) Estancias con el periodo del mes distinto al derivado de la entrada.
-- =============================================================================
\echo '== CONSULTA 7a: Salidas <= entradas (esperado: 0 filas) =='
SELECT id, placa, entrada_en, salida_en
FROM (
    SELECT e.id, v.placa, e.entrada_en, e.salida_en
    FROM parking.estancia e
    JOIN parking.vehiculo v ON v.id = e.vehiculo_id
    WHERE e.salida_en IS NOT NULL
) t
WHERE salida_en <= entrada_en;

\echo '== CONSULTA 7b: DuraciÃ³n inconsistente (almacenada vs calculada) (esperado: 0 filas) =='
SELECT e.id, v.placa, e.duracion_minutos                                          AS almacenada,
       parking.fn_duracion_minutos(e.entrada_en, e.salida_en)                     AS calculada,
       e.cargo                                                                    AS cargo,
       round(parking.fn_duracion_minutos(e.entrada_en, e.salida_en) *
             (SELECT t.precio_minuto FROM parking.tarifa t WHERE t.id = e.tarifa_id), 2) AS cargo_calculado
FROM parking.estancia e
JOIN parking.vehiculo v ON v.id = e.vehiculo_id
WHERE e.salida_en IS NOT NULL
  AND (e.duracion_minutos IS DISTINCT FROM parking.fn_duracion_minutos(e.entrada_en, e.salida_en)
       OR e.cargo IS DISTINCT FROM round(parking.fn_duracion_minutos(e.entrada_en, e.salida_en) *
            (SELECT t.precio_minuto FROM parking.tarifa t WHERE t.id = e.tarifa_id), 2));

\echo '== CONSULTA 7c: periodo de mes incoherente con la entrada (esperado: 0 filas) =='
SELECT e.id, v.placa, e.entrada_en, e.periodo
FROM parking.estancia e
JOIN parking.vehiculo v ON v.id = e.vehiculo_id
WHERE e.periodo IS DISTINCT FROM
      date_trunc('month', e.entrada_en AT TIME ZONE parking.zona_negocio())::date;

-- =============================================================================
-- CONSULTA 8. VehÃ­culos con mayor tiempo acumulado durante el mes
-- -----------------------------------------------------------------------------
-- Suma de minutos de estancias FINALIZADAS del mes actual.
-- =============================================================================
\echo '== CONSULTA 8: Mayor tiempo acumulado en el mes actual =='
SELECT v.placa,
       tv.nombre           AS tipo,
       count(e.id)         AS estancias_cerradas,
       sum(e.duracion_minutos) AS minutos_acumulados,
       round(sum(e.cargo), 2)  AS importe_acumulado
FROM parking.estancia e
JOIN parking.vehiculo      v  ON v.id = e.vehiculo_id
JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
WHERE e.salida_en IS NOT NULL
  AND e.periodo = date_trunc('month', now())::date
GROUP BY v.placa, tv.nombre
ORDER BY minutos_acumulados DESC
LIMIT 15;