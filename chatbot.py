"""
Chatbot giuridico — ricerca ibrida BM25 + k-NN su OpenSearch,
arricchimento contestuale via Neo4j (GraphRAG), risposta via Ollama/Mistral.
"""

import os, re, json, time, requests, urllib3
from datetime import date as _date
from typing import Optional

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Dipendenze opzionali
try:
    from sentence_transformers import CrossEncoder
    try:
        _cross_encoder = CrossEncoder("cross-encoder/mmarco-mMiniLMv2-L12-H384-v1")
        print("[Reranker] cross-encoder multilingue (mmarco) caricato.")
    except Exception:
        _cross_encoder = CrossEncoder("cross-encoder/ms-marco-MiniLM-L-6-v2")
        print("[Reranker] cross-encoder inglese (ms-marco) caricato come fallback.")
    RERANKER_DISPONIBILE = True
except Exception:
    RERANKER_DISPONIBILE = False

try:
    from neo4j import GraphDatabase as _GraphDatabase
    NEO4J_DISPONIBILE = True
except ImportError:
    NEO4J_DISPONIBILE = False

try:
    import cohere as _cohere
except ImportError:
    _cohere = None


# Configurazione
OS_URL        = os.getenv("OS_URL",  "https://localhost:9200")
OS_USER       = os.getenv("OS_USER", "admin")
OS_PASS       = os.getenv("OS_PASS")
INDEX         = "tkg_versions"   # tutte le versioni
INDEX_VIGENTI = "tkg_vigenti"    # sole versioni vigenti

OLLAMA_URL        = os.getenv("OLLAMA_URL", "http://localhost:11434")
LLM_MODEL         = "mistral"
LLM_TIMEOUT       = 180
OLLAMA_KEEP_ALIVE = os.getenv("OLLAMA_KEEP_ALIVE", "30m")

COHERE_API_KEY   = os.getenv("COHERE_API_KEY")
COHERE_MODEL     = "embed-multilingual-v3.0"
COHERE_EMBED_DIM = 1024

# Parametri di retrieval configurabili da riga di comando
# TOP_K: numero di contesti restituiti dal reranker
# SEARCH_SIZE_BASE: pool di candidati per query senza filtri strutturati
# USE_HYDE: abilita HyDE (query expansion tramite articolo ipotetico)
# USE_KW_EXP: abilita keyword expansion tramite Mistral
TOP_K             = int(os.getenv("TOP_K", "5"))
SEARCH_SIZE_BASE  = int(os.getenv("SEARCH_SIZE", "8"))
USE_HYDE          = os.getenv("USE_HYDE", "0") == "1"
USE_KW_EXP        = os.getenv("USE_KW_EXP", "0") == "1"

NEO4J_URI  = os.getenv("NEO4J_URI",  "bolt://localhost:7687")
NEO4J_USER = os.getenv("NEO4J_USER", "neo4j")
NEO4J_PASS = os.getenv("NEO4J_PASS")

AUTH            = (OS_USER, OS_PASS)
FALLBACK_MARKER = "FONTI_NON_SUFFICIENTI"

if not OS_PASS:
    raise RuntimeError("Variabile OS_PASS non impostata.")
if not COHERE_API_KEY:
    raise RuntimeError("Variabile COHERE_API_KEY non impostata.")

_cohere_client = _cohere.Client(api_key=COHERE_API_KEY) if _cohere else None
if _cohere_client:
    print(f"[Embedding] Cohere {COHERE_MODEL} (search_query) pronto.")
else:
    raise RuntimeError("Libreria 'cohere' non installata. Esegui: pip install cohere")


# Embedding query
def calcola_embedding(testo: str) -> list:
    """
    Embedding della query via Cohere con input_type='search_query'.
    Speculare all'input_type='search_document' usato nell'ingest:
    Cohere ottimizza i due spazi per massimizzare la similarità coseno.
    """
    testo = testo.replace("\n", " ").strip()[:2048] or "."
    resp  = _cohere_client.embed(
        texts=[testo], model=COHERE_MODEL,
        input_type="search_query", embedding_types=["float"]
    )
    return resp.embeddings.float[0][:COHERE_EMBED_DIM]


# Warmup LLM
def warmup_llm() -> None:
    """Precarica Mistral in memoria — evita il costo di ricaricamento alla prima query."""
    try:
        print("  Precaricamento LLM...", flush=True)
        requests.post(f"{OLLAMA_URL}/api/generate",
                      json={"model": LLM_MODEL, "prompt": "",
                            "keep_alive": OLLAMA_KEEP_ALIVE},
                      timeout=LLM_TIMEOUT).raise_for_status()
        print("  LLM pronto.\n", flush=True)
    except Exception as e:
        print(f"  ATTENZIONE: warmup LLM fallito ({e})\n", flush=True)


# Estrazione finestra temporale
def estrai_finestra(domanda: str) -> tuple:
    """Ricava l'intervallo temporale dalla domanda. Ritorna (start, end) come YYYYMMDD."""
    d = domanda.lower()

    # Testo originario — varie formulazioni
    if re.search(r"(?:norm|test[oa]|version[ei]|formulazion[ei]|testo)\s+original(?:e|i|ia|ario)", d):
        return "ORIGINALE", "ORIGINALE"
    if re.search(r"original(?:e|io|ari[ao])\s+del\s+\d{4}", d):
        return "ORIGINALE", "ORIGINALE"
    if re.search(r"(?:nel\s+)?testo\s+originari[oa]", d):
        return "ORIGINALE", "ORIGINALE"

    m = re.search(r"prima\s+della?\s+(?:riforma|novella|modifica|revisione|legge)\s+(?:del\s+)?(\d{4})", d)
    if m: return "19000101", f"{int(m.group(1))-1}1231"

    m = re.search(r"(?:previgente|ante[- ]riforma)\s+(?:al?|del)?\s*(\d{4})", d)
    if m: return "19000101", f"{int(m.group(1))-1}1231"

    m = re.search(r"(?:tra\s+(?:il\s+)?|dal?\s+)(\d{4})\s+(?:e\s+(?:il\s+)?|al?\s+)(\d{4})", d)
    if m: return f"{m.group(1)}0101", f"{m.group(2)}1231"

    # "dal 1942 ad oggi" — PRIMA del check "oggi" per non attivare IS_CURRENT
    m = re.search(r"dal?\s+(\d{4})\s+(?:ad?\s+oggi|fino\s+ad?\s+oggi|a\s+oggi)", d)
    if m: return f"{m.group(1)}0101", "99991231"

    m = re.search(r"(?:dopo\s+il|successiv[oa]\s+al?|a\s+partire\s+dal?|dal?)\s+(\d{4})", d)
    if m: return f"{m.group(1)}0101", "99991231"

    m = re.search(r"nel(?:l['\s]+anno|\s+corso\s+del)?\s+(\d{4})", d)
    if m: return f"{m.group(1)}0101", f"{m.group(1)}1231"

    m = re.search(r"(?:prima\s+del|anteriore\s+al?|fino\s+al?|antecedente\s+al?|sino\s+al?)\s+(\d{4})", d)
    if m: return "19000101", f"{int(m.group(1))-1}1231"

    m = re.search(r"(?:entrata\s+in\s+vigore|promulgazione|emanazione).*?(\d{4})", d)
    if m: return f"{m.group(1)}0101", f"{m.group(1)}1231"

    if any(w in d for w in ["vigente","oggi","attuale","corrente","attualmente",
                             "in vigore","adesso","ora","correntemente","al momento"]):
        return "IS_CURRENT", "IS_CURRENT"

    return "19000101", "99991231"

