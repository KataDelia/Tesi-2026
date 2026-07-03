# 06_chatbot.py
# Chatbot giuridico con ricerca ibrida (keyword + k-NN) su OpenSearch
# e generazione risposta via LLaMA3 (Ollama).

import re
import json
import requests
import urllib3
from typing import Optional
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ── Configurazione ─────────────────────────────────────────────────────────────
OS_URL      = "https://localhost:9200"
OS_USER     = "admin"
OS_PASS     = "PasswordForte123"
INDEX       = "tkg_versions"
OLLAMA_URL  = "http://localhost:11434"
EMBED_MODEL = "nomic-embed-text"
LLM_MODEL   = "llama3"

AUTH = (OS_USER, OS_PASS)

# ══════════════════════════════════════════════════════════════════════════════
# 1. EMBEDDING
# ══════════════════════════════════════════════════════════════════════════════

def calcola_embedding(testo: str):
    r = requests.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": EMBED_MODEL, "input": testo},
        timeout=60
    )
    r.raise_for_status()
    return r.json()["embeddings"][0]

# ══════════════════════════════════════════════════════════════════════════════
# 2. ESTRAZIONE FINESTRA TEMPORALE
# ══════════════════════════════════════════════════════════════════════════════

def estrai_finestra(domanda: str) -> tuple[str, str]:
    """
    Estrae la finestra temporale dalla domanda in linguaggio naturale.
    Restituisce (start, end) come stringhe YYYYMMDD,
    oppure ("IS_CURRENT", "IS_CURRENT") per domande sulla vigenza attuale.
    """
    d = domanda.lower()

    # "tra il 1990 e il 2000" / "tra 1990 e 2000" / "dal 1990 al 2000"
    m = re.search(
        r"(?:tra\s+(?:il\s+)?|dal?\s+)(\d{4})\s+(?:e\s+(?:il\s+)?|al?\s+)(\d{4})", d
    )
    if m:
        return f"{m.group(1)}0101", f"{m.group(2)}1231"

    # "nel 1995" / "nel corso del 1995"
    m = re.search(r"\bnel(?:\s+corso\s+del)?\s+(\d{4})\b", d)
    if m:
        return f"{m.group(1)}0101", f"{m.group(1)}1231"

    # "prima del 1981" / "anteriore al 1981" / "fino al 1981"
    m = re.search(r"(?:prima\s+del|anteriore\s+al?|fino\s+al?)\s+(\d{4})", d)
    if m:
        return "19000101", f"{int(m.group(1)) - 1}1231"

    # "dopo il 2018" / "successivo al 2018" / "a partire dal 2018"
    m = re.search(
        r"(?:dopo\s+il|successiv[oa]\s+al?|a\s+partire\s+dal?)\s+(\d{4})", d
    )
    if m:
        return f"{m.group(1)}0101", "99991231"

    # "al momento dell'entrata in vigore" con anno specifico
    m = re.search(r"(?:entrata\s+in\s+vigore|promulgazione).*?(\d{4})", d)
    if m:
        return f"{m.group(1)}0101", f"{m.group(1)}1231"

    # Domande sulla vigenza attuale
    parole_vigenza = [
        "vigente", "oggi", "attuale", "corrente", "attualmente",
        "in vigore", "adesso", "ora", "correntemente"
    ]
    if any(w in d for w in parole_vigenza):
        return "IS_CURRENT", "IS_CURRENT"

    # Nessun vincolo temporale esplicito → tutto il dataset
    return "19000101", "99991231"

# ══════════════════════════════════════════════════════════════════════════════
# 3. ESTRAZIONE FILTRI AGGIUNTIVI
# ══════════════════════════════════════════════════════════════════════════════

# Mappa alias comuni verso codice_breve_atto indicizzato
ALIAS_CODICE = {
    "codice penale":              "c.p.",
    "codice civile":              "c.c.",
    "codice di procedura civile": "c.p.c.",
    "codice di procedura penale": "c.p.p.",
    "codice della navigazione":   "cod.nav.",
    "ordinamento militare":       "c.o.m.",
    "giustizia contabile":        "c.g.c.",
    "contratti pubblici":         None,   # nessun codice_breve, filtra per nome
    r"\bc\.p\.\b":               "c.p.",
    r"\bc\.c\.\b":               "c.c.",
    r"\bc\.p\.c\.\b":            "c.p.c.",
    r"\bc\.p\.p\.\b":            "c.p.p.",
}

