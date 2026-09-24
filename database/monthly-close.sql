-- =============================================================================
-- DBA - Prueba técnica Neology | Sistema de control de acceso vehicular
-- Parte 3: Operación de cierre mensual (database/monthly-close.sql)
-- -----------------------------------------------------------------------------
-- Función transaccional parking.cierre_mensual(p_periodo, p_ejecutado_por):
--   1. Valida que el periodo sea el primer día de un mes.
--   2. Toma un lock de asesoría para serializar ejecuciones simultáneas.
--   3. Verifica que el mes NO esté cerrado (UNIQUE(periodo) + verificación
--      explícita) -> previene ejecuciones duplicadas.
--   4. Agrupa las estancias FINALIZADAS de residentes correspondientes al mes
--      (por estancia.periodo) y NO incluidas en otro cierre.
--   5. Inserta la cabecera de cierre y el detalle por residente.
--   6. Genera el cargo MENSUAL por residente (quedan PENDIENTES de pago).
--   7. Marca las estancias consolidadas (estancia.incluye_cierre) ->
--      conserva histórico y evita recálculo; NO se elimina información.
--   8. Todo ocurre en una única transacción: si falla algo, se revierte
--      completo (consistencia ante errores). La auditoría registra quién y
--      cuándo se ejecutó (campo cierre_mensual.ejecutado_por + tabla auditoria).
--
-- Uso:
--   SET app.v_usuario = 'dba_soporte';          -- identidad de negocio
--   SELECT * FROM parking.proceder_cierre_mensual('2026-08-01', 'NRamirez');
--
-- Nota de negocio: las estancias se asignan al mes de su ENTRADA. Estancias
-- que cruzan la frontera del mes se contabilizan completas en su mes de
-- entrada (decisión documentada en docs/modelo-datos.md).
-- =============================================================================

SET client_encoding = 'UTF8';

