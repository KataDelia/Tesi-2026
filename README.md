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
40 codici nazionali in formato multivigente, scaricati dal portale Open Data di Normattiva (XML in standard Akoma Ntoso, con la storia completa di ogni articolo e le date di validità di ciascuna versione). Pipeline di download, validazione e normalizzazione, con meccanismo di aggiornamento incrementale per le modifiche future.

**2. Temporal Knowledge Graph (Neo4j)**
Il formato multivigente ripete il testo di un articolo ogni volta che una qualsiasi parte dell'atto viene modificata, anche se quello specifico articolo non è cambiato. Una fase di **delta detection** (confronto del testo normalizzato tra versioni consecutive, scarto dei duplicati) riduce le versioni parseate da ~2,9 milioni a **41.764** effettivamente distinte (fattore di compressione di circa 68x). Il grafo finale conta **18.091 nodi "Partizione"**, collegati alle rispettive versioni storiche, alle leggi modificanti e agli articoli citati.

**3. Indice di ricerca ibrido (OpenSearch)**
Ricerca lessicale BM25 + ricerca vettoriale su embedding multilingue Cohere (1.024 dimensioni). Due indici separati (uno per le versioni vigenti, uno per quelle storiche) per evitare che una norma abrogata compaia tra le risposte su cosa è in vigore oggi.

**4. Sistema conversazionale (RAG)**
Modello generativo locale (Mistral via Ollama). Pipeline: classificazione dell'intenzione → retrieval ibrido con fusione e reranking → arricchimento del contesto tramite le relazioni del grafo → generazione della risposta → controllo finale che verifica se ogni articolo citato compare davvero nel contesto recuperato (mitigazione delle allucinazioni).

**5. Valutazione sperimentale**
5 test set annotati a mano, 209 domande totali, per complessità crescente (da riferimenti espliciti a linguaggio colloquiale, incluse domande "evolutive" sulla storia di una disposizione). Metriche: MRR, Precision, Recall, nDCG su quattro configurazioni di retrieval.

## Struttura del repository

```
Tesi-2026/
├── README.md
├── 00_setup.R              # Inizializzazione ambiente R
├── 00_functions.R          # Funzioni di utilità condivise
├── 01_build_metadata.R     # Fase 1 — costruzione metadati del corpus
├── 02_master_loop.R        # Fase 1/2 — ciclo di parsing/normalizzazione + delta detection [verificare]
├── 03_export_neo4j.R       # Fase 2 — costruzione del Temporal Knowledge Graph
├── 04_create_index.py      # Fase 3 — creazione indici ibridi su OpenSearch
├── 05_ingest_versions.py   # Fase 3 — ingestione delle versioni deduplicate negli indici
├── collezione.py           # Download delle collezioni preconfezionate da Normattiva OpenData
├── atto.py                 # Rappresentazione/gestione del singolo atto normativo [verificare]
├── chatbot.py              # Fase 4 — sistema conversazionale RAG
├── Search_test.py          # Fase 5 — valutazione sperimentale (retrieval)
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
install.packages(c("[pacchetto1]", "[pacchetto2]", "..."))
```

### Python
```bash
pip install -r requirements.txt
```
[Se non esiste ancora, va creato elencando almeno: client OpenSearch, client Neo4j, SDK Cohere per gli embedding, client Ollama.]

### Servizi esterni richiesti
- **Neo4j** — istanza attiva per il Temporal Knowledge Graph
- **OpenSearch** — istanza attiva per l'indice ibrido BM25 + vettoriale
- **Ollama** con modello **Mistral** — per la generazione delle risposte
- **Cohere API key** — per gli embedding multilingue (1.024 dimensioni)

## Come eseguire la pipeline

```bash
# Fase 1 — Acquisizione corpus e metadati
Rscript 00_setup.R
Rscript 01_build_metadata.R
Rscript 02_master_loop.R

# Fase 2 — Costruzione del Temporal Knowledge Graph
Rscript 03_export_neo4j.R

# Fase 3 — Indicizzazione ibrida
python 04_create_index.py
python 05_ingest_versions.py

# Fase 4 — Avvio del sistema conversazionale
python chatbot.py

# Fase 5 — Valutazione
python Search_test.py
```

---
