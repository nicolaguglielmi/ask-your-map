-- 04_build.sql
-- Costruisce le tabelle "pulite" che userà il data agent, piu' lo storico per le Sentinelle.
-- Prerequisiti: 01_osm_extract.sql, load_flood.sh, 03_load.sh

-- ---------------------------------------------------------------- zone alluvionali ISPRA
CREATE OR REPLACE TABLE `PROJ.ask_your_map.flood_zones`
CLUSTER BY geom AS
SELECT
  ROW_NUMBER() OVER () AS zone_id,
  UPPER(REGEXP_EXTRACT(CAST(hazard AS STRING), r'(?i)P[123]')) AS hazard,
  geometry AS geom
FROM `PROJ.ask_your_map.flood_stage`
WHERE REGEXP_CONTAINS(CAST(hazard AS STRING), r'(?i)P[123]');

-- ---------------------------------------------------------------- anagrafiche
CREATE OR REPLACE TABLE `PROJ.ask_your_map.depots` AS
SELECT depot_id, name, ST_GEOGPOINT(lon, lat) AS geom
FROM `PROJ.ask_your_map.depots_raw`;

CREATE OR REPLACE TABLE `PROJ.ask_your_map.incidents` AS
SELECT incident_id, vehicle_id, ts, ST_GEOGPOINT(lon, lat) AS geom, severity, kind
FROM `PROJ.ask_your_map.incidents_raw`;

CREATE OR REPLACE TABLE `PROJ.ask_your_map.poi` AS
SELECT poi_id, name, 'scuola' AS kind, geom FROM `PROJ.ask_your_map.osm_schools`
UNION ALL
-- sala del talk: coordinate da rifinire con Maps il giorno prima
SELECT 'DEVFEST', 'DevFest Pescara - sala talk', 'evento', ST_GEOGPOINT(14.22502, 42.45187);

-- ---------------------------------------------------------------- posizioni (tabella dell'agente)
CREATE OR REPLACE TABLE `PROJ.ask_your_map.positions`
CLUSTER BY geom, vehicle_id AS
SELECT vehicle_id, ts, ST_GEOGPOINT(lon, lat) AS geom, speed_kmh, speed_limit_kmh,
       NULLIF(harsh_event, '') AS harsh_event
FROM `PROJ.ask_your_map.positions_raw`;

-- ---------------------------------------------------------------- storico 5 anni per le Sentinelle
-- Stessi percorsi ripetuti all'indietro: 15 finestre da 120 giorni (circa 23 milioni di righe).
CREATE OR REPLACE TABLE `PROJ.ask_your_map.positions_storico_raw` AS
SELECT vehicle_id, TIMESTAMP_SUB(ts, INTERVAL 120 * k DAY) AS ts, lat, lon, speed_kmh, speed_limit_kmh, harsh_event
FROM `PROJ.ask_your_map.positions_raw`, UNNEST(GENERATE_ARRAY(0, 14)) AS k;

CREATE OR REPLACE TABLE `PROJ.ask_your_map.positions_storico`
CLUSTER BY geom AS
SELECT vehicle_id, ts, ST_GEOGPOINT(lon, lat) AS geom, speed_kmh, speed_limit_kmh,
       NULLIF(harsh_event, '') AS harsh_event
FROM `PROJ.ask_your_map.positions_storico_raw`;

-- ---------------------------------------------------------------- descrizioni (le legge l'agente)
ALTER TABLE `PROJ.ask_your_map.positions` SET OPTIONS (description = 'Posizioni GPS dei mezzi della flotta, una ogni 30 secondi di guida. Dati sintetici.');
ALTER TABLE `PROJ.ask_your_map.positions` ALTER COLUMN vehicle_id SET OPTIONS (description = 'Codice del mezzo, es. MZ-07. Join con vehicles.vehicle_id');
ALTER TABLE `PROJ.ask_your_map.positions` ALTER COLUMN ts SET OPTIONS (description = 'Istante della rilevazione (UTC). Per ora locale usare il fuso Europe/Rome');
ALTER TABLE `PROJ.ask_your_map.positions` ALTER COLUMN geom SET OPTIONS (description = 'Posizione del mezzo, punto GEOGRAPHY WGS84');
ALTER TABLE `PROJ.ask_your_map.positions` ALTER COLUMN speed_kmh SET OPTIONS (description = 'Velocità rilevata in km/h');
ALTER TABLE `PROJ.ask_your_map.positions` ALTER COLUMN speed_limit_kmh SET OPTIONS (description = 'Limite di velocità della strada in quel punto, km/h (OpenStreetMap)');
ALTER TABLE `PROJ.ask_your_map.positions` ALTER COLUMN harsh_event SET OPTIONS (description = 'Evento di guida brusca: HARSH_BRAKING (frenata brusca), HARSH_ACCELERATION, oppure NULL');

ALTER TABLE `PROJ.ask_your_map.incidents` SET OPTIONS (description = 'Incidenti dei mezzi della flotta. Dati sintetici.');
ALTER TABLE `PROJ.ask_your_map.incidents` ALTER COLUMN geom SET OPTIONS (description = 'Luogo dell\'incidente, punto GEOGRAPHY');
ALTER TABLE `PROJ.ask_your_map.incidents` ALTER COLUMN severity SET OPTIONS (description = 'Gravità da 1 (lieve) a 5 (molto grave)');
ALTER TABLE `PROJ.ask_your_map.incidents` ALTER COLUMN kind SET OPTIONS (description = 'Tipo di incidente');

ALTER TABLE `PROJ.ask_your_map.vehicles` SET OPTIONS (description = 'Anagrafica dei mezzi: tipo e deposito di appartenenza');
ALTER TABLE `PROJ.ask_your_map.depots` SET OPTIONS (description = 'Depositi della flotta, con posizione');

ALTER TABLE `PROJ.ask_your_map.flood_zones` SET OPTIONS (description = 'Aree a pericolosità idraulica ISPRA (Direttiva Alluvioni). P3 = elevata, P2 = media, P1 = bassa');
ALTER TABLE `PROJ.ask_your_map.flood_zones` ALTER COLUMN hazard SET OPTIONS (description = 'Classe di pericolosità: P3 elevata (alluvioni frequenti), P2 media, P1 bassa');

ALTER TABLE `PROJ.ask_your_map.comuni` SET OPTIONS (description = 'Confini dei comuni dell\'Abruzzo (OpenStreetMap)');
ALTER TABLE `PROJ.ask_your_map.poi` SET OPTIONS (description = 'Punti di interesse: scuole (kind = scuola) e la sala del DevFest (kind = evento)');

SELECT
  (SELECT COUNT(*) FROM `PROJ.ask_your_map.positions`)         AS posizioni,
  (SELECT COUNT(*) FROM `PROJ.ask_your_map.positions_storico`) AS posizioni_storico,
  (SELECT COUNT(*) FROM `PROJ.ask_your_map.incidents`)         AS incidenti,
  (SELECT STRING_AGG(hazard || ':' || CAST(n AS STRING), ' ' ORDER BY hazard)
     FROM (SELECT hazard, COUNT(*) n FROM `PROJ.ask_your_map.flood_zones` GROUP BY hazard)) AS zone;
