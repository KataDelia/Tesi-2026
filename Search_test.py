import requests, json
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

OS_URL  = "https://localhost:9200"
OS_USER = "admin"
OS_PASS = "PasswordForte123"
INDEX   = "tkg_versions"

OLLAMA_URL  = "http://localhost:11434/api/embed"
EMBED_MODEL = "nomic-embed-text"

def calcola_embedding(testo: str):
    r = requests.post(OLLAMA_URL,
                      json={"model": EMBED_MODEL, "input": testo},
                      timeout=60)
    r.raise_for_status()
    return r.json()["embeddings"][0]

def search_knn(q: str, start: str = "19000101", end: str = "99991231", size: int = 5):
    vec = calcola_embedding(q)
    body = {
        "size": size,
        "_source": ["art_id", "versione_id", "title", "valido_dal_dt", "valido_al_dt", "is_current"],
        "query": {
            "knn": {
                "embedding": {
                    "vector": vec,
                    "k": 10
                }
            }
        },
        "post_filter": {
            "bool": {
                "must": [
                    { "range": { "valido_dal_dt": { "lte": end } } },
                    { "range": { "valido_al_dt":  { "gte": start } } }
                ]
            }
        }
    }
    r = requests.post(f"{OS_URL}/{INDEX}/_search",
                      json=body,
                      auth=(OS_USER, OS_PASS),
                      verify=False, timeout=30)
    r.raise_for_status()
    hits = r.json()["hits"]["hits"]
    for h in hits:
        print(f"  score={h['_score']:.3f} | {h['_source']}")

print("=== Ricerca k-NN semantica ===")
search_knn("concessioni portuali", start="19500101", end="20001231")

