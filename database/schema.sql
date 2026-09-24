-- =============================================================================
-- DBA - Prueba técnica Neology | Sistema de control de acceso vehicular
-- Parte 1: Modelo de datos (database/schema.sql)
-- -----------------------------------------------------------------------------
-- Propósito:
--   Define el esquema relacional completo: tipos de vehículo, tarifas,
--   vehículos, residentes, estancias, cargos/pagos, cierres mensuales y
--   auditoría.
--
-- Decisiones de diseño principales (detalle en docs/modelo-datos.md):
--   * Zona horaria de negocio centralizada en parking.zona_negocio()
--     ('America/Mexico_City'). Todas las particiones de tiempo y cálculos
--     de "día"/"mes" se hacen usando ESTA zona, no la sesión.
--   * TIMESTAMPTZ para fechas de entrada/salida (almacena el instante exacto
--     en UTC y lo proyecta a la zona de negocio).
--   * "periodo" en estancia = mes (primer día) de la entrada según la zona de
--     negocio. Se mantiene por trigger para permitir particionamiento RANGE.
--   * Una única estancia abierta por vehículo -> índice único parcial.
--   * La tarifa se captura en la estancia (FOREIGN KEY a tarifa) para
--     conservar el precio histórico aplicado, aunque la tarifa cambie.
--   * Los importes y duraciones se calculan con funciones dedicadas y se
--     almacenan desnormalizados (duracion_minutos, cargo) por rendimiento,
--     con restricciones CHECK que validan coherencia.
--   * Esquemas separados: "parking" (negocio) y "auditoria" (trazabilidad)
--     para facilitar la seguridad por esquema (Parte 5).
-- =============================================================================

SET client_encoding = 'UTF8';

-- -----------------------------------------------------------------------------
-- Esquemas
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS parking;
CREATE SCHEMA IF NOT EXISTS auditoria;

COMMENT ON SCHEMA parking    IS 'Esquema principal de negocio del estacionamiento';
COMMENT ON SCHEMA auditoria  IS 'Esquema de auditoría: trazabilidad de operaciones relevantes';

-- =============================================================================
-- 1. TIPOS DE VEHÍCULO
-- =============================================================================
-- Modela las clasificaciones de vehículo que determinan cómo se cobra.
-- El modelo es extensible: basta agregar una fila + su tarifa.
--   OFICIAL    -> no paga                         (cobra_por_estancia = false)
--   RESIDENTE  -> cobra $0.05/min, acumula mensual (requiere_residente = true)
--   VISITANTE  -> cobra $0.50/min al salir        (por estancia)
CREATE TABLE parking.tipo_vehiculo (
    id                  smallserial     PRIMARY KEY,
    codigo              varchar(20)     NOT NULL UNIQUE,
    nombre              varchar(60)     NOT NULL,
    descripcion         text,
    cobra_por_estancia  boolean         NOT NULL DEFAULT true,
    requiere_residente  boolean         NOT NULL DEFAULT false,
    activo              boolean         NOT NULL DEFAULT true,
    creado_en           timestamptz     NOT NULL DEFAULT now(),
    actualizado_en      timestamptz     NOT NULL DEFAULT now(),
    CONSTRAINT chk_codigo_no_vacio CHECK (codigo <> '')
);

COMMENT ON TABLE parking.tipo_vehiculo
    IS 'Clasificaciones de vehículo. Definidas por archivos/rows de datos, no por código ad-hoc, para permitir nuevos tipos sin cambios de esquema';
COMMENT ON COLUMN parking.tipo_vehiculo.cobra_por_estancia
    IS 'Indica si el cargo se genera por estancia a la salida (false para oficiales; residentes cobran mensual)';
COMMENT ON COLUMN parking.tipo_vehiculo.requiere_residente
    IS 'Indica si el vehículo debe tener un registro de residente activo';

