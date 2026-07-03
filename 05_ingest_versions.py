# 05_ingest_versions.py
# Ingestion dei nodi Versione da JSONL verso OpenSearch con embedding.
#
# Uso: python 05_ingest_versions.py <percorso_file.jsonl>
#
# Il file JSONL si genera esportando i nodi Versione da Neo4j:
#   CALL apoc.export.json.query(
#     "MATCH (v:Versione) RETURN v",
#     "versioni.jsonl", {jsonFormat: "JSON_LINES"}
#   )
# Oppure direttamente dal CSV prodotto da 03_export_neo4j.R:
#   python 05_ingest_versions.py output_neo4j/nodi_Versione.csv

import os
import sys
import csv
import json
import time
import requests
from datetime import date
from typing import List, Optional
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ── Configurazione ─────────────────────────────────────────────────────────────
OS_URL      = os.getenv("OS_URL",      "https://localhost:9200")
OS_USER     = os.getenv("OS_USER",     "admin")
OS_PASS     = os.getenv("OS_PASS",     "PasswordForte123")
INDEX       = os.getenv("OS_INDEX",    "tkg_versions")
OLLAMA_URL  = os.getenv("OLLAMA_URL",  "http://localhost:11434")
EMBED_MODEL = os.getenv("EMBED_MODEL", "nomic-embed-text")

BATCH_SIZE   = 50     # Documenti per batch bulk
MAX_RETRY    = 3      # Tentativi per embedding fallito
RETRY_DELAY  = 2.0    # Secondi tra un tentativo e l'altro

AUTH = (OS_USER, OS_PASS)
TODAY_INT = int(date.today().strftime("%Y%m%d"))

# ── Utilità date ───────────────────────────────────────────────────────────────

def to_int_date(val) -> Optional[int]:
    """Converte un valore data a intero YYYYMMDD. Restituisce None se non valido."""
    if val in (None, "", "NA", "0", 0):
        return None
    try:
        s = str(int(float(str(val).strip())))
        return int(s) if len(s) == 8 else None
    except (ValueError, TypeError):
        return None

def to_date_str(val) -> Optional[str]:
    """Converte a stringa YYYYMMDD per il campo date di OpenSearch."""
    i = to_int_date(val)
    return str(i) if i else None

# ── Embedding ──────────────────────────────────────────────────────────────────

def calcola_embedding(testo: str) -> List[float]:
    """
    Genera embedding via Ollama con retry automatico.
    FIX: aggiunto retry su errori temporanei (Ollama occupato).
    """
    for attempt in range(1, MAX_RETRY + 1):
        try:
            r = requests.post(
                f"{OLLAMA_URL}/api/embed",
                json={"model": EMBED_MODEL, "input": testo},
                timeout=90
            )
            r.raise_for_status()
            data = r.json()
            emb  = data["embeddings"][0]
            if len(emb) != 768:
                raise ValueError(f"Dimensione embedding inattesa: {len(emb)} (atteso 768)")
            return emb
        except Exception as e:
            if attempt < MAX_RETRY:
                print(f"    [Embedding] Tentativo {attempt} fallito: {e}. Riprovo tra {RETRY_DELAY}s...")
                time.sleep(RETRY_DELAY)
            else:
                raise

# ── Costruzione testo per embedding ───────────────────────────────────────────

def build_embedding_text(d: dict) -> str:
    """
    Costruisce un testo ricco e identificativo per l'embedding.
    FIX rispetto all'originale: il testo include numero articolo, nome
    del codice e atto di appartenenza — così il modello distingue
    "art. 52 c.p." da "art. 52 cod.nav." anche senza filtri.
    """
    parts = []

    # Identificazione primaria: numero articolo + codice
    numero         = d.get("numero", "")
    codice_breve   = d.get("codice_breve_atto", "")
    nome_comune    = d.get("nome_comune_atto", "")
    titolo_atto    = d.get("titolo_atto", "")

    if numero:
        if codice_breve:
            parts.append(f"{numero} {codice_breve}")
        elif nome_comune:
            parts.append(f"{numero} — {nome_comune}")
        elif titolo_atto:
            parts.append(f"{numero} — {titolo_atto}")
        else:
            parts.append(numero)

    # Contesto normativo
    if nome_comune:
        parts.append(nome_comune)
    elif titolo_atto:
        parts.append(titolo_atto)

    # Testo completo della norma
    testo = d.get("testo_puro", "") or ""
    if testo:
        parts.append(testo)

    return "\n\n".join(p for p in parts if p.strip())

