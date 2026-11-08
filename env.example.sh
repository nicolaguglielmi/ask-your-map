# Copia questo file in env.sh, metti i tuoi valori e poi:  source env.sh
# Vale solo per la shell corrente: non cambia la configurazione gcloud di default.
export PROJ=il-tuo-progetto-gcp          # usa un progetto NUOVO, dedicato alla prova
export BUCKET=${PROJ}-ask-your-map       # bucket in location US (il dataset OSM pubblico e' in US)
export CLOUDSDK_CORE_PROJECT=$PROJ
export CLOUDSDK_BILLING_QUOTA_PROJECT=$PROJ
[ -d "$(dirname "${BASH_SOURCE[0]:-$0}")/.venv" ] && source "$(dirname "${BASH_SOURCE[0]:-$0}")/.venv/bin/activate"
