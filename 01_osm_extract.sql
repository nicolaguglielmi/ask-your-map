-- 01_osm_extract.sql
-- Estrae dall'OpenStreetMap pubblico in BigQuery tutto quello che serve per l'Abruzzo:
-- strade (con maxspeed), scuole, confine regionale e comuni.
-- UNA sola scansione della tabella pubblica (grande): fai prima il dry-run.
--   ./run_sql.sh 01_osm_extract.sql --dry_run
-- Il dataset pubblico sta in US: per questo anche ask_your_map e' in US.

CREATE SCHEMA IF NOT EXISTS `PROJ.ask_your_map` OPTIONS (location = 'US');

-- 1) estrazione grezza (bbox Abruzzo + tag che ci interessano)
CREATE OR REPLACE TABLE `PROJ.ask_your_map.osm_abruzzo_raw` AS
SELECT osm_id, feature_type, all_tags, geometry AS geom
FROM `bigquery-public-data.geo_openstreetmap.planet_features`
WHERE ST_INTERSECTS(
        geometry,
        ST_GEOGFROMTEXT('POLYGON((13.0 41.65, 14.85 41.65, 14.85 42.92, 13.0 42.92, 13.0 41.65))'))
  AND EXISTS (
        SELECT 1 FROM UNNEST(all_tags) AS t
        WHERE (t.key = 'highway' AND t.value IN (
                 'motorway','motorway_link','trunk','trunk_link','primary','primary_link',
                 'secondary','secondary_link','tertiary','tertiary_link','unclassified','residential'))
           OR (t.key = 'amenity' AND t.value = 'school')
           OR (t.key = 'admin_level' AND t.value IN ('4', '8')));

-- 2) confine della regione
CREATE OR REPLACE TABLE `PROJ.ask_your_map.region` AS
SELECT 'Abruzzo' AS name, geom
FROM `PROJ.ask_your_map.osm_abruzzo_raw`
WHERE feature_type = 'multipolygons'
  AND ('admin_level', '4') IN (SELECT (key, value) FROM UNNEST(all_tags))
  AND ('name', 'Abruzzo') IN (SELECT (key, value) FROM UNNEST(all_tags))
QUALIFY ROW_NUMBER() OVER (ORDER BY ST_AREA(geom) DESC) = 1;

-- 3) strade dentro la regione
CREATE OR REPLACE TABLE `PROJ.ask_your_map.osm_roads`
CLUSTER BY geom AS
SELECT
  r.osm_id,
  (SELECT value FROM UNNEST(r.all_tags) WHERE key = 'highway')  AS highway,
  (SELECT value FROM UNNEST(r.all_tags) WHERE key = 'maxspeed') AS maxspeed_tag,
  (SELECT value FROM UNNEST(r.all_tags) WHERE key = 'name')     AS name,
  (SELECT value FROM UNNEST(r.all_tags) WHERE key = 'oneway')   AS oneway,
  r.geom
FROM `PROJ.ask_your_map.osm_abruzzo_raw` AS r, `PROJ.ask_your_map.region` AS reg
WHERE r.feature_type = 'lines'
  AND EXISTS (SELECT 1 FROM UNNEST(r.all_tags) WHERE key = 'highway')
  AND ST_INTERSECTS(r.geom, reg.geom);

-- 4) comuni (OSM admin_level 8: stessi confini ISTAT, una fonte in meno da scaricare)
CREATE OR REPLACE TABLE `PROJ.ask_your_map.comuni`
CLUSTER BY geom AS
SELECT
  (SELECT value FROM UNNEST(c.all_tags) WHERE key = 'ref:ISTAT') AS istat_code,
  (SELECT value FROM UNNEST(c.all_tags) WHERE key = 'name')      AS name,
  c.geom
FROM `PROJ.ask_your_map.osm_abruzzo_raw` AS c, `PROJ.ask_your_map.region` AS reg
WHERE c.feature_type = 'multipolygons'
  AND ('admin_level', '8') IN (SELECT (key, value) FROM UNNEST(c.all_tags))
  AND ST_INTERSECTS(ST_CENTROID(c.geom), reg.geom);

-- 5) scuole (punti o edifici -> centroide)
CREATE OR REPLACE TABLE `PROJ.ask_your_map.osm_schools` AS
SELECT
  CONCAT('OSM-', CAST(s.osm_id AS STRING)) AS poi_id,
  COALESCE((SELECT value FROM UNNEST(s.all_tags) WHERE key = 'name'), 'Scuola senza nome') AS name,
  ST_CENTROID(s.geom) AS geom
FROM `PROJ.ask_your_map.osm_abruzzo_raw` AS s, `PROJ.ask_your_map.region` AS reg
WHERE ('amenity', 'school') IN (SELECT (key, value) FROM UNNEST(s.all_tags))
  AND ST_INTERSECTS(ST_CENTROID(s.geom), reg.geom);

SELECT
  (SELECT COUNT(*) FROM `PROJ.ask_your_map.region`)      AS regioni,      -- deve essere 1
  (SELECT COUNT(*) FROM `PROJ.ask_your_map.osm_roads`)   AS strade,
  (SELECT COUNT(*) FROM `PROJ.ask_your_map.comuni`)      AS comuni,       -- attesi circa 305
  (SELECT COUNT(*) FROM `PROJ.ask_your_map.osm_schools`) AS scuole;
