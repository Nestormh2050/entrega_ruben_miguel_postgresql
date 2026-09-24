-- =============================================================================
-- DBA - Prueba técnica Neology | Sistema de control de acceso vehicular
-- Parte 2: Datos de demostración (database/data.sql)
-- -----------------------------------------------------------------------------
-- Escenarios cubiertos:
--   * Vehículos oficiales (no pagan) ................ OFI-001 ... OFI-003
--   * Vehículos residentes ($0.05/min, cobro mensual) RES-101 ... RES-104
--   * Vehículos no residentes/visitantes ($0.50/min)  VIS-201 ... VIS-208
--   * Estancias ABERTAS (vehículos dentro ahora)      OFI-003, RES-102,
--                                                     VIS-204, VIS-205
--   * Estancias FINALIZADAS en distintos días, incluyendo el mes anterior
--     y el mes actual (fechas relativas a now() para que el ejemplo se
--     reproduzca en cualquier fecha de ejecución).
--   * Pagos parciales de cargos de visitantes.
--
-- Uso recomendado (aplica siempre al final del script):
--   SET app.v_usuario = '<usuario>';  -- para poblar la auditoría
-- =============================================================================

SET client_encoding = 'UTF8';

-- =============================================================================
-- 1. CATÁLOGOS
-- =============================================================================

-- 1.1 Tipos de vehículo
INSERT INTO parking.tipo_vehiculo (codigo, nombre, descripcion, cobra_por_estancia, requiere_residente) VALUES
    ('OFICIAL',   'Vehículo oficial',   'Vehículos de la empresa y autoridades. NO pagan.', false, false),
    ('RESIDENTE', 'Vehículo residente', 'Vehículos de residentes con pase mensual. Pagan $0.05/min acumulados al mes.', false, true),
    ('VISITANTE', 'Vehículo visitante', 'Vehículos de no residentes. Pagan $0.50/min al registrar su salida.', true, false)
ON CONFLICT (codigo) DO NOTHING;

-- 1.2 Tarifas (vigentes desde una fecha lejana en el pasado para que apliquen
--     a cualquier estancia histórica de ejemplo)
INSERT INTO parking.tarifa (tipo_vehiculo_id, nombre, precio_minuto, vigencia_desde, activa) VALUES
    ((SELECT id FROM parking.tipo_vehiculo WHERE codigo = 'OFICIAL'),
        'Tarifa oficial - sin costo', 0.00, '2024-01-01', true),
    ((SELECT id FROM parking.tipo_vehiculo WHERE codigo = 'RESIDENTE'),
        'Tarifa residente',           0.05, '2024-01-01', true),
    ((SELECT id FROM parking.tipo_vehiculo WHERE codigo = 'VISITANTE'),
        'Tarifa visitante',           0.50, '2024-01-01', true)
ON CONFLICT (tipo_vehiculo_id, nombre) DO NOTHING;

-- 1.3 Vehículos
INSERT INTO parking.vehiculo (placa, tipo_vehiculo_id, marca, modelo, color, observaciones) VALUES
    ('OFI-001', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='OFICIAL'),   'Ford',     'Explorer',  'Blanco', 'Dirección general'),
    ('OFI-002', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='OFICIAL'),   'Nissan',   'Sentra',    'Azul',   'Seguridad'),
    ('OFI-003', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='OFICIAL'),   'Honda',    'CR-V',      'Gris',   'Gerencia'),
    ('RES-101', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='RESIDENTE'), 'Volkswagen','Jetta',    'Rojo',   NULL),
    ('RES-102', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='RESIDENTE'), 'Toyota',   'Corolla',   'Negro',  NULL),
    ('RES-103', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='RESIDENTE'), 'Mazda',    '3',         'Azul',   NULL),
    ('RES-104', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='RESIDENTE'), 'Kia',      'Rio',       'Plata',  NULL),
    ('VIS-201', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='VISITANTE'), 'Chevrolet','Aveo',      'Gris',   NULL),
    ('VIS-202', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='VISITANTE'), 'Nissan',   'March',     'Rojo',   NULL),
    ('VIS-203', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='VISITANTE'), 'Fiat',     '500',       'Blanco', NULL),
    ('VIS-204', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='VISITANTE'), 'Renault',  'Duster',    'Café',   NULL),
    ('VIS-205', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='VISITANTE'), 'Toyota',   'Hilux',     'Negro',  NULL),
    ('VIS-206', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='VISITANTE'), 'Suzuki',   'Swift',     'Gris',   NULL),
    ('VIS-207', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='VISITANTE'), 'Hyundai',  'Accent',    'Plateado',NULL),
    ('VIS-208', (SELECT id FROM parking.tipo_vehiculo WHERE codigo='VISITANTE'), 'Mazda',    'CX-5',      'Blanco', NULL)