# Estrazione filtri strutturati
def _estrai_anni_temporali(testo: str) -> set:
    """
    Estrae anni in contesto temporale dalla domanda
    (dopo "nel", "dal", "del", "al", "prima del", ecc.).
    Usato per escludere falsi positivi: "nel 1950" non deve trovare art. 1950.
    """
    return set(re.findall(
        r"(?:nel|da[l]?|de[l]|a[l]|prima\s+del|dopo\s+il|fino\s+al|sino\s+al)\s+(\d{4})",
        testo.lower()
    ))


# Mappa nomi/abbreviazioni → codice_breve_atto nell'indice
# Nota: si usa (?<!\w)...(?!\w) invece di \b perché \b non funziona
# dopo il punto finale (es. "c.c.?") — il punto è non-word quindi
# \b non trova il boundary atteso a fine abbreviazione.
ALIAS_CODICE = {
    # Sigle formali (regex per gestire punti e confini di parola)
    r"(?<!\w)c\.p\.(?!\w)":       "c.p.",
    r"(?<!\w)c\.c\.(?!\w)":       "c.c.",
    r"(?<!\w)c\.p\.c\.(?!\w)":    "c.p.c.",
    r"(?<!\w)c\.p\.p\.(?!\w)":    "c.p.p. 1988",
    r"(?<!\w)c\.d\.s\.(?!\w)":    "c.d.s.",
    r"(?<!\w)c\.o\.m\.(?!\w)":    "c.o.m.",
    r"(?<!\w)c\.g\.c\.(?!\w)":    "c.g.c.",
    r"(?<!\w)c\.p\.i\.(?!\w)":    "c.p.i.",
    r"(?<!\w)c\.a\.d\.(?!\w)":    "c.a.d.",
    r"(?<!\w)c\.p\.m\.p\.(?!\w)": "c.p.m.p.",
    r"(?<!\w)c\.p\.m\.g\.(?!\w)": "c.p.m.g.",
    r"(?<!\w)cod\.?\s*nav\.":     "cod. nav.",
    r"(?<!\w)cod\.?\s*post\.":    "cod. post.",

    # ── Codici secondari (PRIMA dei codici principali che ne contengono il nome) ──
    # Disposizioni di attuazione
    "disposizioni per l'attuazione del codice civile":               "disp. att. c.c.",
    "disposizioni attuazione codice civile":                         "disp. att. c.c.",
    "disp. att. c.c.":                                              "disp. att. c.c.",
    "disposizioni per l'attuazione del codice di procedura civile":  "disp. att. c.p.c.",
    "disposizioni attuazione codice di procedura civile":            "disp. att. c.p.c.",
    "disposizioni attuazione procedura civile":                      "disp. att. c.p.c.",
    "disp. att. c.p.c.":                                            "disp. att. c.p.c.",
    
    # Regolamento attuativo contratti — PRIMA delle voci generiche "contratti pubblici"
"regolamento di esecuzione ed attuazione del codice dei contratti pubblici": "reg. contr. pubbl.",
"regolamento esecuzione attuazione contratti pubblici":                      "reg. contr. pubbl.",
"regolamento esecuzione contratti pubblici":                                 "reg. contr. pubbl.",

# Codice appalti 2006 con parentesi — PRIMA di "contratti pubblici" generico
"codice dei contratti pubblici (abrogato 2006)":  "cod. appalti 2006",
"codice dei contratti pubblici abrogato 2006":    "cod. appalti 2006",
"codice dei contratti pubblici (abrogato 2016)":  "cod. appalti 2016",
"codice dei contratti pubblici abrogato 2016":    "cod. appalti 2016",

# Proprietà industriale — aggiunge variante con accento
"codice della proprietà industriale":             "c.p.i.",
"proprietà industriale":                          "c.p.i.",

    # Regolamenti attuativi
    "regolamento per l'esecuzione del codice della navigazione":     "reg. cod. nav.",
    "regolamento esecuzione codice della navigazione":               "reg. cod. nav.",
    "regolamento esecuzione codice navigazione":                     "reg. cod. nav.",
    "regolamento di esecuzione e attuazione del codice della strada": "reg. c.d.s.",
    "regolamento di esecuzione del codice della strada":             "reg. c.d.s.",
    "regolamento esecuzione attuazione codice della strada":         "reg. c.d.s.",
    "regolamento esecuzione codice della strada":                    "reg. c.d.s.",
    "reg. c.d.s.":                                                  "reg. c.d.s.",
    "regolamento contratti pubblici":                                "reg. contr. pubbl.",
    "reg. contr. pubbl.":                                           "reg. contr. pubbl.",

    # Norme di attuazione
    "norme di attuazione del codice di procedura penale":            "norme att. c.p.p.",
    "norme di attuazione e di coordinamento del codice di procedura penale": "norme att. c.p.p.",
    "norme attuazione coordinamento codice procedura penale":        "norme att. c.p.p.",
    "norme att. c.p.p.":                                            "norme att. c.p.p.",
    "norme attuazione procedura penale":                             "norme att. c.p.p.",
    "disposizioni attuazione penale":                                "norme att. c.p.p.",

    # ── Codici principali ──────────────────────────────────────────────────────
    "codice penale militare di pace":    "c.p.m.p.",
    "codice penale militare di guerra":  "c.p.m.g.",
    "codice penale militare":            "c.p.m.p.",
    "codice della navigazione":          "cod. nav.",
    "navigazione marittima":             "cod. nav.",
    "navigazione aerea":                 "cod. nav.",
    "codice penale":                     "c.p.",
    "codice civile":                     "c.c.",
    "codice di procedura civile":        "c.p.c.",
    "codice di procedura penale":        "c.p.p. 1988",
    "codice della strada":               "c.d.s.",
    "codice postale":                    "cod. post.",
    "codice delle telecomunicazioni":    "cod. post.",
    "telecomunicazioni":                 "cod. post.",
    "bancoposta":                        "cod. post.",
    "ordinamento militare":              "c.o.m.",
    "codice ordinamento militare":       "c.o.m.",
    "codice di giustizia contabile":     "c.g.c.",
    "giustizia contabile":               "c.g.c.",
    "proprieta industriale":             "c.p.i.",
    "codice proprieta industriale":      "c.p.i.",
    "amministrazione digitale":          "c.a.d.",
    "codice amministrazione digitale":   "c.a.d.",

    # ── Codici di settore ──────────────────────────────────────────────────────
    "codice del consumo":                "cod. consumo",
    "consumo":                           "cod. consumo",
    "codice delle assicurazioni":        "cod. ass.",
    "assicurazioni private":             "cod. ass.",
    "codice della nautica":              "cod. nautica",
    "nautica da diporto":                "cod. nautica",
    "privacy":                           "cod. privacy",
    "protezione dei dati":               "cod. privacy",
    "codice in materia di dati personali":"cod. privacy",
    "beni culturali e del paesaggio":    "cod. beni cult.",
    "codice dei beni culturali":         "cod. beni cult.",
    "beni culturali":                    "cod. beni cult.",
    "paesaggio":                         "cod. beni cult.",
    "processo tributario":               "d.lgs. 546/92",
    "contenzioso tributario":            "d.lgs. 546/92",
    "regolamento codice della strada":   "reg. c.d.s.",
    "comunicazioni elettroniche":        "c.c.e.",
    "codice delle comunicazioni":        "c.c.e.",
    "processo amministrativo":           "c.p.a.",
    "codice del processo amministrativo":"c.p.a.",
    "ricorso al tar":                    "c.p.a.",
    "terzo settore":                     "cod. terzo set.",
    "codice del terzo settore":          "cod. terzo set.",
    "protezione civile":                 "cod. prot. civ.",
    "codice della protezione civile":    "cod. prot. civ.",
    "crisi d'impresa":                   "cod. crisi imp.",
    "crisi di impresa":                  "cod. crisi imp.",
    "insolvenza":                        "cod. crisi imp.",
    "codice antimafia":                  "cod. antimafia",
    "leggi antimafia":                   "cod. antimafia",
    "misure di prevenzione":             "cod. antimafia",
    "codice del turismo":                "cod. turismo",
    "turismo":                           "cod. turismo",
    "pari opportunita":                  "cod. pari opp.",
    "codice delle pari opportunita":     "cod. pari opp.",
    "ambiente":                          "cod. amb.",
    "codice dell'ambiente":              "cod. amb.",
    "norme in materia ambientale":       "cod. amb.",

# Contratti pubblici — tre versioni distinte nell'indice
# IMPORTANTE: le voci specifiche (con anno o parentesi) PRIMA di quelle generiche
r"codice dei contratti pubblici\s*\(abrogato\s*2006\)": "cod. appalti 2006",
r"codice dei contratti pubblici\s*abrogato\s*2006":     "cod. appalti 2006",
"codice dei contratti pubblici 2006":                   "cod. appalti 2006",
"codice appalti 2006":                                  "cod. appalti 2006",
"codice merloni":                                       "cod. appalti 2006",
r"codice dei contratti pubblici\s*\(abrogato\s*2016\)": "cod. appalti 2016",
r"codice dei contratti pubblici\s*abrogato\s*2016":     "cod. appalti 2016",
"codice dei contratti pubblici 2016":                   "cod. appalti 2016",
"codice appalti 2016":                                  "cod. appalti 2016",
r"codice dei contratti pubblici\s*\(vigente\)":         "cod. contr. pubbl. 2023",
"codice dei contratti pubblici 2023":                   "cod. contr. pubbl. 2023",
"nuovo codice degli appalti":                           "cod. contr. pubbl. 2023",
"codice appalti 2023":                                  "cod. contr. pubbl. 2023",
# Senza anno o parentesi → versione più recente (2023)
"codice dei contratti pubblici":                        "cod. contr. pubbl. 2023",
"contratti pubblici":                                   "cod. contr. pubbl. 2023",
"appalti pubblici":                                     "cod. contr. pubbl. 2023",
"appalti":                                              "cod. contr. pubbl. 2023",

    # ── Decreti ministeriali aggiunti dopo correzione indice ──────────────────
    "codice medico":                      "cod. medico",
    "decreto 33":                         "d.m. 33/2010",
    "d.m. 33":                            "d.m. 33/2010",
    "decreto 334":                        "d.m. 334/1989",
    "d.m. 334":                           "d.m. 334/1989",
}

