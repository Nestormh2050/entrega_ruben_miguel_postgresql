-- =============================================================================
-- DBA - Prueba técnica Neology | Sistema de control de acceso vehicular
-- Parte 4: Optimización y rendimiento (database/indexes.sql)
-- -----------------------------------------------------------------------------
-- Este script materializa los índices de optimización propuestos y analizados
-- en docs/performance-analysis.md (EXPLAIN ANALYZE antes/después).
-- Se ejecuta sobre la tabla estancia (varios millones de registros).
--
-- Consideraciones generales:
--   * Todos son B-Tree. Se prioriza el ORDEN DE COLUMNAS:
--       - Primero las columnas de FILTRADO más selectivas o las de igualdad
--         (periodo, salida_en), luego las de ORDEN/GROUP BY y por último las
--         agregadas como INCLUDE (solo para index-only scans).
--   * INCLUDE evita inflar la clave del índice (las columnas incluidas no se
--     ordenan ni participan en búsquedas) reduciendo tamaño y coste de
--     escritura frente a incluirlas en la clave.
--   * Índices parciales: solo indexan filas que cumplen el predicate; ocupan
--     menos y se escriben menos entradas (clave para estancias cerradas).
--
-- IMPACTO EN ESCRITURAS (a documentar):
--   Cada INSERT/UPDATE/DELETE sobre estancia debe mantener ESTOS índices y
--   los iniciales. Coste = O(k * log n) por fila según el número de índices k.
--   Para el equilibrio rendimiento-escritura:
--     * Se prefiere INCLUDE/parciales para minimizar volumen.
--     * Si el rendimiento de eScrituras se vuelve crítico, eliminar índices
--       redundantes y medir con EXPLAIN ANALYZE.
-- =============================================================================

SET client_encoding = 'UTF8';

-- -----------------------------------------------------------------------------
-- 1. Reporte mensual de residentes (Consulta 3) y cierres mensuales
--    Antes: seq scan sobre estancia (3M) + join por residiente.
--    Índice: (vehiculo_id, periodo) con columnas agregadas en INCLUDE.
--    Orden: la igualdad es el vehículo (equi join), luego periodo para el
--    filtro de intervalo por mes. INCLUDE aporta duración/cargo sin inflar
--    la clave -> permite index-only scan del agregado.
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_estancia_vehiculo_periodo_cov
    ON parking.estancia (vehiculo_id, periodo)
    INCLUDE (duracion_minutos, cargo);

-- -----------------------------------------------------------------------------
-- 2. Vehículos con mayor tiempo acumulado en el mes (Consulta 8)
--    Antes: seq scan 3M con filtro de mes (filtra el 8%).
--    Índice parcial y cubriente: (periodo, salida_en) + INCLUDE.
--    Orden: periodo (igualdad al mes), salida_en (filtro salida IS NOT NULL)
--    y las columnas agregadas en INCLUDE para index-only scan.
--    Parcial (WHERE salida_en IS NOT NULL): las estancias abiertas no entran
--    al índice, reduciendo su tamaño.
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_estancia_periodo_cerrada_cov
    ON parking.estancia (periodo, salida_en)
    INCLUDE (vehiculo_id, duracion_minutos, cargo)
    WHERE salida_en IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 3. Ingresos por día y tipo (Consulta 4) - versión operativa con rango de
--    fechas (los reportes BI filtran por intervalo en salida_en).
--    Parcial: solo estancias cerradas. Permite barrido por índice.
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_estancia_salida_cerrada
    ON parking.estancia (salida_en)
    WHERE salida_en IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 4. Apoyo al índice único de estancia abierta: los vehículos DENTRO ahora
--    (Consulta 1) ya se resuelven con uq_estancia_abierta_por_vehiculo
--    (índice parcial único). Se agrega un índice para consultas por
--    entrada_en reciente de estancias abiertas (operativo "quién está
--    dentro hace más tiempo").
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_estancia_abierta_entrada
    ON parking.estancia (entrada_en)
    WHERE salida_en IS NULL;

-- -----------------------------------------------------------------------------
-- 5. Cierres/auditoría: acelerar la lectura de auditoría por operación.
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_auditoria_tabla_operacion_momento
    ON auditoria.auditoria (esquema, tabla, operacion, momento DESC);

-- -----------------------------------------------------------------------------
-- Análisis de utilidad: índices que probablemente NO agregan valor frente a
-- los existentes y que se pueden omitir para reducir coste de escritura:
--   * ix_estancia_entrada (schema) sería útil solo SI los BI consultan por
--     rango de entrada sin periodo; el índice parcial ix_estancia_abierta_entrada
--     cubre el caso operativo. Decisión documentada en performance-analysis.md.
-- -----------------------------------------------------------------------------

-- Actualiza estadísticas para el optimizador
ANALYZE parking.estancia;