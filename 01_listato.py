import requests
from requests.auth import HTTPBasicAuth
import urllib3

# Disattivazione dei warning per connessioni TLS locali non verificate
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Parametri di connessione al cluster OpenSearch
URL_OPENSEARCH = "https://localhost:9200/tkg_versions"
AUTH = HTTPBasicAuth("admin", "PasswordForte123") 

# 1. Reset dell'ambiente: rimozione dell'indice preesistente
print("Inizializzazione: rimozione dell'indice vettoriale preesistente...")
requests.delete(URL_OPENSEARCH, auth=AUTH, verify=False)

# 2. Definizione del payload di configurazione (Settings e Mappings)
payload = {
    "settings": {
        "index": {
            "number_of_shards": 1,
            "number_of_replicas": 1,
            "knn": True
        },
        "analysis": {
            # Definizione di un analizzatore custom per la lingua italiana
            "analyzer": {
                "it_text": {
                    "type": "custom",
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
                    "type": "elision",
                    "articles": ["c", "l", "all", "dell", "d", "gli", "i", "da", "in", "su", "del", "dei", "delle"]
                },
                "italian_stop": {"type": "stop", "stopwords": "_italian_"},
                "italian_stemmer": {"type": "stemmer", "language": "light_italian"}
            }
        }
    },
    "mappings": {
        "properties": {
            # Metadati identificativi e relazionali
            "id": {"type": "keyword"},
            "art_id": {"type": "keyword"},
            "versione_id": {"type": "keyword"},
            "num_versione": {"type": "integer"},
            
            # Stati e classificazione della norma
            "stato_norma": {"type": "keyword"},
            "stato_vigenza": {"type": "keyword"},
            "tipo_modifica": {"type": "keyword"},
            
            # Campi testuali indicizzati per la ricerca semantica
            "title": {"type": "text", "analyzer": "it_text"},
            "testo_puro": {"type": "text", "analyzer": "it_text"},
            "aliases": {
                "type": "text",
                "analyzer": "it_text",
                "fields": {"raw": {"type": "keyword"}}
            },
            "keywords": {"type": "keyword"},
            
            # Dimensioni temporali per la gestione della vigenza dinamica
            "valido_dal_dt": {"type": "date", "format": "yyyyMMdd||strict_date"},
            "valido_al_dt": {"type": "date", "format": "yyyyMMdd||strict_date", "null_value": "99991231"},
            "valido_dal_raw": {"type": "long"},
            "valido_al_raw": {"type": "long"},
            "year_from": {"type": "integer"},
            "year_to": {"type": "integer"},
            "is_current": {"type": "boolean"},
            
            # Configurazione dello spazio vettoriale per il Graph-RAG
            "embedding": {
                "type": "knn_vector",
                "dimension": 768,
                "method": {
                    "name": "hnsw",
                    "space_type": "cosinesimil",
                    "engine": "lucene",
                    "parameters": {"ef_construction": 128, "m": 16}
                }
            }
        }
    }
}

# 3. Creazione del nuovo indice con architettura Lucene HNSW
print("Creazione del nuovo indice vettoriale (Dim: 768, Motore: Lucene)...")
create_response = requests.put(URL_OPENSEARCH, json=payload, auth=AUTH, verify=False)

print(f"Stato HTTP: {create_response.status_code}")
print(f"Risposta del server: {create_response.json()}")