# ── Mapping documento ──────────────────────────────────────────────────────────

def make_doc(d: dict) -> dict:
    """
    Mappa un record CSV/JSONL nello schema OpenSearch.
    FIX: nomi campo allineati al CSV prodotto da 03_export_neo4j.R
         (testo_puro, stato_norma, stato_vigenza, num_versione).
    """
    # Date — gestisce sia i campi INT che DATE del CSV
    vd = to_int_date(d.get("valido_dal:INT") or d.get("valido_dal"))
    va = to_int_date(d.get("valido_al:INT")  or d.get("valido_al")) or 99991231

    vd_s = str(vd) if vd else None
    va_s = str(va)

    # FIX: is_current basato su date reali, non su stato_vigenza
    # (stato_vigenza può essere errato per bug nella pipeline R)
    is_current = (vd is not None and vd <= TODAY_INT <= va)

    # Numero articolo puro (solo cifre) per filtri esatti
    numero = d.get("numero", "") or ""
    import re
    numero_puro = re.search(r"\d+", numero)
    numero_puro = numero_puro.group(0) if numero_puro else None

    # Testo per embedding
    testo_embedding = build_embedding_text(d)
    if not testo_embedding.strip():
        raise ValueError("Testo embedding vuoto — documento scartato")

    emb = calcola_embedding(testo_embedding)

    # ID documento: usa versione_id come chiave primaria
    versione_id = (
        d.get("versione_id:ID(Versione)") or
        d.get("versione_id") or
        d.get("id")
    )
    if not versione_id:
        raise ValueError("versione_id mancante — documento scartato")

    # partizione_id derivato da versione_id se non esplicitamente presente
    partizione_id = d.get("partizione_id") or re.sub(r"_V\d+$", "", versione_id)

    return {
        # Identificativi
        "id":             versione_id,
        "versione_id":    versione_id,
        "art_id":         partizione_id,
        "partizione_id":  partizione_id,
        "num_versione":   int(d.get("num_versione:INT") or d.get("num_versione") or 0),

        # Metadati atto
        "numero":           numero,
        "numero_puro":      numero_puro,
        "titolo_atto":      d.get("titolo_atto", "") or "",
        "nome_comune_atto": d.get("nome_comune_atto", "") or "",
        "codice_breve_atto":d.get("codice_breve_atto", "") or "",
        "atto_appartenenza":d.get("atto_appartenenza", "") or "",

        # Classificazione
        "stato_norma":   d.get("stato_norma",  "") or "",
        "stato_vigenza": d.get("stato_vigenza", d.get("stato_temporale", "")) or "",
        "tipo_modifica": d.get("tipo_modifica", "") or "",

        # Contenuto testuale
        "title":     f"{numero} — {d.get('titolo_atto', '') or ''}".strip(" —"),
        "testo_puro": d.get("testo_puro", "") or "",
        "aliases":   [],
        "keywords":  [],

        # Temporalità
        "valido_dal_dt":  vd_s,
        "valido_al_dt":   va_s,
        "valido_dal_raw": vd,
        "valido_al_raw":  va,
        "year_from": int(vd_s[:4]) if vd_s else None,
        "year_to":   int(va_s[:4]),

        # Flag vigenza
        "is_current": is_current,

        # Embedding
        "embedding": emb
    }

# ── Bulk ingestion ─────────────────────────────────────────────────────────────

