"""
05_ingest_versions.py
=====================
Ingestion dei nodi Versione per OpenSearch.

Legge il CSV prodotto dalla pipeline R e indicizza i documenti in due indici:
    - tkg_versions: tutte le versioni
    - tkg_vigenti: sole versioni vigenti

Uso:
    python3 05_ingest_versions.py output_neo4j/nodi_Versione.csv
"""

import os
import sys
import csv
import json
import time
import re
import requests
from datetime import date
from typing import List, Optional
from concurrent.futures import ThreadPoolExecutor, as_completed
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configurazione

OS_URL       = os.getenv("OS_URL",       "https://localhost:9200")
OS_USER      = os.getenv("OS_USER",      "admin")
OS_PASS      = os.getenv("OS_PASS",      "PasswordForte123")
INDEX_ALL    = os.getenv("OS_INDEX",     "tkg_versions")  # indice completo
INDEX_CUR    = os.getenv("OS_INDEX_CUR", "tkg_vigenti")   # indice vigenti
OLLAMA_URL   = os.getenv("OLLAMA_URL",   "http://localhost:11434")
EMBED_MODEL  = os.getenv("EMBED_MODEL",  "nomic-embed-text")

BATCH_SIZE       = 20    # documenti per richiesta bulk verso OpenSearch
EMBED_BATCH_SIZE = 10    # testi per chiamata batch a Ollama
EMBED_WORKERS    = 3     # thread paralleli per l'embedding
MAX_RETRY        = 3     # tentativi in caso di errore di rete
RETRY_DELAY      = 2.0   # secondi tra un tentativo e il successivo (base)
CHECKPOINT_FILE  = "ingest_checkpoint.json"

AUTH      = (OS_USER, OS_PASS)
TODAY_INT = int(date.today().strftime("%Y%m%d"))


# Checkpoint

def load_checkpoint() -> set:
    """Carica il set degli ID già indicizzati dal checkpoint."""
    if os.path.exists(CHECKPOINT_FILE):
        try:
            with open(CHECKPOINT_FILE) as f:
                return set(json.load(f))
        except Exception:
            pass
    return set()


def save_checkpoint(ids: set) -> None:
    """Salva il set degli ID indicizzati sul disco."""
    with open(CHECKPOINT_FILE, "w") as f:
        json.dump(list(ids), f)


# Utilità date

def to_int_date(val) -> Optional[int]:
    """Converte una data nel formato intero YYYYMMDD."""
    if val in (None, "", "NA", "0", 0):
        return None
    try:
        s = str(int(float(str(val).strip())))
        return int(s) if len(s) == 8 else None
    except (ValueError, TypeError):
        return None


# Gestione indici

def verifica_indice(index_name: str) -> None:
    """Verifica che l'indice esista; termina con errore se assente."""
    r = requests.head(f"{OS_URL}/{index_name}", auth=AUTH, verify=False, timeout=10)
    if r.status_code == 404:
        print(f"ERRORE: indice '{index_name}' non trovato. Eseguire 04_create_index.py")
        sys.exit(1)


def crea_indice_se_mancante(index_name: str) -> None:
    """Crea l'indice secondario copiando settings e mapping dal principale."""
    r = requests.head(f"{OS_URL}/{index_name}", auth=AUTH, verify=False, timeout=10)
    if r.status_code == 200:
        print(f"  Indice '{index_name}' già esistente.")
        return

    r_full = requests.get(f"{OS_URL}/{INDEX_ALL}", auth=AUTH, verify=False, timeout=10)
    if r_full.status_code != 200:
        print(f"  ATTENZIONE: impossibile leggere il mapping da '{INDEX_ALL}'")
        return

    full          = r_full.json()[INDEX_ALL]
    orig_settings = full.get("settings", {}).get("index", {})
    orig_mappings = full.get("mappings", {})

    payload = {
        "settings": {
            "index": {
                "number_of_shards":        orig_settings.get("number_of_shards", "1"),
                "number_of_replicas":      "0",
                "knn":                     True,
                "knn.algo_param.ef_search": 100
            },
            "analysis": orig_settings.get("analysis", {})
        },
        "mappings": orig_mappings
    }

    rc = requests.put(f"{OS_URL}/{index_name}",
                      json=payload, auth=AUTH, verify=False, timeout=30)
    if rc.status_code == 200:
        print(f"  Indice '{index_name}' creato.")
    else:
        print(f"  ATTENZIONE: impossibile creare '{index_name}': {rc.text}")


