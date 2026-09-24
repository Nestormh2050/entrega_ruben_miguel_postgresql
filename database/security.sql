-- =============================================================================
-- DBA - Prueba técnica Neology | Sistema de control de acceso vehicular
-- Parte 5: Seguridad - usuarios, roles y privilegios (database/security.sql)
-- -----------------------------------------------------------------------------
-- Enfoque: PRIVILEGIO MÍNIMO + SEPARACIÓN DE RESPONSABILIDADES.
--
-- Roles de grupo (sin LOGIN):  aplicación, reportes, soporte/operación, DBA.
-- Roles de login (con LOGIN):  heredan de los grupos. Las contraseñas NO se
--   almacenan en este repositorio: se definen fuera (gestión de secretos /
--   Vault) con ALTER ROLE ... PASSWORD. Aquí se crean con PASSWORD NULL y las
--   memorias del ejercicio usan SET ROLE (no requiere contraseña).
--
-- Reglas implementadas:
--   * La aplicación SOLO hace DML vía funciones de negocio y tablas; no lee
--     auditoría, no borra estancias y no ejecuta DDL.
--   * Reportes: SOLO SELECT, y NO accede a datos personales (telefono/email)
--     del residente (se exponen a través de vista enmascarada).
--   * Soporte/operación: DML y ejecución del cierre mensual; puede LEER la
--     auditoría y las estadísticas del servidor (pg_monitor), pero NO modifica
--     la auditoría (append-only).
--   * DBA: administra el esquema y privilegios, sin rol SUPERUSER (defensa en
--     profundidad; replication se entrega aparte).
--   * PUBLIC pierde todo acceso por defecto.
--   * Auditoría de operaciones administrativas: se recomienda pgaudit
--     (extensión) anexo al final, con ejemplo de configuración.
-- =============================================================================

SET client_encoding = 'UTF8';

-- -----------------------------------------------------------------------------
-- 1. Revocar accesos por defecto (arrancar en blanco)
-- -----------------------------------------------------------------------------
REVOKE ALL ON DATABASE estacionamiento FROM PUBLIC;

GRANT USAGE ON SCHEMA parking    TO PUBLIC; -- conexión mínima (se re-stringe abajo)
REVOKE ALL ON SCHEMA parking     FROM PUBLIC;
REVOKE ALL ON SCHEMA auditoria   FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 2. Roles de grupo
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_app_parking') THEN
        CREATE ROLE rol_app_parking;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_reportes') THEN
        CREATE ROLE rol_reportes;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_operacion_soporte') THEN
        CREATE ROLE rol_operacion_soporte;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_admin_bd') THEN
        CREATE ROLE rol_admin_bd;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. Privilegios por rol
-- -----------------------------------------------------------------------------

-- ========================= 3.1 Rol APLICACIÓN =========================
GRANT CONNECT ON DATABASE estacionamiento TO rol_app_parking;
GRANT USAGE    ON SCHEMA parking TO rol_app_parking;

-- Tablas: lo mínimo para el flujo operativo.
--   SIN DELETE sobre estancia (solo cierre/lógica de negocio o soporte).
GRANT SELECT, INSERT, UPDATE ON parking.tipo_vehiculo, parking.tarifa,
                               parking.vehiculo, parking.residente,
                               parking.estancia    TO rol_app_parking;
GRANT SELECT, UPDATE            ON parking.cargo    TO rol_app_parking; -- pagar=UPDATE estado, sin INSERT directo
GRANT SELECT, INSERT            ON parking.pago     TO rol_app_parking;
GRANT SELECT                    ON parking.cierre_mensual,
                                  parking.cierre_residente TO rol_app_parking;

-- Secuencias generadas por serial/bigserial
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA parking TO rol_app_parking;

-- Funciones de negocio (la aplicación interactúa vía API de funciones:
-- registrar_entrada / registrar_salida / fn_tarifa_vigente / fn_duracion_minutos)
GRANT EXECUTE ON FUNCTION parking.registrar_entrada(text, timestamptz) TO rol_app_parking;
GRANT EXECUTE ON FUNCTION parking.registrar_salida(bigint, timestamptz) TO rol_app_parking;
GRANT EXECUTE ON FUNCTION parking.fn_tarifa_vigente(smallint, date)     TO rol_app_parking;
GRANT EXECUTE ON FUNCTION parking.fn_duracion_minutos(timestamptz, timestamptz) TO rol_app_parking;

-- La aplicación NO accede a la auditoría (la escriben los triggers de forma autónoma)
REVOKE ALL ON auditoria.auditoria FROM rol_app_parking;

