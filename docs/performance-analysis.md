# Análisis de rendimiento — Planes de ejecución antes/después

> Parte 4 de la prueba. Voltaje conectar: se generaron **3,000,093 estancias**,
> 60,015 vehículos y 18,004 residentes (`scripts/generate-fake-data.sql`).
> Planes completos en `evidencias/performance-before.out` y
> `evidencias/performance-after.out`.

## 1. Metodología

1. Se cargó el dataset y se ejecutó `ANALYZE` sobre todas las tablas.
2. **ANTES**: se removieron los índices de optimización (`indexes.sql` no
   aplicado). Se capturó `EXPLAIN (ANALYZE, BUFFERS)` de las consultas.
3. **DESPUÉS**: se aplicó `database/indexes.sql` (índices cubrientes y
   parciales) y se repitió la captura.
4. Se comparan **tiempo de ejecución** e **I/O (buffers)**.

Consultas evaluadas (mismas de `queries.sql`):

- **Q8** — Vehículos con mayor tiempo acumulado en el mes.
- **Q8 (forma optimizada)** — La misma consulta reescrita para **agregar
  primero por vehículo y luego unir los catálogos**.
- **Q4** — Ingresos por día y tipo (versión operativa con rango de 7 días).

## 2. Resultados

| Consulta | ANTES (ms) | DESPUÉS (ms) | Δ tiempo | Plan clave ANTES | Plan clave DESPUÉS |
|---|---|---|---|---|---|
| Q8 (original) | 531 | 482 | −9% | Parallel Seq Scan sobre 3M filas | Bitmap scan (mes) + heap + sort/join |
| **Q8 (optimizada)** | **329** | **106** | **3.1× mejor** | Parallel Seq Scan 3M | **Index Only Scan** (`Heap Fetches: 2`) |
| **Q4 (rango 7 días)** | **560** | **185** | **3.0× mejor** | Parallel Seq Scan 3M | **Bitmap Index Scan** sobre `ix_estancia_salida_cerrada` |

### 2.1 I/O (buffers) — el indicador más importante

| Consulta | ANTES | DESPUÉS |
|---|---|---|
| Q8 optimizada | seq scan de toda la tabla→ solo filtra ~83k/3M | agregado **solo desde el índice**: `shared hit=14326 read=2650` (≈16.9k páginas de índice, **2 fetches al heap**) |
| Q4 | escanea 3,000,000 filas (`Rows Removed by Filter: 979,199` por worker) | acción solo sobre **76 páginas de índice** + bloques de heap de las filas que cumplen (62,495); simple |

La mejora de **I/O es la que sostiene la escalabilidad**; el muro de tiempo
se reduce de forma estable al crecer el volumen (3M → 30M el seq scan se vuelve
inviable; el index-only/bitmap se mantiene casi constante).

## 3. Problemas detectados en el estado inicial

1. **Seq Scan de `estancia` completa** (3M filas) para filtrar un mes (~250k)
   o un rango de 7 días (~62k): desperdicio de I/O y CPU.
2. **Q8 en su forma original unía antes de agregar**: join de 250k filas a
   `vehiculo`+`tipo_vehiculo` y sort de todos los grupos antes del `LIMIT 15`.
   El agregado debe ocurrir antes del join.
3. **Q3 (reporte mensual)** trabaja bien gracias a `ix_estancia_periodo_vehiculo`
   y `ix_estancia_vehiculo_periodo_cov`; el límite está en el **agregado-sort**
   de ~250k filas por mes y el join con 18k residentes (correcto para
   "todos los residentes, incluso sin estancias"). A reporte de millones de
   filas por mes conviene **particionar** (sección 6).
4. **Q8 en su forma original, incluso con índices, apenas mejora (−9 %)**:
   el plan Bitmap resuelve el mes por índices pero el **join a los catálogos y
   el sort de 250k grupos dominan el costo**. Es la evidencia de que **un
   índice no arregla una mala forma de consulta**; la reescritura "agregar
   antes de unir" es la pieza decisiva (3.1×).

## 4. Índices propuestos (`database/indexes.sql`) y orden de columnas

### 4.1 `ix_estancia_periodo_cerrada_cov`

```sql
CREATE INDEX ix_estancia_periodo_cerrada_cov
  ON parking.estancia (periodo, salida_en)
  INCLUDE (vehiculo_id, duracion_minutos, cargo)
  WHERE salida_en IS NOT NULL;
```

**Orden de columnas:**
1. `periodo`: **igualdad** (WHERE mes = ...). Primero columnas de igualdad.
2. `salida_en`: rango/`IS NOT NULL` del reporte (después de la igualdad).
3. `INCLUDE(vehiculo_id, duracion_minutos, cargo)`: **no ordenadas**, solo
   payload para poder responder SIN ir al heap (index-only scan).

`WHERE salida_en IS NOT NULL` (parcial): las estancias abiertas no ocupan el
índice → menor tamaño y menor coste de mantenimiento.

### 4.2 `ix_estancia_salida_cerrada`

```sql
CREATE INDEX ix_estancia_salida_cerrada
  ON parking.estancia (salida_en)
  WHERE salida_en IS NOT NULL;
```
Soporta rangos de salida (reportes diarios/mensuales por día de salida).
Un solo nivel de clave basta; no se incluyen payload porque el join a
`vehiculo`/`tipo_vehiculo` fuerza visitar el heap de todas formas.

### 4.3 `ix_estancia_vehiculo_periodo_cov`

