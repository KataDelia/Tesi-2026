"""Chatbot giuridico con ricerca ibrida su OpenSearch e risposta via Ollama."""

import re
import json
import requests
import urllib3
from typing import Optional

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

try:
    from sentence_transformers import CrossEncoder
    _cross_encoder = CrossEncoder("cross-encoder/ms-marco-MiniLM-L-6-v2")
    RERANKER_DISPONIBILE = True
    print("[Reranker] cross-encoder/ms-marco-MiniLM-L-6-v2 caricato.")
except Exception:
    RERANKER_DISPONIBILE = False

# Configurazione

OS_URL        = "https://localhost:9200"
OS_USER       = "admin"
OS_PASS       = "PasswordForte123"
INDEX         = "tkg_versions"   # tutte le versioni (storiche + vigenti)
INDEX_VIGENTI = "tkg_vigenti"    # sole versioni vigenti — più veloce per query attuali
OLLAMA_URL    = "http://localhost:11434"
EMBED_MODEL   = "nomic-embed-text"
LLM_MODEL     = "mistral"
LLM_TIMEOUT   = 120              # timeout LLM in secondi

AUTH             = (OS_USER, OS_PASS)
FALLBACK_MARKER  = "FONTI_NON_SUFFICIENTI"


# Embedding

def calcola_embedding(testo: str) -> list:
    """Genera il vettore di embedding per la domanda."""
    try:
        r = requests.post(
            f"{OLLAMA_URL}/api/embed",
            json={"model": EMBED_MODEL, "input": testo},
            timeout=60
        )
        r.raise_for_status()
        return r.json()["embeddings"][0]
    except requests.exceptions.HTTPError:
        r = requests.post(
            f"{OLLAMA_URL}/api/embeddings",
            json={"model": EMBED_MODEL, "prompt": testo},
            timeout=60
        )
        r.raise_for_status()
        return r.json()["embedding"]


# Finestra temporale

def estrai_finestra(domanda: str) -> tuple:
        """Estrae la finestra temporale dalla domanda."""
    d = domanda.lower()

    # Testo originario
    if re.search(r"(?:norm|test[oa]|version[ei]|formulazion[ei])\s+original(?:e|i|ia|ario)", d):
        return "ORIGINALE", "ORIGINALE"

    m = re.search(
        r"prima\s+della?\s+(?:riforma|novella|modifica|revisione|legge)\s+(?:del\s+)?(\d{4})", d
    )
    if m:
        return "19000101", f"{int(m.group(1)) - 1}1231"

    m = re.search(r"(?:previgente|ante[- ]riforma)\s+(?:al?|del)?\s*(\d{4})", d)
    if m:
        return "19000101", f"{int(m.group(1)) - 1}1231"

    m = re.search(
        r"(?:tra\s+(?:il\s+)?|dal?\s+)(\d{4})\s+(?:e\s+(?:il\s+)?|al?\s+)(\d{4})", d
    )
    if m:
        return f"{m.group(1)}0101", f"{m.group(2)}1231"

    m = re.search(r"nel(?:l['\s]+anno|\s+corso\s+del)?\s+(\d{4})", d)
    if m:
        return f"{m.group(1)}0101", f"{m.group(1)}1231"

    m = re.search(
        r"(?:prima\s+del|anteriore\s+al?|fino\s+al?|antecedente\s+al?|sino\s+al?)\s+(\d{4})", d
    )
    if m:
        return "19000101", f"{int(m.group(1)) - 1}1231"

    m = re.search(
        r"(?:dopo\s+il|successiv[oa]\s+al?|a\s+partire\s+dal?)\s+(\d{4})", d
    )
    if m:
        return f"{m.group(1)}0101", "99991231"

    m = re.search(r"(?:entrata\s+in\s+vigore|promulgazione|emanazione).*?(\d{4})", d)
    if m:
        return f"{m.group(1)}0101", f"{m.group(1)}1231"

    parole_vigenza = [
        "vigente", "oggi", "attuale", "corrente", "attualmente",
        "in vigore", "adesso", "ora", "correntemente", "al momento"
    ]
    if any(w in d for w in parole_vigenza):
        return "IS_CURRENT", "IS_CURRENT"

    return "19000101", "99991231"


# Filtri semantici

