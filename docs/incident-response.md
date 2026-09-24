# Runbook de incidentes — DBA de guardia

> Parte 7 de la prueba. Demostración real ejecutada en `evidencias/incident-lock-demo.out`
> (script reutilizable: `scripts/incident-lock-demo.sh`).

## 1. Incidentes cubiertos

| ID | Síntoma | Severidad típica |
|---|---|---|
| INC-01 | Tabla `parking.tipo_vehiculo` (o cualquier tabla) **bloqueada**: el INSERT/UPDATE de la app no termina | Alta (detienen la operación) |
| INC-02 | Aplicación lenta de forma sostenida; colas de consultas | Media/Alta |
| INC-03 | Necesidad de **recuperar datos borrados/actualizados por error** (PITR) | Crítica |

## 2. INC-01 — Tabla bloqueada (caso más frecuente)

### 2.1 Síntoma típico
> "Reportan que `tipo_vehiculo` está bloqueada y el SQL de insertar no termina."

Causas habituales:
1. **Migración / ALTER TABLE colgado** manteniendo `ACCESS EXCLUSIVE`.
2. **Transacción larga abierta** (`BEGIN` olvidado) que retiene locks.
3. **Empleado del negocio o app** que dejó una transacción sin commit/rollback.
4. `VACUUM`-long / hotspot en la misma tabla (menos frecuente en INSERT).

### 2.2 Escalado de diagnóstico (en orden)

**Paso 1 — ¿Quién está esperando (WAIT)?** `scripts/incident-lock-demo.sh` o:

```sql
SELECT pid, usename, state, wait_event_type, wait_event,
       now()-xact_start AS xact_dur, left(query, 60) AS query
FROM pg_stat_activity
WHERE datname = 'estacionamiento' AND pid <> pg_backend_pid()
ORDER BY pid;
```

**Paso 2 — Árbol de bloqueo (quién bloquea a quién):**

```sql
SELECT b.pid  AS bloqueado_pid, b.wait_event_type,
       left(b.query, 45) AS bloqueada,
       a.pid  AS bloqueante_pid, left(a.query, 45) AS bloqueante
FROM pg_stat_activity b
JOIN pg_stat_activity a ON a.pid = ANY (pg_blocking_pids(b.pid))
WHERE b.datname = 'estacionamiento';
```

**Paso 3 — Locks reales sobre la tabla (modos y estado `granted`):**

```sql
SELECT l.pid, l.mode, l.granted, c.relname
FROM pg_locks l
JOIN pg_class c ON c.oid = l.relation
WHERE c.relname = 'tipo_vehiculo'        -- o la tabla implicada
ORDER BY l.pid, l.mode;
```

### 2.3 Lectura del diagnóstico (evidencia INC-01 del demo)

| pid | estado | wait_event | Lectura |
|---|---|---|---|
| 3458 | active | `Timeout/PgSleep` | **Bloqueante**: migración con `BEGIN; LOCK TABLE ... ACCESS EXCLUSIVE` |
| 3461 | active | `Lock/relation` | **Bloqueada**: `INSERT` esperando |
| locks | `AccessExclusiveLock` granted=t (3458) | `RowExclusiveLock` granted=f (3461) | Causa y efecto confirmados |

### 2.4 Resolución

1. **Confirmar quién es el dueño** de la sesión bloqueante (query, usuario, host,
   duración) antes de actuar.
2. **Opción A (conservadora):** avisar al dueño / proceso y esperar a que
   complete o libere. **Recomendada** si la migración es legítima y el INSERT
   no es crítico: reintentar el INSERT tras el desbloqueo (`SET statement_timeout`,
   esquema de reintentos del cliente).
3. **Opción B (DBA):** terminar la sesión bloqueante:

```sql
SELECT pg_terminate_backend(<pid_bloqueante>);
```

4. **Nunca** matar el backend del primario (PID 1) ni el autovacuum a la ligera
   (revisar `pg_stat_activity`); preferir esperar si la operación es
   programada.
5. **Verificar desbloqueo**: repetir el Paso 1 y confirmar que el INSERT de la
   app completa (demo: sesión B termina `INSERT 0 1`).

### 2.5 Prevención