```sql
CREATE INDEX ix_estancia_vehiculo_periodo_cov
  ON parking.estancia (vehiculo_id, periodo)
  INCLUDE (duracion_minutos, cargo);
```
Apoya el **reporte mensual de residentes** (Q3) y el cierre mensual: igualdad
por vehículo (equi-join) y luego intervalo de mes; `duracion`/`cargo` como
payload para agregados sin ir al heap.

### 4.4 Índice existente que NO aporta en este patrón de acceso

`ix_estancia_entrada (entrada_en)`: rango de entrada sin `periodo` agrega
ambigüedad de plan y coste de escritura; se sustituye por la **combinación** de
`periodo` en los índices anteriores y el parcial `ix_estancia_abierta_entrada`
para "quién lleva más tiempo dentro".

## 5. Impacto de los índices en operaciones de escritura

- Cada `INSERT`/`UPDATE`/`DELETE` sobre `estancia` debe mantener **todos los
  índices** de la tabla. Coste adicional por fila ≈ `O(k·log N)`, donde k =
  número de índices y N = filas.
- Con los índices de optimización, `estancia` pasa a ~10 índices
  (PK + 6+5). Para el patrón del estacionamiento (muchas entradas/salidas,
  pocos UPDATE destructivos), la penalización de escritura es aceptable si el
  **volumen de estancias por segundo es moderado**.
- Mitigaciones aplicadas:
  - **Parciales**: las filas fuera del predicado no mantienen entrada.
  - **INCLUDE**: no infla la clave (la clave sigue siendo corta), menos bytes
    por entrada → menos I/O de escritura.
  - **Borrar redundantes** (p. ej. `ix_estancia_entrada`) para no pagar
    mantenimiento sin beneficio.
- **Medida** (`pg_stat_user_indexes`):

```sql
SELECT relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes
WHERE relname = 'estancia'
ORDER BY idx_scan;
```

> En un entorno de escritura intensiva (> miles de estancias/minuto) medir el
> delta con y sin índices; revisar si `ix_estancia_tarifa` y `ix_estancia_entrada`
> se usan realmente (`idx_scan = 0`) y, de no usarse, considerarlos para
> eliminación y reducir el coste de escritura.

## 6. ¿Particionamiento? Sí, bajo estas condiciones

**Decisión:** particionar `estancia` por **`RANGE (periodo)` mensual** cuando:

- el volumen supere ~**50M de filas** o ~**10 GiB** (punto donde el seq scan y
  el vaciado por `autovacuum` degradan), o
- se quiera **archivar** rápido: `DETACH PARTITION` del mes viejo y moverla a
  almacenamiento de bajo costo / readonly,
- los reportes del mes actual operan sobre ~1/12 del total (pruning), y
- `autovacuum` sobre cada partición resulte manejable.

Diseño:

```sql
CREATE TABLE parking.estancia_p (LIKE parking.estancia INCLUDING ALL)
PARTITION BY RANGE (periodo);

CREATE TABLE parking.estancia_2026_08 PARTITION OF parking.estancia_p
  FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
-- ... una partición por mes + DEFAULT para meses futuros
```

Detalles/a considerar:

- La **clave de partición** (`periodo`) está alineada con todas las consultas
  mensuales y con `ix_estancia_periodo_*`.
- Los **índices** se crean por partición (o un único `CREATE INDEX` sobre la
  partición padre los replica).
- El **cierre mensual y Q4/Q8/Q3** se benefician de *partition pruning*:
  el executor solo abre la partición del mes.
- Coste: gestión de particiones nuevas (job mensual), y los códigos que
  insertan `entrada_en` (sin `periodo`) seguirán usando el trigger
  `trg_estancia_periodo` que ya calcula el mes.
- Script de referencia: `database/particionamiento.sql` (extra, no aplicado por
  defecto en la demo para no interferir con las mediciones de `estancia`).

**Alternativa archivado sin particiones:** tabla `estancia_historico` +
INSERT/SELECT con `DELETE` al mover meses > X (RSP) — equivalente funcional pero
más lento y con más locks; el particionamiento declarativo es la opción
recomendada.

## 7. Comparativa resumida (evidencias enlazadas)

| | ANTES | DESPUÉS |
|---|---|---|
| Datasets | 3,000,093 estancias, 60,015 vehículos, 18,004 residentes | igual |
| Q8 optimizada | 329 ms · seq scan 3M | **106 ms** · index-only (16.9k páginas de índice) |
| Q4 (7 días, mes poblado) | 560 ms · seq scan 3M | **185 ms** · bitmap (índice parcial de salida) |
| Evidencia completa | `evidencias/performance-before.out` | `evidencias/performance-after.out` |

Comandos de reproducción:

```bash
# Generar datos masivos (dentro del contenedor)
docker compose exec -T db psql -U park_superuser -d estacionamiento -f scripts/generate-fake-data.sql

# Quitar índices de optimización (reiniciar estado "antes")
docker compose exec db psql -U park_superuser -d estacionamiento -c \
 "DROP INDEX IF EXISTS parking.ix_estancia_vehiculo_periodo_cov, parking.ix_estancia_periodo_cerrada_cov, parking.ix_estancia_salida_cerrada, parking.ix_estancia_abierta_entrada;"

# Medir antes
docker compose exec -T db psql -U park_superuser -d estacionamiento \
 -v etiqueta=ANTES -f scripts/performance-evidences.sql

# Aplicar índices y medir después
docker compose exec -T db psql -U park_superuser -d estacionamiento -f database/indexes.sql
docker compose exec -T db psql -U park_superuser -d estacionamiento \
 -v etiqueta=DESPUES -f scripts/performance-evidences.sql
```