# Mappa alias -> codice_breve_atto.
ALIAS_CODICE = {
    r"\bc\.p\.\b":               "c.p.",
    r"\bc\.c\.\b":               "c.c.",
    r"\bc\.p\.c\.\b":            "c.p.c.",
    r"\bc\.p\.p\.\b":            "c.p.p.",
    r"\bcod\.?\s*post\.":        "cod. post.",
    r"\bcod\.?\s*nav\.":         "cod.nav.",
    "codice postale":             "cod. post.",
    "codice delle telecomunicazioni": "cod. post.",
    "telecomunicazioni":          "cod. post.",
    "bancoposta":                 "cod. post.",
    "codice penale":              "c.p.",
    "codice civile":              "c.c.",
    "codice di procedura civile": "c.p.c.",
    "codice di procedura penale": "c.p.p.",
    "codice della navigazione":   "cod.nav.",
    "codice dei contratti":       None,   # filtra per nome, nessun codice_breve
    "contratti pubblici":         None,
}

def estrai_filtri(domanda: str) -> dict:
        """Estrae i filtri strutturati dalla domanda."""
    d = domanda.lower()
    filtri = {}

    for pattern, breve in ALIAS_CODICE.items():
        if re.search(pattern, d):
            if breve:
                filtri["codice_breve_atto"] = breve
            break

    m = re.search(r"art(?:icolo)?\.?\s*(\d+(?:[_\-][a-z0-9]+)?)", d)
    if m:
        filtri["numero_puro"] = m.group(1)

    return filtri


# Ricerca OpenSearch

SOURCE_FIELDS = [
    "art_id", "versione_id", "title", "testo_puro",
    "numero", "numero_puro", "titolo_atto",
    "nome_comune_atto", "codice_breve_atto",
    "valido_dal_raw", "valido_al_raw", "is_current",
    "stato_norma", "tipo_modifica"
]

def build_temporal_filter(start: str, end: str) -> list:
    """Filtro temporale su campi interi YYYYMMDD."""
    return [
        {"range": {"valido_dal_raw": {"lte": int(end)}}},
        {"range": {"valido_al_raw":  {"gte": int(start)}}}
    ]

def build_extra_filters(filtri: dict) -> list:
    """Costruisce filtri term su codice, numero articolo e versione."""
    extra = []
    if "codice_breve_atto" in filtri:
        extra.append({"term": {"codice_breve_atto": filtri["codice_breve_atto"]}})
    if "numero_puro" in filtri:
        extra.append({"term": {"numero_puro": filtri["numero_puro"]}})
    if "num_versione" in filtri:
        extra.append({"term": {"num_versione": filtri["num_versione"]}})
    return extra

def _esegui_ricerca_os(index: str, body: dict) -> list:
    r = requests.post(
        f"{OS_URL}/{index}/_search",
        json=body, auth=AUTH, verify=False, timeout=30
    )
    r.raise_for_status()
    return r.json()["hits"]["hits"]

def search_keyword(q: str, start: str, end: str, filtri: dict, size: int = 8) -> list:
    """Ricerca BM25 su tkg_versions."""
    body = {
        "size": size,
        "_source": SOURCE_FIELDS,
        "query": {
            "bool": {
                "must":   [{"multi_match": {
                    "query":  q,
                    "fields": ["title^3", "numero^3", "testo_puro", "aliases"],
                    "type":   "best_fields"
                }}],
                "filter": build_temporal_filter(start, end) + build_extra_filters(filtri)
            }
        }
    }
    return _esegui_ricerca_os(INDEX, body)

def search_knn(q: str, start: str, end: str, filtri: dict, size: int = 8) -> list:
    """Ricerca k-NN su tkg_versions."""
    vec      = calcola_embedding(q)
    filtri_q = build_temporal_filter(start, end) + build_extra_filters(filtri)
    body = {
        "size": size,
        "_source": SOURCE_FIELDS,
        "query": {
            "knn": {
                "embedding": {
                    "vector": vec,
                    "k":      size * 2,
                    "filter": {"bool": {"must": filtri_q}}
                }
            }
        }
    }
    return _esegui_ricerca_os(INDEX, body)

def search_keyword_current(q: str, filtri: dict, size: int = 8) -> list:
    """Ricerca BM25 su tkg_vigenti."""
    body = {
        "size": size,
        "_source": SOURCE_FIELDS,
        "query": {
            "bool": {
                "must":   [{"multi_match": {
                    "query":  q,
                    "fields": ["title^3", "numero^3", "testo_puro", "aliases"],
                    "type":   "best_fields"
                }}],
                "filter": [{"term": {"is_current": True}}] + build_extra_filters(filtri)
            }
        }
    }
    return _esegui_ricerca_os(INDEX_VIGENTI, body)