-- =============================================================================
-- 2. TARIFAS
-- =============================================================================
-- Cada tarifa pertenece a un tipo de vehículo y tiene un precio por minuto y
-- un intervalo de vigencia. Permite históricos de precios y nuevas tarifas sin
-- modificar código. La estancia referencia la tarifa exacta usada.
CREATE TABLE parking.tarifa (
    id                  bigserial       PRIMARY KEY,
    tipo_vehiculo_id    smallint        NOT NULL REFERENCES parking.tipo_vehiculo(id),
    nombre              varchar(80)     NOT NULL,
    precio_minuto       numeric(10,2)   NOT NULL CHECK (precio_minuto >= 0),
    vigencia_desde      date            NOT NULL,
    vigencia_hasta      date,
    activa              boolean         NOT NULL DEFAULT true,
    creado_en           timestamptz     NOT NULL DEFAULT now(),
    CONSTRAINT uq_tarifa_tipo_nombre UNIQUE (tipo_vehiculo_id, nombre),
    CONSTRAINT chk_tarifa_fechas
        CHECK (vigencia_hasta IS NULL OR vigencia_hasta >= vigencia_desde)
);

COMMENT ON TABLE parking.tarifa
    IS 'Tarifas por tipo de vehículo con vigencia temporal. El precio se aplica por minuto (reglas de negocio). Oficiales = $0.00';
COMMENT ON COLUMN parking.tarifa.precio_minuto
    IS 'Precio en pesos por minuto de estancia (0.05 residentes, 0.50 no residentes, 0.00 oficiales)';

-- =============================================================================
-- 3. VEHÍCULOS
-- =============================================================================
CREATE TABLE parking.vehiculo (
    id                  bigserial       PRIMARY KEY,
    placa               varchar(20)     NOT NULL,
    tipo_vehiculo_id    smallint        NOT NULL REFERENCES parking.tipo_vehiculo(id),
    marca               varchar(50),
    modelo              varchar(50),
    color               varchar(30),
    observaciones       text,
    creado_en           timestamptz     NOT NULL DEFAULT now(),
    actualizado_en      timestamptz     NOT NULL DEFAULT now(),
    CONSTRAINT uq_vehiculo_placa UNIQUE (placa),
    CONSTRAINT chk_placa_no_vacio CHECK (placa <> '')
);

COMMENT ON TABLE parking.vehiculo
    IS 'Cátalogo de vehículos. La placa es el identificador natural único del vehículo';

-- =============================================================================
-- 4. RESIDENTES
-- =============================================================================
-- Un residente está asociado a un vehículo (una plaza de residente = un
-- pase/vehículo). Se conserva la vigencia para mantener historia. Solo puede
-- existir un residente ACTIVO por vehículo (índice único parcial).
CREATE TABLE parking.residente (
    id                  bigserial       PRIMARY KEY,
    vehiculo_id         bigint          NOT NULL REFERENCES parking.vehiculo(id),
    nombre              varchar(60)     NOT NULL,
    apellidos           varchar(120)    NOT NULL,
    telefono            varchar(20),
    email               varchar(120),
    tarjeta_acceso      varchar(40),
    activo              boolean         NOT NULL DEFAULT true,
    vigencia_desde      date            NOT NULL DEFAULT CURRENT_DATE,
    vigencia_hasta      date,
    creado_en           timestamptz     NOT NULL DEFAULT now(),
    actualizado_en      timestamptz     NOT NULL DEFAULT now(),
    CONSTRAINT chk_residente_vigencia
        CHECK (vigencia_hasta IS NULL OR vigencia_hasta >= vigencia_desde)
);

COMMENT ON TABLE parking.residente
    IS 'Registro de residentes (personas con pase de estacionamiento). Histórico por vigencia; un solo activo por vehículo';

CREATE UNIQUE INDEX uq_residente_vehiculo_activo
    ON parking.residente (vehiculo_id)
    WHERE activo;