# Embedding

def calcola_embedding_batch(testi: List[str]) -> List[List[float]]:
    """Genera embedding batch con fallback su /api/embeddings."""
    for attempt in range(1, MAX_RETRY + 1):
        try:
            try:
                r = requests.post(
                    f"{OLLAMA_URL}/api/embed",
                    json={"model": EMBED_MODEL, "input": testi},
                    timeout=120
                )
                r.raise_for_status()
                embeddings = r.json()["embeddings"]
            except requests.exceptions.HTTPError:
                embeddings = []
                for testo in testi:
                    r2 = requests.post(
                        f"{OLLAMA_URL}/api/embeddings",
                        json={"model": EMBED_MODEL, "prompt": testo},
                        timeout=90
                    )
                    r2.raise_for_status()
                    embeddings.append(r2.json()["embedding"])

            if len(embeddings) != len(testi):
                raise ValueError(
                    f"Embedding attesi: {len(testi)}, ricevuti: {len(embeddings)}"
                )
            return embeddings

        except Exception as e:
            if attempt < MAX_RETRY:
                delay = RETRY_DELAY * (2 ** (attempt - 1))
                time.sleep(delay)
            else:
                raise


# Testo di embedding

def build_embedding_text(d: dict) -> str:
    """Costruisce il testo di embedding per ogni versione."""
    parts = []
    numero       = d.get("numero", "") or ""
    codice_breve = d.get("codice_breve_atto", "") or ""
    nome_comune  = d.get("nome_comune_atto", "") or ""
    titolo_atto  = d.get("titolo_atto", "") or ""
    vd           = d.get("valido_dal") or d.get("valido_dal_raw", "")
    va           = d.get("valido_al")  or d.get("valido_al_raw", "")
    tipo_mod     = d.get("tipo_modifica", "") or ""
    stato_norma  = d.get("stato_norma", "") or ""

    if numero:
        id_str = numero
        if codice_breve:  id_str += f" {codice_breve}"
        elif nome_comune: id_str += f" — {nome_comune}"
        elif titolo_atto: id_str += f" — {titolo_atto}"
        parts.append(id_str)

    if nome_comune:   parts.append(nome_comune)
    elif titolo_atto: parts.append(titolo_atto)

    if vd and va:
        va_str = "in vigore" if str(va) == "99991231" else f"fino al {va}"
        parts.append(f"Vigente dal {vd} {va_str}")

    if tipo_mod and tipo_mod not in ("originale", ""):
        parts.append(f"Tipo modifica: {tipo_mod}")

    if stato_norma and stato_norma != "ATTIVO":
        parts.append(f"Stato: {stato_norma}")

    testo = d.get("testo_puro", "") or ""
    if testo:
        parts.append(testo)

    return "\n\n".join(p for p in parts if p.strip())


# Mapping documento OpenSearch