def estrai_filtri(domanda: str) -> dict:
    """
    Ricava codice_breve_atto e numero_puro dalla domanda.
    Gli anni (es. 1942, 1960) non vengono mai estratti come numero_puro.
    """
    d      = domanda.lower()
    filtri = {}

    anni_domanda = _estrai_anni_temporali(d)

    for pattern, breve in ALIAS_CODICE.items():
        if re.search(pattern, d):
            filtri["codice_breve_atto"] = breve
            filtri["_query_prefix"]     = breve
            break

    m = re.search(r"art(?:icolo)?\s*\.?\s*(\d+(?:[\-](?:bis|ter|quater|quinquies|sexies|septies|octies))?)", d)
    if m:
        num      = m.group(1).strip().replace(" ", "-")
        contesto = d[max(0, m.start(1)-25):m.start(1)]
        prec_temp = bool(re.search(
            r"\b(?:nel|del|dopo il|prima del|dal|al|nel corso del|sino al)\s*$", contesto
        ))
        num_base = re.match(r"\d+", num)
        e_anno   = num_base and num_base.group(0) in anni_domanda
        if not prec_temp and not e_anno:
            filtri["numero_puro"] = num

    return filtri


# Ricerca OpenSearch
SOURCE_FIELDS = [
    "versione_id", "partizione_id", "title", "testo_puro",
    "numero", "numero_puro", "titolo_atto",
    "nome_comune_atto", "codice_breve_atto", "denominazione_comune",
    "valido_dal_raw", "valido_al_raw", "is_current",
    "stato_vigenza", "stato_norma", "tipo_modifica", "aliases"
]

def build_today_filter() -> list:
    """
    Filtro vigenza: usa stato_vigenza='VIGENTE' (fonte di verità NIR).
    valido_al=99991231 su un ABROGATO non significa vigente — semantica NIR.
    Il range su valido_dal esclude versioni future.
    """
    oggi = int(_date.today().strftime("%Y%m%d"))
    return [
        {"term":  {"stato_vigenza": "VIGENTE"}},
        {"range": {"valido_dal_raw": {"lte": oggi}}}
    ]

def build_temporal_filter(start: str, end: str) -> list:
    return [
        {"range": {"valido_dal_raw": {"lte": int(end)}}},
        {"range": {"valido_al_raw":  {"gte": int(start)}}}
    ]

def build_extra_filters(filtri: dict) -> list:
    extra = []
    if "codice_breve_atto" in filtri:
        extra.append({"term": {"codice_breve_atto": filtri["codice_breve_atto"]}})
    if "numero_puro" in filtri:
        extra.append({"term": {"numero_puro": filtri["numero_puro"]}})
    if "num_versione" in filtri:
        extra.append({"term": {"num_versione": filtri["num_versione"]}})
    return extra

def _search(index: str, body: dict) -> list:
    r = requests.post(f"{OS_URL}/{index}/_search",
                      json=body, auth=AUTH, verify=False, timeout=30)
    r.raise_for_status()
    return r.json()["hits"]["hits"]

def _kw_body(q, filters, size=8, anni_exclude: set = None):
    """
    Query BM25. Se anni_exclude è fornito, aggiunge must_not per escludere
    documenti il cui numero_puro coincide con un anno della domanda
    (es. "nel 1950" → esclude art. 1950 c.c. che è la fideiussione).
    """
    must_not = []
    for anno in (anni_exclude or set()):
        must_not.append({"term": {"numero_puro": anno}})

    bool_q = {
        "must":   [{"multi_match": {"query": q,
                    "fields": ["title^3","numero^3","numero_puro^3",
                               "testo_puro","aliases"],
                    "type": "best_fields"}}],
        "filter": filters
    }
    if must_not:
        bool_q["must_not"] = must_not

    return {"size": size, "_source": SOURCE_FIELDS, "query": {"bool": bool_q}}

def _knn_body(q, filters, size=8):
    """
    Query k-NN compatibile con OpenSearch 3.x.
    In OS 3.x il filtro non va dentro la query knn ma come clausola
    bool esterna: must=[knn] + filter=[filtri temporali/term].
    """
    return {
        "size": size, "_source": SOURCE_FIELDS,
        "query": {"bool": {
            "must": [{"knn": {"embedding": {
                "vector": calcola_embedding(q),
                "k":      size * 2
            }}}],
            "filter": filters
        }}
    }

