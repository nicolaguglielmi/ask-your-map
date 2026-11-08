-- 05_verify.sql
-- Controlla che le storie piantate escano davvero. Ogni blocco dice cosa aspettarsi.

-- 1) domanda d'apertura (Q1): atteso MZ-07 in testa con 3 incidenti
WITH zone_p3 AS (SELECT ST_UNION_AGG(geom) AS geom FROM `PROJ.ask_your_map.flood_zones` WHERE hazard = 'P3')
SELECT 'Q1' AS check_, i.vehicle_id, COUNT(*) AS incidenti
FROM `PROJ.ask_your_map.incidents` AS i CROSS JOIN zone_p3 AS z
WHERE i.ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  AND ST_DWITHIN(i.geom, z.geom, 5000)
GROUP BY i.vehicle_id ORDER BY incidenti DESC LIMIT 3;

-- 2) deposito in zona a pericolosità: atteso "Deposito Val Pescara" con P2 (e nessuna riga P3)
SELECT 'depositi' AS check_, d.name, z.hazard
FROM `PROJ.ask_your_map.depots` AS d
JOIN `PROJ.ask_your_map.flood_zones` AS z ON ST_INTERSECTS(d.geom, z.geom)
WHERE z.hazard IN ('P2', 'P3');

-- 3) frenate brusche vicino alle scuole: attese 2 scuole di Pescara molto sopra le altre
SELECT 'scuole' AS check_, s.name, COUNT(*) AS frenate_brusche
FROM `PROJ.ask_your_map.positions` AS p
JOIN `PROJ.ask_your_map.poi` AS s ON s.kind = 'scuola' AND ST_DWITHIN(p.geom, s.geom, 300)
WHERE p.ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY) AND p.harsh_event = 'HARSH_BRAKING'
GROUP BY s.name ORDER BY frenate_brusche DESC LIMIT 5;

-- 4) eccessi notturni: atteso MZ-23 nettamente primo
SELECT 'notte' AS check_, vehicle_id, COUNT(*) AS eccessi_notturni
FROM `PROJ.ask_your_map.positions`
WHERE ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND speed_kmh > speed_limit_kmh
  AND (EXTRACT(HOUR FROM ts AT TIME ZONE 'Europe/Rome') >= 21 OR EXTRACT(HOUR FROM ts AT TIME ZONE 'Europe/Rome') < 6)
GROUP BY vehicle_id ORDER BY eccessi_notturni DESC LIMIT 3;

-- 5) hotspot costa: attese celle tra Pescara e Montesilvano (lon 14.15-14.22, lat 42.46-42.53) ai primi posti
SELECT 'costa' AS check_, ST_GEOHASH(geom, 6) AS cella,
       ROUND(AVG(speed_kmh / speed_limit_kmh), 2) AS speed_risk_medio, COUNT(*) AS punti,
       ROUND(ST_X(ST_CENTROID_AGG(geom)), 3) AS lon, ROUND(ST_Y(ST_CENTROID_AGG(geom)), 3) AS lat
FROM `PROJ.ask_your_map.positions`
WHERE ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY) AND speed_limit_kmh > 0 AND speed_kmh >= 30
GROUP BY cella HAVING punti >= 20 ORDER BY speed_risk_medio DESC LIMIT 5;

-- 6) "quest'aula": passaggi entro 1 km dalla sala, per giorno (attesi tutti i giorni, di più il 7 e l'8)
SELECT 'aula' AS check_, DATE(p.ts, 'Europe/Rome') AS giorno, COUNT(DISTINCT p.vehicle_id) AS mezzi
FROM `PROJ.ask_your_map.positions` AS p, `PROJ.ask_your_map.poi` AS a
WHERE a.name = 'DevFest Pescara - sala talk' AND ST_DWITHIN(p.geom, a.geom, 1000)
  AND p.ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 10 DAY)
GROUP BY giorno ORDER BY giorno DESC;