- **DDL en ventanas** de baja operación + `lock_timeout` para los ALTER:
  ```sql
  SET lock_timeout = '10s';  -- la migración aborta si no obtiene el lock
  ```
- **`statement_timeout`** en la app (30 s) para no acumular sesiones colgadas.
- **Monitoreo**: alerta si `write_stall > N` usos de `pg_stat_activity` con
  `wait_event_type='Lock'` y `xact_start` antiguo.
- Revisión de **transacciones sin commit** en la app (timeout de inactividad).
- Tener **2 conexiones de respaldo** en el pooler (PGBouncer) para el DBA
  aunque el pool esté saturado.

## 3. INC-02 — Aplicación lenta sostenida

### 3.1 Diagnóstico inicial
```sql
-- Consultas largas actuales
SELECT pid, state, wait_event_type,
       now()-query_start AS duracion, left(query, 80)
FROM pg_stat_activity
WHERE datname='estacionamiento' AND state='active' AND pid <> pg_backend_pid()
ORDER BY duracion DESC LIMIT 10;

-- Índices usados/desusados
SELECT relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes WHERE relname IN ('estancia','vehiculo','residente');

-- Bloqueos retenidos actualmente
SELECT locktype, mode, granted, count(*)
FROM pg_locks WHERE pid <> pg_backend_pid()
GROUP BY locktype, mode, granted;
```

### 3.2 Rutas de resolución
- Plan (`EXPLAIN (ANALYZE, BUFFERS)`) de la consulta reportada y compararlo con
  los índices de `docs/performance-analysis.md`.
- Revisar autovacuum (dead rows acumuladas ⇢ plan malo): `pg_stat_user_tables`.
- ¿Hotspot de escritura? Particionar `estancia` por `periodo` (Parte 4/6 de
  `performance-analysis.md`).
- Escalar réplicas de lectura para los reportes (Q2–Q8) con una app
  read/write-split.

## 4. INC-03 — Borrado/actualización errónea y PITR

> Procedimiento completo en `docs/backup-recovery.md` (sección 4.3).

1. **Parar** el cluster afectado o el flujo de escrituras de la app (para que
   el punto de recuperación no se mueva).
2. Identificar **timestamp objetivo**: la transacción errónea antes de su
   commit (preguntar al reportante / `pg_stat_activity` histórico si aplica).
3. Restaurar el **último pg_basebackup** en un datadir temporal y configurar
   `restore_command` + `recovery_target_time` (+ `recovery_target_xid` si se
   conoce el XID). Promover y **verificar conteos**:

```sql
SELECT (SELECT count(*) FROM parking.estancia)          AS estancias,
       (SELECT count(*) FROM parking.cierre_mensual)    AS cierres,
       (SELECT count(*) FROM parking.cargo)             AS cargos;
```

4. **Extraer solo el dato** afectado (p. ej. la fila borrada de `residente` o
   los `cargo` borrados) y reinsertarlo en producción.
5. Aplicar lecciones: `pg_dump` diario del esquema/sensibles, auditoría
   (tabla `auditoria.auditoria`) para saber QUÉ cambió y la identidad
   (`app.v_usuario`).

## 5. Plan de comunicación del incidente

| Fase | Mensaje |
|---|---|
| Detección | Severidad, impacto operativo, servicio afectado |
| Diagnóstico | Sesión bloqueante/transacción, tabla, tiempo, dueño |
| Resolución | Acción tomada (terminación de backend / espera / rollback), hora |
| Cierre | Verificación, causa raíz, acciones de prevención |

Ejemplo breve:
> **INC-01**: tipo_vehiculo bloqueada por migración `LOCK ACCESS EXCLUSIVE`
> (sesión 3458, xact_dur 2 s). Se terminó el backend, INSERT completado
> (`INSERT 0 1`), servicio normal. Causa raíz: migración sin `lock_timeout`.
> Acción: alerta + ventana de DDL + lock_timeout 10 s. Evidencia: `evidencias/incident-lock-demo.out`.

## 6. Quién resta / confirma

- DBA de guardia ejecuta diagnóstico y resolución del bloqueo.
- Líder de desarrollo confirma que la migración/transacción era la esperada.
- QA vuelve a probar el alta de `tipo_vehiculo` desde la app.
- Se documenta el incidente para la revisión mensual de estabilidad.