def search_knn_current(q: str, filtri: dict, size: int = 8) -> list:
    """Ricerca k-NN su tkg_vigenti."""
    vec   = calcola_embedding(q)
    extra = build_extra_filters(filtri)
    body = {
        "size": size,
        "_source": SOURCE_FIELDS,
        "query": {
            "knn": {
                "embedding": {
                    "vector": vec,
                    "k":      size * 2,
                    "filter": {"bool": {"must": [{"term": {"is_current": True}}] + extra}}
                }
            }
        }
    }
    return _esegui_ricerca_os(INDEX_VIGENTI, body)


# Fusione e reranking

def merge_hits(kw_hits: list, knn_hits: list, max_contesti: int = 5) -> list:
    """Fonde i risultati keyword e k-NN deduplicando per partizione."""
    seen: dict = {}
    for h in kw_hits + knn_hits:
        src = h["_source"]
        pid = src.get("art_id") or src.get("partizione_id", "")
        if not pid:
            continue
        vd = src.get("valido_dal_raw", 0) or 0
        if pid not in seen or vd > (seen[pid].get("valido_dal_raw") or 0):
            seen[pid] = src

    risultati = list(seen.values())
    attivi    = [r for r in risultati if r.get("stato_norma") != "ABROGATO"]
    abrogati  = [r for r in risultati if r.get("stato_norma") == "ABROGATO"]
    return (attivi if attivi else abrogati)[:max_contesti]

def rerank(domanda: str, contesti: list, top_k: int = 5) -> list:
    """Riordina i contesti con un cross-encoder, se disponibile."""
    if not RERANKER_DISPONIBILE or not contesti:
        return contesti[:top_k]

    coppie = [
        (domanda, f"{c.get('numero','')} {c.get('codice_breve_atto','')}\n{(c.get('testo_puro','') or '')[:500]}")
        for c in contesti
    ]
    scores = _cross_encoder.predict(coppie)
    return [c for _, c in sorted(zip(scores, contesti), key=lambda x: x[0], reverse=True)[:top_k]]


# Classificazione domanda

def is_domanda_testuale(domanda: str, filtri: dict) -> bool:
    """True se la domanda richiede il testo letterale di un articolo."""
    d            = domanda.lower()
    ha_numero    = bool(filtri.get("numero_puro"))
    chiede_testo = any(w in d for w in [
        "testo", "cosa dice", "cosa prevede", "riporta", "trascrivi",
        "copia", "letteralmente", "testualmente", "come recita", "dispone"
    ])
    return ha_numero and chiede_testo

def is_domanda_evolutiva(domanda: str) -> bool:
    """True se la domanda riguarda l'evoluzione storica di una norma."""
    d = domanda.lower()
    return any(w in d for w in [
        "come è cambiato", "come è cambiata", "evoluzione", "storia",
        "modifiche", "versioni", "nel tempo", "come è evoluto",
        "quante versioni", "storia delle modifiche"
    ])


# Generazione risposta

def formatta_contesto(contesti: list) -> str:
    """Formatta i contesti recuperati per il prompt LLM."""
    ctx = ""
    for i, c in enumerate(contesti, 1):
        numero  = c.get("numero", "")
        codice  = c.get("codice_breve_atto", "") or c.get("nome_comune_atto", "")
        titolo  = c.get("titolo_atto", "")
        vd      = c.get("valido_dal_raw", "?")
        va      = c.get("valido_al_raw", "?")
        va_str  = "in vigore" if str(va) in ("99991231", "99991230") else str(va)
        stato   = c.get("stato_norma", "")
        testo   = (c.get("testo_puro", "") or "")[:1500]

        intestazione = numero
        if codice:  intestazione += f" {codice}"
        if titolo:  intestazione += f" — {titolo}"

        ctx += (
            f"[{i}] {intestazione}\n"
            f"Vigenza: {vd} → {va_str}"
            + (f" [{stato}]" if stato and stato != "ATTIVO" else "") + "\n"
            f"Testo: {testo}\n\n"
        )
    return ctx

