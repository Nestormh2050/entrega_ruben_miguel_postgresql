# Diseño NoSQL — Capa analítica e histórico de eventos

> Parte 8 de la prueba. Diseño de una solución documental (MongoDB/Amazon
> DocumentDB) para descargar de PostgreSQL las lecturas pesadas del histórico
> (millones de estancias, auditoría, reportes de agregación) sin sacrificar la
> integridad transaccional del esquema de negocio.

## 1. Motivación y límites del SQL en este caso

- `parking.estancia` alcanza decenas de millones de filas y los reportes
  marcan `SUM/COUNT/GROUP BY` sobre rangos grandes; aunque se particione y se
  usen índices cubrientes (Parte 4), el coste de CPU/I/O lo paga el mismo
  cluster transaccional.
- La **auditoría** (tabla que solo crece, append-only) no pertenece al OLTP.
- Se necesita separar **OLTP (transaccional)** de **OLAP/lecturas analíticas**
  sin duplicar esfuerzo de integración por cada reporte.

## 2. Piedra: divide la arquitectura en dos sistemas

```
                 +--------------------+
   Aplicación    |  PostgreSQL (OLTP) |  parking.*  (transaccional, FKs, triggers)
   (operativa)   |  estacionamiento   |  auditoria  (bitácora del olá)
                 +--------------------+
                         | logical replication (WAL)  / CDC (Debezium) / JSONB
                         v
                 +--------------------+
   Reportes /    |  MongoDB (OLAP)    |  collections: vehiculos, estancias (agregadas)
   análisis      |  histórico NoSQL   |  residentes, cierre_mensual, eventos_auditoria
                 +--------------------+
```

- **Operativo**: toda escritura de la app sigue en PostgreSQL (consistencia,
  transacciones, integridad referencial garantizada por el modelo relacional).
- **Analítico**: lecturas masivas de reportes (Q2, Q3, Q4, Q8) y búsquedas de
  histórico se sirven desde la copia NoSQL.
- **Sincronización**: CDC desde el WAL de PostgreSQL -> topic de eventos ->
  consumidor que materializa los documentos (upsert) y re-agrega los cierres.

## 3. Documentos de diseño (MongoDB / DocumentDB)

### 3.1 Colección `vehiculos` (perfil + historial resumido)

```json
{
  "_id": 10001,
  "placa": "ABC-123",
  "tipo_vehiculo": "VISITANTE",
  "marca": "Honda",
  "modelo": "Civic",
  "color": "Gris",
  "residente_activo": false,
  "ultima_entrada": "2026-09-22T15:30:00-06:00",
  "estancia_abierta": false,
  "estadisticas": {
    "estancias_30d": 12,
    "total_minutos_30d": 340,
    "total_cargo_30d": 120.50
  }
}
```

**Patrón de acceso**: ficha de un vehículo al instante (perfil + 30 días);
evita joins con el histórico de uso del vehículo.

### 3.2 Colección `estancias` (el evento agregado)

Documento por **estancia** + **momentos del mes** (pre-agregado por día):

```json
{
  "_id": 900001,
  "vehiculo_id": 10001,
  "placa": "ABC-123",
  "entrada_en": "2026-08-05T09:00:00-06:00",
  "salida_en":   "2026-08-05T10:15:00-06:00",
  "periodo": "2026-08-01",
  "duracion_minutos": 75,
  "cargo": 37.50,
  "tipo_vehiculo": "VISITANTE",
  "residente": { "id": 5, "nombre": "Juan Pérez" },
  "cierre_mensual": { "id": 12, "periodo": "2026-08-01" }
}
```

**Patrón de acceso**:
- "Estancias del mes X por vehículo": índice `{vehiculo_id:1, periodo:1}`.
- "Ingresos por día y tipo" (Q4): índice `{salida_en:1, tipo_vehiculo:1}`.
- "Top de minutos acumulados" (Q8): **agregación por pipeline** con
  `$group` por `placa` + sort + limit; MongoDB toma muestra SAMPLE del
  historial si el volumen es enorme (sea transparente).

### 3.3 Colección `cierre_mensual` (reporte pre-calculado, anti-join)

```json
{
  "_id": 12,
  "periodo": "2026-08-01",
  "generado_en": "2026-09-01T00:05:00-06:00",
  "resumen": {
    "total_estancias": 250012,
    "residentes_activos": 18004,
    "ventas_visitantes": 987654.30,
    "cargos_mensuales": 54321.00
  },
  "top_residentes": [
    { "residente_id": 4, "nombre": "...", "minutos": 6432, "cargo": 321.60 },
    { "residente_id": 9, "nombre": "...", "minutos": 5901, "cargo": 295.05 }
  ],
  "ingresos_por_dia": [
    { "dia": "2026-08-01", "tipo": "VISITANTE", "total": 4520.0 }
  ]
}
```

**Patrón de acceso**: la pantalla del director pregunta "¿cuánto ingresó y
quiénes son los top este mes?" sin tocar millones de filas: **un documento**.

### 3.4 Colección `eventos_auditoria` (append-only)

