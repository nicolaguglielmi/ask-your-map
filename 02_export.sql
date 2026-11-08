-- 02_export.sql
-- Esporta strade e scuole su Cloud Storage per il generatore (bucket in US).

EXPORT DATA OPTIONS (uri = 'gs://BUCKET/ask_your_map/export/roads-*.json', format = 'JSON', overwrite = true) AS
SELECT osm_id, highway, maxspeed_tag, oneway, ST_ASGEOJSON(geom) AS geojson
FROM `PROJ.ask_your_map.osm_roads`;

EXPORT DATA OPTIONS (uri = 'gs://BUCKET/ask_your_map/export/schools-*.json', format = 'JSON', overwrite = true) AS
SELECT poi_id, name, ST_ASGEOJSON(geom) AS geojson
FROM `PROJ.ask_your_map.osm_schools`;
