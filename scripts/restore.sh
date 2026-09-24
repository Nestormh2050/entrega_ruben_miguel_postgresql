#!/usr/bin/env bash
# =============================================================================
# DBA - Prueba técnica Neology
# Restauración de la base de datos del estacionamiento (scripts/restore.sh)
# -----------------------------------------------------------------------------
# Modos:
#   1) RESTAURACIÓN LÓGICA (pg_restore): restaura el respaldo generado por
#      backup.sh a una base (nueva o existente).
#   2) RECUPERACIÓN A PUNTO EN EL TIEMPO (PITR): escribe el bloque de
#      configuración/referencia y las instrucciones; la operación real se hace
#      con archivos físicos (pg_basebackup + WAL). Ver docs/backup-recovery.md
#
# Uso (local / contenedor):
#   RESTORE_DB=estacionamiento_restore ./scripts/restore.sh /ruta/archivo.dump
#   docker compose exec -T db ./scripts/restore.sh
#
# Configuración por variables de entorno:
#   PGHOST, PGUSER, PGDATABASE, PGBACKUPDIR, RESTORE_DB, RESTORE_TARGET_TIME
# =============================================================================

set -Eeuo pipefail

: "${PGDATABASE:=estacionamiento}"
: "${PGBACKUPDIR:=/backups}"
: "${RESTORE_DB:=}"
: "${PGHOST:=localhost}"
DUMP="${1:-}"

if [ -z "${DUMP}" ]; then
  DUMP="$(ls -t "${PGBACKUPDIR}"/*.dump 2>/dev/null | head -n1 || true)"
fi
if [ -z "${DUMP}" ] || [ ! -f "${DUMP}" ]; then
  echo "ERROR: no se encontró un respaldo. Uso:" >&2
  echo "  ${0} /ruta/al/respaldo.dump" >&2
  echo "  (o defina PGBACKUPDIR con los respaldos)" >&2
  exit 1
fi

echo "==> Restaurando respaldo: ${DUMP}"

# 1) Crear la base destino si no existe
if [ -n "${RESTORE_DB}" ] && ! psql -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname='${RESTORE_DB}'" | grep -q 1; then
  echo "==> Creando base destino '${RESTORE_DB}'"
  psql -d postgres -c "CREATE DATABASE ${RESTORE_DB}"
fi

TARGET_DB="${RESTORE_DB:-${PGDATABASE}}"
echo "==> Restaurando en '${TARGET_DB}' (proceso: TRUNCATE + re-create)"

# 2) Restauración lógica (custom)
#    --clean --if-exists : elimina objetos antes de crearlos (reproducible)
#    --no-owner          : no exige el propietario original
pg_restore --dbname "${TARGET_DB}" \
           --clean --if-exists \
           --no-owner \
           --verbose \
           "${DUMP}" 2>&1 | grep -vE "^pg_restore: (dropping|processing)" || true

echo "==> Restauración LÓGICA completada"
echo "    Base: ${TARGET_DB}"

# =============================================================================
# RECUPERACIÓN A PUNTO EN EL TIEMPO (PITR) — referencia de producción
# -----------------------------------------------------------------------------
# 1. El servidor debe archivar WAL:
#      postgresql.conf:
#        wal_level = replica
#        archive_mode = on
#        archive_command = 'test ! -f /wal_arch/%f && cp %p /wal_arch/%f'
#    (El respaldo físico se toma con: pg_basebackup -Ft -z -D /backups/base)
# 2. Restauración:
#    a) Descomprimir el pg_basebackup en el directorio de datos destino.
#    b) En postgresql.conf (copia) activar el modo recuperación:
#         restore_command = 'cp /wal_arch/%f %p'
#         recovery_target_time = '2026-09-22 15:30:00'   <- redefine RESTORE_TARGET_TIME
#    c) Iniciar PostgreSQL: entra en modo recovery y aplica los WAL hasta el
#       tiempo objetivo, luego promueve a primario.
# 3. Verificación: SELECT * FROM pg_stat_wal_receiver; / tablas validadas.
#
# RPO/RTO de referencia (ver docs/backup-recovery.md):
#   RPO objetivo:  5 min (archivo WAL streaming + archive)
#   RTO objetivo:  30 min (automatizado con scripts y runbooks)
# =============================================================================
echo "==> PITR: ver instrucciones en docs/backup-recovery.md"
echo "    (variable RESTORE_TARGET_TIME = ${RESTORE_TARGET_TIME:-<no definido>})"