def search_keyword(q, start, end, filtri, size=8, anni_exc=None):
    return _search(INDEX, _kw_body(q, build_temporal_filter(start,end) + build_extra_filters(filtri), size, anni_exc))

def search_knn(q, start, end, filtri, size=8):
    return _search(INDEX, _knn_body(q, build_temporal_filter(start,end) + build_extra_filters(filtri), size))

def search_keyword_current(q, filtri, size=8, anni_exc=None):
    return _search(INDEX_VIGENTI, _kw_body(q, build_today_filter() + build_extra_filters(filtri), size, anni_exc))

def search_knn_current(q, filtri, size=8):
    return _search(INDEX_VIGENTI, _knn_body(q, build_today_filter() + build_extra_filters(filtri), size))


# Fusione, filtro e reranking
def _punteggio_vicinanza(src: dict, punto_medio: int) -> int:
    vd = int(src.get("valido_dal_raw") or 0)
    return abs(vd - punto_medio)


def merge_hits(kw_hits: list, knn_hits: list,
               max_contesti: int = 20, anni_domanda: set = None,
               filtri: dict = None, start: str = None, end: str = None) -> list:
    """
    Fonde BM25 e k-NN deduplicando per partizione_id.
    Con finestra storica, seleziona la versione il cui intervallo contiene
    il punto medio della finestra invece della più recente.
    """
    anni_domanda  = anni_domanda or set()
    filtri_codice = (filtri or {}).get("codice_breve_atto","") if filtri else ""

    try:
        _s = int(start) if start and start not in ("IS_CURRENT","ORIGINALE","19000101") else None
        _e = int(end)   if end   and end   not in ("IS_CURRENT","ORIGINALE","99991231") else None
        punto_medio = (_s + _e) // 2 if _s and _e else None
    except (ValueError, TypeError):
        punto_medio = None

    seen = {}
    for h in kw_hits + knn_hits:
        src = h["_source"]
        pid = src.get("partizione_id", "")
        if not pid:
            continue
        np = src.get("numero_puro","") or ""
        if np in anni_domanda:
            continue
        if filtri_codice and np and len(np) == 1 and np.isdigit():
            if src.get("codice_breve_atto","") != filtri_codice:
                continue
        vd = int(src.get("valido_dal_raw") or 0)
        va = int(src.get("valido_al_raw")  or 99991231)
        if pid not in seen:
            seen[pid] = src
        else:
            if punto_medio:
                src_contiene  = vd <= punto_medio <= va
                seen_vd = int(seen[pid].get("valido_dal_raw") or 0)
                seen_va = int(seen[pid].get("valido_al_raw")  or 99991231)
                seen_contiene = seen_vd <= punto_medio <= seen_va
                if src_contiene and not seen_contiene:
                    seen[pid] = src
                elif src_contiene and seen_contiene:
                    if vd > seen_vd:
                        seen[pid] = src
                elif not src_contiene and not seen_contiene:
                    if vd > seen_vd:
                        seen[pid] = src
            else:
                seen_vd = int(seen[pid].get("valido_dal_raw") or 0)
                if vd > seen_vd:
                    seen[pid] = src

    # ── Warning ambiguità temporale ─────────────────────────────────────────
    if punto_medio:
        conteggio_per_partizione = {}
        for h in kw_hits + knn_hits:
            src_h = h["_source"]
            pid_h = src_h.get("partizione_id", "")
            vd_h  = src_h.get("valido_dal_raw")
            va_h  = src_h.get("valido_al_raw") or 99991231
            if pid_h and vd_h:
                try:
                    s_i = int(start) if start and start not in ("IS_CURRENT","ORIGINALE","19000101") else 0
                    e_i = int(end)   if end   and end   not in ("IS_CURRENT","ORIGINALE","99991231") else 99991231
                    if int(vd_h) <= e_i and int(va_h) >= s_i:
                        conteggio_per_partizione[pid_h] = conteggio_per_partizione.get(pid_h, 0) + 1
                except (ValueError, TypeError):
                    pass
        for pid_h, n in conteggio_per_partizione.items():
            if n > 1 and pid_h in seen:
                src_w = seen[pid_h]
                print(
                    f"  [⚠ AMBIGUITÀ TEMPORALE] art. {src_w.get('numero_puro','?')} "
                    f"[{src_w.get('codice_breve_atto','?')}]: {n} versioni nella finestra "
                    f"richiesta — selezionata quella valida dal "
                    f"{src_w.get('valido_dal_raw','?')} al {src_w.get('valido_al_raw','?')}."
                )
                src_w["_ambiguita_temporale"] = True
                src_w["_n_versioni_nel_range"] = n

    risultati = list(seen.values())
    vigenti   = [r for r in risultati if r.get("stato_vigenza") == "VIGENTE"]
    altri     = [r for r in risultati if r.get("stato_vigenza") != "VIGENTE"]
    candidati = (vigenti if vigenti else altri)[:max_contesti]

    seen_nc, dedup = set(), []
    for r in candidati:
        key = (r.get("numero_puro",""), r.get("codice_breve_atto",""))
        if key not in seen_nc:
            seen_nc.add(key)
            dedup.append(r)
    return dedup
def filtra_per_coerenza_codice(contesti: list, filtri: dict) -> list:
    """Scarta contesti di codici diversi da quello richiesto (difesa a valle)."""
    if not filtri or "codice_breve_atto" not in filtri or not contesti:
        return contesti
    cod      = filtri["codice_breve_atto"]
    coerenti = [c for c in contesti if c.get("codice_breve_atto","") == cod]
    return coerenti if coerenti else contesti

def rerank(domanda: str, contesti: list, top_k: int = 5) -> list:
    """Riordina con cross-encoder se disponibile, altrimenti tronca a top_k."""
    if not RERANKER_DISPONIBILE or not contesti:
        return contesti[:top_k]
    coppie = [(domanda, f"{c.get('numero','')} {c.get('codice_breve_atto','')}\n"
                        f"{(c.get('testo_puro','') or '')[:500]}")
              for c in contesti]
    scores = _cross_encoder.predict(coppie)
    return [c for _, c in sorted(zip(scores, contesti),
                                 key=lambda x: x[0], reverse=True)[:top_k]]


# Classificatori domanda
def is_domanda_testuale(domanda: str, filtri: dict) -> bool:
    """True se si chiede il testo letterale di un articolo specifico."""
    return bool(filtri.get("numero_puro")) and any(
        w in domanda.lower() for w in
        ["testo","cosa dice","cosa prevede","riporta","trascrivi",
         "copia","letteralmente","testualmente","come recita","dispone"]
    )

