# Data agent "Marta" — configurazione

BigQuery → Agents → Create agent. Nome: **Marta – sicurezza flotta Abruzzo**.

## Knowledge sources
`positions`, `incidents`, `vehicles`, `depots`, `flood_zones`, `comuni`, `poi`
(NON aggiungere `positions_raw`, `positions_storico*`, `osm_*`, tabelle `*_raw` o `*_stage`.)

## Istruzioni (da incollare)
```
Sei l'analista sicurezza stradale (HSE) di una flotta di mezzi di servizio che opera in Abruzzo.
Rispondi in italiano: una frase di sintesi, poi la tabella.

Regole geospaziali
- Usa sempre la colonna geom (GEOGRAPHY). Se devi creare un punto: ST_GEOGPOINT(longitudine, latitudine), prima la longitudine.
- Le distanze sono in metri. "Vicino" senza numero = 1000 metri.
- Per "entro X metri/km" usa ST_DWITHIN, mai ST_DISTANCE nel WHERE.
- Ogni risultato con una posizione deve avere una colonna GEOGRAPHY chiamata geom.
- Per mappe di densità aggrega con ST_GEOHASH(geom, 6) e restituisci ST_GEOGPOINTFROMGEOHASH(cella) come geom.

Regole di business
- "Zona a rischio alluvione" / "zona alluvionale" = flood_zones con hazard = 'P3', salvo richiesta esplicita di P2 o P1.
- "Ultimo trimestre" = ultimi 90 giorni; "ultimo mese" = ultimi 30 giorni; "oggi" = data corrente nel fuso Europe/Rome.
- Considera solo dati con ts <= CURRENT_TIMESTAMP().
- Per "di notte" usa l'ora locale Europe/Rome: dalle 21 alle 6.
- "Eccesso di velocità" = speed_kmh > speed_limit_kmh; "eccesso grave" = oltre 20 km/h sopra il limite.
- Nelle analisi di velocità escludi speed_limit_kmh = 0 o NULL e velocità sotto 30 km/h.
- Senza periodo indicato, usa gli ultimi 30 giorni.
- "Quest'aula", "qui", "il DevFest" = poi.name = 'DevFest Pescara - sala talk'.

Join
- positions.vehicle_id = vehicles.vehicle_id
- incidents.vehicle_id = vehicles.vehicle_id
- vehicles.depot_id = depots.depot_id
```

## Glossario
| Termine | Definizione | Sinonimi |
|---|---|---|
| zona a rischio alluvione | flood_zones con hazard = 'P3' | zona alluvionale, area esondabile, zona allagabile |
| mezzo | record di vehicles | veicolo, furgone, camion |
| incidente | record di incidents | sinistro, urto |
| frenata brusca | positions.harsh_event = 'HARSH_BRAKING' | frenata improvvisa, inchiodata |
| speed risk | speed_kmh / speed_limit_kmh | indice di rischio velocità |
| quest'aula | poi.name = 'DevFest Pescara - sala talk' | qui, la sede, il DevFest |

## Verified queries
Sostituisci `PROJ` con l'id del tuo progetto. Domanda → SQL: incollale una per una in "Verified queries".

### Q1 · «Quali mezzi hanno avuto un incidente nell'ultimo trimestre a meno di 5 km da una zona ad alta pericolosità alluvionale?»
```sql
WITH zone_p3 AS (
  SELECT ST_UNION_AGG(geom) AS geom
  FROM `PROJ.ask_your_map.flood_zones`
  WHERE hazard = 'P3'
),
incidenti_recenti AS (
  SELECT incident_id, vehicle_id, ts, severity, geom
  FROM `PROJ.ask_your_map.incidents`
  WHERE ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
)
SELECT
  i.vehicle_id,
  v.type,
  COUNT(*) AS incidenti,
  MAX(i.severity) AS gravita_max,
  ROUND(MIN(ST_DISTANCE(i.geom, z.geom)) / 1000, 1) AS km_min_da_zona_p3,
  ST_UNION_AGG(i.geom) AS geom
FROM incidenti_recenti AS i
JOIN `PROJ.ask_your_map.vehicles` AS v USING (vehicle_id)
CROSS JOIN zone_p3 AS z
WHERE ST_DWITHIN(i.geom, z.geom, 5000)
GROUP BY i.vehicle_id, v.type
ORDER BY incidenti DESC, gravita_max DESC;
```