def estrai_filtri(domanda: str) -> dict:
    """
    Estrae filtri aggiuntivi dalla domanda:
    - codice_breve: se la domanda menziona un codice specifico
    - numero_articolo: se la domanda menziona un numero di articolo
    """
    d = domanda.lower()
    filtri = {}

    # Codice citato
    for pattern, breve in ALIAS_CODICE.items():
        if re.search(pattern, d):
            if breve:
                filtri["codice_breve_atto"] = breve
            break

    # Numero articolo esplicito ("art. 52", "articolo 323", "artt. 52 e 54")
    m = re.search(r"art(?:icolo)?\.?\s*(\d+(?:[_\-][a-z0-9]+)?)", d)
    if m:
        filtri["numero_puro"] = m.group(1)

    return filtri

# ══════════════════════════════════════════════════════════════════════════════
# 4. RICERCA
# ══════════════════════════════════════════════════════════════════════════════

SOURCE_FIELDS = [
    "art_id", "versione_id", "title", "testo_puro",
    "numero", "numero_puro", "titolo_atto",
    "nome_comune_atto", "codice_breve_atto",
    "valido_dal_raw", "valido_al_raw", "is_current",
    "stato_norma", "tipo_modifica"
]

def build_temporal_filter(start: str, end: str) -> list:
    """Costruisce i filtri temporali su campi long (più affidabili di date string)."""
    return [
        {"range": {"valido_dal_raw": {"lte": int(end)}}},
        {"range": {"valido_al_raw":  {"gte": int(start)}}}
    ]

def build_extra_filters(filtri: dict) -> list:
    """Costruisce filtri aggiuntivi su codice e numero articolo."""
    extra = []
    if "codice_breve_atto" in filtri:
        extra.append({"term": {"codice_breve_atto": filtri["codice_breve_atto"]}})
    if "numero_puro" in filtri:
        extra.append({"term": {"numero_puro": filtri["numero_puro"]}})
    return extra

def search_keyword(q: str, start: str, end: str,
                   filtri: dict, size: int = 8) -> list:
    """Ricerca BM25 con filtri temporali e opzionali."""
    filtri_query = build_temporal_filter(start, end) + build_extra_filters(filtri)

    body = {
        "size": size,
        "_source": SOURCE_FIELDS,
        "query": {
            "bool": {
                "must": [
                    {"multi_match": {
                        "query":  q,
                        "fields": ["title^3", "numero^3", "testo_puro", "aliases"],
                        "type":   "best_fields"
                    }}
                ],
                "filter": filtri_query
            }
        }
    }
    r = requests.post(
        f"{OS_URL}/{INDEX}/_search",
        json=body, auth=AUTH, verify=False, timeout=30
    )
    r.raise_for_status()
    return r.json()["hits"]["hits"]

def search_knn(q: str, start: str, end: str,
               filtri: dict, size: int = 8) -> list:
    """
    Ricerca k-NN con filter PRE-ricerca (non post_filter).
    FIX critico rispetto all'originale: post_filter agisce DOPO il k-NN
    e scarta risultati già recuperati — con filter il filtro è applicato
    PRIMA della ricerca vettoriale, garantendo risultati nel range corretto.
    """
    vec = calcola_embedding(q)

    filtri_knn = build_temporal_filter(start, end) + build_extra_filters(filtri)

    body = {
        "size": size,
        "_source": SOURCE_FIELDS,
        "query": {
            "knn": {
                "embedding": {
                    "vector": vec,
                    "k": size * 2,
                    # FIX: filter dentro knn, non post_filter
                    "filter": {
                        "bool": {"must": filtri_knn}
                    }
                }
            }
        }
    }
    r = requests.post(
        f"{OS_URL}/{INDEX}/_search",
        json=body, auth=AUTH, verify=False, timeout=30
    )
    r.raise_for_status()
    return r.json()["hits"]["hits"]

