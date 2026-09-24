-- =============================================================================
-- DBA - Prueba técnica Neology
-- EXTRA: Particionamiento declarativo de parking.estancia por periodo (mes)
-- -----------------------------------------------------------------------------
-- Este script NO se aplica por defecto en la cadena (database/*.sql) porque
-- las mediciones de rendimiento se registran sobre la tabla completa.
-- Sirve como MIGRACIÓN REFERENCIADA desde docs/performance-analysis.md (sección 6).
--
-- Uso (crea la estructura particionada VACÍA junto a estancia; no copia datos):
--   docker compose exec -T db psql -U park_superuser -d estacionamiento -f database/particionamiento.sql
-- =============================================================================

-- 0) Opción de prueba segura (por defecto SOLO crea estructura, sin mover datos)
\set crear_estructura  false

-- 1) Tabla padre particionada (misma forma e índices; FKs aparte para no bloquear)
CREATE TABLE IF NOT EXISTS parking.estancia_p (LIKE parking.estancia INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
PARTITION BY RANGE (periodo);

-- 2) Índice en la tabla padre (los heredan todas las particiones)
CREATE INDEX IF NOT EXISTS ix_estancia_p_abierta
  ON parking.estancia_p (vehiculo_id) WHERE salida_en IS NULL;
CREATE INDEX IF NOT EXISTS ix_estancia_p_periodo_cerrada_cov
  ON parking.estancia_p (periodo, salida_en)
  INCLUDE (vehiculo_id, duracion_minutos, cargo)
  WHERE salida_en IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_estancia_p_salida_cerrada
  ON parking.estancia_p (salida_en) WHERE salida_en IS NOT NULL;

-- 3) Unidad de partición: un mes (misma zona horaria de negocio que el trigger
--    trg_estancia_periodo). Se abren la partición del mes en curso y dos más:
DO $$
DECLARE
  mes date;
  n text;
BEGIN
  FOR mes IN SELECT date_trunc('month', now() AT TIME ZONE parking.zona_negocio())
                   + (g || ' months')::interval
            FROM generate_series(0, 2) g
  LOOP
    n := to_char(mes, 'YYYY_MM');
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS parking.estancia_%s PARTITION OF parking.estancia_p
         FOR VALUES FROM (%L) TO (%L)',
      n, mes::text, (mes + interval '1 month')::text);
  END LOOP;
END $$;

-- 4) Migración de datos (solo cuando se decide cortar). Parámetros de bloqueo
--    seguros para no tumbar la operación:
--      SET lock_timeout = '10s';
--    Ej.: INSERT INTO parking.estancia_p SELECT * FROM parking.estancia
--         WHERE periodo < date_trunc('month', now());
--    seguido de DELETE FROM parking.estancia WHERE periodo < ... (mismo batch).

-- 5) El trigger de periodo se re-crea sobre la tabla padre; las particiones lo
--    heredan al crearse (DROP previo para hacerlo re-ejecutable):
DROP TRIGGER IF EXISTS trg_estancia_p_periodo ON parking.estancia_p;
CREATE TRIGGER trg_estancia_p_periodo
  BEFORE INSERT OR UPDATE OF entrada_en ON parking.estancia_p
  FOR EACH ROW EXECUTE FUNCTION parking.fn_estancia_periodo();

-- 6) NOTA para producción: el cierre mensual y el retiro de la partición vieja
--      ALTER TABLE parking.estancia_p DETACH PARTITION parking.estancia_2026_07;
--    mueve un mes entero a archivo/read-only sin tocar las filas del mes actual.

-- 7) Verificación
SELECT c.relname AS tabla,
       CASE c.relkind WHEN 'p' THEN 'particionada' WHEN 'r' THEN 'tabla' ELSE relkind::text END AS tipo
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'parking' AND c.relname LIKE 'estancia%'
ORDER BY c.relname;