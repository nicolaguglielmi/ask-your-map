# Ask your map · Parla con la tua mappa

Kit della demo del talk **"Parla con la tua mappa: analisi geospaziale in linguaggio naturale con Gemini e BigQuery"**, DevFest Pescara 2026.

Con questi script ricostruisci a casa lo stesso ambiente della demo: una flotta sintetica di 60 mezzi in Abruzzo, le aree a pericolosità idraulica ISPRA, strade, comuni e scuole da OpenStreetMap, tutto in BigQuery. Sopra ci metti un data agent Gemini (Conversational Analytics) a cui fare domande in italiano.

> I dati della flotta sono **sintetici**: mezzi, percorsi e incidenti sono inventati da `generate_fleet.py`.

## Cosa serve
- Un progetto Google Cloud **nuovo e dedicato**, con la fatturazione attiva. Per i costi vedi sotto.
- `gcloud` e `bq` ([Google Cloud CLI](https://cloud.google.com/sdk/docs/install)), autenticati con `gcloud auth login`.
- Python 3.10 o superiore.
- GDAL 3.1 o superiore (`ogr2ogr`), solo per le aree ISPRA: c'è già se hai QGIS, altrimenti `brew install gdal` o `apt install gdal-bin`.

Tempo: circa 30–45 minuti, quasi tutto attesa.

## Costi
- L'estrazione da OpenStreetMap (`01_osm_extract.sql`) legge la tabella pubblica `planet_features`. Il dry-run stima al massimo circa 330 GB, ma grazie al clustering i byte fatturati sono molti meno. Rientra comunque nel TB di query gratuito al mese.
- Le altre query leggono al massimo 1–2 GB l'una.
- Lo storage è di pochi GB per pochi giorni: centesimi.
- Le funzioni Gemini in BigQuery (data agent) possono avere costi o limiti propri: controlla la pagina prezzi prima di usarle.
- Consiglio: imposta un budget con avvisi sul progetto e, a fine prova, lancia `./99_teardown.sh`.

## 0. Preparazione
```bash
cp env.example.sh env.sh          # poi apri env.sh e metti il tuo PROJ
source env.sh
gcloud services enable bigquery.googleapis.com storage.googleapis.com \
  geminidataanalytics.googleapis.com cloudaicompanion.googleapis.com
gcloud storage buckets create gs://$BUCKET --location=US --uniform-bucket-level-access
python3 -m venv .venv && .venv/bin/pip install numpy networkx scipy shapely
source env.sh                     # di nuovo, per attivare il venv
chmod +x *.sh
```

## 1. OpenStreetMap → BigQuery (strade, comuni, scuole)
```bash
./run_sql.sh 01_osm_extract.sql   # atteso: 1 regione, ~305 comuni, ~60.000 strade, ~400 scuole
./run_sql.sh 02_export.sql
mkdir -p in && gcloud storage cp "gs://$BUCKET/ask_your_map/export/*.json" in/
cat in/roads-*.json > roads.jsonl && cat in/schools-*.json > schools.jsonl
```

## 2. ISPRA → BigQuery (aree a pericolosità idraulica)
Scarica la *Mosaicatura ISPRA 2020 delle aree a pericolosità idraulica* (circa 750 MB) dalla pagina [Open Data di IdroGEO](https://idrogeo.isprambiente.it/app/page/open-data) e passa lo zip così com'è:
```bash
mkdir -p data && curl -L -o data/ispra_idraulica_2020.zip \
  https://idrogeo.isprambiente.it/opendata/wms/Mosaicatura_ISPRA_2020_aree_pericolosita_idraulica.zip
./load_flood.sh data/ispra_idraulica_2020.zip
```
Lo script ritaglia l'Abruzzo, mappa *elevata/media/bassa* su P3/P2/P1 e carica `flood_stage`. Va bene anche il GeoPackage ISPRA, se ne hai una copia.

## 3. Flotta sintetica
```bash
python generate_fleet.py --roads roads.jsonl --schools schools.jsonl \
  --flood flood_abruzzo.geojsonl --out out --end "$(date +%Y-%m-%dT%H:%M)"
```
- `--end` fa finire i dati adesso: le domande tipo "ultimo trimestre" sono relative a oggi.
- Il risultato sono 60 mezzi e 120 giorni di posizioni ogni 30 secondi, circa 2,5 milioni di righe, in un paio di minuti.
- Per una prova veloce aggiungi `--vehicles-scale 0.2 --days 20`.
- In `out/report.json` trovi le scuole scelte, i depositi e i giorni degli incidenti di MZ-07.

## 4. Tabelle finali e verifica
```bash
./03_load.sh out
./run_sql.sh 04_build.sql
./run_sql.sh 05_verify.sql        # ogni blocco dice cosa aspettarsi
./06_sentinelle.sh                # stessa domanda, due modi: byte letti a confronto
```

## 5. Il data agent "Marta"
Segui [`agent_marta.md`](agent_marta.md). Dove trovi `PROJ` nelle query, metti l'id del tuo progetto.

Per vedere la differenza che fa il contesto, apri `positions_raw` in BigQuery Studio, avvia una chat diretta (senza agente) e fai la stessa domanda.

## Le storie nascoste nei dati
1. Hotspot di velocità sulla costa Pescara–Montesilvano.
2. MZ-07: 3 incidenti negli ultimi 90 giorni entro 5 km da zone P3. È la risposta alla domanda d'apertura:
   *«Quali mezzi hanno avuto un incidente nell'ultimo trimestre a meno di 5 km da una zona ad alta pericolosità alluvionale?»*
3. Il deposito Val Pescara è in area P2.
4. Frenate brusche concentrate vicino a 2 scuole di Pescara.
5. MZ-23: eccessi di velocità di notte.
6. Mezzi che passano entro 1 km dalla sala del talk (`--venue lon,lat` per spostarla, e cambiala anche in `04_build.sql`).

## Tabelle
| Tabella | Uso |
|---|---|
| positions, incidents, vehicles, depots, flood_zones, comuni, poi | knowledge sources dell'agente |
| positions_raw | chat diretta senza contesto |
| positions_storico_raw / positions_storico | ~37M righe: senza clustering vs clusterizzata per GEOGRAPHY |
| osm_*, region, *_raw, flood_stage | appoggio |

## Pulizia
```bash
./99_teardown.sh             # cancella dataset ask_your_map e bucket
./99_teardown.sh --project   # in più stacca il billing e cancella il progetto
```

## Fonti e licenze
- **OpenStreetMap**, © OpenStreetMap contributors, [ODbL](https://www.openstreetmap.org/copyright), tramite il dataset pubblico `bigquery-public-data.geo_openstreetmap`.
- **ISPRA**, Mosaicatura nazionale delle aree a pericolosità idraulica 2020: vedi le condizioni d'uso incluse nello zip. Questo repo non ridistribuisce i dati: li scarichi dalla fonte.
- Codice: licenza MIT (vedi `LICENSE`).