-- ========================= 3.2 Rol REPORTES (solo lectura) =========================
GRANT CONNECT ON DATABASE estacionamiento TO rol_reportes;
GRANT USAGE    ON SCHEMA parking TO rol_reportes;

GRANT SELECT ON parking.tipo_vehiculo, parking.tarifa, parking.vehiculo,
               parking.estancia, parking.cierre_mensual, parking.cierre_residente,
               parking.cargo, parking.pago TO rol_reportes;

-- Datos sensibles: el residente completo (con telefono/email) NO se expone.
-- Los reportes usan la vista enmascarada.
CREATE OR REPLACE VIEW parking.vw_residente_reportes AS
SELECT r.id            AS residente_id,
       r.nombre,
       r.apellidos,
       v.placa,
       r.tarjeta_acceso,
       r.activo,
       r.vigencia_desde,
       r.vigencia_hasta
FROM parking.residente r
JOIN parking.vehiculo v ON v.id = r.vehiculo_id;

COMMENT ON VIEW parking.vw_residente_reportes
    IS 'Vista para reportes: datos de residente SIN datos personales de contacto (PII)';

GRANT SELECT ON parking.vw_residente_reportes TO rol_reportes;
REVOKE ALL ON parking.residente FROM rol_reportes;

-- ========================= 3.3 Rol OPERACIÓN Y SOPORTE =========================
GRANT CONNECT ON DATABASE estacionamiento TO rol_operacion_soporte;
GRANT USAGE    ON SCHEMA parking, auditoria TO rol_operacion_soporte;

GRANT SELECT, INSERT, UPDATE, DELETE ON parking.tipo_vehiculo, parking.tarifa,
                                        parking.vehiculo, parking.residente,
                                        parking.estancia, parking.cargo,
                                        parking.pago  TO rol_operacion_soporte;
GRANT SELECT ON parking.cierre_mensual, parking.cierre_residente TO rol_operacion_soporte;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA parking TO rol_operacion_soporte;

-- Ejecución del cierre mensual (SECURITY DEFINER: requiere privilegio de escritura)
GRANT EXECUTE ON FUNCTION parking.proceder_cierre_mensual(date, text) TO rol_operacion_soporte;
GRANT EXECUTE ON FUNCTION parking.registrar_entrada(text, timestamptz) TO rol_operacion_soporte;
GRANT EXECUTE ON FUNCTION parking.registrar_salida(bigint, timestamptz) TO rol_operacion_soporte;

-- Mantenimiento
-- pg_signal_backend permite terminar sesiones de forma controlada (mínimo
-- privilegio: no requiere ser superusuario).
GRANT pg_signal_backend TO rol_operacion_soporte;
GRANT pg_monitor TO rol_operacion_soporte;   -- pg_stat_activity, pg_stat_statements, etc.

-- Auditoría: soporte PUEDE LEER (diagnóstico) pero NO modificar ni borrar.
GRANT SELECT ON auditoria.auditoria TO rol_operacion_soporte;
REVOKE INSERT, UPDATE, DELETE ON auditoria.auditoria FROM rol_operacion_soporte;

-- ========================= 3.4 Rol DBA / ADMINISTRACIÓN =========================
GRANT CONNECT ON DATABASE estacionamiento TO rol_admin_bd;
GRANT ALL ON SCHEMA parking, auditoria TO rol_admin_bd;
-- Privilegios sobre OBJETOS EXISTENTES (tablas, secuencias, funciones)
GRANT ALL ON ALL TABLES     IN SCHEMA parking, auditoria TO rol_admin_bd;
GRANT ALL ON ALL SEQUENCES  IN SCHEMA parking, auditoria TO rol_admin_bd;
GRANT ALL ON ALL FUNCTIONS  IN SCHEMA parking, auditoria TO rol_admin_bd;
ALTER DEFAULT PRIVILEGES IN SCHEMA parking, auditoria GRANT ALL ON TABLES    TO rol_admin_bd;
ALTER DEFAULT PRIVILEGES IN SCHEMA parking, auditoria GRANT ALL ON FUNCTIONS TO rol_admin_bd;
ALTER DEFAULT PRIVILEGES IN SCHEMA parking, auditoria GRANT ALL ON SEQUENCES TO rol_admin_bd;

-- Perfil administrativo SIN SUPERUSER: para DDL y autorizaciones, pero con
-- CREATEDB/CREATEROLE restringidos a quien administre (se asigna a los
-- LOGIN correspondientes, NO al grupo de forma automática).
--   CREATE ROLE usr_dba LOGIN CREATEDB CREATEROLE PASSWORD '<secreto>' IN ROLE rol_admin_bd;