def risposta_diretta(contesti: list) -> str:
    """Restituisce il testo normativo con citazione formale."""
    if not contesti:
        return "Articolo non trovato nel dataset."

    righe = []
    for c in contesti:
        numero  = c.get("numero", "")
        codice  = c.get("codice_breve_atto", "") or c.get("nome_comune_atto", "")
        titolo  = c.get("titolo_atto", "")
        vd      = c.get("valido_dal_raw", "")
        va      = c.get("valido_al_raw", "")
        va_str  = "in vigore" if str(va) in ("99991231", "99991230") else f"fino al {va}"
        testo   = c.get("testo_puro", "") or ""
        stato   = c.get("stato_norma", "ATTIVO")

        fonte = numero
        if codice:  fonte += f" {codice}"
        elif titolo: fonte += f" — {titolo}"
        fonte += f" [vigente dal {vd} {va_str}]"
        if stato != "ATTIVO":
            fonte += f" [{stato}]"

        righe.append(fonte + "\n\n" + testo)

    return "\n\n---\n\n".join(righe)

def risposta_evolutiva(contesti: list, domanda: str) -> str:
    """Costruisce una timeline strutturata della storia di una norma."""
    if not contesti:
        return "Nessuna versione trovata per questa norma nel dataset."

    versioni = sorted(contesti, key=lambda c: c.get("valido_dal_raw", 0) or 0)

    righe = []
    c0     = versioni[0]
    numero = c0.get("numero", "")
    codice = c0.get("codice_breve_atto", "") or c0.get("nome_comune_atto", "")
    righe.append(f"Storia di {numero} {codice} ({len(versioni)} versioni nel dataset)\n")

    for c in versioni:
        vd       = c.get("valido_dal_raw", "?")
        va       = c.get("valido_al_raw",  "?")
        va_str   = "in vigore" if str(va) in ("99991231", "99991230") else str(va)
        tipo_mod = c.get("tipo_modifica", "")
        stato    = c.get("stato_norma", "ATTIVO")
        testo    = (c.get("testo_puro", "") or "")[:300]

        riga = f"  [{vd} → {va_str}]"
        if tipo_mod and tipo_mod != "originale":
            riga += f" {tipo_mod}"
        if stato != "ATTIVO":
            riga += f" [{stato}]"
        riga += f"\n    {testo}{'...' if len(c.get('testo_puro','') or '') > 300 else ''}"
        righe.append(riga)

    return "\n".join(righe)

def genera_risposta(domanda: str, contesti: list, filtri: dict = None) -> str:
        """Genera la risposta con Mistral tramite streaming."""
    if filtri is None:
        filtri = {}

    if not contesti:
        return "Non ho trovato articoli rilevanti nel dataset per questa domanda."

    ctx_text = formatta_contesto(contesti)

    # Istruzione contestuale
    d = domanda.lower()
    if any(w in d for w in ["cambiato", "cambiata", "evoluzione", "storia", "versioni", "nel tempo"]):
        istruzione_extra = (
            "La domanda riguarda l'evoluzione storica della norma. "
            "Struttura la risposta come una lista cronologica: "
            "per ogni versione indica le date di vigenza, il tipo di modifica e le variazioni principali.\n"
        )
    elif filtri.get("numero_puro"):
        istruzione_extra = (
            f"La domanda riguarda l'articolo {filtri['numero_puro']}. "
            "Riassumi il contenuto citando le disposizioni principali.\n"
        )
    else:
        istruzione_extra = ""

    prompt = (
        "Sei un assistente giuridico italiano specializzato in normativa storica e vigente.\n"
        f"{istruzione_extra}"
        "Rispondi SOLO basandoti sulle fonti fornite di seguito.\n"
        f"Se le fonti non contengono la norma richiesta, rispondi con SOLO: {FALLBACK_MARKER}\n\n"
        "REGOLE DI CITAZIONE:\n"
        "1. Cita il testo normativo tra virgolette.\n"
        "2. Indica sempre: numero articolo, codice o decreto, periodo di vigenza.\n"
        "3. Formato: \"Art. X [codice] (vigente dal YYYYMMDD al YYYYMMDD): 'testo'\".\n"
        "4. Non parafrasare: cita letteralmente.\n"
        "5. Non inventare testi non presenti nelle fonti.\n\n"
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
                "temperature": 0.1,
                "top_p":       0.9,
                "num_predict": 512
            }
        },
        timeout=LLM_TIMEOUT,
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


# Pipeline principale

