#!/usr/bin/env bash
# =============================================================================
# DBA - Prueba técnica Neology
# Demo de diagnóstico ante "la tabla parking.tipo_vehiculo está bloqueada"
# (Parte 7: incidentes). Ejecutar DENTRO del servidor (contenedor) como
# superusuario.
#
#   docker cp scripts/incident-lock-demo.sh parking_postgres:/scripts/incident-lock-demo.sh
#   docker exec parking_postgres chmod +x /scripts/incident-lock-demo.sh
#   docker exec parking_postgres /scripts/incident-lock-demo.sh
#
# Escenario simulado:
#   1) Sesión A mantiene un LOCK ACCESS EXCLUSIVE sobre parking.tipo_vehiculo
#      (migración ALTER TABLE "colgada"), duración prevista 120 s.
#   2) Sesión B (la app) intenta INSERTAR un tipo de vehículo y queda ESPERANDO.
#   3) El DBA diagnostica con pg_stat_activity / pg_locks / pg_blocking_pids.
#   4) Decide terminar la sesión bloqueante con pg_terminate_backend.
#   5) Sesión B COMPLETA su INSERT: tipo_vehiculo operativa de nuevo.
# =============================================================================

set -u
PSQL="psql -U park_superuser -d estacionamiento"

echo "=========== INCIDENTE: tipo_vehiculo bloqueada — DEMO ==========="

echo "== [1] Sesión A (migración) toma ACCESS EXCLUSIVE sobre tipo_vehiculo =="
$PSQL -c "BEGIN; LOCK TABLE parking.tipo_vehiculo IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(120); COMMIT;" \
  > /tmp/lock_holder.out 2>&1 &
sleep 1

echo "== [2] Sesión B (app): INSERT de nuevo tipo_vehiculo — queda a la espera =="
$PSQL -c "SET statement_timeout='30000'; INSERT INTO parking.tipo_vehiculo (codigo, nombre, cobra_por_estancia, requiere_residente, activo) VALUES ('TEST', 'Tipo prueba', false, false, true);" \
  > /tmp/lock_blocked.out 2>&1 &
B_PID=$!
sleep 1

echo ""
echo "== [3] DIAGNÓSTICO del DBA =="
echo "    [3a] Sesiones activas del cluster (pg_stat_activity)"
$PSQL -c "SELECT pid, usename, state, wait_event_type, wait_event, now()-xact_start AS xact_dur, left(query, 50) AS query FROM pg_stat_activity WHERE datname = 'estacionamiento' AND pid <> pg_backend_pid() ORDER BY pid;"

echo "    [3b] Árbol de bloqueo: quién bloquea a quién"
$PSQL -c "SELECT b.pid AS bloqueado_pid, b.wait_event_type AS espera, left(b.query, 35) AS bloqueada, a.pid AS bloqueante_pid, left(a.query, 35) AS bloqueante FROM pg_stat_activity b JOIN pg_stat_activity a ON a.pid = ANY (pg_blocking_pids(b.pid)) WHERE b.datname = 'estacionamiento';"

echo "    [3c] Locks sobre tipo_vehiculo (modo y estado granted)"
$PSQL -c "SELECT l.pid AS sesion, l.mode AS modo, l.granted AS concedido, c.relname AS tabla FROM pg_locks l JOIN pg_class c ON c.oid = l.relation WHERE c.relname = 'tipo_vehiculo' ORDER BY l.pid;"

echo ""
echo "== [4] DECISIÓN: terminar la migración colgada (pg_terminate_backend) =="
PID_BLOQUEANTE=$($PSQL -tAc "SELECT a.pid FROM pg_stat_activity a WHERE a.datname='estacionamiento' AND a.backend_type='client backend' AND a.query LIKE 'BEGIN%LOCK TABLE%' LIMIT 1;" | tail -n 1)
if [ -n "${PID_BLOQUEANTE}" ]; then
  echo "    Se termina el backend ${PID_BLOQUEANTE} (sesión A)."
  $PSQL -c "SELECT pg_terminate_backend(${PID_BLOQUEANTE}) AS terminado;"
else
  echo "    (No se detectó; se usa pg_terminate_backend del pid de la sesión A)"
  $PSQL -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname='estacionamiento' AND query LIKE 'BEGIN%LOCK TABLE%';"
fi

echo ""
echo "== [5] La sesión B completa su INSERT (evidencia de desbloqueo) =="
wait $B_PID 2>/dev/null || true
tail -n 4 /tmp/lock_blocked.out

echo ""
echo "== [6] Limpieza de la fila de prueba =="
$PSQL -c "DELETE FROM parking.tipo_vehiculo WHERE codigo = 'TEST';" > /tmp/lock_clean.out 2>&1
tail -n 2 /tmp/lock_clean.out

echo ""
echo "=========== FIN DEMO — tipo_vehiculo operativa de nuevo ==========="