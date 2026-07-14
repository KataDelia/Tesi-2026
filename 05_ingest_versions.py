"""
05_ingest_versions.py

Legge nodi_Versione.csv (prodotto dalla pipeline R su NIR/Normattiva)
e indicizza i documenti in due indici OpenSearch:
    - tkg_versions : tutte le versioni (storiche + vigenti)
    - tkg_vigenti  : sole versioni con is_current=True (query rapide)

Variabili d'ambiente richieste:
    OS_PASS         password OpenSearch
    COHERE_API_KEY  chiave API Cohere

Uso:
    python3 05_ingest_versions.py nodi_Versione.csv
    python3 05_ingest_versions.py --refresh-vigenza
"""

import os, sys, csv, json, time, re, requests
from datetime import date
from typing import List, Optional
from concurrent.futures import ThreadPoolExecutor, as_completed
import urllib3
import cohere

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configurazione

OS_URL    = os.getenv("OS_URL",       "https://localhost:9200")
OS_USER   = os.getenv("OS_USER",      "admin")
OS_PASS   = os.getenv("OS_PASS")
INDEX_ALL = os.getenv("OS_INDEX",     "tkg_versions")
INDEX_CUR = os.getenv("OS_INDEX_CUR", "tkg_vigenti")

COHERE_API_KEY = os.getenv("COHERE_API_KEY")
COHERE_MODEL   = "embed-multilingual-v3.0"
EMBED_DIM      = 1024

BATCH_SIZE       = 20   # documenti per richiesta bulk OpenSearch
EMBED_BATCH_SIZE = 48   # testi per chiamata Cohere (rate limit trial: 100k token/min)
EMBED_WORKERS    = 1    # worker singolo per rispettare il rate limit
MAX_RETRY        = 3
RETRY_DELAY      = 2.0
CHECKPOINT_FILE  = "ingest_checkpoint.json"

if not OS_PASS:
    print("ERRORE: variabile d'ambiente OS_PASS non impostata.")
    sys.exit(1)

AUTH = (OS_USER, OS_PASS)


# Client Cohere (lazy)

_cohere_client = None

def get_cohere_client():
    global _cohere_client
    if _cohere_client is None:
        if not COHERE_API_KEY:
            print("ERRORE: variabile d'ambiente COHERE_API_KEY non impostata.")
            sys.exit(1)
        _cohere_client = cohere.Client(api_key=COHERE_API_KEY)
    return _cohere_client


# Checkpoint

def load_checkpoint() -> set:
    if os.path.exists(CHECKPOINT_FILE):
        try:
            return set(json.load(open(CHECKPOINT_FILE)))
        except Exception:
            pass
    return set()

def save_checkpoint(ids: set) -> None:
    json.dump(list(ids), open(CHECKPOINT_FILE, "w"))


# Utilità

def to_int_date(val) -> Optional[int]:
    if val in (None, "", "NA", "0", 0):
        return None
    try:
        s = str(int(float(str(val).strip())))
        return int(s) if len(s) == 8 else None
    except (ValueError, TypeError):
        return None


# Gestione indici

def verifica_indice(name: str) -> None:
    r = requests.head(f"{OS_URL}/{name}", auth=AUTH, verify=False, timeout=10)
    if r.status_code == 404:
        print(f"ERRORE: indice '{name}' non trovato. Eseguire 04_create_index.py")
        sys.exit(1)

def crea_indice_se_mancante(name: str) -> None:
    """Crea tkg_vigenti copiando mapping e settings da tkg_versions."""
    if requests.head(f"{OS_URL}/{name}", auth=AUTH, verify=False, timeout=10).status_code == 200:
        print(f"  Indice '{name}' già esistente.")
        return
    r = requests.get(f"{OS_URL}/{INDEX_ALL}", auth=AUTH, verify=False, timeout=10)
    if r.status_code != 200:
        print(f"  Impossibile leggere il mapping da '{INDEX_ALL}'")
        return
    src = r.json()[INDEX_ALL]
    payload = {
        "settings": {
            "index": {
                "number_of_shards":         src["settings"]["index"].get("number_of_shards", "1"),
                "number_of_replicas":       "0",
                "knn":                      True,
                "knn.algo_param.ef_search": 200
            },
            "analysis": src["settings"]["index"].get("analysis", {})
        },
        "mappings": src["mappings"]
    }
    r = requests.put(f"{OS_URL}/{name}", json=payload, auth=AUTH, verify=False, timeout=30)
    print(f"  Indice '{name}' {'creato.' if r.status_code == 200 else f'ERRORE: {r.text}'}")