def is_domanda_evolutiva(domanda: str) -> bool:
    """
    True se si chiede la storia/evoluzione di una norma nel tempo.
    Copre: "come è cambiato/evoluto", "come era ... nel tempo",
    "come è evoluta la disciplina di X", "come era disciplinata X nel tempo".
    """
    d = domanda.lower()
    # Pattern espliciti di evoluzione
    if any(w in d for w in [
        "come è cambiato","come è cambiata","come è evoluto","come è evoluta",
        "come si è evoluta","come si è evoluto","come è mutato","come è mutata",
        "come ha cambiato","come è variato","come è variata",
        "evoluzione","storia delle modifiche","ha subito modifiche",
        "dalla sua emanazione","dalla riforma","nel corso degli anni",
        "quante versioni","storia di","modifiche nel tempo",
    ]):
        return True
    # "nel tempo" + verbo di cambiamento implicito
    if "nel tempo" in d:
        return True
    # "come era ... nel tempo" / "come è evoluta la disciplina"
    if re.search(r"come\s+(?:era|è|e')\s+(?:disciplinat|regolat|previst).+\s+(?:nel\s+tempo|dal\s+\d{4}|nel\s+corso)", d):
        return True
    # "come è evoluta la disciplina di X"
    if re.search(r"come\s+(?:è|e')\s+evolu", d):
        return True
    return False


# Arricchimento Neo4j
def arricchisci_con_grafo(contesti: list, start: str, end: str) -> list:
    """
    Espande ogni contesto OpenSearch con 4 query Neo4j:
      1. Versioni nel range temporale (EVOLVE_IN + legge modificante)
      2. Confronto testo storico vs vigente (solo query con finestra ristretta)
      3. Leggi che hanno modificato l'articolo
      4. Articoli citati dalla versione corrente (CITA_NORMA)
    Degrada silenziosamente se Neo4j non è raggiungibile.
    """
    if not NEO4J_DISPONIBILE:
        return contesti

    start_i    = 0        if start in ("IS_CURRENT","ORIGINALE","19000101") else int(start)
    end_i      = 99991231 if end   in ("IS_CURRENT","ORIGINALE","99991231") else int(end)
    is_storica = start not in ("IS_CURRENT","19000101")

    try:
        driver = _GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USER, NEO4J_PASS))
        with driver.session() as session:
            for c in contesti:
                pid = c.get("partizione_id")
                vid = c.get("versione_id")
                if not pid:
                    continue

                versioni_range = session.run("""
                    MATCH (p:Partizione {partizione_id: $pid})--(v:Versione)
                    WHERE v.valido_dal >= $start AND v.valido_al <= $end
                    OPTIONAL MATCH (v_prec:Versione)-[e:EVOLVE_IN]->(v)
                    RETURN v.valido_dal AS dal, v.valido_al AS al,
                           v.tipo_modifica AS modifica, v.stato_norma AS stato,
                           e.tipo_azione AS tipo_azione,
                           e.urn_legge_modificante AS legge_modificante,
                           left(v.testo_puro, 250) AS incipit
                    ORDER BY v.valido_dal LIMIT 6
                """, pid=pid, start=start_i, end=end_i).data()

                confronto = {}
                if is_storica and vid:
                    raw = session.run("""
                        MATCH (p:Partizione {partizione_id: $pid})
                        MATCH (p)-[:VIGENTE]->(v_att:Versione)
                        MATCH (p)--(v_stor:Versione)
                        WHERE v_stor.valido_dal >= $start AND v_stor.valido_al <= $end
                          AND v_stor.versione_id <> v_att.versione_id
                        RETURN left(v_stor.testo_puro,300) AS testo_storico,
                               left(v_att.testo_puro, 300) AS testo_attuale,
                               v_stor.valido_dal AS dal_storico,
                               v_att.valido_dal  AS dal_attuale
                        LIMIT 1
                    """, pid=pid, start=start_i, end=end_i).data()
                    if raw:
                        confronto = raw[0]

                leggi_modificanti = session.run("""
                    MATCH (p:Partizione {partizione_id: $pid})--(v:Versione)
                    MATCH (v_prec:Versione)-[e:EVOLVE_IN]->(v)
                    WHERE e.urn_legge_modificante IS NOT NULL
                    RETURN DISTINCT e.urn_legge_modificante AS legge,
                           e.tipo_azione AS tipo, v.valido_dal AS data_vigenza
                    ORDER BY v.valido_dal LIMIT 5
                """, pid=pid).data()

                citati = []
                if vid:
                    citati = session.run("""
                        MATCH (v:Versione {versione_id: $vid})-[:CITA_NORMA]->(p2:Partizione)
                        MATCH (p2)-[:VIGENTE]->(v2:Versione)
                        RETURN p2.numero AS numero, p2.codice_breve_atto AS codice,
                               left(v2.testo_puro,150) AS testo
                        LIMIT 3
                    """, vid=vid).data()

                if versioni_range:    c["versioni_range"]    = versioni_range
                if confronto:         c["confronto_storico"] = confronto
                if leggi_modificanti: c["leggi_modificanti"] = leggi_modificanti
                if citati:            c["articoli_citati"]   = citati

        driver.close()
        print(f"  [Neo4j] Arricchimento completato su {len(contesti)} contesti")

    except Exception as e:
        print(f"  [Neo4j] Non disponibile — solo OpenSearch ({e})")

    return contesti


# Formattazione contesto per il prompt
def _va_str(va) -> str:
    return "in vigore" if str(va) in ("99991231","99991230") else str(va)

def _dedup_testo(testo: str) -> str:
    """
    Rimuove frasi duplicate nel testo_puro (bug Akoma Ntoso/NIR).
    Usa le prime 80 char di ogni frase come chiave di dedup per catturare
    anche duplicati parziali (testi con leggere variazioni iniziali uguali).
    """
    if not testo or len(testo) < 50:
        return testo
    frasi = re.split(r"(?<=[.;!?])\s+|\n+", testo)
    viste, risultato = set(), []
    for f in frasi:
        f = f.strip()
        if not f:
            continue
        chiave = re.sub(r"\s+", " ", f.lower())[:80]
        if chiave not in viste:
            viste.add(chiave)
            risultato.append(f)
    return " ".join(risultato)

def formatta_contesto(contesti: list) -> str:
    ctx = ""
    for i, c in enumerate(contesti, 1):
        numero = c.get("numero","")
        codice = (c.get("codice_breve_atto","") or c.get("denominazione_comune","")
                  or c.get("nome_comune_atto",""))
        titolo = c.get("titolo_atto","")
        vd     = c.get("valido_dal_raw","?")
        va     = c.get("valido_al_raw","?")
        stato  = c.get("stato_norma","")
        testo  = _dedup_testo((c.get("testo_puro","") or ""))[:800]

        intestazione = numero
        if codice: intestazione += f" {codice}"
        if titolo: intestazione += f" — {titolo}"

        avviso_temporale = ""
        if c.get("_ambiguita_temporale"):
            n = c.get("_n_versioni_nel_range", 2)
            avviso_temporale = (
                f"\n  ⚠ Nota: per il periodo richiesto esistono {n} versioni distinte "
                f"di questo articolo. La risposta si riferisce alla versione in vigore "
                f"nella maggior parte dell'intervallo indicato. Se il periodo esatto è "
                f"rilevante, specifica una data più precisa nella domanda."
            )

        ctx += (f"[{i}] {intestazione}\n"
                f"Vigenza: {vd} → {_va_str(va)}"
                + (f" [{stato}]" if stato and stato != "ATTIVO" else "")
                + avviso_temporale
                + f"\nTesto: {testo}\n")

        for v in c.get("versioni_range", []):
            tipo  = v.get("tipo_azione") or v.get("modifica") or ""
            legge = v.get("legge_modificante","")
            ctx += (f"  [{v.get('dal','?')} → {v.get('al','?')}] {tipo}"
                    + (f" — mod. da {legge}" if legge else "") + "\n"
                    + f"    {v.get('incipit','')[:150]}\n")

        if c.get("confronto_storico"):
            cf = c["confronto_storico"]
            ctx += (f"Testo storico ({cf.get('dal_storico','?')}): {cf.get('testo_storico','')[:200]}\n"
                    f"Testo vigente ({cf.get('dal_attuale','?')}): {cf.get('testo_attuale','')[:200]}\n")

        if c.get("leggi_modificanti"):
            ctx += "Leggi modificanti:\n"
            for lm in c["leggi_modificanti"]:
                ctx += f"  {lm.get('data_vigenza','?')} {lm.get('tipo','')} — {lm.get('legge','')}\n"

        if c.get("articoli_citati"):
            ctx += "Articoli citati:\n"
            for cit in c["articoli_citati"]:
                ctx += f"  {cit.get('numero','')} {cit.get('codice','')}: {cit.get('testo','')[:100]}\n"

        ctx += "\n"
    return ctx


