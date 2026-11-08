#!/usr/bin/env bash
# Prepara le aree ISPRA a pericolosita' idraulica per l'Abruzzo e le carica in BigQuery.
# Uso: PROJ=... BUCKET=... ./load_flood.sh aree_pericolosita_idraulica_v5_2020_4258.gpkg
# Richiede GDAL >= 3.1 (ogr2ogr, ogrinfo: li hai con QGIS).
#
# La classe (P1/P2/P3) viene presa dal nome del layer. Se il GeoPackage ha un solo layer
# con la classe in un campo, passa il nome del campo:  HAZARD_FIELD=nome_campo ./load_flood.sh ...
set -euo pipefail
: "${PROJ:?}"; : "${BUCKET:?}"
GPKG=${1:?percorso del .gpkg ISPRA (o dello zip IdroGEO con gli shapefile)}
# lo zip IdroGEO (Mosaicatura_ISPRA_2020_aree_pericolosita_idraulica.zip) si legge senza scompattarlo
case "$GPKG" in *.zip) GPKG="/vsizip/$(cd "$(dirname "$GPKG")" && pwd)/$(basename "$GPKG")";; esac
OUT=flood_abruzzo.geojsonl
TMP=$(mktemp -d)
rm -f "$OUT"

echo "Layer nel GeoPackage:"; ogrinfo -q "$GPKG"
for LAYER in $(ogrinfo -q "$GPKG" | sed -n 's/^[0-9]*: \([^ ]*\).*/\1/p'); do
  HZ=$(echo "$LAYER" | grep -oiE 'p[123]' | head -1 | tr '[:lower:]' '[:upper:]' || true)
  # shapefile IdroGEO: HPH_..._elevata = P3, MPH_..._media = P2, LPH_..._bassa = P1
  case "$LAYER" in *elevata*) HZ=P3;; *media*) HZ=P2;; *bassa*) HZ=P1;; esac
  if [ -n "${HAZARD_FIELD:-}" ]; then EXPR="CAST(\"${HAZARD_FIELD}\" AS TEXT)"; else EXPR="'${HZ}'"; fi
  echo "-> layer ${LAYER}: hazard = ${HZ:-dal campo $HAZARD_FIELD}"
  # due passaggi: GDAL non accetta -spat_srs insieme a -sql
  ogr2ogr -f GPKG -t_srs EPSG:4326 -spat 13.0 41.65 14.85 42.92 -spat_srs EPSG:4326 \
    -makevalid -nlt PROMOTE_TO_MULTI -nln clip "$TMP/$LAYER.gpkg" "$GPKG" "$LAYER"
  ogr2ogr -f GeoJSONSeq -dialect sqlite -sql "SELECT *, ${EXPR} AS hazard FROM clip" \
    -lco RS=NO "$TMP/$LAYER.geojsonl" "$TMP/$LAYER.gpkg"
  cat "$TMP/$LAYER.geojsonl" >> "$OUT"
done
echo "Feature totali: $(wc -l < "$OUT")"

gsutil cp "$OUT" "gs://${BUCKET}/ask_your_map/flood/${OUT}"
bq load --project_id="$PROJ" --location=US --replace \
  --source_format=NEWLINE_DELIMITED_JSON --json_extension=GEOJSON --autodetect \
  ask_your_map.flood_stage "gs://${BUCKET}/ask_your_map/flood/${OUT}"
echo "Fatto. Il file locale ${OUT} serve anche al generatore (--flood)."