def bulk_index(docs: List[dict]) -> int:
    """
    Carica un batch di documenti con gestione granulare degli errori.
    FIX: non lancia più eccezione al primo errore — logga i fallimenti
    e restituisce il numero di documenti effettivamente indicizzati.
    """
    lines = []
    for doc in docs:
        lines.append(json.dumps(
            {"index": {"_index": INDEX, "_id": doc["id"]}},
            ensure_ascii=False
        ))
        lines.append(json.dumps(doc, ensure_ascii=False))

    body = "\n".join(lines) + "\n"

    r = requests.post(
        f"{OS_URL}/_bulk",
        data=body.encode("utf-8"),
        headers={"Content-Type": "application/x-ndjson"},
        auth=AUTH,
        verify=False,
        timeout=300
    )
    r.raise_for_status()
    res = r.json()

    if res.get("errors"):
        errori = [
            it["index"] for it in res["items"]
            if it.get("index", {}).get("error")
        ]
        print(f"    [Bulk] {len(errori)} errori su {len(docs)} documenti:")
        for e in errori[:3]:
            print(f"      ID: {e.get('_id')} — {e.get('error', {}).get('reason', 'n/a')}")
        return len(docs) - len(errori)

    return len(docs)

# ── Lettura input ──────────────────────────────────────────────────────────────

def leggi_records(path: str):
    """
    Legge record da CSV o JSONL in modo trasparente.
    Supporta sia il CSV di 03_export_neo4j.R che JSONL da Neo4j export.
    """
    ext = os.path.splitext(path)[1].lower()

    if ext == ".csv":
        with open(path, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                yield dict(row)
    else:
        # JSONL: una riga = un documento JSON
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    raw = json.loads(line)
                    # Gestisce sia {"v": {...}} (export Neo4j) che {...} flat
                    if "v" in raw and isinstance(raw["v"], dict):
                        yield raw["v"]
                    else:
                        yield raw

# ── Pipeline principale ────────────────────────────────────────────────────────

def verifica_indice():
    """Verifica che l'indice OpenSearch esista prima di iniziare."""
    r = requests.head(f"{OS_URL}/{INDEX}", auth=AUTH, verify=False, timeout=10)
    if r.status_code == 404:
        print(f"ERRORE: indice '{INDEX}' non trovato.")
        print("Esegui prima 04_create_index.py")
        sys.exit(1)
    elif r.status_code != 200:
        print(f"ERRORE connessione OpenSearch: HTTP {r.status_code}")
        sys.exit(1)
    print(f"  Indice '{INDEX}' verificato.")

def run(path: str):
    print(f"\nAvvio ingestion da: {path}")
    print(f"  Batch size : {BATCH_SIZE}")
    print(f"  Modello    : {EMBED_MODEL}")
    print(f"  Data oggi  : {TODAY_INT}\n")

    verifica_indice()

    buf        = []
    total_ok   = 0
    total_err  = 0
    t_start    = time.time()

    for i, raw in enumerate(leggi_records(path), 1):
        try:
            doc = make_doc(raw)
            buf.append(doc)
        except Exception as e:
            print(f"  [Riga {i}] Scartata — {e}")
            total_err += 1
            continue

        if len(buf) >= BATCH_SIZE:
            indicizzati = bulk_index(buf)
            total_ok   += indicizzati
            total_err  += len(buf) - indicizzati
            elapsed     = time.time() - t_start
            vel         = total_ok / elapsed if elapsed > 0 else 0
            print(f"  [{i:6d} righe] {total_ok} indicizzati | {total_err} errori | {vel:.1f} doc/s")
            buf = []

    if buf:
        indicizzati = bulk_index(buf)
        total_ok   += indicizzati
        total_err  += len(buf) - indicizzati

    elapsed = time.time() - t_start
    print(f"""
=== Ingestion completata ===
  Documenti indicizzati : {total_ok}
  Documenti scartati    : {total_err}
  Tempo totale          : {elapsed:.1f}s
  Velocità media        : {total_ok / elapsed:.1f} doc/s
""")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso: python 05_ingest_versions.py <file.csv|file.jsonl>")
        sys.exit(1)
    run(sys.argv[1])