def search_keyword_current(q: str, filtri: dict, size: int = 8) -> list:
    """Ricerca keyword su versioni correntemente in vigore."""
    extra = build_extra_filters(filtri)
    body = {
        "size": size,
        "_source": SOURCE_FIELDS,
        "query": {
            "bool": {
                "must": [
                    {"multi_match": {
                        "query":  q,
                        "fields": ["title^3", "numero^3", "testo_puro", "aliases"],
                        "type":   "best_fields"
                    }}
                ],
                "filter": [{"term": {"is_current": True}}] + extra
            }
        }
    }
    r = requests.post(
        f"{OS_URL}/{INDEX}/_search",
        json=body, auth=AUTH, verify=False, timeout=30
    )
    r.raise_for_status()
    return r.json()["hits"]["hits"]

def search_knn_current(q: str, filtri: dict, size: int = 8) -> list:
    """Ricerca k-NN su versioni correntemente in vigore."""
    vec   = calcola_embedding(q)
    extra = build_extra_filters(filtri)

    body = {
        "size": size,
        "_source": SOURCE_FIELDS,
        "query": {
            "knn": {
                "embedding": {
                    "vector": vec,
                    "k": size * 2,
                    "filter": {
                        "bool": {
                            "must": [{"term": {"is_current": True}}] + extra
                        }
                    }
                }
            }
        }
    }
    r = requests.post(
        f"{OS_URL}/{INDEX}/_search",
        json=body, auth=AUTH, verify=False, timeout=30
    )
    r.raise_for_status()
    return r.json()["hits"]["hits"]

# ══════════════════════════════════════════════════════════════════════════════
# 5. FUSIONE RISULTATI
# ══════════════════════════════════════════════════════════════════════════════

def merge_hits(kw_hits: list, knn_hits: list, max_contesti: int = 5) -> list:
    """
    Fusione e deduplicazione risultati keyword + k-NN.
    FIX: deduplicazione per partizione (art_id), non per versione —
    se lo stesso articolo ha più versioni nel range temporale viene
    tenuta solo la più recente. I risultati keyword hanno priorità.
    """
    seen_partizione = {}  # art_id → source della versione più recente

    for h in kw_hits + knn_hits:
        src = h["_source"]
        pid = src.get("art_id") or src.get("partizione_id", "")
        if not pid:
            continue
        vd = src.get("valido_dal_raw", 0) or 0

        # Tieni la versione più recente per ogni partizione
        if pid not in seen_partizione or vd > (seen_partizione[pid].get("valido_dal_raw") or 0):
            seen_partizione[pid] = src

    risultati = list(seen_partizione.values())

    # Preferisci norme ATTIVE se disponibili
    attivi   = [r for r in risultati if r.get("stato_norma") != "ABROGATO"]
    abrogati = [r for r in risultati if r.get("stato_norma") == "ABROGATO"]

    return (attivi if attivi else abrogati)[:max_contesti]

# ══════════════════════════════════════════════════════════════════════════════
# 6. GENERAZIONE RISPOSTA
# ══════════════════════════════════════════════════════════════════════════════

def formatta_contesto(contesti: list) -> str:
    """
    Formatta i contesti per il prompt LLM.
    FIX rispetto all'originale: testo esteso a 1500 caratteri (era 200),
    aggiunto numero articolo e codice espliciti nel contesto.
    """
    ctx = ""
    for i, c in enumerate(contesti, 1):
        numero      = c.get("numero", "")
        codice      = c.get("codice_breve_atto", "") or c.get("nome_comune_atto", "")
        titolo_atto = c.get("titolo_atto", "")
        vd          = c.get("valido_dal_raw", "?")
        va          = c.get("valido_al_raw", "?")
        va_str      = "in vigore" if str(va) == "99991231" else str(va)
        stato       = c.get("stato_norma", "")
        testo       = (c.get("testo_puro", "") or "")[:1500]

        intestazione = f"{numero}"
        if codice:
            intestazione += f" {codice}"
        if titolo_atto:
            intestazione += f" — {titolo_atto}"

        ctx += (
            f"[{i}] {intestazione}\n"
            f"Vigenza: {vd} → {va_str}"
            + (f" [{stato}]" if stato and stato != "ATTIVO" else "") + "\n"
            f"Testo: {testo}\n\n"
        )
    return ctx