-- =============================================================================
-- 5. ESTANCIAS  (tabla principal; puede crecer a millones de registros)
-- =============================================================================
CREATE TABLE parking.estancia (
    id                  bigserial       PRIMARY KEY,
    vehiculo_id         bigint          NOT NULL REFERENCES parking.vehiculo(id),
    entrada_en          timestamptz     NOT NULL,
    salida_en           timestamptz,
    tarifa_id           bigint          NOT NULL REFERENCES parking.tarifa(id),
    -- Mes (primer día) de la estancia según zona de negocio. Se asigna por
    -- trigger BEFORE INSERT/UPDATE y sirve como clave de particionamiento.
    periodo             date            NOT NULL,
    duracion_minutos    integer,
    cargo               numeric(12,2),
    incluye_cierre         bigint,  -- FK definida tras crear cierre_mensual
    creado_en           timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT chk_estancia_salida_posterior
        CHECK (salida_en IS NULL OR salida_en > entrada_en),
    CONSTRAINT chk_estancia_periodo
        CHECK (periodo = date_trunc('month', entrada_en AT TIME ZONE 'America/Mexico_City')::date),
    -- Coherencia entre salida, duración e importe
    CONSTRAINT chk_estancia_abierta_sin_cobro
        CHECK ((salida_en IS NULL AND duracion_minutos IS NULL AND cargo IS NULL)
               OR salida_en IS NOT NULL),
    CONSTRAINT chk_estancia_duracion_coherente
        CHECK (duracion_minutos IS NULL
               OR duracion_minutos = CEIL(EXTRACT(EPOCH FROM (salida_en - entrada_en)) / 60.0)::integer),
    CONSTRAINT chk_estancia_importe_no_negativo
        CHECK (cargo IS NULL OR cargo >= 0)
);

COMMENT ON TABLE parking.estancia
    IS 'Estancias de vehículos: entrada, salida, tarifa aplicada, duración e importe. Una estancia abierta por vehículo vía índice único parcial';
COMMENT ON COLUMN parking.estancia.periodo
    IS 'Mes calendario (primer día) al que pertenece la estancia según la zona de negocio. Usado para cierres mensuales y particionamiento RANGE';
COMMENT ON COLUMN parking.estancia.duracion_minutos
    IS 'Duración en minutos (con redondeo hacia arriba). Se calcula al registrar la salida';
COMMENT ON COLUMN parking.estancia.cargo
    IS 'Importe de la estancia según la tarifa capturada en tarifa_id';

-- Restricción de negocio: un vehículo NO puede tener más de una estancia
-- abierta. Es un índice único parcial (solo aplica a filas abiertas).
CREATE UNIQUE INDEX uq_estancia_abierta_por_vehiculo
    ON parking.estancia (vehiculo_id)
    WHERE salida_en IS NULL;

-- =============================================================================
-- 6. CIERRES MENSUALES (cabecera + detalle por residente)
-- =============================================================================
CREATE TABLE parking.cierre_mensual (
    id                  bigserial       PRIMARY KEY,
    periodo             date            NOT NULL UNIQUE,   -- primer día del mes cerrado
    ejecutado_por       text            NOT NULL,
    ejecutado_en        timestamptz     NOT NULL DEFAULT now(),
    notas               text
);

COMMENT ON TABLE parking.cierre_mensual
    IS 'Cabecera de cierre mensual de residentes. UNIQUE(periodo) previene ejecuciones duplicadas. Registra quién y cuándo ejecutó el cierre';

CREATE TABLE parking.cierre_residente (
    id                  bigserial       PRIMARY KEY,
    cierre_mensual_id   bigint          NOT NULL REFERENCES parking.cierre_mensual(id) ON DELETE RESTRICT,
    residente_id        bigint          NOT NULL REFERENCES parking.residente(id) ON DELETE RESTRICT,
    minutos             integer         NOT NULL CHECK (minutos >= 0),
    cargo_total         numeric(12,2)   NOT NULL CHECK (cargo_total >= 0),
    pagado              boolean         NOT NULL DEFAULT false,
    CONSTRAINT uq_cierre_residente UNIQUE (cierre_mensual_id, residente_id)
);

COMMENT ON TABLE parking.cierre_residente
    IS 'Detalle por residente del cierre mensual: minutos acumulados e importe total del periodo';