ON CONFLICT (placa) DO NOTHING;

-- 1.4 Residentes (un residente activo por vehículo)
INSERT INTO parking.residente
    (vehiculo_id, nombre, apellidos, telefono, email, tarjeta_acceso, activo, vigencia_desde) VALUES
    ((SELECT id FROM parking.vehiculo WHERE placa='RES-101'), 'Daniel',   'Morales Sánchez',  '5551234001', 'dmorales@correo.com',   'TAC-0101', true, '2025-08-01'),
    ((SELECT id FROM parking.vehiculo WHERE placa='RES-102'), 'Lucía',    'Hernández Pérez',  '5551234002', 'lhernandez@correo.com', 'TAC-0102', true, '2025-08-01'),
    ((SELECT id FROM parking.vehiculo WHERE placa='RES-103'), 'Sofía',    'Torres Nava',      '5551234003', 'storres@correo.com',   'TAC-0103', true, '2025-08-01'),
    ((SELECT id FROM parking.vehiculo WHERE placa='RES-104'), 'Roberto',  'Vázquez Luna',     '5551234004', 'rvazquez@correo.com',  'TAC-0104', true, '2025-08-01');

-- =============================================================================
-- 2. ESTANCIAS
-- -----------------------------------------------------------------------------
-- Se registran a través de las funciones de negocio parking.registrar_entrada
-- y parking.registrar_salida para que las reglas las aplique la propia base
-- (cálculo de duración, tarifa y generación de cargos).
--
-- Fechas:
--   * 'PREV': estancias del mes anterior (primer día del mes anterior + offset)
--   * 'NOW' : estancias del mes actual relativas a now() (atrás / duración)
--   * salida NULL = estancia abierta (vehículo aún dentro)
-- =============================================================================

DO $$
DECLARE
    r            record;
    v_estancia   bigint;
    m_anterior   timestamptz := date_trunc('month', now()) - interval '1 month';