-- -----------------------------------------------------------------------------
-- 4. Roles de login (contraseñas fuera del repositorio; PASSWORD NULL aquí)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'usr_app_parking') THEN
        CREATE ROLE usr_app_parking  LOGIN PASSWORD NULL IN ROLE rol_app_parking;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'usr_reportes_le') THEN
        CREATE ROLE usr_reportes_le  LOGIN PASSWORD NULL IN ROLE rol_reportes;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'usr_soporte') THEN
        CREATE ROLE usr_soporte      LOGIN PASSWORD NULL IN ROLE rol_operacion_soporte;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'usr_dba') THEN
        CREATE ROLE usr_dba          LOGIN PASSWORD NULL IN ROLE rol_admin_bd;
    END IF;
END;
$$;

COMMENT ON ROLE usr_app_parking IS 'Aplicación: DML operativo, sin auditoría, sin borrado de estancias';
COMMENT ON ROLE usr_reportes_le IS 'Reportes: solo lectura, sin PII de contacto';
COMMENT ON ROLE usr_soporte     IS 'Operación/soporte: DML + cierre mensual + lectura de auditoría';
COMMENT ON ROLE usr_dba         IS 'Administrador: DDL y privilegios. Password asignado vía secretos';

-- -----------------------------------------------------------------------------
-- 5. Demostración (SET ROLE no requiere contraseña; la prueba no guarda claves)
-- -----------------------------------------------------------------------------
\echo '== 5.1 Reportes: SELECT permitido sobre vista enmascarada =='
SET ROLE rol_reportes;
SELECT count(*) AS residentes_visibles FROM parking.vw_residente_reportes;
SELECT 'SELECT directo sobre PII (debe FALLAR):' AS chequeo;
-- SELECT telefono FROM parking.residente;  -- descomente para ver el REVOKE en acción

\echo '== 5.2 Reportes: INTENTO de escritura (debe FALLAR) =='
-- INSERT INTO parking.vehiculo (placa, tipo_vehiculo_id) VALUES ('XX-000',1);

\echo '== 5.3 Aplicación: flujo normal de entrada/salida (transacción revocada) =='
RESET ROLE;
BEGIN;
SET LOCAL ROLE usr_app_parking;
SELECT parking.registrar_entrada('VIS-206') AS estancia_nueva \gset
SELECT parking.registrar_salida(:'estancia_nueva'::bigint, now() + interval '10 minutes')
       AS resultado_salida;
ROLLBACK;

\echo '== 5.4 Aplicación: INTENTO de DELETE sobre estancia (debe FALLAR) =='
SET ROLE usr_app_parking;
-- DELETE FROM parking.estancia WHERE id = 1;  -- descomente para ver el error de privilegio
RESET ROLE;

\echo '== 5.5 Aplicación: INTENTO de leer auditoría (debe FALLAR) =='
SET ROLE usr_app_parking;
-- SELECT * FROM auditoria.auditoria;  -- descomente para ver el REVOKE
RESET ROLE;

\echo '== 5.6 Soporte: lectura de auditoría permitida =='
SET ROLE rol_operacion_soporte;
SELECT count(*) AS filas_auditoria, max(momento) AS ultima
FROM auditoria.auditoria;
RESET ROLE;

\echo '== 5.7 Reasignación de permisos (ejemplo de REVOKE/GRANT) =='
-- En producción lo ejecuta el propietario de los objetos (el DBA). En la demo
-- se utiliza el superusuario del entorno.
REVOKE SELECT ON parking.pago FROM rol_reportes;
-- SELECT * FROM parking.pago;  -- con SET ROLE rol_reportes: PERMISO DENEGADO
GRANT SELECT ON parking.pago TO rol_reportes;

-- -----------------------------------------------------------------------------
-- 6. Notas de endurecimiento adicional (producción)
--   * pg_hba.conf: rechazar 'trust', exigir 'scram-sha-256' y SSL/TLS.
--   * pgbouncer/odyssey: pool de conexiones y límite por usuario.
--   * pgaudit: auditar DDL y operaciones administrativas del rol admin.
--   * SET app.v_usuario en cada conexión de aplicación para poblar auditoría.
--   * job de rotación de contraseñas (Vault) y revocación de roles al salir
--     el personal (GRANT/REVOKE explícito, listado en este archivo).
-- -----------------------------------------------------------------------------
\echo 'END security.sql - roles y privilegios aplicados'