-- Estancias referencian el cierre que las consolidó (trazabilidad; evita
-- recálculo doble y permite auditoría).
ALTER TABLE parking.estancia
    ADD CONSTRAINT fk_estancia_cierre
    FOREIGN KEY (incluye_cierre) REFERENCES parking.cierre_mensual(id) ON DELETE RESTRICT;

-- =============================================================================
-- 7. CARGOS Y PAGOS
-- =============================================================================
CREATE TABLE parking.cargo (
    id                  bigserial       PRIMARY KEY,
    estancia_id         bigint          REFERENCES parking.estancia(id) ON DELETE RESTRICT,
    cierre_residente_id bigint          REFERENCES parking.cierre_residente(id) ON DELETE RESTRICT,
    residente_id        bigint          REFERENCES parking.residente(id) ON DELETE RESTRICT,
    tipo                varchar(20)     NOT NULL DEFAULT 'ESTANCIA'
                        CHECK (tipo IN ('ESTANCIA', 'MENSUAL')),
    concepto            text            NOT NULL,
    monto               numeric(12,2)   NOT NULL CHECK (monto >= 0),
    estado              varchar(20)     NOT NULL DEFAULT 'PENDIENTE'
                        CHECK (estado IN ('PENDIENTE', 'PAGADO', 'ANULADO')),
    generado_en         timestamptz     NOT NULL DEFAULT now(),
    -- Todo cargo debe estar ligado a una estancia o a un cierre de residente
    CONSTRAINT chk_cargo_origen
        CHECK (estancia_id IS NOT NULL OR cierre_residente_id IS NOT NULL)
);

COMMENT ON TABLE parking.cargo
    IS 'Cargos generados por estancia (visitantes) o por cierre mensual (residentes)';

CREATE TABLE parking.pago (
    id                  bigserial       PRIMARY KEY,
    cargo_id            bigint          NOT NULL REFERENCES parking.cargo(id) ON DELETE RESTRICT,
    monto               numeric(12,2)   NOT NULL CHECK (monto > 0),
    metodo              varchar(30)     NOT NULL CHECK (metodo IN ('EFECTIVO', 'TARJETA', 'TRANSFERENCIA', 'MENS_ROL', 'DESCUENTO_NOMINA')),
    referencia          varchar(60),
    cobrado_en          timestamptz     NOT NULL DEFAULT now(),
    CONSTRAINT uq_pago_referencia UNIQUE (referencia)
);

COMMENT ON TABLE parking.pago
    IS 'Pagos aplicados a cargos. UNIQUE(referencia) evita dobles pagos por la misma transacción';

-- =============================================================================
-- 8. AUDITORÍA
-- =============================================================================
CREATE TABLE auditoria.auditoria (
    id                  bigserial       PRIMARY KEY,
    momento             timestamptz     NOT NULL DEFAULT now(),
    esquema             text            NOT NULL,
    tabla               text            NOT NULL,
    operacion           char(1)         NOT NULL CHECK (operacion IN ('I', 'U', 'D')),
    registro_id         text,
    datos_viejos        jsonb,
    datos_nuevos        jsonb,
    usuario             text,
    aplicacion          text,
    pid                 integer,
    sesion_id           bigint
);

COMMENT ON TABLE auditoria.auditoria
    IS 'Bitácora de auditoría (append-only). Las filas no deben eliminarse ni modificarse';

-- Función genérica de auditoría. El usuario se obtiene del ajuste de sesión
-- app.v_usuario (evita depender de la identidad de conexión a BD).
-- SECURITY DEFINER: el trigger debe poder INSERTAR en la bitácora aunque la
-- operación la realice un rol de aplicación con privilegios mínimos (la tabla
-- auditoria NO es accesible para la aplicación; solo el definer escribe).
CREATE OR REPLACE FUNCTION auditoria.fn_auditar() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = auditoria, pg_catalog
AS $$
DECLARE
    v_esquema   text        := TG_TABLE_SCHEMA;
    v_tabla     text        := TG_TABLE_NAME;
    v_operacion text        := TG_OP;
    v_old       jsonb;
    v_new       jsonb;
    v_reg       text;