# Generazione risposta
def risposta_diretta(contesti: list, filtri: dict = None) -> str:
    """
    Restituisce il testo normativo con citazione formale, senza LLM.
    Quando numero_puro è molto comune (es. "1") e ci sono più codici,
    filtra per codice_breve_atto e restituisce solo il primo risultato.
    """
    if not contesti:
        return "Articolo non trovato nel dataset."
    if filtri and "codice_breve_atto" in filtri:
        cod = filtri["codice_breve_atto"]
        coerenti = [c for c in contesti if c.get("codice_breve_atto","") == cod]
        if coerenti:
            # Se il numero è molto comune (1-9), tieni solo il primo per codice
            # per evitare di mostrare art. 1 di 4 codici diversi
            np = filtri.get("numero_puro","")
            if np and len(np) == 1 and np.isdigit():
                contesti = coerenti[:1]
            else:
                contesti = coerenti
        else:
            return f"Non ho trovato l'articolo nel codice '{cod}'."

    righe = []
    for c in contesti:
        numero = c.get("numero","")
        codice = (c.get("codice_breve_atto","") or c.get("denominazione_comune","")
                  or c.get("nome_comune_atto",""))
        titolo = c.get("titolo_atto","")
        vd     = c.get("valido_dal_raw","")
        va     = c.get("valido_al_raw","")
        testo  = c.get("testo_puro","") or ""
        stato  = c.get("stato_norma","ATTIVO")

        fonte = numero
        if codice:  fonte += f" {codice}"
        elif titolo: fonte += f" — {titolo}"
        fonte += f" [vigente dal {vd} {_va_str(va)}]"
        if stato != "ATTIVO": fonte += f" [{stato}]"

        righe.append(fonte + "\n\n" + testo)
    return "\n\n---\n\n".join(righe)

def risposta_evolutiva(contesti: list, domanda: str, filtri: dict = None) -> str:
    """
    Costruisce una timeline cronologica delle versioni di una norma.
    Raggruppa per partizione_id per non mescolare articoli di codici diversi
    con lo stesso numero (es. art. 143 c.c. vs art. 143 c.o.m.).
    """
    from collections import defaultdict
    if not contesti:
        return "Nessuna versione trovata."

    if filtri and "codice_breve_atto" in filtri:
        cod = filtri["codice_breve_atto"]
        coerenti = [c for c in contesti if c.get("codice_breve_atto","") == cod]
        if coerenti:
            contesti = coerenti
        else:
            return f"Non ho trovato versioni nel codice '{cod}'."

    # Raggruppa per partizione_id — prendi il gruppo con più versioni
    gruppi: dict = defaultdict(list)
    for c in contesti:
        pid = c.get("partizione_id","")
        if pid:
            gruppi[pid].append(c)
    if not gruppi:
        return "Nessuna versione trovata."

    pid_principale = max(
        gruppi,
        key=lambda p: (len(gruppi[p]),
                       -(min(c.get("valido_dal_raw",0) or 0 for c in gruppi[p])))
    )
    versioni = sorted(gruppi[pid_principale],
                      key=lambda c: c.get("valido_dal_raw",0) or 0)

    c0     = versioni[0]
    numero = c0.get("numero","")
    codice = c0.get("codice_breve_atto","") or c0.get("nome_comune_atto","")
    righe  = [f"Storia di {numero} {codice} ({len(versioni)} versioni nel dataset)\n"]

    for c in versioni:
        vd       = c.get("valido_dal_raw","?")
        va       = c.get("valido_al_raw","?")
        tipo_mod = c.get("tipo_modifica","")
        stato    = c.get("stato_norma","ATTIVO")
        testo    = (c.get("testo_puro","") or "")[:300]

        riga = f"  [{vd} \u2192 {_va_str(va)}]"
        if tipo_mod and tipo_mod != "originale": riga += f" {tipo_mod}"
        if stato != "ATTIVO":                    riga += f" [{stato}]"
        riga += f"\n    {testo}{'...' if len(c.get('testo_puro','') or '') > 300 else ''}"
        righe.append(riga)

    return "\n".join(righe)
def _articoli_nelle_fonti(contesti: list) -> set:
    """Ritorna l'insieme dei numero_puro presenti nei contesti recuperati."""
    return {c.get("numero_puro","") for c in contesti if c.get("numero_puro")}


def controlla_allucinazioni(risposta: str, contesti: list) -> str:
    """
    Controllo post-generazione: cerca numeri articolo citati nella risposta
    che non sono presenti nei contesti recuperati e aggiunge un avviso.
    """
    citati = set(re.findall(r"[Aa]rt\.\s*(\d+(?:[\-][a-z]+)?)", risposta))
    potenziali = set()
    for n in citati:
        nb = re.match(r"\d+", n)
        if nb:
            in_fonti = any(
                nb.group(0) in (c.get("numero_puro","") or "") or
                nb.group(0) in (c.get("numero","") or "") or
                nb.group(0) in (c.get("testo_puro","") or "")[:300]
                for c in contesti
            )
            if not in_fonti:
                potenziali.add(n)
    if potenziali and FALLBACK_MARKER not in risposta:
        nums = ", ".join(sorted(potenziali))
        return (risposta +
                f"\n\n[ATTENZIONE: gli articoli {nums} citati sopra non sono "
                f"nelle fonti recuperate — verificare la risposta.]")
    return risposta


