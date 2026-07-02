import requests, json, re
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ── configurazione ────────────────────────────────────────────────────────────
OS_URL      = "https://localhost:9200"
OS_USER     = "admin"
OS_PASS     = "PasswordForte123"
INDEX       = "tkg_versions"
OLLAMA_URL  = "http://localhost:11434"
EMBED_MODEL = "nomic-embed-text"
LLM_MODEL   = "llama3"

# ── embedding ─────────────────────────────────────────────────────────────────
def calcola_embedding(testo: str):
    r = requests.post(f"{OLLAMA_URL}/api/embed",
                      json={"model": EMBED_MODEL, "input": testo},
                      timeout=60)
    r.raise_for_status()
    return r.json()["embeddings"][0]

# ── estrazione finestra temporale dalla domanda ───────────────────────────────
def estrai_finestra(domanda: str):
    """
    Estrae start/end in formato yyyyMMdd dalla domanda.
    Esempi gestiti:
      "nel 1952"            → 19520101 / 19521231
      "tra 1950 e 2000"     → 19500101 / 20001231
      "dal 1942 al 1994"    → 19420101 / 19941231
      "vigente oggi"        → oggi / 99991231
      "prima del 1980"      → 19000101 / 19791231
      niente                → 19000101 / 99991231 (tutto)
    """
    d = domanda.lower()

    # "tra ANNO e ANNO" o "dal ANNO al ANNO"
    m = re.search(r"(?:tra|dal?)\s+(\d{4})\s+(?:e|al?)\s+(\d{4})", d)
    if m:
        return f"{m.group(1)}0101", f"{m.group(2)}1231"

    # "nel ANNO"
    m = re.search(r"\bnel\s+(\d{4})\b", d)
    if m:
        return f"{m.group(1)}0101", f"{m.group(1)}1231"

    # "prima del ANNO"
    m = re.search(r"prima\s+del\s+(\d{4})", d)
    if m:
        return "19000101", f"{int(m.group(1))-1}1231"

    # "dopo il ANNO"
    m = re.search(r"dopo\s+il\s+(\d{4})", d)
    if m:
        return f"{m.group(1)}0101", "99991231"

    # "vigente" o "oggi" → solo versioni correnti
    if any(w in d for w in ["vigente", "oggi", "attuale", "corrente"]):
        return "20260101", "99991231"

    # nessun vincolo temporale → tutto
    return "19000101", "99991231"

# ── ricerca keyword ───────────────────────────────────────────────────────────
def search_keyword(q: str, start: str, end: str, size: int = 5):
    body = {
        "size": size,
        "_source": ["art_id", "versione_id", "title", "testo_puro",
                    "valido_dal_dt", "valido_al_dt", "is_current"],
        "query": {
            "bool": {
                "must": [
                    {"multi_match": {
                        "query": q,
                        "fields": ["title^2", "testo_puro", "aliases"]
                    }}
                ],
                "filter": [
                    {"range": {"valido_dal_dt": {"lte": end}}},
                    {"range": {"valido_al_dt":  {"gte": start}}}
                ]
            }
        }
    }
    r = requests.post(f"{OS_URL}/{INDEX}/_search",
                      json=body, auth=(OS_USER, OS_PASS),
                      verify=False, timeout=30)
    r.raise_for_status()
    return r.json()["hits"]["hits"]

# ── ricerca k-NN ──────────────────────────────────────────────────────────────
def search_knn(q: str, start: str, end: str, size: int = 5):
    vec  = calcola_embedding(q)
    body = {
        "size": size,
        "_source": ["art_id", "versione_id", "title", "testo_puro",
                    "valido_dal_dt", "valido_al_dt", "is_current"],
        "query": {
            "knn": {"embedding": {"vector": vec, "k": 10}}
        },
        "post_filter": {
            "bool": {
                "must": [
                    {"range": {"valido_dal_dt": {"lte": end}}},
                    {"range": {"valido_al_dt":  {"gte": start}}}
                ]
            }
        }
    }
    r = requests.post(f"{OS_URL}/{INDEX}/_search",
                      json=body, auth=(OS_USER, OS_PASS),
                      verify=False, timeout=30)
    r.raise_for_status()
    return r.json()["hits"]["hits"]

# ── fusione e dedup risultati ─────────────────────────────────────────────────
def merge_hits(kw_hits, knn_hits):
    seen = {}
    for h in kw_hits + knn_hits:
        vid = h["_source"]["versione_id"]
        if vid not in seen:
            seen[vid] = h["_source"]
    return list(seen.values())[:5]

# ── genera risposta con LLaMA3 ────────────────────────────────────────────────

def genera_risposta(domanda: str, contesti: list):
    if not contesti:
        return "Non ho trovato articoli rilevanti per la tua domanda."

    ctx_text = ""
    for i, c in enumerate(contesti, 1):
        ctx_text += (
            f"[{i}] {c['title']} — {c['art_id']}\n"
            f"Valido dal {c['valido_dal_dt']} al {c['valido_al_dt']}\n"
            f"Testo: {c['testo_puro'][:200]}\n\n"
        )

    prompt = (
        "Sei un assistente giuridico italiano. Rispondi in modo conciso.\n"
        "Usa SOLO le fonti fornite. Cita articolo e decreto.\n\n"
        f"DOMANDA: {domanda}\n\n"
        f"FONTI:\n{ctx_text}\n"
        "RISPOSTA:"
    )

    print("  [LLM] generazione in corso...", flush=True)

    risposta = ""
    r = requests.post(
        "http://localhost:11434/api/generate",
        json={"model": "llama3", "prompt": prompt, "stream": True},
        timeout=300,
        stream=True
    )
    r.raise_for_status()

    for line in r.iter_lines():
        if line:
            chunk = json.loads(line)
            token = chunk.get("response", "")
            print(token, end="", flush=True)
            risposta += token
            if chunk.get("done"):
                break
    print()
    return risposta.strip()


# ── chatbot principale ────────────────────────────────────────────────────────

def chatbot(domanda: str):
    print(f"\nDomanda: {domanda}")

    # 1) estrai finestra temporale
    start, end = estrai_finestra(domanda)
    print(f"Finestra temporale: {start} → {end}")

    # 2) ricerca ibrida
    kw_hits  = search_keyword(domanda, start, end)
    knn_hits = search_knn(domanda, start, end)
    contesti = merge_hits(kw_hits, knn_hits)
    print(f"Articoli trovati: {len(contesti)}")

    # 3) genera risposta
    risposta = genera_risposta(domanda, contesti)
    print(f"\nRisposta:\n{risposta}")
    return risposta

# ── test ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    while True:
        domanda = input("\nFai una domanda (o 'esci' per uscire): ")
        if domanda.lower() == "esci":
            break
        chatbot(domanda)
