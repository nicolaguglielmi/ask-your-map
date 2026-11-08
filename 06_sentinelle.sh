#!/usr/bin/env bash
# Le Sentinelle: stessa domanda sullo storico di 5 anni, due modi di scriverla.
# Il dry-run stima i byte senza eseguire (e senza costi). Poi esegue davvero per i byte fatturati.
# Uso: PROJ=... ./06_sentinelle.sh
set -euo pipefail
: "${PROJ:?}"
Q2019="SELECT vehicle_id, ts, speed_kmh FROM \`${PROJ}.ask_your_map.positions_storico_raw\`
WHERE ST_DISTANCE(ST_GEOGPOINT(lon, lat), ST_GEOGPOINT(14.22502, 42.45187)) < 1000"
QOGGI="SELECT vehicle_id, ts, speed_kmh FROM \`${PROJ}.ask_your_map.positions_storico\`
WHERE ST_DWITHIN(geom, ST_GEOGPOINT(14.22502, 42.45187), 1000)"

for NAME in 2019 OGGI; do
  VAR="Q${NAME}"
  echo "== ${NAME} =="
  echo "${!VAR}"
  bq query --project_id="$PROJ" --location=US --use_legacy_sql=false --dry_run "${!VAR}" | tail -1
  JOB="sentinelle_${NAME}_$(date +%s)"
  bq query --project_id="$PROJ" --location=US --use_legacy_sql=false --nouse_cache --max_rows=0 --job_id="$JOB" "${!VAR}" > /dev/null
  bq show --project_id="$PROJ" --location=US --format=prettyjson -j "$JOB" | grep -E '"totalBytes(Processed|Billed)"'
done
echo "Il dry-run su una tabella clusterizzata stima il massimo: i byte fatturati reali sono quelli del job."