BEGIN
    IF TG_OP IN ('DELETE', 'UPDATE') THEN
        v_old := to_jsonb(OLD);
        v_reg := COALESCE(v_old->>'id', v_reg);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_new := to_jsonb(NEW);
        v_reg := COALESCE(v_reg, v_new->>'id');
    END IF;

    INSERT INTO auditoria.auditoria
        (esquema, tabla, operacion, registro_id, datos_viejos, datos_nuevos,
         usuario, aplicacion, pid, sesion_id)
    VALUES
        (v_esquema, v_tabla, v_operacion::char(1), v_reg, v_old, v_new,
         NULLIF(current_setting('app.v_usuario', true), ''),
         NULLIF(current_setting('application_name', true), ''),
         pg_backend_pid(), pg_backend_pid());

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- =============================================================================
-- 9. ZONA HORARIA DE NEGOCIO (función centralizada)
-- =============================================================================
CREATE OR REPLACE FUNCTION parking.zona_negocio() RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT 'America/Mexico_City';
$$;

-- =============================================================================
-- 10. FUNCIONES DE NEGOCIO
-- =============================================================================

-- Duración de una estancia en minutos (redondeo hacia arriba).
CREATE OR REPLACE FUNCTION parking.fn_duracion_minutos(
    p_entrada timestamptz,
    p_salida  timestamptz
) RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
               WHEN p_salida IS NULL OR p_salida <= p_entrada THEN NULL
               ELSE CEIL(EXTRACT(EPOCH FROM (p_salida - p_entrada)) / 60.0)::integer
           END;
$$;

-- Tarifa vigente para un tipo de vehículo en una fecha determinada.
-- Devuelve la tarifa activa con mayor prioridad (la vigente).
CREATE OR REPLACE FUNCTION parking.fn_tarifa_vigente(
    p_tipo_vehiculo_id smallint,
    p_fecha            date DEFAULT CURRENT_DATE
) RETURNS parking.tarifa
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT t
    FROM parking.tarifa t
    WHERE t.tipo_vehiculo_id = p_tipo_vehiculo_id
      AND t.activa
      AND t.vigencia_desde <= p_fecha
      AND (t.vigencia_hasta IS NULL OR t.vigencia_hasta >= p_fecha)
    ORDER BY t.vigencia_desde DESC
    LIMIT 1;
$$;

-- Asigna "periodo" (mes) a la estancia según la zona de negocio.
CREATE OR REPLACE FUNCTION parking.fn_estancia_periodo() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.entrada_en IS DISTINCT FROM OLD.entrada_en THEN
        NEW.periodo := date_trunc(
            'month',
            NEW.entrada_en AT TIME ZONE parking.zona_negocio()
        )::date;
    END IF;
    RETURN NEW;
END;
$$;

