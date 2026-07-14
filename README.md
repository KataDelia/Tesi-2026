# Tesi-2026 — Modellazione della vigenza dinamica normativa

**Un approccio basato su grafi per il tracciamento storico della normativa italiana**

Tesi di Delia Anamaria Bogdan

## Indice

- [Contesto e obiettivo](#contesto-e-obiettivo)
- [Architettura](#architettura)
- [Struttura del repository](#struttura-del-repository)
- [Risultati principali](#risultati-principali)
- [Limiti e sviluppi futuri](#limiti-e-sviluppi-futuri)
- [Requisiti e installazione](#requisiti-e-installazione)
- [Come eseguire la pipeline](#come-eseguire-la-pipeline)

## Contesto e obiettivo

La normativa italiana cambia di continuo: ogni legge nuova può abrogare, sostituire o integrare disposizioni precedenti, e la versione di un articolo in vigore oggi può essere l'ennesima di una lunga storia di modifiche. Normattiva conserva questa stratificazione, ma in un formato pensato per la consultazione umana, non per l'interrogazione automatica — e un modello linguistico interpellato su un articolo di legge risponde comunque, senza garanzia che la versione richiamata sia quella effettivamente vigente nel momento richiesto.

L'obiettivo della tesi è progettare un sistema che risponda a domande sulla normativa italiana restando ancorato alle fonti ufficiali, trattando il tempo come parte della **struttura del dato** — non come qualcosa che si spera il modello linguistico interpreti correttamente da solo.

## Architettura

Il lavoro si articola in cinque fasi:

**1. Acquisizione del corpus**
40 codici nazionali in formato multivigente, scaricati dal portale Open Data di Normattiva tramite `collezione.py`. Ogni documento XML è marcato secondo lo standard Akoma Ntoso e contiene la storia completa di ciascun articolo con le date di validità di ogni versione. La pipeline valida l'integrità dei file e segnala le discrepanze tra URN da cartella e URN da XML.

**2. Costruzione dei metadati e parsing XML**
`01_build_metadata.R` estrae in parallelo i metadati di ciascun atto (URN NIR, ELI, titolo AKN, date di vigenza) e costruisce il dataframe principale. `02_master_loop.R` itera su ogni atto, ne analizza il formato Akoma Ntoso e produce nodi e archi per Neo4j, scrivendo output parziali su disco per ogni atto elaborato.

**3. Temporal Knowledge Graph (Neo4j)**
Il formato multivigente ripete il testo di un articolo ogni volta che una qualsiasi parte dell'atto viene modificata, anche se quell'articolo specifico non è cambiato. La **delta detection** in `03_export_neo4j.R` confronta il testo normalizzato (fingerprint alfanumerico) tra versioni consecutive e scarta i duplicati, riducendo le versioni da ~2,9 milioni a **41.764** effettivamente distinte — un fattore di compressione di circa 68x. Il grafo finale conta **18.091 nodi Partizione**, collegati alle rispettive versioni storiche, alle leggi modificanti e agli articoli citati, tramite relazioni tipizzate: `HA_VERSIONE`, `EVOLVE_IN`, `ABROGATO_DA`, `CITA`, `CITA_ATTO`, `RIMANDA_A`, `APPARTIENE`, `SOTTO_PARTIZIONE`.

**4. Indice di ricerca ibrido (OpenSearch)**
`04_create_index.py` costruisce due indici separati — uno per le versioni vigenti, uno per quelle storiche — per evitare che una norma abrogata compaia tra le risposte su cosa è in vigore oggi. `05_ingest_versions.py` indicizza le versioni deduplicate combinando ricerca lessicale BM25 e ricerca vettoriale su embedding multilingue Cohere a 1.024 dimensioni.

**5. Sistema conversazionale (RAG)**
`chatbot.py` implementa un sistema RAG con modello generativo locale (Mistral via Ollama). La pipeline prevede: classificazione dell'intenzione → retrieval ibrido con fusione e reranking → arricchimento del contesto tramite le relazioni del grafo → generazione della risposta → controllo finale che verifica se ogni articolo citato compare davvero nel contesto recuperato (mitigazione delle allucinazioni).

**6. Valutazione sperimentale**
`Search_test.py` esegue la valutazione su 5 test set annotati a mano (209 domande totali) per complessità crescente: da riferimenti espliciti a linguaggio colloquiale, incluse domande evolutive sulla storia di una disposizione. Metriche: MRR, Precision, Recall, nDCG su quattro configurazioni di retrieval.

## Struttura del repository

```
Tesi-2026/
├── README.md
├── 00_setup.R              # Installazione e caricamento dipendenze R
├── 00_functions.R          # Costanti, pattern e funzioni condivise (AKN, URN, timeline, delta)
├── 01_build_metadata.R     # Estrazione metadati, validazione URN, pre-check XML
├── 02_master_loop.R        # Parsing XML, costruzione nodi e archi, output CSV parziali
├── 03_export_neo4j.R       # Delta detection, generazione archi temporali, export CSV definitivo
├── 04_create_index.py      # Creazione indici ibridi su OpenSearch (BM25 + vettoriale)
├── 05_ingest_versions.py   # Ingestione versioni deduplicate negli indici
├── collezione.py           # Download collezioni preconfezionate da Normattiva OpenData
├── atto.py                 # Gestione del singolo atto normativo
├── chatbot.py              # Sistema conversazionale RAG (Mistral via Ollama)
├── Search_test.py          # Valutazione sperimentale del retrieval
└── test_risultati_20260705_17....csv   # Risultati di una sessione di test
```

## Risultati principali

| Categoria di domanda | Metrica | Valore |
|---|---|---|
| Riferimenti espliciti (codice + articolo) | MRR | **0,983** |
| Riferimenti espliciti + vincolo temporale | MRR | **0,936** |
| Linguaggio colloquiale (config. migliore) | MRR | 0,777 |

- Sulle domande con riferimenti espliciti, il risultato è **stabile su tutte le configurazioni** di retrieval: conferma l'ipotesi centrale della tesi, ossia che ancorare la temporalità alla struttura del dato (e non all'interpretazione del modello linguistico) funziona in modo affidabile.
- Sulle domande colloquiali, la strategia più efficace è l'**espansione per parole chiave**, che recupera la terminologia tecnica implicita in una formulazione informale.
- **Contributo del Knowledge Graph**: non decisivo sulle domande a riferimento esplicito (dove il retrieval è già diretto per chiave), ma misurabile dove il retrieval è puramente semantico, fino a **+0,063 MRR** con espansione HyDE e **+0,367 Recall@10**. Il beneficio è maggiore proprio sulle domande più difficili (MRR di partenza < 0,5): **+0,075 di miglioramento medio**, con un solo caso su 49 in cui il grafo peggiora il risultato.


## Requisiti e installazione

### R

```r
# Il file 00_setup.R installa automaticamente i pacchetti mancanti tramite pak.
# In alternativa, installazione manuale:
install.packages(c(
  "here", "dplyr", "stringr", "xml2", "purrr", "httr2",
  "pbapply", "lubridate", "readr", "digest", "data.table",
  "future", "furrr", "tibble", "memoise", "parallelly"
))
```

### Python

```bash
pip install -r requirements.txt
```

### Servizi esterni richiesti
- **Neo4j** — istanza attiva per il Temporal Knowledge Graph
- **OpenSearch** — istanza attiva per l'indice ibrido BM25 + vettoriale
- **Ollama** con modello **Mistral** — per la generazione delle risposte
- **Cohere API key** — per gli embedding multilingue (1.024 dimensioni)

## Come eseguire la pipeline

```bash
# 1. Setup dipendenze R
Rscript 00_setup.R

# 2. Estrazione metadati e parsing XML
Rscript 01_build_metadata.R
Rscript 02_master_loop.R

# 3. Delta detection ed export CSV per Neo4j
Rscript 03_export_neo4j.R

# 4. Creazione indici e ingestione su OpenSearch
python 04_create_index.py
python 05_ingest_versions.py

# 5. Avvio del sistema conversazionale
python chatbot.py

# 6. Valutazione sperimentale
python Search_test.py
```

---

---
