"""Creazione dell'indice vettoriale OpenSearch per il sistema RAG."""

import os
import sys
import json
import requests
from requests.auth import HTTPBasicAuth
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

OS_HOST = os.getenv("OS_HOST", "https://localhost:9200")
OS_USER = os.getenv("OS_USER", "admin")
OS_PASS = os.getenv("OS_PASS")
INDEX   = os.getenv("OS_INDEX", "tkg_versions")

if not OS_PASS:
    print("ERRORE: variabile d'ambiente OS_PASS non impostata.")
    sys.exit(1)

URL  = f"{OS_HOST}/{INDEX}"
AUTH = HTTPBasicAuth(OS_USER, OS_PASS)


def os_req(method, url, **kwargs):
    try:
        return requests.request(method, url, auth=AUTH, verify=False, timeout=30, **kwargs)
    except requests.exceptions.ConnectionError:
        print(f"ERRORE: impossibile connettersi a OpenSearch su {OS_HOST}")
        sys.exit(1)


# Verifica connessione

r = os_req("GET", OS_HOST)
if r.status_code != 200:
    print(f"ERRORE connessione: HTTP {r.status_code}")
    sys.exit(1)
info = r.json()
print(f"Cluster: {info.get('cluster_name')}  versione: {info['version']['number']}")


# Protezione anti-cancellazione accidentale
# Gli embedding sono generati a pagamento (Cohere). Senza --force il comando
# si blocca se l'indice contiene già documenti.

FORCE = os.getenv("FORCE_RECREATE", "0") == "1" or "--force" in sys.argv

r_check = os_req("GET", f"{OS_HOST}/_cat/count/{INDEX}?h=count")
n_docs  = int(r_check.text.strip()) if r_check.status_code == 200 and r_check.text.strip().isdigit() else 0

if n_docs > 0 and not FORCE:
    print(f"L'indice '{INDEX}' contiene {n_docs} documenti con embedding Cohere.")
    print(f"Per ricrearlo: FORCE_RECREATE=1 python3 {sys.argv[0]}")
    sys.exit(1)

r = os_req("DELETE", URL)
if r.status_code == 200:
    print("Indice precedente eliminato.")
elif r.status_code == 404:
    print("Indice non esisteva.")
else:
    print(f"DELETE inattesa: HTTP {r.status_code} — {r.text}")


# Mapping

payload = {
    "settings": {
        "index": {
            "number_of_shards":         1,
            "number_of_replicas":       0,
            "knn":                      True,
            "knn.algo_param.ef_search": 200
        },
        "analysis": {
            "analyzer": {
                "it_text": {
                    "type":      "custom",
                    "tokenizer": "standard",
                    "filter":    ["lowercase", "italian_elision",
                                  "italian_stop", "italian_stemmer"]
                }
            },
            "filter": {
                "italian_elision": {
                    "type":     "elision",
                    "articles": ["c","l","all","dell","d","gli",
                                 "i","da","in","su","del","dei","delle"]
                },
                "italian_stop":    {"type": "stop",    "stopwords": "_italian_"},
                "italian_stemmer": {"type": "stemmer", "language":  "light_italian"}
            }
        }
    },
    "mappings": {
        "properties": {

            # Identificativi
            "versione_id":   {"type": "keyword"},   # chiave primaria (_id OpenSearch)
            "partizione_id": {"type": "keyword"},   # URN articolo senza suffisso versione
            "num_versione":  {"type": "integer"},   # 0 = originario, 1,2,... = modifiche

            # Articolo
            "numero":      {"type": "keyword"},     # es. "Art. 12-bis"
            "numero_puro": {"type": "keyword"},     # es. "12-bis" — per filtro esatto

            # Testo e ricerca full-text
            # title = numero + codice/alias/denominazione: peso ^3 in BM25
            "title":      {"type": "text", "analyzer": "it_text",
                           "fields": {"raw": {"type": "keyword"}}},
            "testo_puro": {"type": "text", "analyzer": "it_text"},
            # aliases: sinonimi dell'atto — migliorano il recall su nomi alternativi
            "aliases":    {"type": "text", "analyzer": "it_text",
                           "fields": {"raw": {"type": "keyword"}}},

            # Metadati atto — keyword per filtri term esatti
            "nome_comune_atto":     {"type": "keyword"},  # es. "Codice Penale"
            "codice_breve_atto":    {"type": "keyword"},  # es. "c.p."
            "denominazione_comune": {"type": "keyword"},
            "titolo_atto":          {"type": "text", "analyzer": "it_text",
                                     "fields": {"raw": {"type": "keyword"}}},
            "atto_appartenenza":    {"type": "keyword"},  # URN dell'atto contenitore

            # Vigenza
            # stato_vigenza = fonte di verità NIR (VIGENTE / STORICO / ABROGATO)
            # valido_al=99991231 su un ABROGATO significa "nessuna data esplicita",
            # non "vigente oggi": per questo si usa stato_vigenza e non le date
            "stato_vigenza":  {"type": "keyword"},
            "stato_norma":    {"type": "keyword"},  # ATTIVO / PARZIALMENTE_ABROGATO
            "tipo_modifica":  {"type": "keyword"},
            "valido_dal_raw": {"type": "long"},     # YYYYMMDD intero — filtrabile con range
            "valido_al_raw":  {"type": "long"},
            "is_current":     {"type": "boolean"},  # true solo se stato_vigenza=VIGENTE

            # Vettore semantico
            # Cohere embed-multilingual-v3.0: 1024 dim, vettori già normalizzati.
            # innerproduct su vettori normalizzati = cosine similarity.
            "embedding": {
                "type":      "knn_vector",
                "dimension": 1024,
                "method": {
                    "name":       "hnsw",
                    "space_type": "innerproduct",
                    "engine":     "lucene",
                    "parameters": {"ef_construction": 256, "m": 24}
                }
            }
        }
    }
}


# Creazione indice

print(f"Creazione indice '{INDEX}'...")
r = os_req("PUT", URL, json=payload)
if r.status_code == 200:
    print("Indice creato.")
else:
    print(f"ERRORE: HTTP {r.status_code}")
    print(json.dumps(r.json(), indent=2, ensure_ascii=False))
    sys.exit(1)


# Verifica

r = os_req("GET", f"{OS_HOST}/_cat/indices/{INDEX}?h=index,health,status,docs.count,store.size")
print(r.text.strip())

props = os_req("GET", f"{URL}/_mapping").json()[INDEX]["mappings"]["properties"]
campi = ["versione_id","partizione_id","numero_puro","title","testo_puro",
         "aliases","stato_vigenza","valido_dal_raw","is_current","embedding"]
for c in campi:
    flag = "✓" if c in props else "✗ MANCANTE"
    print(f"  {flag}  {c}: {props.get(c,{}).get('type','n/a')}")

print(f"\n[OK] '{INDEX}' pronto per l'ingestion.")