-- Registra la ENTRADA de un vehículo al estacionamiento.
--   * El vehículo debe existir (identificado por placa).
--   * Captura la tarifa vigente para conservar el precio histórico.
--   * Valida que no exista ya una estancia abierta (índice único parcial).
CREATE OR REPLACE FUNCTION parking.registrar_entrada(
    p_placa     text,
    p_entrada   timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_vehiculo   parking.vehiculo%ROWTYPE;
    v_tarifa     parking.tarifa;
    v_estancia_id bigint;
BEGIN
    IF p_placa IS NULL OR p_placa = '' THEN
        RAISE EXCEPTION 'La placa es obligatoria';
    END IF;
    IF p_entrada > now() + interval '5 minutes' THEN
        RAISE EXCEPTION 'La fecha de entrada es futura: %', p_entrada;
    END IF;

    SELECT v.* INTO v_vehiculo
    FROM parking.vehiculo v
    WHERE v.placa = upper(trim(p_placa));

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehículo no registrado con placa %', upper(trim(p_placa));
    END IF;

    -- Tarifa vigente al momento de la entrada (precio histórico)
    v_tarifa := parking.fn_tarifa_vigente(v_vehiculo.tipo_vehiculo_id,
                                          (p_entrada AT TIME ZONE parking.zona_negocio())::date);
    IF v_tarifa IS NULL THEN
        RAISE EXCEPTION 'No existe tarifa vigente para el tipo de vehículo %', v_vehiculo.tipo_vehiculo_id;
    END IF;

    INSERT INTO parking.estancia (vehiculo_id, entrada_en, tarifa_id)
    VALUES (v_vehiculo.id, p_entrada, v_tarifa.id)
    RETURNING id INTO v_estancia_id;

    -- El índice único parcial uq_estancia_abierta_por_vehiculo rechaza una
    -- segunda estancia abierta del mismo vehículo.
    RETURN v_estancia_id;
END;
$$;

-- Registra la SALIDA. Calcula duración e importe con la tarifa capturada en la
-- estancia, valida que la salida sea posterior a la entrada y genera el cargo
-- por estancia para los tipos que cobran por estancia (visitantes).
-- SECURITY DEFINER + search_path fijado: encapsula la creación de cargos
-- (la aplicación NO tiene INSERT directo sobre parking.cargo).
CREATE OR REPLACE FUNCTION parking.registrar_salida(
    p_estancia_id bigint,
    p_salida      timestamptz DEFAULT now()
) RETURNS record
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = parking, public
AS $$
DECLARE
    v_estancia   parking.estancia%ROWTYPE;
    v_tarifa     parking.tarifa;
    v_tipo       parking.tipo_vehiculo%ROWTYPE;
    v_duracion   integer;
    v_cargo      numeric(12,2);
BEGIN
    SELECT e.* INTO v_estancia
    FROM parking.estancia e
    WHERE e.id = p_estancia_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La estancia % no existe', p_estancia_id;
    END IF;
    IF v_estancia.salida_en IS NOT NULL THEN
        RAISE EXCEPTION 'La estancia % ya tiene salida registrada', p_estancia_id;
    END IF;
    IF p_salida <= v_estancia.entrada_en THEN
        RAISE EXCEPTION 'La salida (%) no puede ser anterior o igual a la entrada (%)',
            p_salida, v_estancia.entrada_en;
    END IF;

    SELECT t.* INTO v_tarifa   FROM parking.tarifa t       WHERE t.id = v_estancia.tarifa_id;
    SELECT tv.* INTO v_tipo
    FROM parking.vehiculo v
    JOIN parking.tipo_vehiculo tv ON tv.id = v.tipo_vehiculo_id
    WHERE v.id = v_estancia.vehiculo_id;

    v_duracion := parking.fn_duracion_minutos(v_estancia.entrada_en, p_salida);
    v_cargo    := ROUND(v_duracion * v_tarifa.precio_minuto, 2);

    UPDATE parking.estancia
       SET salida_en = p_salida,
           duracion_minutos = v_duracion,
           cargo = v_cargo
     WHERE id = p_estancia_id;

    -- Genera cargo por estancia SOLO si el tipo cobra por estancia y el
    -- importe es mayor a cero (los oficiales tienen tarifa $0.00).
    IF v_tipo.cobra_por_estancia AND v_cargo > 0 THEN
        INSERT INTO parking.cargo (estancia_id, residente_id, tipo, concepto, monto)
        VALUES (p_estancia_id, NULL, 'ESTANCIA',
                format('Estancia #%s (%s - %s)', p_estancia_id,
                       v_estancia.entrada_en, p_salida),
                v_cargo);
    END IF;

    -- retorna fila como tipo compuesto genérico
    RETURN ROW(p_estancia_id, v_duracion, v_cargo);
END;
$$;

-- =============================================================================
-- 11. TRIGGERS
-- =============================================================================

-- Asignación de mes para estancias
CREATE TRIGGER trg_estancia_periodo
    BEFORE INSERT OR UPDATE OF entrada_en ON parking.estancia
    FOR EACH ROW EXECUTE FUNCTION parking.fn_estancia_periodo();

-- Auditoría en operaciones relevantes (INSERT/UPDATE/DELETE)
CREATE TRIGGER trg_auditaria_tipo_vehiculo AFTER INSERT OR UPDATE OR DELETE ON parking.tipo_vehiculo
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();
CREATE TRIGGER trg_auditaria_tarifa AFTER INSERT OR UPDATE OR DELETE ON parking.tarifa
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();
CREATE TRIGGER trg_auditaria_vehiculo AFTER INSERT OR UPDATE OR DELETE ON parking.vehiculo
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();
CREATE TRIGGER trg_auditaria_residente AFTER INSERT OR UPDATE OR DELETE ON parking.residente
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();
CREATE TRIGGER trg_auditaria_estancia AFTER INSERT OR UPDATE OR DELETE ON parking.estancia
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();
CREATE TRIGGER trg_auditaria_cierre_mensual AFTER INSERT OR UPDATE OR DELETE ON parking.cierre_mensual
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();
CREATE TRIGGER trg_auditaria_cierre_residente AFTER INSERT OR UPDATE OR DELETE ON parking.cierre_residente
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();
CREATE TRIGGER trg_auditaria_cargo AFTER INSERT OR UPDATE OR DELETE ON parking.cargo
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();
CREATE TRIGGER trg_auditaria_pago AFTER INSERT OR UPDATE OR DELETE ON parking.pago
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();

-- =============================================================================
-- 12. ÍNDICES INICIALES
-- =============================================================================
-- (El índice único parcial de estancia abierta ya está creado con la tabla)

-- Foreing keys / joins
CREATE INDEX ix_estancia_vehiculo          ON parking.estancia (vehiculo_id);
CREATE INDEX ix_estancia_tarifa            ON parking.estancia (tarifa_id);
CREATE INDEX ix_estancia_entrada           ON parking.estancia (entrada_en);
-- Agrupaciones por mes / reportes mensuales y clave de particionamiento
CREATE INDEX ix_estancia_periodo_vehiculo  ON parking.estancia (periodo, vehiculo_id);
-- Estancias cerradas por vehículo ordenadas por salida (consulta "tiempo acumulado")
CREATE INDEX ix_estancia_vehiculo_salida   ON parking.estancia (vehiculo_id, salida_en);

CREATE INDEX ix_vehiculo_tipo               ON parking.vehiculo (tipo_vehiculo_id);

-- Tarifas: búsqueda de vigente por tipo
CREATE INDEX ix_tarifa_tipo_activa          ON parking.tarifa (tipo_vehiculo_id, activa, vigencia_desde DESC);

CREATE INDEX ix_residente_vehiculo          ON parking.residente (vehiculo_id);

CREATE INDEX ix_cargo_estancia              ON parking.cargo (estancia_id);
CREATE INDEX ix_cargo_cierre_residente      ON parking.cargo (cierre_residente_id);
CREATE INDEX ix_cargo_residente             ON parking.cargo (residente_id);
CREATE INDEX ix_pago_cargo                  ON parking.pago (cargo_id);

-- Auditoría: consultas por tabla y tiempo
CREATE INDEX ix_auditoria_tabla_momento     ON auditoria.auditoria (tabla, momento DESC);
CREATE INDEX ix_auditoria_registro          ON auditoria.auditoria (registro_id);

-- =============================================================================
-- 13. VERIFICACIÓN DEL MODELO
-- =============================================================================
DO $$
DECLARE
    v_tablas int := 0;
BEGIN
    SELECT count(*) INTO v_tablas
    FROM pg_tables
    WHERE schemaname IN ('parking', 'auditoria')
      AND tablename IN ('tipo_vehiculo','tarifa','vehiculo','residente','estancia',
                        'cierre_mensual','cierre_residente','cargo','pago','auditoria');
    IF v_tablas <> 10 THEN
        RAISE EXCEPTION 'El modelo no quedó completo: se crearon % de 10 tablas', v_tablas;
    END IF;
END;
$$;