```json
{
  "_id": 1000001,
  "momento": "2026-08-05T09:00:00-06:00",
  "operacion": "U",
  "tabla": "residente",
  "registro_id": "5",
  "usuario": "recepción",
  "antes": { "activo": true,   "telefono": "55-0000-0001" },
  "despues": { "activo": false, "telefono": "55-0000-0001" }
}
```
TTL index sobre `momento` (p. ej. 24 meses) para auto-vaciado — en SQL exigiría
partición y `DROP PARTITION`.

## 4. Modelado y diseño clave (clave de partición si fuese DynamoDB)

| Colección | Clave de partición | Clave de ordenación | Uso |
|---|---|---|---|
| estancias | `vehiculo_id` | `entrada_en` | Accesos por vehículo y rango temporal |
| eventos | `tabla` + `momento(iso)` | `registro_id` | Escaneo por tabla y ventana |
| cierre_mensual | `periodo` | — | 1 documento por mes |
| vehiculos | `placa` | — | Identidad natural |

Elección: **por vehículo** es el acceso dominante (historial de un auto);
**agregados por mes** se sirven desde `cierre_mensual`.

## 5. Justificación de la decisión NoSQL vs SQL

| Criterio | PostgreSQL (OLTP) | MongoDB (analítico) |
|---|---|---|
| Consistencia | ACID, integridad referencial, triggers | eventual, agregada, tolerante al fallo |
| Escritura | única fuente de verdad | no escriben la app: espejo CDC |
| Reportes masivos | coste alto comparte cluster | **anti-join/pre-agregado**, escala horizontal (sharding por `vehiculo_id`/`periodo`) |
| Auditoría append-only | compite con el OLTP | TTL y sharding natural |
| Flexibilidad de campos (nuevos estados de ticket) | esquema rígido (migración) | esquema libre por documento |

**Cuándo NO**: transacciones que cruzan varias tablas (entrada/salida, cargo y
pago) deben vivir en PostgreSQL: un pago y su cargo deben ser o ambos o
ninguno. NoSQL para operación diaria del kiosco sería un retroceso.

## 6. Sincronización (CDC) y operativa

1. **Habilitar réplica lógica en PostgreSQL** (publicaciones `parking.*`,
   `auditoria.*`); o Debezium de la app (captura del WAL).
2. El consumidor:
   - Upsert de `vehiculos`, `estancias`.
   - Re-agregación del mes (`cierre_mensual`) solo al cerrar el mes (trabajo
     del `parking.proceder_cierre_mensual` que ya conoce del OLTP) o al
     detectar `UPDATE` de `incluye_cierre`.
   - Encabezado de eventos para la auditoría.
3. **Retirada de la lectura pesada del OLTP**: los reportes Q2–Q8 leen de
   MongoDB. PostgreSQL guarda CPU para transacciones y evita lanzarse réplicas
   de solo-lectura de alto costo si no harían falta.

## 7. Proveedores en la nube y coste estimado (referencia)

| Opción | Servicio | Cuándo usarla |
|---|---|---|
| AWS | **DocumentDB** 3.6+ (compatible MongoDB) | Si el stack ya está en AWS; cluster multi-AZ |
| AWS | **DynamoDB** (on-demand + TTL) | Si los accesos son SÓLO clave-valor/agregado y quieres cero gestión |
| Azure | **Cosmos DB (Mongo API)** | Si el equipo usa Azure; SLA 99.999 % multirregión |
| GCP | **Firestore / MongoDB Atlas** | Latencia global o llevado por el equipo Mongo |

Coste orientativo (DynamoDB on-demand): los reportes del día leen ~1–3 MB
(agregados), los eventos con TTL 24 meses crecen pero se auto-vacían; el coste
dominante son las escrituras del CDC (algunos miles de eventos/día → pocos
dólares/mes). DocumentDB 2 nodos t3.medium ≈ 60–100 USD/mes. Se elige
DocumentDB si interesa el **pipeline de agregación Mongo** nativo.

## 8. Plan de entrega (fases)

| Fase | Entregable | Validación |
|---|---|---|
| F1 | Colecciones + índices en el cluster de prueba | Documentos con datos de la demo (3M estancias) |
| F2 | Pequeño consumidor CDC (por lotes nocturno inicial) | Conteos estancias/residentes idénticos |
| F3 | Reportes Q3/Q4/Q8 leyendo de NoSQL | Tiempos p95 reportados en `docs/performance-analysis.md` |
| F4 | TTL de auditoría y alertas de lag del CDC | Alerta si lag > 5 min |

## 9. Limitaciones y decisiones de la propuesta

- La consistencia **eventual** exige que las pantallas operativas sigan leyendo
  de PostgreSQL; solo los reportes/analítica leen NoSQL.
- La copia analítica **no es la fuente de verdad**; si se detecta divergencia,
  se re-materializa desde Postgres (job de reconciliación).
- Los agregados del mes se pre-calculan con `proceder_cierre_mensual` (ya
  existente); el director ve **cifras cerradas**, no estimaciones.