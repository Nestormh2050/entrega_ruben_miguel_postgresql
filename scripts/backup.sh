#!/usr/bin/env bash
# =============================================================================
# DBA - Prueba técnica Neology
# Respaldo de la base de datos del estacionamiento (scripts/backup.sh)
# -----------------------------------------------------------------------------
# Estrategia implementada (funcional):
#   * Respaldo LÓGICO COMPLETO con pg_dump (formato custom -Fc, comprimido),
#     portable y restaurable por partes.
#
# Estrategia descrita en docs/backup-recovery.md (producción):
#   * pg_basebackup (respaldo físico completo) + archivo continuo de WAL para
#     recuperación a punto en el tiempo (PITR).
#   * Cifrado de los respaldos (openssl/gpg) y copia fuera del servidor.
#   * Validación periódica mediante restauraciones de prueba.
#
# Uso (local / contenedor):
#   PGHOST=localhost PGUSER=park_superuser PGBACKUPDIR=./backups ./scripts/backup.sh
#   docker compose exec -T db ./scripts/backup.sh   (dentro del contenedor)
#
# Configuración por variables de entorno (sin secretos en el repositorio):
#   PGHOST, PGPORT, PGUSER, PGPASSWORD (o .pgpass), PGDATABASE, PGBACKUPDIR
# =============================================================================

set -Eeuo pipefail

: "${PGDATABASE:=estacionamiento}"
: "${PGBACKUPDIR:=/backups}"
: "${PGHOST:=localhost}"

mkdir -p "${PGBACKUPDIR}"

STAMP="$(date +%Y%m%d_%H%M%S)"
BASE="${PGDATABASE}_${STAMP}"
DUMP="${PGBACKUPDIR}/${BASE}.dump"
LOG="${PGBACKUPDIR}/${BASE}.log"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

echo "==> Iniciando respaldo lógico de '${PGDATABASE}' (${STAMP})"

# 1) Respaldo lógico completo (custom, compresión media)
pg_dump --dbname "${PGDATABASE}" \
        --format=custom \
        --compress=9 \
        --file "${DUMP}" \
        --verbose 2> "${LOG}"

echo "==> Respaldo creado: ${DUMP} ($(du -h "${DUMP}" | cut -f1))"

# 2) Validación básica: leer el respaldo (no restaura, solo verifica)
echo "==> Verificando integridad del respaldo"
pg_restore --list "${DUMP}" > "${PGBACKUPDIR}/${BASE}.list"
echo "    Objetos listados: $(wc -l < "${PGBACKUPDIR}/${BASE}.list")"

# 3) Cifrado opcional (producción). En este repo no se incluyen secretos reales.
#    Ejemplo:
#      openssl enc -aes-256-cbc -salt -pbkdf2 -in "${DUMP}" \
#          -out "${DUMP}.enc" -kfile "/run/secrets/backup_key"
#      rm -f "${DUMP}"

# 4) Retención: elimina respaldos de más de N días
echo "==> Aplicando retención (${RETENTION_DAYS} días)"
find "${PGBACKUPDIR}" -name "*.dump" -mtime "+${RETENTION_DAYS}" -delete

# 5) Salida fuera del servidor (producción)
#    Ejemplos: rsync/rclone a bucket S3, o escenario DR. Ver docs/backup-recovery.md

echo "==> Respaldo completado OK"
echo "    Log: ${LOG}"