# Embedding

def calcola_embedding_batch(testi: List[str]) -> List[List[float]]:
    """Chiama Cohere embed con input_type=search_document e ritorna vettori 1024-dim."""
    client     = get_cohere_client()
    testi_norm = [t.replace("\n", " ").strip()[:8000] or "." for t in testi]

    for attempt in range(1, MAX_RETRY + 1):
        try:
            time.sleep(1.5)   # rispetta il rate limit trial
            resp = client.embed(
                texts=testi_norm,
                model=COHERE_MODEL,
                input_type="search_document",
                embedding_types=["float"]
            )
            embs = resp.embeddings.float
            if len(embs) != len(testi):
                raise ValueError(f"Embedding attesi {len(testi)}, ricevuti {len(embs)}")
            return embs
        except Exception as e:
            if attempt < MAX_RETRY:
                time.sleep(RETRY_DELAY * (2 ** (attempt - 1)))
            else:
                raise


# Testo per embedding

def build_embedding_text(d: dict) -> str:
    """
    Costruisce il testo che Cohere embedda per ogni versione.
    Include tutti i segnali utili al retrieval semantico:
    identificatore articolo, nomi alternativi dell'atto, vigenza, testo normativo.
    """
    numero        = d.get("numero", "")            or ""
    codice_breve  = d.get("codice_breve_atto", "")  or ""
    nome_comune   = d.get("nome_comune_atto", "")   or ""
    denominazione = d.get("denominazione_comune","") or ""
    alias         = d.get("alias_codice", "")       or ""
    titolo_atto   = d.get("titolo_atto", "")        or ""
    vd            = d.get("valido_dal", "")         or ""
    va            = d.get("valido_al", "")          or ""
    tipo_mod      = d.get("tipo_modifica", "")      or ""
    stato_vig     = d.get("stato_vigenza", "")      or ""

    parts = []

    if numero:
        tag = codice_breve or alias or nome_comune or denominazione or titolo_atto
        parts.append(f"{numero} {tag}".strip() if tag else numero)

    for n in sorted({x for x in [nome_comune, denominazione, alias] if x}):
        parts.append(n)

    if vd and va:
        if stato_vig == "ABROGATO":
            va_str = f"abrogato, valido fino al {va}" if va != "99991231" else "abrogato"
        elif stato_vig == "STORICO":
            va_str = f"storico, fino al {va}"
        else:
            va_str = "in vigore" if va == "99991231" else f"fino al {va}"
        parts.append(f"Vigente dal {vd} {va_str}")

    if tipo_mod and tipo_mod != "originale":
        parts.append(f"Tipo modifica: {tipo_mod}")

    testo = d.get("testo_puro", "") or ""
    if testo:
        parts.append(testo)

    return "\n\n".join(p for p in parts if p.strip())


# Costruzione documento OpenSearch