-- -----------------------------------------------------------------------------
-- 1. LÓGICA DE CIERRE
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION parking.proceder_cierre_mensual(
    p_periodo        date,
    p_ejecutado_por  text
) RETURNS TABLE(
    cierre_id       bigint,
    residentes      integer,
    total_minutos   bigint,
    total_cargo     numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = parking, public
AS $$
DECLARE
    v_id       bigint;
    v_total_residentes integer;
    v_total_min  bigint := 0;
    v_total_cargo numeric := 0;
    v_estancias bigint;
BEGIN
    -- 1. Validación del periodo: debe ser el primer día de un mes
    IF p_periodo IS NULL OR p_periodo <> date_trunc('month', p_periodo)::date THEN
        RAISE EXCEPTION 'El periodo debe ser el primer día de un mes (ej. 2026-08-01)';
    END IF;
    IF p_ejecutado_por IS NULL OR trim(p_ejecutado_por) = '' THEN
        RAISE EXCEPTION 'Debe indicarse quién ejecuta el cierre (p_ejecutado_por)';
    END IF;

    -- 2. Lock de asesoría: serializa executes concurrentes del cierre
    PERFORM pg_advisory_xact_lock(hashtextextended('parking.cierre_mensual', 0));

    -- 3. Prevención de ejecuciones duplicadas
    IF EXISTS (SELECT 1 FROM parking.cierre_mensual cm WHERE cm.periodo = p_periodo) THEN
        RAISE EXCEPTION 'El mes % ya fue cerrado. Para auditar/recalcular use un periodo nuevo.', p_periodo
            USING HINT = 'Los datos históricos nunca se eliminan; si hubo un error, registra un cierre correctivo.';
    END IF;

    -- 4. Conteo de estancias a consolidar
    SELECT count(*) INTO v_estancias
    FROM parking.estancia e
    JOIN parking.vehiculo v ON v.id = e.vehiculo_id
    JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
    WHERE tv.requiere_residente
      AND e.periodo = p_periodo
      AND e.salida_en IS NOT NULL
      AND e.incluye_cierre IS NULL;

    IF v_estancias = 0 THEN
        RAISE NOTICE 'No se encontraron estancias pendientes de consolidar para %', p_periodo;
    END IF;

    -- 5. Cabecera de cierre (registra quién y cuándo)
    INSERT INTO parking.cierre_mensual (periodo, ejecutado_por, notas)
    VALUES (p_periodo,
            p_ejecutado_por,
            format('Cierre automatizado de %s para residentes', to_char(p_periodo, 'YYYY-MM')))
    RETURNING id INTO v_id;

    -- 6. Detalle por residiente (agrupado) + reproducción idéntica de datos históricos
    WITH consol AS (
        SELECT v.id AS vehiculo_id,
               coalesce(r.id, 0) AS residente_id,
               r.id IS NOT NULL  AS tiene_residente,
               count(e.id)       AS n_estancias,
               sum(e.duracion_minutos) AS mins,
               round(sum(e.cargo), 2)  AS cargo
        FROM parking.estancia e
        JOIN parking.vehiculo v  ON v.id = e.vehiculo_id
        JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
        LEFT JOIN parking.residente r ON r.vehiculo_id = v.id AND r.activo
        WHERE tv.requiere_residente
          AND e.periodo  = p_periodo
          AND e.salida_en IS NOT NULL
          AND e.incluye_cierre IS NULL
        GROUP BY v.id, r.id
    )
    INSERT INTO parking.cierre_residente (cierre_mensual_id, residente_id, minutos, cargo_total)
    SELECT v_id,
           c.residente_id,
           c.mins,
           c.cargo
    FROM consol c
    WHERE c.tiene_residente;

    GET DIAGNOSTICS v_total_residentes = ROW_COUNT;

    -- Totales para el reporte de salida
    SELECT coalesce(sum(cr.minutos), 0), coalesce(sum(cr.cargo_total), 0)
      INTO v_total_min, v_total_cargo
    FROM parking.cierre_residente cr
    WHERE cr.cierre_mensual_id = v_id;

    -- 7. Genera el cargo MENSUAL por residente (queda PENDIENTE)
    INSERT INTO parking.cargo (estancia_id, cierre_residente_id, residente_id, tipo, concepto, monto)
    SELECT NULL, cr.id, cr.residente_id, 'MENSUAL',
           format('Cuota mensual %s - %s', to_char(p_periodo, 'YYYY-MM'), r.apellidos),
           cr.cargo_total
    FROM parking.cierre_residente cr
    JOIN parking.residente r ON r.id = cr.residente_id
    WHERE cr.cierre_mensual_id = v_id;

    -- 8. Marca las estancias consolidadas (histórico preservado, sin DELETE)
    UPDATE parking.estancia e
       SET incluye_cierre = v_id
    FROM parking.vehiculo v
    JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
    WHERE tv.requiere_residente
      AND e.vehiculo_id = v.id
      AND e.periodo = p_periodo
      AND e.salida_en IS NOT NULL
      AND e.incluye_cierre IS NULL;

    RETURN QUERY SELECT v_id::bigint,
                        v_total_residentes::integer,
                        v_total_min::bigint,
                        v_total_cargo::numeric;
END;
$$;

-- =============================================================================
-- 2. DEMOSTRACIÓN
-- -----------------------------------------------------------------------------
-- Cierra el mes anterior (contiene estancias residentes de ejemplo).
-- Se ejecuta como el usuario de negocio 'NRamirez' para poblar la auditoría.
-- =============================================================================

-- (a) Cierre del mes anterior
SET app.v_usuario = 'NRamirez';
SELECT to_char(date_trunc('month', now()) - interval '1 month', 'YYYY-MM-DD') AS mes_a_cerrar \gset

SELECT * FROM parking.proceder_cierre_mensual(:'mes_a_cerrar'::date, 'NRamirez');

-- (b) Intento de ejecución duplicada (debe FALLAR: el mes ya está cerrado)
\echo '== Intento de cierre duplicado (esperado: ERROR) =='
SELECT * FROM parking.proceder_cierre_mensual(:'mes_a_cerrar'::date, 'RRamirez');

-- (c) Cierre de un periodo inválido (debe FALLAR)
\echo '== Periodo inválido (esperado: ERROR) =='
SELECT * FROM parking.proceder_cierre_mensual('2026-08-15', 'NRamirez');

-- =============================================================================
-- 3. VERIFICACIÓN DEL CIERRE
-- =============================================================================
\echo '== Cierres registrados =='
SELECT id, periodo, ejecutado_por, ejecutado_en
FROM parking.cierre_mensual
ORDER BY periodo;

\echo '== Detalle por residente del mes cerrado =='
SELECT cm.periodo,
       r.apellidos,
       r.nombre,
       v.placa,
       cr.minutos,
       cr.cargo_total,
       cr.pagado
FROM parking.cierre_mensual cm
JOIN parking.cierre_residente cr ON cr.cierre_mensual_id = cm.id
JOIN parking.residente           r ON r.id = cr.residente_id
JOIN parking.vehiculo            v ON v.id = r.vehiculo_id
ORDER BY cm.periodo, r.apellidos;

\echo '== Cargos MENSUALES generados =='
SELECT c.id, c.tipo, c.monto, c.estado, c.concepto
FROM parking.cargo c
WHERE c.tipo = 'MENSUAL'
ORDER BY c.id;