#!/usr/bin/env bash
# Pulizia a fine prova: cancella il dataset ask_your_map e il bucket del kit.
# Uso: source env.sh && ./99_teardown.sh             (dataset + bucket)
#      source env.sh && ./99_teardown.sh --project   (in piu' stacca il billing e cancella il progetto)
# Chiede sempre conferma scrivendo il nome della risorsa.
set -euo pipefail
: "${PROJ:?imposta PROJ (source env.sh)}"; : "${BUCKET:?imposta BUCKET (source env.sh)}"

echo "Progetto: ${PROJ}"
echo "Tabelle nel dataset ask_your_map:"
bq ls --project_id="$PROJ" --max_results=100 ask_your_map 2>/dev/null | sed 's/^/  /' || echo "  (dataset non trovato)"
echo "Bucket: gs://${BUCKET}"
gcloud storage du -s "gs://${BUCKET}" --project="$PROJ" 2>/dev/null | sed 's/^/  /' || echo "  (bucket non trovato)"
echo
read -r -p "Scrivi il nome del bucket per cancellare dataset e bucket: " CONFIRM
[ "$CONFIRM" = "$BUCKET" ] || { echo "Annullato."; exit 1; }

bq rm -r -f --project_id="$PROJ" ask_your_map || true
gcloud storage rm -r "gs://${BUCKET}" --project="$PROJ" || true

if [ "${1:-}" = "--project" ]; then
  read -r -p "Scrivi l'id del progetto per cancellarlo del tutto: " CONFIRM
  [ "$CONFIRM" = "$PROJ" ] || { echo "Progetto non cancellato."; exit 0; }
  gcloud billing projects unlink "$PROJ" || true
  gcloud projects delete "$PROJ" --quiet
  echo "Progetto in cancellazione (recuperabile per 30 giorni con: gcloud projects undelete ${PROJ})"
fi
echo "Fatto."