def make_doc(d: dict, emb: List[float]) -> dict:
    """
    Mappa una riga CSV nel documento OpenSearch da indicizzare.
    - partizione_id usa URN_base dal CSV (più affidabile del regex su versione_id)
    - numero_puro include il suffisso bis/ter per evitare collisioni tra articoli
    - is_current deriva da stato_vigenza, non dalle date (semantica NIR:
      valido_al=99991231 su un ABROGATO significa "nessuna data esplicita")
    - aliases popolato con sinonimi dell'atto per migliorare il recall BM25
    """
    vd = to_int_date(d.get("valido_dal"))
    va = to_int_date(d.get("valido_al")) or 99991231

    versione_id = d.get("versione_id:ID(Versione)") or d.get("versione_id") or d.get("id")
    if not versione_id:
        raise ValueError("versione_id mancante nel record")

    partizione_id = (d.get("URN_base") or d.get("partizione_id") or
                     re.sub(r"_V\d+$", "", versione_id))

    numero        = d.get("numero", "")           or ""
    codice_breve  = d.get("codice_breve_atto","")  or ""
    nome_comune   = d.get("nome_comune_atto","")   or ""
    denominazione = d.get("denominazione_comune","") or ""
    alias         = d.get("alias_codice","")       or ""
    titolo_atto   = d.get("titolo_atto","")        or ""
    stato_vig     = d.get("stato_vigenza","")      or ""

    m = re.search(
        r"(\d+(?:[\-\s](?:bis|ter|quater|quinquies|sexies|septies|octies))?)",
        numero, re.IGNORECASE
    )
    numero_puro = m.group(1).lower().replace(" ", "-") if m else None

    id_atto = codice_breve or alias or nome_comune or denominazione or titolo_atto
    title   = f"{numero} {id_atto}".strip() if id_atto else numero
    aliases = list({x for x in [alias, denominazione, nome_comune] if x})

    return {
        "versione_id":          versione_id,
        "partizione_id":        partizione_id,
        "num_versione":         int(d.get("num_versione") or 0),
        "numero":               numero,
        "numero_puro":          numero_puro,
        "title":                title,
        "titolo_atto":          titolo_atto,
        "nome_comune_atto":     nome_comune,
        "codice_breve_atto":    codice_breve,
        "denominazione_comune": denominazione,
        "atto_appartenenza":    d.get("atto_appartenenza","") or "",
        "stato_vigenza":        stato_vig,
        "stato_norma":          d.get("stato_norma","")       or "",
        "tipo_modifica":        d.get("tipo_modifica","")     or "",
        "testo_puro":           d.get("testo_puro","")        or "",
        "aliases":              aliases,
        "valido_dal_raw":       vd,
        "valido_al_raw":        va,
        "is_current":           (stato_vig == "VIGENTE"),
        "embedding":            emb
    }


# Indicizzazione bulk

def bulk_index(docs: List[dict], index_name: str) -> int:
    lines = []
    for doc in docs:
        lines.append(json.dumps({"index": {"_index": index_name, "_id": doc["versione_id"]}},
                                ensure_ascii=False))
        lines.append(json.dumps(doc, ensure_ascii=False))
    r = requests.post(
        f"{OS_URL}/_bulk",
        data=("\n".join(lines) + "\n").encode("utf-8"),
        headers={"Content-Type": "application/x-ndjson"},
        auth=AUTH, verify=False, timeout=300
    )
    r.raise_for_status()
    res = r.json()
    if res.get("errors"):
        errori = [it for it in res["items"] if it.get("index", {}).get("error")]
        return len(docs) - len(errori)
    return len(docs)

def bulk_index_dual(docs_all: List[dict], docs_cur: List[dict]) -> tuple:
    ok_all = bulk_index(docs_all, INDEX_ALL) if docs_all else 0
    ok_cur = bulk_index(docs_cur, INDEX_CUR) if docs_cur else 0
    return ok_all, ok_cur


# Lettura CSV / JSONL

def leggi_records(path: str):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".csv":
        with open(path, encoding="utf-8") as f:
            yield from (dict(r) for r in csv.DictReader(f))
    else:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    raw = json.loads(line)
                    yield raw["v"] if isinstance(raw.get("v"), dict) else raw


# Elaborazione chunk

def processa_chunk(records: List[dict]) -> List[dict]:
    testi, validi = [], []
    for d in records:
        try:
            t = build_embedding_text(d)
            if t.strip():
                testi.append(t)
                validi.append(d)
        except Exception:
            continue
    if not testi:
        return []
    embs = calcola_embedding_batch(testi)
    docs = []
    for d, emb in zip(validi, embs):
        try:
            docs.append(make_doc(d, emb))
        except Exception:
            pass
    return docs


# Aggiornamento vigenza senza nuovi embedding

