#!/usr/bin/env bash
# Esegue uno script SQL sostituendo PROJ e BUCKET.
# Uso: PROJ=mio-progetto BUCKET=mio-bucket ./run_sql.sh 04_build.sql [altri flag bq, es. --dry_run]
set -euo pipefail
: "${PROJ:?imposta PROJ (id progetto GCP)}"
FILE=${1:?file .sql}; shift || true
SQL=$(sed -e "s/PROJ/${PROJ}/g" -e "s/BUCKET/${BUCKET:-BUCKET_NON_IMPOSTATO}/g" "$FILE")
# la SQL passa da stdin: se iniziasse con "--" (commento) bq la leggerebbe come flag
printf '%s\n' "$SQL" | bq query --project_id="$PROJ" --location=US --use_legacy_sql=false --max_rows=100 "$@"