def esegui_ricerca(domanda: str, start: str, end: str, filtri: dict) -> tuple:
    """Esegue ricerca ibrida BM25 + k-NN e restituisce i contesti fusi."""
    if start == "IS_CURRENT":
        kw_hits  = search_keyword_current(domanda, filtri)
        knn_hits = search_knn_current(domanda, filtri)
    elif start == "ORIGINALE":
        filtri_orig = {**filtri, "num_versione": 0}
        kw_hits  = search_keyword(domanda, "19000101", "99991231", filtri_orig)
        knn_hits = search_knn(domanda, "19000101", "99991231", filtri_orig)
    else:
        kw_hits  = search_keyword(domanda, start, end, filtri)
        knn_hits = search_knn(domanda, start, end, filtri)

    contesti_raw = merge_hits(kw_hits, knn_hits, max_contesti=20)
    contesti     = rerank(domanda, contesti_raw, top_k=5)
    return contesti, len(kw_hits), len(knn_hits)

def chatbot(domanda: str) -> str:
        """Funzione principale del chatbot."""
    print(f"\nDomanda: {domanda}")

    start, end = estrai_finestra(domanda)
    print(f"  Finestra temporale  : {start} → {end}")

    filtri = estrai_filtri(domanda)
    if filtri:
        print(f"  Filtri rilevati     : {filtri}")

    contesti, n_kw, n_knn = esegui_ricerca(domanda, start, end, filtri)
    print(f"  Risultati keyword   : {n_kw} | k-NN: {n_knn} | Contesti: {len(contesti)}")

    if contesti:
        for c in contesti:
            numero = c.get("numero", "?")
            codice = c.get("codice_breve_atto", "") or c.get("titolo_atto", "")[:30]
            vd     = c.get("valido_dal_raw", "?")
            va     = c.get("valido_al_raw",  "?")
            print(f"    - {numero} {codice} [{vd}→{va}]")

    # Modalità risposta
    if is_domanda_testuale(domanda, filtri) and contesti:
        print("  [Modalità] Risposta diretta")
        risposta = risposta_diretta(contesti)
        print("\n" + risposta)
        return risposta

    if is_domanda_evolutiva(domanda) and contesti:
        print("  [Modalità] Timeline evolutiva")
        risposta = risposta_evolutiva(contesti, domanda)
        print("\n" + risposta)
        return risposta

    risposta = genera_risposta(domanda, contesti, filtri)

    # Retry progressivo
    if FALLBACK_MARKER in risposta:
        print("\n  [Retry] Fonti insufficienti — allargo la ricerca...")

        # Strategia 1
        if "numero_puro" in filtri:
            filtri_r = {k: v for k, v in filtri.items() if k != "numero_puro"}
            contesti_r, _, _ = esegui_ricerca(domanda, start, end, filtri_r)
            if contesti_r:
                risp = genera_risposta(domanda, contesti_r, filtri_r)
                if FALLBACK_MARKER not in risp:
                    print("  [Retry] Successo (senza filtro numero).")
                    return risp

        # Strategia 2
        if filtri:
            contesti_r, _, _ = esegui_ricerca(domanda, start, end, {})
            if contesti_r:
                risp = genera_risposta(domanda, contesti_r, {})
                if FALLBACK_MARKER not in risp:
                    print("  [Retry] Successo (senza filtri semantici).")
                    return risp

        # Strategia 3
        if start not in ("IS_CURRENT", "ORIGINALE", "19000101"):
            contesti_r, _, _ = esegui_ricerca(domanda, "19000101", "99991231", {})
            if contesti_r:
                risp = genera_risposta(domanda, contesti_r, {})
                if FALLBACK_MARKER not in risp:
                    print("  [Retry] Successo (finestra allargata).")
                    return risp

        print("  [Retry] Nessun risultato dopo 3 tentativi.")
        return "Le fonti disponibili non contengono questa norma nel dataset attuale."

    return risposta


# Entry point
    # Entry point
if __name__ == "__main__":
    print("=== Chatbot Giuridico — Normativa Italiana ===")
    print(f"  Indice completo  : {INDEX}")
    print(f"  Indice vigenti   : {INDEX_VIGENTI}")
    print(f"  Modello LLM      : {LLM_MODEL}")
    print(f"  Embedding        : {EMBED_MODEL}")
    print(f"  Reranker         : {'attivo' if RERANKER_DISPONIBILE else 'non disponibile'}")
    print("  Digita 'esci' per terminare.\n")

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
        except requests.exceptions.Timeout:
            print(f"  ERRORE: timeout dopo {LLM_TIMEOUT}s. Ollama potrebbe essere sovraccarico.")
        except Exception as e:
            print(f"  ERRORE: {e}")