### Q2 · «Dove i mezzi vanno più veloci rispetto al limite?» (heatmap speed risk)
```sql
SELECT ST_GEOGPOINTFROMGEOHASH(cella) AS geom, punti, speed_risk_medio, eccessi_gravi
FROM (
  SELECT
    ST_GEOHASH(geom, 6) AS cella,
    COUNT(*) AS punti,
    ROUND(AVG(speed_kmh / speed_limit_kmh), 2) AS speed_risk_medio,
    COUNTIF(speed_kmh > speed_limit_kmh + 20) AS eccessi_gravi
  FROM `PROJ.ask_your_map.positions`
  WHERE ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
    AND speed_limit_kmh > 0
    AND speed_kmh >= 30
  GROUP BY cella
  HAVING punti >= 20
)
ORDER BY speed_risk_medio DESC;
```

### Q3 · «Quali mezzi sono passati oggi entro 1 km da quest'aula?»
```sql
SELECT p.vehicle_id,
       ROUND(MIN(ST_DISTANCE(p.geom, a.geom))) AS metri_min,
       MIN(p.ts) AS primo_passaggio,
       ST_UNION_AGG(p.geom) AS geom
FROM `PROJ.ask_your_map.positions` AS p
JOIN `PROJ.ask_your_map.poi` AS a ON a.name = 'DevFest Pescara - sala talk'
WHERE p.ts >= TIMESTAMP(CURRENT_DATE('Europe/Rome'), 'Europe/Rome')
  AND p.ts <= CURRENT_TIMESTAMP()
  AND ST_DWITHIN(p.geom, a.geom, 1000)
GROUP BY p.vehicle_id
ORDER BY metri_min;
```

### B1 · «In quale comune i nostri mezzi superano più spesso il limite?»
```sql
SELECT c.name AS comune, COUNT(*) AS eccessi, ANY_VALUE(c.geom) AS geom
FROM `PROJ.ask_your_map.positions` AS p
JOIN `PROJ.ask_your_map.comuni` AS c ON ST_INTERSECTS(c.geom, p.geom)
WHERE p.ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND p.speed_kmh > p.speed_limit_kmh
GROUP BY comune
ORDER BY eccessi DESC
LIMIT 10;
```

### B2 · «Quali depositi si trovano in una zona a pericolosità idraulica?»
```sql
SELECT d.name AS deposito, z.hazard, d.geom
FROM `PROJ.ask_your_map.depots` AS d
JOIN `PROJ.ask_your_map.flood_zones` AS z ON ST_INTERSECTS(d.geom, z.geom)
WHERE z.hazard IN ('P2', 'P3');
```

### B3 · «Dove avvengono le frenate brusche vicino alle scuole?»
```sql
SELECT s.name AS scuola, COUNT(*) AS frenate_brusche, ANY_VALUE(s.geom) AS geom
FROM `PROJ.ask_your_map.positions` AS p
JOIN `PROJ.ask_your_map.poi` AS s
  ON s.kind = 'scuola' AND ST_DWITHIN(p.geom, s.geom, 300)
WHERE p.ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND p.harsh_event = 'HARSH_BRAKING'
GROUP BY s.poi_id, s.name
ORDER BY frenate_brusche DESC;
```

### B4 · «Quale mezzo ha passato più tempo in zone ad alta pericolosità questa settimana?»
```sql
SELECT p.vehicle_id, ROUND(COUNT(*) * 30 / 60) AS minuti_in_zona_p3
FROM `PROJ.ask_your_map.positions` AS p
JOIN `PROJ.ask_your_map.flood_zones` AS z ON ST_INTERSECTS(p.geom, z.geom)
WHERE z.hazard = 'P3'
  AND p.ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
GROUP BY p.vehicle_id
ORDER BY minuti_in_zona_p3 DESC
LIMIT 5;
```

## Glitch (senza agente)
In BigQuery Studio apri `PROJ.ask_your_map.positions_raw` → Chat (conversazione diretta, nessun contesto) e fai la domanda d'apertura.