BEGIN
    -- ---------------------------------------------------------------
    -- Estancias del MES ANTERIOR (todas finalizadas)
    -- ---------------------------------------------------------------
    FOR r IN SELECT * FROM (VALUES
        ('OFI-001', interval '1 day 07:00', interval '4 hours'),
        ('OFI-001', interval '8 days 09:00', interval '5 hours'),
        ('OFI-002', interval '3 days 07:30', interval '9 hours'),
        ('RES-101', interval '1 day 08:00', interval '9 hours'),
        ('RES-101', interval '2 days 08:00', interval '8 hours'),
        ('RES-101', interval '15 days 08:30', interval '9 hours 30 min'),
        ('RES-102', interval '1 day 09:00', interval '8 hours'),
        ('RES-102', interval '14 days 08:00', interval '9 hours'),
        ('RES-103', interval '5 days 10:00', interval '7 hours'),
        ('RES-103', interval '20 days 08:00', interval '8 hours'),
        ('VIS-201', interval '2 days 10:00', interval '2 hours'),
        ('VIS-202', interval '5 days 12:00', interval '1 hour'),
        ('VIS-203', interval '8 days 15:00', interval '40 min'),
        ('VIS-204', interval '12 days 09:00', interval '3 hours'),
        ('VIS-205', interval '16 days 20:00', interval '2 hours'),
        ('VIS-206', interval '22 days 11:00', interval '4 hours'),
        ('VIS-207', interval '25 days 08:00', interval '6 hours')
    ) t(placa, atras_dias_horas, duracion) LOOP
        v_estancia := parking.registrar_entrada(r.placa,
                                               m_anterior + r.atras_dias_horas);
        PERFORM parking.registrar_salida(v_estancia,
                                        m_anterior + r.atras_dias_horas + r.duracion);
    END LOOP;

    -- ---------------------------------------------------------------
    -- Estancias del MES ACTUAL
    -- 1) Primero las FINALIZADAS (para no chocar con estancias abiertas)
    -- ---------------------------------------------------------------
    FOR r IN SELECT * FROM (VALUES
        -- Placa, entrada (atrás), duración
        ('OFI-002', interval '1 day 03:00', interval '2 hours'),
        ('RES-101', interval '2 days 01:00', interval '9 hours'),
        ('RES-101', interval '1 day 00:00', interval '8 hours'),
        ('RES-102', interval '4 days 00:30', interval '9 hours'),
        ('RES-103', interval '6 days 00:00', interval '8 hours'),
        ('RES-104', interval '3 days 00:00', interval '9 hours'),
        ('VIS-201', interval '5 days 00:00', interval '2 hours'),
        ('VIS-202', interval '3 days 00:00', interval '1 hour 30 min'),
        ('VIS-203', interval '2 days 00:00', interval '45 min'),
        ('VIS-206', interval '7 days 00:00', interval '3 hours'),
        ('VIS-207', interval '4 days 02:00', interval '5 hours'),
        ('VIS-208', interval '30 hours',    interval '1 hour')
    ) t(placa, atras, duracion) LOOP
        v_estancia := parking.registrar_entrada(r.placa, now() - r.atras);
        PERFORM parking.registrar_salida(v_estancia, now() - r.atras + r.duracion);
    END LOOP;

    -- 2) Estancias ABIERTAS (vehículos actualmente dentro)
    FOR r IN SELECT * FROM (VALUES
        ('OFI-003', interval '3 hours'),
        ('RES-102', interval '8 hours'),
        ('VIS-204', interval '2 hours'),
        ('VIS-205', interval '1 day')
    ) t(placa, atras) LOOP
        PERFORM parking.registrar_entrada(r.placa, now() - r.atras);
    END LOOP;
END;
$$;

-- =============================================================================
-- 3. PAGOS DE EJEMPLO
-- -----------------------------------------------------------------------------
-- Se marcan como pagados dos cargos recientes de visitantes para demostrar el
-- flujo cargo -> pago.
-- =============================================================================

INSERT INTO parking.pago (cargo_id, monto, metodo, referencia)
SELECT c.id, c.monto, 'EFECTIVO', 'PAG-' || lpad(c.id::text, 8, '0')
FROM parking.cargo c
WHERE c.tipo = 'ESTANCIA'
  AND c.estado = 'PENDIENTE'
ORDER BY c.generado_en
LIMIT 2;

UPDATE parking.cargo c
SET estado = 'PAGADO'
WHERE c.id IN (SELECT cargo_id FROM parking.pago);

-- =============================================================================
-- 4. RESUMEN DE VERIFICACIÓN (evidencia rápida)
-- =============================================================================
SELECT 'tipos'  AS concepto, count(*)::text AS cantidad FROM parking.tipo_vehiculo
UNION ALL SELECT 'tarifas', count(*)::text FROM parking.tarifa
UNION ALL SELECT 'vehículos', count(*)::text FROM parking.vehiculo
UNION ALL SELECT 'residentes', count(*)::text FROM parking.residente
UNION ALL SELECT 'estancias', count(*)::text FROM parking.estancia
UNION ALL SELECT 'estancias abiertas', count(*)::text FROM parking.estancia WHERE salida_en IS NULL
UNION ALL SELECT 'cargos', count(*)::text FROM parking.cargo
UNION ALL SELECT 'pagos', count(*)::text FROM parking.pago
UNION ALL SELECT 'auditoría', count(*)::text FROM auditoria.auditoria;