# Estrategia de respaldo, restauración y recuperación

> Parte 6 de la prueba. Implementación funcional en `scripts/backup.sh` y
> `scripts/restore.sh` (respaldos lógicos demostrados). Esta guía cubre la
> estrategia de producción (físico + WAL + PITR).

## 1. Objetivos de recuperación (RPO / RTO)

| Métrica | Propuesta | Explicación |
|---|---|---|
| **RPO** | 5 min | Pérdida máxima aceptable: respaldos físicos diarios + WAL continuo (transacciones de los últimos minutos como máximo). |
| **RTO** | 30 min | Restauración automatizada con runbook: descomprimir base + aplicar WAL y promover. |
| SLA nominal | Disponibilidad 99.5 % | Ni el estacionamiento ni los reportes financieros detienen la operación por más de 30 min. |

## 2. Estrategia implementada (funcional, demostrada)

- **Respaldo lógico completo** con `pg_dump -Fc` (custom, comprimido):
  - `scripts/backup.sh` — genera `<db>_<stamp>.dump`, verifica con
    `pg_restore --list` y aplica retención por días.
  - `scripts/restore.sh` — restaura con `pg_restore --clean --if-exists
    --no-owner`; crea la base destino si se pide.
  - **Evidencia ejecutada**: `evidencias/backup-execution.out` y
    `evidencias/restore-execution.out` (restauración a `estacionamiento_restore`
    con **3,000,093 estancias**, idéntico al origen).

## 3. Estrategia completa (producción)

### 3.1 Jerarquía de respaldos

| Capa | Herramienta | Frecuencia | Uso |
|---|---|---|---|
| Físico completo | `pg_basebackup` (tar/z) | Diaria (00:30) | Base de la recuperación; restaura en minutos |
| WAL continuo | `archive_mode=on` + `archive_command` copia a `wal_arch/` | Continuo (cada segmento) | PITR y DR |
| Lógico | `pg_dump -Fc` | Semanal + antes de migraciones | Portabilidad; export de esquema/datos |
| Binarios/DR | rsync / rclone a bucket (S3-compatible) | Tras cada respaldo | Offsite/DR |

### 3.2 Configuración de archivo continuo

```ini
# postgresql.conf (parámetros de arranque en docker-compose o mount)
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /wal_arch/%f && cp %p /wal_arch/%f'
max_wal_senders = 8
```

> En el contenedor demo no se montó `/wal_arch` para no alterar el ejercicio;
> el bloque funcional (pg_dump/pg_restore) sí quedó demostrado.

### 3.3 Respaldo físico con `pg_basebackup`

```bash
# Dentro del servidor/contenedor:
pg_basebackup -h localhost -U park_superuser -D /backups/base_tar \
  --format=tar --gzip --wal-method=fetch
```
- Preferible `--wal-method=stream` para no perder WAL entre el inicio del
  backup y la toma del último segmento.

### 3.4 Recuperación a un punto en el tiempo (PITR)

1. Descomprimir el `pg_basebackup` en el datadir destino.
2. Crear en ese datadir un `postgresql.auto.conf` (o `recovery.conf` en
   versiones ≤ 11):

```ini
restore_command        = 'cp /wal_arch/%f %p'
recovery_target_time   = '2026-09-22 15:30:00'
recovery_target_action = 'promote'
```
3. Arrancar PostgreSQL. Aplica los WAL hasta el instante pedido y promueve.
4. Verificación: `SELECT pg_is_in_recovery();` → `false`; y conteos de tablas.

> Eliminar un borrado accidental: se recupera justo ANTES del `DROP`/`DELETE`
> erróneo (script de soporte en el runbook de incidentes, Parte 7).

### 3.5 Validación periódica de respaldos

- **Restauración de prueba mensual** automatizada (job): crear DB temporal
  (`estacionamiento_restore_test`), `pg_restore`, comparar conteos críticos y
  `pgrst` sobre una muestra de tablas (estancias, cierres).
  - Prueba rápida sin restaurar: `pg_restore --list` en `scripts/backup.sh`.
- **Checksums**: tiene pg cluster con `data_checksums=on` para detectar
  corrupción silenciosa.

### 3.6 Retención y cifrado

| Aspecto | Configuración |
|---|---|
| Retención física | 14 días locales (últimos 14 × `pg_basebackup`) + **3 mensuales** + **1 anual** (archivo) |
| Retención lógica | 8 semanas (`pg_dump`) |
| Cifrado en reposo | `openssl enc -aes-256-cbc` con clave desde `/run/secrets` (fuera del repo) |
| Cifrado en tránsito | TLS/HTTPS para bucket; `rsync` sobre SSH o `rclone` con cifrado del bucket |

### 3.7 Replicación y recuperación ante desastres

- **Replica de streaming síncrona o asíncrona** (hot standby) en otra AZ para
  failover rápido (RTO < 5 min con `pg_ctl promote`), casos RPO~0 si se usan
  `synchronous_standby_names`.
- **WAL archivo en bucket/S3** como cinta lógica: permite PITR aunque el
  primario y la réplica fallen simultáneamente.
- **DR drill trimestral** con las mismas instrucciones de esta sección.

## 4. Procedimiento operativo (runbook resumido)

### 4.1 Respaldo (diario)
```bash
PGUSER=park_superuser PGBACKUPDIR=/backups ./scripts/backup.sh
```

### 4.2 Restauración completa lógica (ejemplo)
```bash
PGUSER=park_superuser RESTORE_DB=estacionamiento_restore \
  ./scripts/restore.sh /backups/estacionamiento_20260924_104933.dump
```

### 4.3 PITR (a un instante)
```bash
# 1. detectar el momento objetivo (timestamp del reporte/transacción)
# 2. descomprimir base del día, configurar restore_command + recovery_target_time
# 3. arrancar y verificar
```

## 5. Ejemplo funcional capturado

`evidencias/backup-execution.out`:
```
==> Iniciando respaldo lógico de 'estacionamiento' (20260924_104933)
==> Respaldo creado: /backups/estacionamiento_20260924_104933.dump (45.2M)
==> Verificando integridad del respaldo
    Objetos listados: 200
```

`evidencias/restore-execution.out` (restauración lógica a `estacionamiento_restore`):
```
-- conteo original --       → 3000093
-- conteo restaurado --     → 3000093
```

## 6. Limitaciones y decisiones

- En el contenedor de demo no se habilitó archivo WAL (requiere reinicio y
  montaje); queda documentado y el mecanismo es estándar PostgreSQL.
- El cifrado con clave en secreto no se ejecutó (no se incluyen secretos reales
  en el repositorio).
- Los respaldos (`backup.sh`/`restore.sh`) usan `pg_dump`/`pg_restore`; para
  volúmenes >50GB se recomienda primar físico (pg_basebackup + WAL) y mantener
  el lógico solo para casos puntuales (migración, consultas de esquema).