def genera_risposta(domanda: str, contesti: list, filtri: dict = None) -> str:
    """
    Genera la risposta con Mistral via streaming.
    Prompt anti-allucinazione: lista esplicita degli articoli disponibili,
    istruzione di citare SOLO il testo letterale delle fonti, temperatura 0.
    """
    if not contesti:
        return "Non ho trovato articoli rilevanti per questa domanda."
    filtri = filtri or {}

    # Elenco esplicito degli articoli nelle fonti — ancora contro le allucinazioni
    art_disp = sorted(_articoli_nelle_fonti(contesti))
    lista_art = (f"ARTICOLI NELLE FONTI: {', '.join(art_disp)}\n"
                 if art_disp else "")

    d = domanda.lower()
    if any(w in d for w in ["cambiato","cambiata","evoluzione","storia","versioni","nel tempo"]):
        extra = ("La domanda riguarda l'evoluzione storica della norma. "
                 "Struttura la risposta come lista cronologica: "
                 "date di vigenza, tipo di modifica, variazioni principali.\n")
    elif filtri.get("numero_puro"):
        extra = (f"La domanda riguarda l'articolo {filtri['numero_puro']}. "
                 "Riassumi il contenuto citando le disposizioni principali.\n")
    else:
        extra = ""

    prompt = (
        "Sei un assistente giuridico italiano specializzato in normativa storica e vigente.\n"
        f"{extra}"
        f"{lista_art}"
        "REGOLE ASSOLUTE:\n"
        "1. Cita SOLO articoli presenti nell'elenco ARTICOLI NELLE FONTI.\n"
        "2. Il testo tra virgolette deve essere COPIATO LETTERALMENTE dalle fonti. "
        "Non riformulare, non integrare, non completare.\n"
        "3. Non aggiungere testo normativo che non sia letteralmente scritto nelle FONTI.\n"
        f"4. Se le fonti non contengono la risposta, scrivi SOLO: {FALLBACK_MARKER}\n"
        "5. Formato: Art. N codice [vigente dal YYYYMMDD al YYYYMMDD]: 'testo letterale'\n\n"
        f"DOMANDA: {domanda}\n\n"
        f"FONTI:\n{formatta_contesto(contesti)}"
        "RISPOSTA:"
    )

    print("  [LLM] generazione...", flush=True)
    risposta = ""
    r = requests.post(
        f"{OLLAMA_URL}/api/generate",
        json={"model": LLM_MODEL, "prompt": prompt, "stream": True,
              "keep_alive": OLLAMA_KEEP_ALIVE,
              "options": {"temperature": 0.0, "top_p": 0.9, "num_predict": 600}},
        timeout=LLM_TIMEOUT, stream=True
    )
    r.raise_for_status()
    for line in r.iter_lines():
        if line:
            chunk = json.loads(line)
            token = chunk.get("response","")
            print(token, end="", flush=True)
            risposta += token
            if chunk.get("done"): break
    print()
    return controlla_allucinazioni(risposta.strip(), contesti)

# Estrazione temi per query semantica
# Parole non tematiche da rimuovere dalla query k-NN nelle domande evolutive/
# tematiche: articoli, preposizioni, verbi ausiliari, aggettivi generici.
_STOPWORDS_QUERY = {
    "come","era","la","il","lo","le","i","gli","una","uno","un",
    "nel","nella","nei","nelle","del","della","dei","delle",
    "dal","dalla","dai","dalle","al","alla","ai","alle",
    "di","da","in","su","per","con","tra","fra","che","ad","ed",
    "questo","questa","questi","queste","quello","quella",
    "agli","degli","sulle","sullo","sul","nello",
    "regolata","disciplinata","cambiato","cambiata","evoluta","evoluto",
    "prima","dopo","tempo","oggi","sino","fino","corso","anni",
    "testo","originario","originale","vigente","qual","era","sono",
    "stato","stata","stati","state","essere","avere","fare",
}

def _estrai_temi_query(domanda: str, prefix: str = None) -> str:
    """
    Per domande tematiche senza numero_puro (es. "Come era la prescrizione
    nel codice civile nel 1942?"), estrae le sole parole tematiche rimuovendo
    il nome del codice (già nel filtro term), gli anni (già nella finestra
    temporale) e le stopwords. Il risultato è una query k-NN più precisa
    che non viene attratta da documenti che contengono solo "codice civile 1942".
    """
    # Rimuovi nome codice
    q = re.sub(r"\bcodice\s+\w+(?:\s+(?:civile|penale|procedura|strada|navigazione))?\b",
               "", domanda, flags=re.IGNORECASE)
    # Rimuovi anni
    q = re.sub(r"\b\d{4}\b", "", q)
    # Tokenizza, lowercase, filtra stopwords e parole corte
    parole = re.findall(r"[a-zA-Z\u00C0-\u024F']+", q.lower())
    temi   = [p for p in parole if p not in _STOPWORDS_QUERY and len(p) > 3]
    q_tema = " ".join(temi) if temi else domanda  # fallback alla domanda originale
    return f"{prefix} {q_tema}" if prefix else q_tema


# Pipeline principale
def hyde_query(domanda: str, filtri: dict) -> str:
    """HyDE: genera articolo ipotetico come query semantica.
    Attivato solo se USE_HYDE=1 e nessun numero_puro nei filtri."""
    if not USE_HYDE or filtri.get("numero_puro"):
        return domanda
    try:
        codice = filtri.get("_query_prefix") or filtri.get("codice_breve_atto", "")
        prompt = (
            "Sei un esperto di diritto italiano. "
            "Scrivi il testo sintetico (massimo 3 righe) dell'articolo di legge "
            + (f"del codice {codice} " if codice else "")
            + f"che risponde a questa domanda: {domanda}\n"
            "Rispondi SOLO con il testo dell'articolo, senza titolo, senza commenti."
        )
        r = requests.post(
            f"{OLLAMA_URL}/api/generate",
            json={"model": LLM_MODEL, "prompt": prompt,
                  "stream": False, "options": {"temperature": 0, "num_predict": 150}},
            timeout=30
        )
        testo = r.json().get("response", "").strip()
        if testo:
            print(f"  [HyDE] query espansa: {testo[:80]}...")
        return testo if testo else domanda
    except Exception as e:
        print(f"  [HyDE] non disponibile ({e})")
        return domanda


def espandi_query_semantica(domanda: str, filtri: dict) -> str:
    """Keyword expansion: estrae termini giuridici tecnici dalla domanda.
    Attivato solo se USE_KW_EXP=1 e nessun filtro strutturato presente."""
    if not USE_KW_EXP:
        return domanda
    if filtri.get("numero_puro") or filtri.get("codice_breve_atto"):
        return domanda
    try:
        prompt = (
            "Dalla seguente domanda estrai esattamente 5 termini giuridici "
            "tecnici italiani che potrebbero comparire nella legge che risponde "
            "alla domanda. Rispondi SOLO con i 5 termini separati da virgola, "
            "nessun altro testo, nessuna spiegazione.\n"
            f"Domanda: {domanda}"
        )
        r = requests.post(
            f"{OLLAMA_URL}/api/generate",
            json={"model": LLM_MODEL, "prompt": prompt,
                  "stream": False, "options": {"temperature": 0, "num_predict": 50}},
            timeout=20
        )
        termini = r.json().get("response", "").strip()
        if termini:
            print(f"  [KW-EXP] termini: {termini[:80]}")
            return f"{domanda} {termini}"
        return domanda
    except Exception as e:
        print(f"  [KW-EXP] non disponibile ({e})")
        return domanda

def cerca_tutte_versioni(numero_puro: str, codice_breve_atto: str,
                         start: str = "19000101", end: str = "99991231") -> list:
    """
    Recupera tutte le versioni di un articolo specifico senza la deduplicazione
    di merge_hits(), che riduce a una sola versione per partizione.
    Usata per domande evolutive con numero di articolo esplicito,
    dove l'obiettivo è mostrare l'intera storia della disposizione.
    """
    filtri_es = build_temporal_filter(start, end) + [
        {"term": {"numero_puro":       numero_puro}},
        {"term": {"codice_breve_atto": codice_breve_atto}},
    ]
    body = {
        "size":    50,
        "_source": SOURCE_FIELDS,
        "query":   {"bool": {"filter": filtri_es}},
        "sort":    [{"valido_dal_raw": {"order": "asc"}}]
    }
    return [h["_source"] for h in _search(INDEX, body)]


