#!/usr/bin/env bash
# Carica in BigQuery l'output del generatore (cartella out/).
# Uso: PROJ=... BUCKET=... ./03_load.sh [out]
set -euo pipefail
: "${PROJ:?}"; : "${BUCKET:?}"
OUT=${1:-out}
DST="gs://${BUCKET}/ask_your_map/gen"
gsutil -m cp "$OUT"/positions_raw.csv.gz "$OUT"/incidents.csv "$OUT"/vehicles.csv "$OUT"/depots.csv "$DST/"

load() {  # tabella file schema
  bq load --project_id="$PROJ" --location=US --replace --source_format=CSV --skip_leading_rows=1 \
    "ask_your_map.$1" "$DST/$2" "$3"
}
load positions_raw  positions_raw.csv.gz "vehicle_id:STRING,ts:TIMESTAMP,lat:FLOAT64,lon:FLOAT64,speed_kmh:INT64,speed_limit_kmh:INT64,harsh_event:STRING"
load incidents_raw  incidents.csv        "incident_id:STRING,vehicle_id:STRING,ts:TIMESTAMP,lat:FLOAT64,lon:FLOAT64,severity:INT64,kind:STRING"
load vehicles       vehicles.csv         "vehicle_id:STRING,type:STRING,depot_id:STRING"
load depots_raw     depots.csv           "depot_id:STRING,name:STRING,lat:FLOAT64,lon:FLOAT64"
echo "Caricato. Ora: ./run_sql.sh 04_build.sql"
