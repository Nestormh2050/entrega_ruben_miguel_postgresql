# Prueba técnica DBA — Sistema de Control de Acceso Vehicular

Autor: **Rubén Miguel** — Rama: `entrega/ruben-miguel`

Desarrollo completo de una base de datos PostgreSQL **16** para un estacionamiento
(control de acceso, tipos de vehículo, tarifas, residentes, estancias, cierres
mensuales, cargos/pagos y auditoría), con análisis de rendimiento sobre
**3,000,093 registros**, seguridad por roles, respaldo/restauración (demo real),
runbook de incidentes y diseño de capa NoSQL.

Todo se ejecuta contra un **PostgreSQL 16 real en Docker**; cada parte deja
evidencia de ejecución en `evidencias/`.

---

## 1. Requisitos

- Docker (probado con Docker v29 / Compose v5.3) o un PostgreSQL 16 local.
- Todo el pipeline usa solo `psql` de PostgreSQL (sin plugins).

## 2. Puesta en marcha

```bash
# 1) Arrancar PostgreSQL 16 (docker-compose.yml)
docker compose up -d

# 2) Aplicar la cadena completa (orden estricto; 3M filas tarda ~4-6 min)
docker compose exec -T db psql -U park_superuser -d estacionamiento -f database/schema.sql
docker compose exec -T db psql -U park_superuser -d estacionamiento -f database/data.sql
docker compose exec -T db psql -U park_superuser -d estacionamiento -f database/queries.sql
docker compose exec -T db psql -U park_superuser -d estacionamiento -f database/monthly-close.sql
docker compose exec -T db psql -U park_superuser -d estacionamiento -f scripts/generate-fake-data.sql
docker compose exec -T db psql -U park_superuser -d estacionamiento -f database/indexes.sql
docker compose exec -T db psql -U park_superuser -d estacionamiento -f database/security.sql
```

> Las **8 consultas** y el **cierre mensual** se demuestran sobre el dataset
> semilla (resultados legibles y auditables por el evaluador); el **generador de
> volumen** se aplica después y solo puebla los meses 2..13 atrás (nunca el mes
> anterior, que el cierre ya cerró, ni el mes en curso salvo las estancias
> abiertas). Para medir ANTES/DESPUÉS de los índices: correr
> `performance-evidences.sql` con `-v etiqueta=ANTES` tras `generate-fake-data.sql`,
> aplicar `indexes.sql` y correr con `-v etiqueta=DESPUES` (ver `docs/performance-analysis.md` §7).

> Windows: los `.sql` son UTF-8 sin BOM. Para reproducir las evidencias sin
> corrupción de codificación use `docker cp <archivo> parking_postgres:/tmp/<f>` y
> dentro del contenedor `psql ... -f /tmp/<f> > /tmp/<out>` (ver §6).

## 3. Contenido del repositorio

```
docker-compose.yml            Postgres 16.15 + healthcheck (db: parking_postgres)
database/
  schema.sql                  Modelo completo: esquemas parking/auditoria, 10 tablas,
                              funciones de negocio (zona_negocio, registrar_entrada/
                              salida, cierre mensual), triggers y auditoría, índices
  data.sql                    Datos de demostración (escenarios del enunciado)
  queries.sql                 Las 8 consultas del enunciado (ejecutadas y validadas)
  monthly-close.sql           Función proceder_cierre_mensual + demo transaccional
  indexes.sql                 Índices de optimización para millones de filas
  security.sql                Roles, privilegios, vista enmascarada y demostraciones 5.1-5.7
  particionamiento.sql        (EXTRA) migración a particionado RANGE mensual
scripts/
  generate-fake-data.sql      Carga masiva: 3M estancias, 60k vehículos, 18k residentes
  performance-evidences.sql   Runner EXPLAIN (ANALYZE, BUFFERS) ANTES/DESPUÉS
  backup.sh                   Respaldo lógico completo (pg_dump -Fc) DEMOSTRADO
  restore.sh                  Restauración lógica (pg_restore) + guía PITR DEMOSTRADA
  incident-lock-demo.sh       Demo real de bloqueo de tabla + diagnóstico/terminación
docs/
  modelo-datos.md             Modelo ER (Mermaid), decisiones, índices, limitaciones
  performance-analysis.md     Planes antes/después, I/O, orden de columnas, particionado
  backup-recovery.md          RPO/RTO, pg_basebackup + WAL + PITR, runbook
  incident-response.md        Runbook DBA de guardia (tabla bloqueada, lentitud, PITR)
  nosql-design.md             Capa analítica NoSQL (MongoDB/DocumentDB) + CDC
evidencias/                   Salidas REALES de cada parte (ver §6)
```