def genera_risposta(domanda: str, contesti: list, filtri: dict = None) -> str:
    """
    Genera la risposta con LLaMA3.
    FIX rispetto all'originale:
    - testo contesto esteso (1500 char invece di 200)
    - prompt con istruzione esplicita di fallback quando le fonti non bastano
    - temperatura bassa per risposte più precise su testi normativi
    """
    if filtri is None:
        filtri = {}

    if not contesti:
        return "Non ho trovato articoli rilevanti nel dataset per questa domanda."

    ctx_text = formatta_contesto(contesti)


    istruzione_articolo = ""
    if filtri.get("numero_puro"):
        istruzione_articolo = (
            f"La domanda riguarda l'articolo {filtri['numero_puro']}. "
            "Riassumi il contenuto basandoti sul testo fornito, "
            "spiegando cosa disciplina e le disposizioni principali.\n"
        )

    prompt = (
        "Sei un assistente giuridico italiano specializzato in normativa storica e vigente.\n"
        f"{istruzione_articolo}"
        "Rispondi SOLO basandoti sulle fonti fornite di seguito.\n"
        "Se le fonti non contengono l'articolo o il periodo richiesto, rispondi esattamente:\n"
        "'Le fonti disponibili non contengono questa norma per il periodo richiesto.'\n"
        "Non inventare testi normativi. Non aggiungere interpretazioni non supportate dalle fonti.\n"
        "Cita sempre: numero articolo, nome del codice/decreto, periodo di vigenza.\n\n"
        f"DOMANDA: {domanda}\n\n"
        f"FONTI:\n{ctx_text}"
        "RISPOSTA:"
    )

    print("  [LLM] generazione in corso...", flush=True)

    risposta = ""
    r = requests.post(
        f"{OLLAMA_URL}/api/generate",
        json={
            "model":   LLM_MODEL,
            "prompt":  prompt,
            "stream":  True,
            "options": {
                "temperature": 0.1,   # bassa per testi normativi
                "top_p":       0.9,
                "num_predict": 512
            }
        },
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

# ══════════════════════════════════════════════════════════════════════════════
# 7. CHATBOT PRINCIPALE
# ══════════════════════════════════════════════════════════════════════════════

def chatbot(domanda: str) -> str:
    print(f"\nDomanda: {domanda}")

    # 1. Estrai finestra temporale
    start, end = estrai_finestra(domanda)
    print(f"  Finestra temporale : {start} → {end}")

    # 2. Estrai filtri aggiuntivi (codice, numero articolo)
    filtri = estrai_filtri(domanda)
    if filtri:
        print(f"  Filtri rilevati    : {filtri}")

    # 3. Ricerca ibrida
    if start == "IS_CURRENT":
        print("  Modalità           : versioni vigenti")
        kw_hits  = search_keyword_current(domanda, filtri)
        knn_hits = search_knn_current(domanda, filtri)
    else:
        kw_hits  = search_keyword(domanda, start, end, filtri)
        knn_hits = search_knn(domanda, start, end, filtri)

    print(f"  Risultati keyword  : {len(kw_hits)}")
    print(f"  Risultati k-NN     : {len(knn_hits)}")

    # 4. Fusione e selezione contesti
    contesti = merge_hits(kw_hits, knn_hits, max_contesti=5)
    print(f"  Contesti selezionati: {len(contesti)}")

    if contesti:
        print("  Articoli trovati:")
        for c in contesti:
            numero = c.get("numero", "?")
            codice = c.get("codice_breve_atto", "") or c.get("titolo_atto", "")[:40]
            vd     = c.get("valido_dal_raw", "?")
            va     = c.get("valido_al_raw", "?")
            print(f"    - {numero} {codice} [{vd}→{va}]")

    # 5. Genera risposta
    risposta = genera_risposta(domanda, contesti, filtri)
    # risposta già stampata token per token durante lo streaming
    return risposta

# ══════════════════════════════════════════════════════════════════════════════
# 8. ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    print("=== Chatbot Giuridico ===")
    print(f"Indice: {INDEX} | Modello LLM: {LLM_MODEL} | Embedding: {EMBED_MODEL}")
    print("Digita 'esci' per terminare.\n")

    while True:
        try:
            domanda = input("Domanda: ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\nUscita.")
            break

        if not domanda:
            continue
        if domanda.lower() in ("esci", "exit", "quit"):
            break

        try:
            chatbot(domanda)
        except Exception as e:
            print(f"  ERRORE: {e}")
