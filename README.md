# Tesi-2026

Pipeline per la costruzione di un knowledge graph della normativa italiana a partire dai dati Open Data di Normattiva, con esportazione su Neo4j e interrogazione tramite chatbot.

## Indice

- [Descrizione del progetto](#descrizione-del-progetto)
- [Struttura del repository](#struttura-del-repository)
- [Pipeline di elaborazione](#pipeline-di-elaborazione)
- [Componenti applicativi](#componenti-applicativi)
- [Test](#test)
- [Requisiti e installazione](#requisiti-e-installazione)
- [Come eseguire la pipeline](#come-eseguire-la-pipeline)

## Descrizione del progetto

[Contesto della tesi: obiettivo, dominio (dati normativi italiani / Normattiva), tecnologie principali (R, Python, Neo4j, ecc.), e cosa dimostra il progetto nel suo complesso.]

## Struttura del repository

```
Tesi-2026/
├── README.md
├── 00_setup.R
├── 00_functions.R
├── 01_build_metadata.R
├── 02_master_loop.R
├── 03_export_neo4j.R
├── 04_create_index.py
├── 05_ingest_versions.py
├── chatbot.py
├── atto.py
├── collezione.py
├── Search_test.py
└── test_risultati_20260705_17....csv
```

## Pipeline di elaborazione

Gli script numerati vanno eseguiti **in ordine**, dato che ciascuno si basa sull'output del precedente.

| Script | Linguaggio | Descrizione |
|---|---|---|
| `00_setup.R` | R | [Inizializza l'ambiente: librerie, connessioni, variabili globali] |
| `00_functions.R` | R | [Funzioni di utilità condivise dagli altri script R] |
| `01_build_metadata.R` | R | [Costruisce i metadati degli atti normativi a partire da ...] |
| `02_master_loop.R` | R | [Ciclo principale che orchestra l'elaborazione di ... per ogni atto/collezione] |
| `03_export_neo4j.R` | R | [Esporta i dati elaborati verso il database a grafo Neo4j] |
| `04_create_index.py` | Python | [Crea l'indice (es. per ricerca semantica / full-text) su ...] |
| `05_ingest_versions.py` | Python | [Carica le diverse versioni (multivigenza) degli atti in ...] |

## Componenti applicativi

Script indipendenti dalla pipeline, che utilizzano i dati prodotti:

- **`chatbot.py`** — [Descrizione: es. interfaccia conversazionale per interrogare la base di conoscenza normativa costruita dalla pipeline]
- **`atto.py`** — [Descrizione: es. gestione/rappresentazione di un singolo atto normativo]
- **`collezione.py`** — [Descrizione: es. download e gestione delle collezioni preconfezionate da Normattiva]

## Test

- **`Search_test.py`** — [Cosa testa: es. verifica delle funzionalità di ricerca]
- **`test_risultati_20260705_17....csv`** — [Output/risultati di una sessione di test del 5 luglio 2026]

## Requisiti e installazione

### R
```r
# Pacchetti richiesti
install.packages(c("[pacchetto1]", "[pacchetto2]", "..."))
```

### Python
```bash
pip install -r requirements.txt
```

[Se non esiste ancora un `requirements.txt`, elenca qui le librerie usate, es. requests, neo4j, ecc., e poi crea il file separatamente.]

### Altri prerequisiti
- [Istanza Neo4j attiva, con credenziali configurate in ...]
- [Eventuale API key o configurazione per l'accesso a Normattiva OpenData]

## Come eseguire la pipeline

```bash
# 1. Setup ambiente R
Rscript 00_setup.R

# 2. Costruzione metadati
Rscript 01_build_metadata.R

# 3. Elaborazione principale
Rscript 02_master_loop.R

# 4. Esportazione su Neo4j
Rscript 03_export_neo4j.R

# 5. Creazione indice
python 04_create_index.py

# 6. Ingestione versioni
python 05_ingest_versions.py
```

---
