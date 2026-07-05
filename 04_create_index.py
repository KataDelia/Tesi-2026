"""Creazione dell'indice vettoriale OpenSearch per il sistema RAG."""
 
import os
import sys
import json
import requests
from requests.auth import HTTPBasicAuth
import urllib3
 
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
 
# Configurazione
 
OS_HOST = os.getenv("OS_HOST", "https://localhost:9200")
OS_USER = os.getenv("OS_USER", "admin")
OS_PASS = os.getenv("OS_PASS", "PasswordForte123")
INDEX   = os.getenv("OS_INDEX", "tkg_versions")
URL     = f"{OS_HOST}/{INDEX}"
AUTH    = HTTPBasicAuth(OS_USER, OS_PASS)
 
 
def os_request(method: str, url: str, **kwargs):
    """Wrapper HTTP con gestione errori di connessione centralizzata."""
    try:
        return requests.request(method, url, auth=AUTH, verify=False,
                                timeout=30, **kwargs)
    except requests.exceptions.ConnectionError:
        print(f"ERRORE: impossibile connettersi a OpenSearch su {OS_HOST}")
        print("Verifica che il cluster sia avviato.")
        sys.exit(1)
 
 
# Verifica connessione
 
print("Verifica connessione a OpenSearch...")
r = os_request("GET", OS_HOST)
if r.status_code != 200:
    print(f"ERRORE connessione: HTTP {r.status_code}")
    sys.exit(1)
 
cluster_info = r.json()
print(f"  Cluster : {cluster_info.get('cluster_name', 'n/a')}")
print(f"  Versione: {cluster_info.get('version', {}).get('number', 'n/a')}")
 
# Reset indice preesistente
 
print(f"\nReset indice '{INDEX}'...")
r = os_request("DELETE", URL)
if r.status_code == 200:
    print("  Indice precedente eliminato.")
elif r.status_code == 404:
    print("  Indice non esisteva, procedo con la creazione.")
else:
    print(f"  ATTENZIONE: risposta inattesa alla DELETE: HTTP {r.status_code}")
    print(f"  {r.text}")
 
# Definizione mapping
 
payload = {
    "settings": {
        "index": {
            "number_of_shards":            1,
            "number_of_replicas":          0,       # 0 repliche su cluster single-node
            "knn":                         True,
            "knn.algo_param.ef_search":    200      # alzato da 100: miglior recall
        },
        "analysis": {
            "analyzer": {
                "it_text": {
                    "type":      "custom",
                    "tokenizer": "standard",
                    "filter": [
                        "lowercase",
                        "italian_elision",
                        "italian_stop",
                        "italian_stemmer"
                    ]
                }
            },
            "filter": {
                "italian_elision": {
                    "type":     "elision",
                    "articles": [
                        "c", "l", "all", "dell", "d", "gli",
                        "i", "da", "in", "su", "del", "dei", "delle"
                    ]
                },
                "italian_stop": {
                    "type":      "stop",
                    "stopwords": "_italian_"
                },
                "italian_stemmer": {
                    "type":     "stemmer",
                    "language": "light_italian"
                }
            }
        }
    },
    "mappings": {
        "properties": {
 
            # Identificativi
            "id":            {"type": "keyword"},
            "art_id":        {"type": "keyword"},
            "versione_id":   {"type": "keyword"},
            "partizione_id": {"type": "keyword"},
            "num_versione":  {"type": "integer"},
 
            # Metadati atto
            "numero":      {"type": "keyword"},
            "numero_puro": {"type": "keyword"},   # sole cifre — es. "52", "323"
 
            "title": {
                "type":     "text",
                "analyzer": "it_text",
                "fields":   {"raw": {"type": "keyword"}}
            },
            "titolo_atto": {
                "type":     "text",
                "analyzer": "it_text",
                "fields":   {"raw": {"type": "keyword"}}
            },
            "nome_comune_atto":  {"type": "keyword"},  # es. "Codice Penale"
            "codice_breve_atto": {"type": "keyword"},  # es. "c.p."
 
            "atto_appartenenza": {
                "type":   "keyword",
                "fields": {"text": {"type": "text", "analyzer": "it_text"}}
            },
 
            # Classificazione norma
            "stato_norma":   {"type": "keyword"},
            "stato_vigenza": {"type": "keyword"},
            "tipo_modifica": {"type": "keyword"},
 
            # Contenuto testuale
            "testo_puro": {
                "type":     "text",
                "analyzer": "it_text"
            },
            "aliases": {
                "type":     "text",
                "analyzer": "it_text",
                "fields":   {"raw": {"type": "keyword"}}
            },
            "keywords": {"type": "keyword"},
 
            # Temporalità
            "valido_dal_raw": {"type": "long"},
            "valido_al_raw":  {"type": "long"},
 
            # Campi date
            "valido_dal_dt": {
                "type":   "date",
                "format": "yyyyMMdd||strict_date||epoch_millis"
            },
            "valido_al_dt": {
                "type":   "date",
                "format": "yyyyMMdd||strict_date||epoch_millis"
            },
            "year_from":  {"type": "integer"},
            "year_to":    {"type": "integer"},
            "is_current": {"type": "boolean"},
 
            # Vettore semantico
            "embedding": {
                "type":      "knn_vector",
                "dimension": 768,
                "method": {
                    "name":       "hnsw",
                    "space_type": "cosinesimil",
                    "engine":     "lucene",
                    "parameters": {
                        "ef_construction": 256,
                        "m":               24
                    }
                }
            }
        }
    }
}
 
# Creazione indice
 
print(f"\nCreazione indice '{INDEX}' (768 dim, Lucene HNSW m=24, ef_search=200)...")
r = os_request("PUT", URL, json=payload)
if r.status_code == 200:
    print("  Indice creato con successo.")
else:
    print(f"  ERRORE creazione indice: HTTP {r.status_code}")
    print(f"  {json.dumps(r.json(), indent=2, ensure_ascii=False)}")
    sys.exit(1)
 
# Verifica stato indice
 
print("\nVerifica stato indice...")
r = os_request(
    "GET",
    f"{OS_HOST}/_cat/indices/{INDEX}?v&h=index,health,status,pri,rep,docs.count,store.size"
)
if r.status_code == 200:
    print(f"  {r.text.strip()}")
else:
    print(f"  ATTENZIONE: impossibile verificare lo stato: HTTP {r.status_code}")
 
# Verifica mapping
 
print("\nVerifica mapping campi principali...")
r = os_request("GET", f"{URL}/_mapping")
if r.status_code == 200:
    props = r.json()[INDEX]["mappings"]["properties"]
    campi_attesi = [
        "embedding", "testo_puro", "title", "numero",
        "nome_comune_atto", "codice_breve_atto",
        "valido_dal_raw", "valido_al_raw", "is_current"
    ]
    for campo in campi_attesi:
        stato = "✓" if campo in props else "✗ MANCANTE"
        tipo  = props.get(campo, {}).get("type", "n/a")
        print(f"  {stato}  {campo}: {tipo}")
else:
    print(f"  ATTENZIONE: impossibile leggere il mapping: HTTP {r.status_code}")
 
print(f"\n[OK] Indice '{INDEX}' pronto per l'ingestion.")