def refresh_vigenza() -> None:
    """
    Ricalcola is_current su tkg_versions e sincronizza tkg_vigenti.
    Non chiama Cohere — riusa gli embedding già salvati.
    Utile dopo aggiornamenti del CSV senza riffare l'ingest completo.
    """
    print(f"\nRefresh vigenza (nessuna chiamata Cohere)")
    verifica_indice(INDEX_ALL)
    crea_indice_se_mancante(INDEX_CUR)

    script = {
        "script": {
            "lang":   "painless",
            "source": "ctx._source.is_current = (ctx._source.stato_vigenza == 'VIGENTE');",
        },
        "query": {"match_all": {}}
    }
    r = requests.post(f"{OS_URL}/{INDEX_ALL}/_update_by_query?conflicts=proceed",
                      json=script, auth=AUTH, verify=False, timeout=300)
    r.raise_for_status()
    print(f"  is_current aggiornato: {r.json().get('updated', 0)} documenti")

    r = requests.post(f"{OS_URL}/_reindex",
                      json={"source": {"index": INDEX_ALL, "query": {"term": {"is_current": True}}},
                            "dest":   {"index": INDEX_CUR}},
                      auth=AUTH, verify=False, timeout=300)
    r.raise_for_status()
    print(f"  Sincronizzati in '{INDEX_CUR}': {r.json().get('total', 0)} documenti")

    r = requests.post(f"{OS_URL}/{INDEX_CUR}/_delete_by_query",
                      json={"query": {"term": {"is_current": False}}},
                      auth=AUTH, verify=False, timeout=300)
    r.raise_for_status()
    print(f"  Rimossi da '{INDEX_CUR}': {r.json().get('deleted', 0)} documenti non vigenti\n")


# Pipeline principale

def run(path: str) -> None:
    print(f"\nIngest da: {path}")
    print(f"  Indice completo : {INDEX_ALL}")
    print(f"  Indice vigenti  : {INDEX_CUR}")
    print(f"  Embedding model : {COHERE_MODEL} ({EMBED_DIM} dim)\n")

    verifica_indice(INDEX_ALL)
    crea_indice_se_mancante(INDEX_CUR)

    done    = load_checkpoint()
    records = [r for r in leggi_records(path)
               if (r.get("versione_id") or r.get("versione_id:ID(Versione)") or "")
               not in done]
    n_tot   = len(records)
    print(f"  Da indicizzare: {n_tot} (già fatti: {len(done)})\n")

    ok_all = ok_cur = err = 0
    t0     = time.time()
    done_ids: set = set(done)
    buf_all: List[dict] = []
    buf_cur: List[dict] = []

    def flush():
        nonlocal ok_all, ok_cur, err
        if not buf_all:
            return
        a, c = bulk_index_dual(buf_all, buf_cur)
        ok_all += a; ok_cur += c; err += len(buf_all) - a
        for doc in buf_all:
            done_ids.add(doc["versione_id"])
        buf_all.clear(); buf_cur.clear()

    chunks  = [records[i:i+EMBED_BATCH_SIZE] for i in range(0, n_tot, EMBED_BATCH_SIZE)]
    futures = {ThreadPoolExecutor(max_workers=EMBED_WORKERS)
               .submit(processa_chunk, c): c for c in chunks}

    for idx, future in enumerate(as_completed(futures), 1):
        try:
            docs = future.result()
        except Exception as e:
            print(f"  [Chunk {idx}] Errore: {e}")
            err += len(futures[future])
            continue

        for doc in docs:
            buf_all.append(doc)
            if doc["is_current"]:
                buf_cur.append(doc)

        while len(buf_all) >= BATCH_SIZE:
            to_all = buf_all[:BATCH_SIZE]
            to_cur = [d for d in to_all if d["is_current"]]
            buf_all[:] = buf_all[BATCH_SIZE:]
            buf_cur[:] = [d for d in buf_cur if d not in to_all]
            a, c = bulk_index_dual(to_all, to_cur)
            ok_all += a; ok_cur += c; err += len(to_all) - a
            for doc in to_all:
                done_ids.add(doc["versione_id"])

        if idx % 10 == 0:
            vel = ok_all / (time.time() - t0)
            print(f"  [{idx*EMBED_BATCH_SIZE:6d}/{n_tot}] "
                  f"all={ok_all} cur={ok_cur} err={err} | {vel:.1f} doc/s")
            save_checkpoint(done_ids)

    flush()
    save_checkpoint(done_ids)
    elapsed = time.time() - t0
    print(f"""
=== Ingest completato ===
  tkg_versions : {ok_all}
  tkg_vigenti  : {ok_cur}
  Scartati     : {err}
  Tempo        : {elapsed:.1f}s  ({ok_all/elapsed:.1f} doc/s)
""")


# Entry point

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso:")
        print("  python3 05_ingest_versions.py <file.csv|file.jsonl>")
        print("  python3 05_ingest_versions.py --refresh-vigenza")
        sys.exit(1)
    if sys.argv[1] == "--refresh-vigenza":
        refresh_vigenza()
    else:
        run(sys.argv[1])