## 4. Resumen de resultados obtenidos

| Parte | Resultado | Evidencia |
|---|---|---|
| 1 Modelo | 10 tablas, triggers, auditoría; entradas/salidas transaccionales | `evidencias/queries.out` |
| 2 Datos | 33 estancias (4 abiertas), 13 cargos, 104 eventos de auditoría | `evidencias/queries.out` (Q1) |
| 3 Consultas | Las 8 consultas responden con datos reales | `evidencias/queries.out` |
| 4 Rendimiento | Q8 optim.: **329→106 ms** (Index-Only); Q4: **560→185 ms** (Bitmap); ~3× mejor | `evidencias/performance-*.out` |
| 5 Seguridad | Roles con mínimo privilegio; app sin DELETE/lectura de auditoría; vista sin PII | `evidencias/sec.out` |
| 6 Backup/restore | Backup 45 MB + restauración de 3,000,093 estancias IDÉNTICAS | `evidencias/backup-*.out`, `restore-*.out` |
| 7 Incidentes | Bloqueo de `tipo_vehiculo` diagnosticado y resuelto (pg_terminate_backend) | `evidencias/incident-lock-demo.out` |
| 8 NoSQL | Diseño doc/documento + esquemas JSON + CDC | `docs/nosql-design.md` |

## 5. Datos de conexión (solo desarrollo)

- Host `localhost:5432`, base `estacionamiento`, usuario `park_superuser`.
- Password: variable `PG_PASSWORD` del entorno; **default de desarrollo**
  `SoloDesarrolloCambiar123` (no usar en producción; ver §7).
- Roles creados: `rol_app_parking`, `rol_reportes`, `rol_operacion_soporte`,
  `rol_admin_bd`; usuarios login: `usr_app_parking`, `usr_reportes_le`,
  `usr_soporte`, `usr_dba` (todos `PASSWORD NULL`).

## 6. Reproducción de evidencias (importante en Windows)

En PowerShell el pipe de SQL a `docker compose exec` corrompe el UTF-8. Método
fiable y usado durante el desarrollo:

```powershell
docker cp database/queries.sql parking_postgres:/tmp/q.sql
docker compose exec db sh -c "psql -U park_superuser -d estacionamiento -f /tmp/q.sql > /tmp/q.out 2>&1"
docker cp parking_postgres:/tmp/q.out evidencias/queries.out
```

El contenido de `evidencias/` es correcto y UTF-8; la consola local puede
mostrar `?` por la página de códigos (solo cosmético).

## 7. Supuestos y decisiones relevantes

1. **Zona horaria** única de negocio `America/Mexico_City` vía
   `parking.zona_negocio()`; estancia.`periodo` = mes (primer día) por trigger.
2. **Periodo por ENTRADA**: estancias que cruzan el mes se consolidan en el mes
   de inicio (mejora A1: prorrateo, documentada).
3. **Cobro**: OFICIAL $0.00; RESIDENTE $0.05/min (acumulado → cargo MENSUAL);
   VISITANTE $0.50/min (cargo al salir). Duración en minutos con redondeo
   superior (CEIL).
4. Las **tarifas se capturan históricamente** en cada estancia (cambios de
   tarifa no revalorizan pasado).
5. **1 estancia abierta por vehículo** garantizada por índice único parcial.
6. La app operativa **no tiene** DELETE ni SELECT sobre auditoría; los triggers
   de auditoría y la salida/cobro usan funciones `SECURITY DEFINER`.
7. Los respaldos físicos/WAL/PITR se documentan y la parte *lógica*
   (pg_dump/pg_restore) está **ejecutada y verificada**.
8. El script `particionamiento.sql` es un EXTRA referenciado en el análisis de
   rendimiento; no forma parte de la cadena de carga por defecto.
9. El generador de volumen (`generate-fake-data.sql`) puebla los **meses 2 a 13
   atrás** (nunca el mes anterior que cierra `monthly-close.sql` ni el mes en
   curso de las estancias abiertas), evitando estancias "huérfanas" sobre un mes
   ya cerrado.

## 8. Documentación detallada

- `docs/modelo-datos.md` — modelo ER (Mermaid) y decisiones por tabla.
- `docs/performance-analysis.md` — metodología ANTES/DESPUÉS e índices.
- `docs/backup-recovery.md` — RPO/RTO, pg_basebackup, WAL, PITR.
- `docs/incident-response.md` — runbook de incidentes (bloqueos, lentitud, PITR).
- `docs/nosql-design.md` — capa analítica NoSQL con CDC.