def esegui_ricerca(domanda: str, start: str, end: str,
                   filtri: dict, usa_grafo: bool = True) -> tuple:
    filtri    = dict(filtri)
    prefix    = filtri.pop("_query_prefix", None)
    filtri_os = {k: v for k, v in filtri.items() if not k.startswith("_")}

    anni_dom  = _estrai_anni_temporali(domanda)
    evolutiva = is_domanda_evolutiva(domanda)

    # Per domande evolutive senza numero_puro, rimuovi dall'embedding della query
    # gli anni e i nomi del codice (già nel filtro) — così il k-NN si concentra
    # sul tema (es. "filiazione", "prescrizione", "matrimonio") invece di essere
    # attratto dai documenti che contengono solo "codice civile 1942".
    if evolutiva and not filtri_os.get("numero_puro"):
        q = _estrai_temi_query(domanda, prefix)
    else:
        q_base = f"{prefix} {domanda}" if prefix else domanda
        q_hyde = hyde_query(q_base, filtri)
        q = espandi_query_semantica(q_hyde, filtri)

    # Le domande evolutive devono sempre cercare su tkg_versions (tutte le
    # versioni storiche), mai su tkg_vigenti. Se la finestra è IS_CURRENT
    # la convertiamo in range aperto per non perdere le versioni storiche.
    if evolutiva and start == "IS_CURRENT":
        start, end = "19000101", "99991231"

    # Size adattivo: più candidati quando non ci sono filtri strutturati
    _no_filtri = not filtri_os.get("numero_puro") and not filtri_os.get("codice_breve_atto")
    _sz_base = SEARCH_SIZE_BASE * 2 if _no_filtri else SEARCH_SIZE_BASE

    if start == "IS_CURRENT":
        kw   = search_keyword_current(q, filtri_os, anni_exc=anni_dom, size=_sz_base)
        knn  = search_knn_current(q, filtri_os, size=_sz_base)
    elif start == "ORIGINALE":
        fo   = {**filtri_os, "num_versione": 0}
        _sz  = SEARCH_SIZE_BASE if filtri_os.get("numero_puro") else max(12, _sz_base)
        kw   = search_keyword(q, "19000101", "99991231", fo, size=_sz, anni_exc=anni_dom)
        knn  = search_knn(q,    "19000101", "99991231", fo, size=_sz)
    else:
        kw   = search_keyword(q, start, end, filtri_os, size=_sz_base, anni_exc=anni_dom)
        knn  = search_knn(q,    start, end, filtri_os, size=_sz_base)

    contesti = rerank(domanda,
                      filtra_per_coerenza_codice(
                          merge_hits(kw, knn, anni_domanda=anni_dom,
                                     filtri=filtri_os, start=start, end=end),
                          filtri),
                      top_k=TOP_K)
    if usa_grafo:
        contesti = arricchisci_con_grafo(contesti, start, end)
    return contesti, len(kw), len(knn)

def chatbot(domanda: str, usa_grafo: bool = True) -> str:
    print(f"\nDomanda: {domanda}")
    print(f"  Modalità : {'OpenSearch + Neo4j' if usa_grafo else 'solo OpenSearch'}")

    start, end = estrai_finestra(domanda)
    print(f"  Finestra : {start} → {end}")

    filtri = estrai_filtri(domanda)
    if filtri:
        print(f"  Filtri   : {filtri}")

    contesti, n_kw, n_knn = esegui_ricerca(domanda, start, end, filtri, usa_grafo)
    print(f"  KW={n_kw} | kNN={n_knn} | Contesti={len(contesti)}")
    for c in contesti:
        print(f"    - {c.get('numero','?')} "
              f"{c.get('codice_breve_atto','') or c.get('titolo_atto','')[:30]} "
              f"[{c.get('valido_dal_raw','?')}→{c.get('valido_al_raw','?')}]")

    if is_domanda_testuale(domanda, filtri) and contesti:
        print("  [Modalità] Risposta diretta")
        r = risposta_diretta(contesti, filtri)
        print("\n" + r)
        return r

    if is_domanda_evolutiva(domanda) and contesti:
        print("  [Modalità] Timeline evolutiva")
        r = risposta_evolutiva(contesti, domanda, filtri)
        print("\n" + r)
        return r

    risposta = genera_risposta(domanda, contesti, filtri)

    if FALLBACK_MARKER in risposta:
        print("\n  [Retry] Allargo la ricerca...")
        contesti_r = filtri_r = None

        if "numero_puro" in filtri:
            f2 = {k: v for k, v in filtri.items() if k != "numero_puro"}
            cr, _, _ = esegui_ricerca(domanda, start, end, f2, usa_grafo)
            if cr: contesti_r, filtri_r = cr, f2

        if contesti_r is None and filtri:
            cr, _, _ = esegui_ricerca(domanda, start, end, {}, usa_grafo)
            if cr: contesti_r, filtri_r = cr, {}

        if contesti_r is None and start not in ("IS_CURRENT","ORIGINALE","19000101"):
            cr, _, _ = esegui_ricerca(domanda, "19000101", "99991231", {}, usa_grafo)
            if cr: contesti_r, filtri_r = cr, {}

        if contesti_r:
            r2 = genera_risposta(domanda, contesti_r, filtri_r)
            if FALLBACK_MARKER not in r2:
                return r2

        return "Le fonti disponibili non contengono questa norma nel dataset."

    return risposta

def confronta(domanda: str) -> dict:
    """Esegue la domanda con e senza Neo4j e confronta tempi e risposte."""
    print("\n" + "="*70)
    print(f"CONFRONTO — {domanda}")
    print("="*70)

    t0 = time.time()
    r_os = chatbot(domanda, usa_grafo=False)
    t_os = time.time() - t0

    t0 = time.time()
    r_kg = chatbot(domanda, usa_grafo=True)
    t_kg = time.time() - t0

    print(f"\nSolo OpenSearch   : {t_os:.1f}s")
    print(f"OpenSearch + Neo4j: {t_kg:.1f}s")
    print("="*70)
    return {"domanda": domanda,
            "solo_opensearch":    {"risposta": r_os, "tempo_s": round(t_os,1)},
            "opensearch_e_neo4j": {"risposta": r_kg, "tempo_s": round(t_kg,1)}}


# Entry point
if __name__ == "__main__":
    print("=== Chatbot Giuridico — Normativa Italiana ===")
    print(f"  Indice        : {INDEX} / {INDEX_VIGENTI}")
    print(f"  LLM           : {LLM_MODEL} (Ollama)")
    print(f"  Embedding     : {COHERE_MODEL} ({COHERE_EMBED_DIM}dim, Cohere)")
    print(f"  Reranker      : {'attivo' if RERANKER_DISPONIBILE else 'non disponibile'}")
    print(f"  Neo4j         : {'disponibile' if NEO4J_DISPONIBILE else 'non disponibile'}")
    print("  Comandi: 'esci' per uscire, 'confronta: <domanda>' per A/B test\n")

    warmup_llm()

    while True:
        try:
            domanda = input("Domanda: ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\nUscita.")
            break
        if not domanda:
            continue
        if domanda.lower() in ("esci","exit","quit"):
            break
        try:
            if domanda.lower().startswith("confronta:"):
                confronta(domanda.split(":",1)[1].strip())
            else:
                chatbot(domanda)
        except requests.exceptions.Timeout:
            print(f"  ERRORE: timeout dopo {LLM_TIMEOUT}s.")
        except Exception as e:
            print(f"  ERRORE: {e}")