def make_doc(d: dict, emb: List[float]) -> dict:
    """Mappa un record del CSV nodi_Versione nel documento OpenSearch."""
    vd = to_int_date(d.get("valido_dal") or d.get("valido_dal_raw"))
    va = to_int_date(d.get("valido_al")  or d.get("valido_al_raw")) or 99991231

    vd_s       = str(vd) if vd else None
    va_s       = str(va)
    is_current = (vd is not None and vd <= TODAY_INT <= va)

    numero      = d.get("numero", "") or ""
    numero_puro = re.search(r"\d+", numero)
    numero_puro = numero_puro.group(0) if numero_puro else None

    versione_id = (d.get("versione_id:ID(Versione)") or
                   d.get("versione_id") or d.get("id"))
    if not versione_id:
        raise ValueError("versione_id mancante nel record")

    partizione_id = d.get("partizione_id") or re.sub(r"_V\d+$", "", versione_id)

    return {
        "id":                versione_id,
        "versione_id":       versione_id,
        "art_id":            partizione_id,
        "partizione_id":     partizione_id,
        "num_versione":      int(d.get("num_versione") or 0),
        "numero":            numero,
        "numero_puro":       numero_puro,
        "titolo_atto":       d.get("titolo_atto", "")       or "",
        "nome_comune_atto":  d.get("nome_comune_atto", "")  or "",
        "codice_breve_atto": d.get("codice_breve_atto", "") or "",
        "atto_appartenenza": d.get("atto_appartenenza", "") or "",
        "stato_norma":       d.get("stato_norma", "")       or "",
        "stato_vigenza":     d.get("stato_vigenza", d.get("stato_temporale", "")) or "",
        "tipo_modifica":     d.get("tipo_modifica", "")     or "",
        "title":             f"{numero} — {d.get('titolo_atto', '') or ''}".strip(" —"),
        "testo_puro":        d.get("testo_puro", "")        or "",
        "aliases":           [],
        "keywords":          [],
        "valido_dal_dt":     vd_s,
        "valido_al_dt":      va_s,
        "valido_dal_raw":    vd,
        "valido_al_raw":     va,
        "year_from":         int(vd_s[:4]) if vd_s else None,
        "year_to":           int(va_s[:4]),
        "is_current":        is_current,
        "embedding":         emb
    }


# Indicizzazione bulk

def bulk_index(docs: List[dict], index_name: str) -> int:
    """Invia un batch di documenti a OpenSearch tramite l'API _bulk."""
    lines = []
    for doc in docs:
        lines.append(json.dumps(
            {"index": {"_index": index_name, "_id": doc["id"]}},
            ensure_ascii=False
        ))
        lines.append(json.dumps(doc, ensure_ascii=False))

    body = "\n".join(lines) + "\n"
    r = requests.post(
        f"{OS_URL}/_bulk",
        data=body.encode("utf-8"),
        headers={"Content-Type": "application/x-ndjson"},
        auth=AUTH, verify=False, timeout=300
    )
    r.raise_for_status()
    res = r.json()

    if res.get("errors"):
        errori = [it["index"] for it in res["items"]
                  if it.get("index", {}).get("error")]
        return len(docs) - len(errori)
    return len(docs)


def bulk_index_dual(docs_all: List[dict], docs_cur: List[dict]) -> tuple:
    """
    Invia i documenti verso entrambi gli indici in sequenza.
    docs_all → tkg_versions (tutte le versioni)
    docs_cur → tkg_vigenti  (sole versioni vigenti, sottoinsieme di docs_all)
    """
    ok_all = bulk_index(docs_all, INDEX_ALL) if docs_all else 0
    ok_cur = bulk_index(docs_cur, INDEX_CUR) if docs_cur else 0
    return ok_all, ok_cur


# Lettura file sorgente

def leggi_records(path: str):
    """Legge il file sorgente e restituisce i record come dizionari."""
    ext = os.path.splitext(path)[1].lower()
    if ext == ".csv":
        with open(path, "r", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                yield dict(row)
    else:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    raw = json.loads(line)
                    yield raw["v"] if "v" in raw and isinstance(raw["v"], dict) else raw


# Elaborazione chunk

def processa_chunk(records: List[dict]) -> List[dict]:
    """Elabora un chunk di record e scarta silenziosamente gli errori."""
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

    embeddings = calcola_embedding_batch(testi)
    docs = []
    for d, emb in zip(validi, embeddings):
        try:
            docs.append(make_doc(d, emb))
        except Exception:
            pass
    return docs


# Pipeline principale

def run(path: str) -> None:
    """Esegue la pipeline di ingestion completa."""
    print(f"\nAvvio ingestion da: {path}")
    print(f"  Indice completo  : {INDEX_ALL}")
    print(f"  Indice vigenti   : {INDEX_CUR}")
    print(f"  Batch embedding  : {EMBED_BATCH_SIZE} testi/chiamata Ollama")
    print(f"  Worker paralleli : {EMBED_WORKERS}\n")

    verifica_indice(INDEX_ALL)
    crea_indice_se_mancante(INDEX_CUR)

    already_done = load_checkpoint()
    if already_done:
        print(f"  Checkpoint: {len(already_done)} documenti già indicizzati.\n")

    all_records = list(leggi_records(path))
    n_tot       = len(all_records)
    all_records = [
        r for r in all_records
        if (r.get("versione_id") or r.get("versione_id:ID(Versione)") or "")
        not in already_done
    ]
    print(f"  Record totali    : {n_tot}")
    print(f"  Da indicizzare   : {len(all_records)}\n")

    total_ok_all = 0
    total_ok_cur = 0
    total_err    = 0
    t_start      = time.time()
    done_ids     = set(already_done)
    buf_all: List[dict] = []
    buf_cur: List[dict] = []

    def flush() -> None:
        """Svuota i buffer inviando i documenti rimanenti a OpenSearch."""
        nonlocal total_ok_all, total_ok_cur, total_err
        if buf_all or buf_cur:
            ok_a, ok_c = bulk_index_dual(buf_all, buf_cur)
            total_ok_all += ok_a
            total_ok_cur += ok_c
            total_err    += len(buf_all) - ok_a
            for doc in buf_all:
                done_ids.add(doc["id"])
            buf_all.clear()
            buf_cur.clear()

    chunks = [
        all_records[i:i + EMBED_BATCH_SIZE]
        for i in range(0, len(all_records), EMBED_BATCH_SIZE)
    ]

    with ThreadPoolExecutor(max_workers=EMBED_WORKERS) as executor:
        futures = {executor.submit(processa_chunk, c): c for c in chunks}

        for idx, future in enumerate(as_completed(futures), 1):
            try:
                docs = future.result()
            except Exception as e:
                print(f"  [Chunk {idx}] Errore: {e}")
                total_err += len(futures[future])
                continue

            for doc in docs:
                buf_all.append(doc)
                if doc.get("is_current"):
                    buf_cur.append(doc)

            # Flush buffer
            while len(buf_all) >= BATCH_SIZE:
                to_all = buf_all[:BATCH_SIZE]
                to_cur = [d for d in to_all if d.get("is_current")]
                buf_all[:] = buf_all[BATCH_SIZE:]
                buf_cur[:] = [d for d in buf_cur if d not in to_all]
                ok_a, ok_c = bulk_index_dual(to_all, to_cur)
                total_ok_all += ok_a
                total_ok_cur += ok_c
                total_err    += len(to_all) - ok_a
                for doc in to_all:
                    done_ids.add(doc["id"])

            # Progresso e checkpoint
            if idx % 10 == 0:
                elapsed = time.time() - t_start
                vel     = total_ok_all / elapsed if elapsed > 0 else 0
                print(f"  [{idx * EMBED_BATCH_SIZE:6d}/{len(all_records)}] "
                      f"all={total_ok_all} cur={total_ok_cur} "
                      f"err={total_err} | {vel:.1f} doc/s")
                save_checkpoint(done_ids)

    flush()
    save_checkpoint(done_ids)

    elapsed = time.time() - t_start
    print(f"""
=== Ingestion completata ===
  Indicizzati (tkg_versions) : {total_ok_all}
  Indicizzati (tkg_vigenti)  : {total_ok_cur}
  Scartati                   : {total_err}
  Tempo totale               : {elapsed:.1f}s
  Velocità media             : {total_ok_all / elapsed:.1f} doc/s
""")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso: python3 05_ingest_versions.py <file.csv|file.jsonl>")
        sys.exit(1)
    run(sys.argv[1])
