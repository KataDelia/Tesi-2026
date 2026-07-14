"""
ablation_kg.py — Studio di ablazione: Knowledge Graph ON vs OFF
================================================================
Misura il contributo di Neo4j (arricchimento tramite grafo) separandolo
dall'effetto delle strategie di retrieval (top_k, HyDE, keyword expansion).

Disegno sperimentale:
    4 configurazioni × 2 modalità (KG-ON / KG-OFF) × 5 categorie × N domande

Configurazioni:
    C1  TOP_K=5,  HyDE=OFF, KW_EXP=OFF   (baseline originale)
    C2  TOP_K=10, HyDE=OFF, KW_EXP=OFF
    C3  TOP_K=10, HyDE=ON,  KW_EXP=OFF
    C4  TOP_K=10, HyDE=OFF, KW_EXP=ON

Metriche (identiche a §5.7):
    Precision@k, Recall@k, MRR, nDCG@k    per k = 3, 5, 10

Output:
    ablation_risultati.json   — dati grezzi per domanda
    ablation_metriche.csv     — tabella aggregata per configurazione × categoria
    ablation_metriche.txt     — tabella leggibile a schermo

Utilizzo:
    # Assicurati che le variabili d'ambiente siano impostate:
    # OS_PASS, COHERE_API_KEY, NEO4J_PASS (quest'ultima solo per KG-ON)

    python ablation_kg.py

    # Per eseguire solo una configurazione specifica (utile per test rapidi):
    python ablation_kg.py --config C2

    # Per eseguire solo alcune categorie:
    python ablation_kg.py --categorie 3 5

    # Per saltare le domande già processate (resume dopo interruzione):
    python ablation_kg.py --resume
"""

import os, sys, json, math, time, argparse, csv
from copy import deepcopy
from pathlib import Path

# Importa il chatbot (deve essere nella stessa directory o nel PYTHONPATH)
# Il file si aspetta chatbot.py nella stessa directory.
sys.path.insert(0, str(Path(__file__).parent))

# Le variabili d'ambiente che controllano le configurazioni vengono impostate
# PRIMA dell'import, perché il modulo le legge a livello di modulo.
# Lo script le sovrascrive programmaticamente per ogni run (vedi imposta_config).

import importlib

# Configurazioni sperimentali
CONFIGS = {
    "C1": {"TOP_K": 5,  "USE_HYDE": "0", "USE_KW_EXP": "0"},
    "C2": {"TOP_K": 10, "USE_HYDE": "0", "USE_KW_EXP": "0"},
    "C3": {"TOP_K": 10, "USE_HYDE": "1", "USE_KW_EXP": "0"},
    "C4": {"TOP_K": 10, "USE_HYDE": "0", "USE_KW_EXP": "1"},
}

# Percorsi dei test set
BASE_DIR   = Path(__file__).parent
TEST_SETS  = {
    1: BASE_DIR / "test_set_categoria1.json",
    2: BASE_DIR / "test_set_categoria2.json",
    3: BASE_DIR / "test_set_categoria3.json",
    4: BASE_DIR / "test_set_categoria4.json",
    5: BASE_DIR / "test_set_categoria5.json",
}

OUTPUT_JSON = BASE_DIR / "ablation_risultati.json"
OUTPUT_CSV  = BASE_DIR / "ablation_metriche.csv"
OUTPUT_TXT  = BASE_DIR / "ablation_metriche.txt"

# Valori di k per le metriche
KS = [3, 5, 10]

# Logica di matching (riproduce fedelmente §5.7 della tesi)

def _overlap_temporale(c: dict, valido_dal_raw, valido_al_raw) -> bool:
    """
    Verifica che l'intervallo di vigenza del contesto si sovrapponga
    alla finestra attesa. Usato per la categoria 3 (vincolo temporale).
    """
    if valido_dal_raw is None and valido_al_raw is None:
        return True  # domanda "vigente oggi" — qualsiasi IS_CURRENT va bene
    cdal = c.get("valido_dal_raw")
    cal  = c.get("valido_al_raw")
    if cdal is None or cal is None:
        return False
    # sovrapposizione: [cdal, cal] ∩ [valido_dal_raw, valido_al_raw] ≠ ∅
    return cdal <= valido_al_raw and cal >= valido_dal_raw

def grado_match(contesto: dict, rilevante: dict, categoria: int) -> int:
    """
    Ritorna il grado di match (3 = esatto, 1 = parziale, 0 = no match)
    secondo la logica di §5.7.

    Categoria 1: match esatto su numero_puro + codice_breve_atto
    Categoria 2: grado 3 se articolo esatto, grado 1 se solo codice corretto
    Categoria 3: come categoria 1 + vincolo temporale su valido_dal/al_raw
    Categoria 4: come categoria 2
    Categoria 5: match su numero_puro + codice_breve_atto (serve min_versioni
                 versioni distinte tra i contesti — verificato a livello di lista)
    """
    c_num  = str(contesto.get("numero_puro", "") or "")
    c_cod  = str(contesto.get("codice_breve_atto", "") or "")
    r_num  = str(rilevante.get("numero_puro", "") or "")
    r_cod  = str(rilevante.get("codice_breve_atto", "") or "")
    r_grado = rilevante.get("grado", 3)

    codice_ok = (c_cod == r_cod)
    numero_ok = (r_num == "" or c_num == r_num)

    if categoria == 3:
        if not (codice_ok and numero_ok):
            return 0
        vdal = rilevante.get("valido_dal_raw")
        val  = rilevante.get("valido_al_raw")
        # Domande "vigenti oggi": accetta IS_CURRENT
        if vdal is None and val is None:
            if contesto.get("is_current") or contesto.get("stato_vigenza") == "VIGENTE":
                return r_grado
            return 0
        if _overlap_temporale(contesto, vdal, val):
            return r_grado
        return 0

    if codice_ok and numero_ok:
        return r_grado          # grado 3 (o il grado specificato)
    if codice_ok and r_num == "":
        return r_grado          # rilevante senza numero_puro: solo codice
    if codice_ok and r_grado == 1:
        return 1                # match parziale (solo codice)
    return 0

def match_categoria5(contesti: list, rilevante: dict) -> bool:
    """
    Per categoria 5: il rilevante richiede min_versioni versioni distinte
    dello stesso articolo tra i contesti restituiti.
    """
    min_v   = rilevante.get("min_versioni", 2)
    r_num   = str(rilevante.get("numero_puro", "") or "")
    r_cod   = str(rilevante.get("codice_breve_atto", "") or "")

    # Conta versioni distinte (per valido_dal_raw, o per versione_id)
    versioni = set()
    for c in contesti:
        c_num = str(c.get("numero_puro", "") or "")
        c_cod = str(c.get("codice_breve_atto", "") or "")
        match_num = (r_num == "" or c_num == r_num)
        if c_cod == r_cod and match_num:
            vid = c.get("versione_id") or c.get("valido_dal_raw")
            if vid is not None:
                versioni.add(vid)

    return len(versioni) >= min_v

def gradi_rilevanti(contesti: list, rilevanti: list, categoria: int) -> list:
    """
    Per ogni posizione nella lista contesti, calcola il grado massimo di
    rilevanza rispetto a tutti i criteri rilevanti della domanda.
    Ritorna una lista di interi (un grado per posizione).
    """
    if categoria == 5:
        # Per cat5 usiamo match_categoria5 su tutta la lista
        # Il "grado" per la metrica è 3 se la condizione è soddisfatta
        # (vogliamo sapere se tra i top-k ci sono ≥ min_versioni versioni)
        # Restituiamo una lista indicatore: 1 alla posizione in cui viene
        # soddisfatta la condizione min_versioni (per il calcolo di P/R/MRR)
        gradi = [0] * len(contesti)
        for ril in rilevanti:
            # Verifica se nei primi k contesti ci sono abbastanza versioni
            min_v = ril.get("min_versioni", 2)
            r_num = str(ril.get("numero_puro", "") or "")
            r_cod = str(ril.get("codice_breve_atto", "") or "")
            versioni_viste = set()
            for i, c in enumerate(contesti):
                c_num = str(c.get("numero_puro", "") or "")
                c_cod = str(c.get("codice_breve_atto", "") or "")
                if c_cod == r_cod and (r_num == "" or c_num == r_num):
                    vid = c.get("versione_id") or c.get("valido_dal_raw")
                    if vid is not None:
                        versioni_viste.add(vid)
                # Segna la posizione in cui la soglia viene raggiunta
                if len(versioni_viste) >= min_v and gradi[i] == 0:
                    gradi[i] = ril.get("grado", 3)
        return gradi

    gradi = []
    for c in contesti:
        g = max((grado_match(c, r, categoria) for r in rilevanti), default=0)
        gradi.append(g)
    return gradi

# Calcolo metriche IR (§5.7)

def precision_at_k(gradi: list, k: int, soglia: int = 1) -> float:
    """Fraction di risultati rilevanti tra i primi k."""
    top = gradi[:k]
    if not top:
        return 0.0
    return sum(1 for g in top if g >= soglia) / k

def recall_at_k(gradi: list, k: int, n_rilevanti: int, soglia: int = 1) -> float:
    """Fraction di rilevanti trovati tra i primi k."""
    if n_rilevanti == 0:
        return 0.0
    trovati = sum(1 for g in gradi[:k] if g >= soglia)
    return trovati / n_rilevanti

def mrr(gradi: list, soglia: int = 1) -> float:
    """Mean Reciprocal Rank: 1/posizione del primo rilevante."""
    for i, g in enumerate(gradi, start=1):
        if g >= soglia:
            return 1.0 / i
    return 0.0

def ndcg_at_k(gradi: list, k: int) -> float:
    """
    nDCG@k con gain = grado (3 per esatto, 1 per parziale).
    DCG ideale calcolato ordinando i gradi decrescenti.
    """
    def dcg(gs):
        return sum((2**g - 1) / math.log2(i + 2) for i, g in enumerate(gs))

    top    = gradi[:k]
    ideal  = sorted(gradi, reverse=True)[:k]
    idcg   = dcg(ideal)
    if idcg == 0:
        return 0.0
    return dcg(top) / idcg

def calcola_metriche(gradi: list, n_rilevanti: int) -> dict:
    """Calcola tutte le metriche per una singola domanda."""
    m = {}
    for k in KS:
        m[f"P@{k}"]    = precision_at_k(gradi, k)
        m[f"R@{k}"]    = recall_at_k(gradi, k, n_rilevanti)
        m[f"nDCG@{k}"] = ndcg_at_k(gradi, k)
    m["MRR"] = mrr(gradi)
    return m

# Gestione dinamica delle configurazioni

_chatbot_module = None

def carica_chatbot(config: dict):
    """
    Imposta le variabili d'ambiente e (ri)carica il modulo chatbot.
    Necessario perché TOP_K, USE_HYDE, USE_KW_EXP vengono letti a import-time.
    """
    global _chatbot_module
    os.environ["TOP_K"]      = str(config["TOP_K"])
    os.environ["USE_HYDE"]   = config["USE_HYDE"]
    os.environ["USE_KW_EXP"] = config["USE_KW_EXP"]

    if _chatbot_module is None:
        import chatbot as _mod
        _chatbot_module = _mod
    else:
        # Aggiorna i parametri globali del modulo già importato
        _chatbot_module.TOP_K       = config["TOP_K"]
        _chatbot_module.USE_HYDE    = config["USE_HYDE"] == "1"
        _chatbot_module.USE_KW_EXP  = config["USE_KW_EXP"] == "1"

    return _chatbot_module

# Loop principale di valutazione

def valuta_domanda(mod, domanda: str, rilevanti: list,
                   categoria: int, usa_grafo: bool) -> dict:
    """
    Esegue una singola domanda e calcola le metriche.
    Ritorna un dict con contesti recuperati + metriche.
    """
    start, end = mod.estrai_finestra(domanda)
    filtri     = mod.estrai_filtri(domanda)

    t0 = time.time()
    try:
        contesti, n_kw, n_knn = mod.esegui_ricerca(
            domanda, start, end, filtri, usa_grafo=usa_grafo
        )
    except Exception as e:
        print(f"    ERRORE esegui_ricerca: {e}")
        contesti, n_kw, n_knn = [], 0, 0
    elapsed = round(time.time() - t0, 2)

    gradi = gradi_rilevanti(contesti, rilevanti, categoria)

    # n_rilevanti: numero di criteri di grado 3 (target principali)
    n_ril = sum(1 for r in rilevanti if r.get("grado", 3) == 3)
    n_ril = max(n_ril, 1)  # evita divisione per zero

    metriche = calcola_metriche(gradi, n_ril)

    return {
        "domanda":    domanda,
        "categoria":  categoria,
        "usa_grafo":  usa_grafo,
        "n_contesti": len(contesti),
        "n_kw":       n_kw,
        "n_knn":      n_knn,
        "elapsed_s":  elapsed,
        "gradi":      gradi[:10],   # salva i primi 10 per debug
        "metriche":   metriche,
        # Contesti restituiti (campi chiave per audit)
        "contesti": [
            {
                "numero_puro":       c.get("numero_puro"),
                "codice_breve_atto": c.get("codice_breve_atto"),
                "valido_dal_raw":    c.get("valido_dal_raw"),
                "valido_al_raw":     c.get("valido_al_raw"),
                "is_current":        c.get("is_current"),
            }
            for c in contesti[:10]
        ],
    }

def media_metriche(risultati: list) -> dict:
    """Calcola la media di ogni metrica su una lista di risultati."""
    if not risultati:
        return {}
    chiavi = risultati[0]["metriche"].keys()
    return {
        k: round(sum(r["metriche"][k] for r in risultati) / len(risultati), 4)
        for k in chiavi
    }

def esegui_ablation(configs_da_eseguire: list, categorie_da_eseguire: list,
                    resume: bool = False) -> dict:
    """
    Loop principale: configs × (KG-ON, KG-OFF) × categorie × domande.
    Ritorna il dizionario completo dei risultati.
    """
    # Carica risultati precedenti se --resume
    if resume and OUTPUT_JSON.exists():
        with open(OUTPUT_JSON, encoding="utf-8") as f:
            tutti = json.load(f)
        print(f"[Resume] Caricati {sum(len(v) for v in tutti.values())} risultati precedenti.")
    else:
        tutti = {}  # struttura: tutti[config_key][domanda_idx] = {on: ..., off: ...}

    for cfg_name in configs_da_eseguire:
        cfg = CONFIGS[cfg_name]
        print(f"\n{'='*60}")
        print(f"CONFIGURAZIONE {cfg_name}: TOP_K={cfg['TOP_K']} | "
              f"HyDE={'SI' if cfg['USE_HYDE']=='1' else 'NO'} | "
              f"KW_EXP={'SI' if cfg['USE_KW_EXP']=='1' else 'NO'}")
        print(f"{'='*60}")

        mod = carica_chatbot(cfg)

        for cat in categorie_da_eseguire:
            ts_path = TEST_SETS[cat]
            if not ts_path.exists():
                print(f"  [!] Test set categoria {cat} non trovato: {ts_path}")
                continue

            with open(ts_path, encoding="utf-8") as f:
                domande = json.load(f)

            print(f"\n  Categoria {cat} — {len(domande)} domande")

            for i, item in enumerate(domande):
                domanda   = item["domanda"]
                rilevanti = item["rilevanti"]
                chiave    = f"{cfg_name}_cat{cat}_q{i}"

                # Resume: salta se già elaborata completamente
                if resume and chiave in tutti:
                    entry = tutti[chiave]
                    if "kg_on" in entry and "kg_off" in entry:
                        print(f"    [{i+1:3d}/{len(domande)}] già elaborata — skip")
                        continue

                print(f"    [{i+1:3d}/{len(domande)}] {domanda[:70]}...")

                entry = tutti.get(chiave, {"meta": {
                    "config": cfg_name, "categoria": cat,
                    "domanda": domanda, "rilevanti": rilevanti
                }})

                # KG-OFF
                if "kg_off" not in entry or not resume:
                    print(f"           KG-OFF...", end=" ", flush=True)
                    entry["kg_off"] = valuta_domanda(
                        mod, domanda, rilevanti, cat, usa_grafo=False
                    )
                    m = entry["kg_off"]["metriche"]
                    print(f"MRR={m['MRR']:.3f} | R@5={m['R@5']:.3f}")

                # KG-ON
                if "kg_on" not in entry or not resume:
                    print(f"           KG-ON ...", end=" ", flush=True)
                    entry["kg_on"] = valuta_domanda(
                        mod, domanda, rilevanti, cat, usa_grafo=True
                    )
                    m = entry["kg_on"]["metriche"]
                    print(f"MRR={m['MRR']:.3f} | R@5={m['R@5']:.3f}")

                tutti[chiave] = entry

                # Salvataggio incrementale (ogni domanda) — protegge da crash
                with open(OUTPUT_JSON, "w", encoding="utf-8") as f:
                    json.dump(tutti, f, ensure_ascii=False, indent=2)

    return tutti

# Aggregazione e report

METRICHE_PRINCIPALI = ["MRR", "P@5", "R@5", "nDCG@5", "R@10", "nDCG@10"]

def aggrega_risultati(tutti: dict) -> dict:
    """
    Aggrega i risultati per configurazione × categoria × modalità.
    Ritorna struttura: agg[config][cat]["kg_on"|"kg_off"] = dict metriche medie
    """
    agg = {}
    for chiave, entry in tutti.items():
        cfg = entry["meta"]["config"]
        cat = entry["meta"]["categoria"]
        agg.setdefault(cfg, {}).setdefault(cat, {"kg_on": [], "kg_off": []})

        if "kg_on" in entry:
            agg[cfg][cat]["kg_on"].append(entry["kg_on"])
        if "kg_off" in entry:
            agg[cfg][cat]["kg_off"].append(entry["kg_off"])

    # Calcola medie
    for cfg in agg:
        for cat in agg[cfg]:
            for modalita in ("kg_on", "kg_off"):
                ris = agg[cfg][cat][modalita]
                agg[cfg][cat][modalita] = media_metriche(ris)

    return agg

def _delta(on: dict, off: dict, k: str) -> str:
    """Formatta il delta ON-OFF con segno e colore ASCII."""
    if not on or not off or k not in on or k not in off:
        return "   n/d"
    d = on[k] - off[k]
    sign = "+" if d >= 0 else ""
    return f"{sign}{d:+.4f}"

def stampa_report(agg: dict) -> str:
    """Genera la tabella testuale del report e la ritorna come stringa."""
    linee = []
    sep   = "─" * 100

    linee.append("\nABLATION STUDY — Contributo del Knowledge Graph (Neo4j)")
    linee.append("Δ = KG-ON minus KG-OFF  |  positivo = il grafo migliora")
    linee.append(sep)

    for cfg in sorted(agg):
        c = CONFIGS[cfg]
        linee.append(f"\n{'▌ ' + cfg + ' ':{'─'}<50} "
                     f"TOP_K={c['TOP_K']} | HyDE={'SI' if c['USE_HYDE']=='1' else 'NO'} | "
                     f"KW_EXP={'SI' if c['USE_KW_EXP']=='1' else 'NO'}")

        header = (f"  {'Cat':>4}  {'Mod':>7}  "
                  + "  ".join(f"{m:>10}" for m in METRICHE_PRINCIPALI))
        linee.append(header)
        linee.append("  " + "─" * (len(header) - 2))

        for cat in sorted(agg[cfg]):
            on  = agg[cfg][cat].get("kg_on",  {})
            off = agg[cfg][cat].get("kg_off", {})

            for mod_label, vals in [("KG-OFF", off), ("KG-ON", on)]:
                row = f"  {cat:>4}  {mod_label:>7}  "
                row += "  ".join(
                    f"{vals.get(m, float('nan')):>10.4f}"
                    for m in METRICHE_PRINCIPALI
                )
                linee.append(row)

            # Riga delta
            row_d = f"  {'':>4}  {'Δ':>7}  "
            row_d += "  ".join(
                f"{_delta(on, off, m):>10}" for m in METRICHE_PRINCIPALI
            )
            linee.append(row_d)
            linee.append("")

    # Riepilogo aggregato su tutte le categorie per configurazione
    linee.append(sep)
    linee.append("\nRIEPILOGO GLOBALE (media su tutte le categorie)")
    linee.append(sep)

    header = (f"  {'Cfg':>4}  {'Mod':>7}  "
              + "  ".join(f"{m:>10}" for m in METRICHE_PRINCIPALI))
    linee.append(header)
    linee.append("  " + "─" * (len(header) - 2))

    for cfg in sorted(agg):
        for mod_label, mod_key in [("KG-OFF", "kg_off"), ("KG-ON", "kg_on")]:
            # Media su tutte le categorie
            valori = {m: [] for m in METRICHE_PRINCIPALI}
            for cat in agg[cfg]:
                d = agg[cfg][cat].get(mod_key, {})
                for m in METRICHE_PRINCIPALI:
                    if m in d:
                        valori[m].append(d[m])
            medie = {m: (sum(v)/len(v) if v else float("nan"))
                     for m, v in valori.items()}
            row = f"  {cfg:>4}  {mod_label:>7}  "
            row += "  ".join(f"{medie[m]:>10.4f}" for m in METRICHE_PRINCIPALI)
            linee.append(row)

        # Delta globale
        on_g  = {m: sum(agg[cfg][c].get("kg_on",{}).get(m,0) for c in agg[cfg])
                     / len(agg[cfg]) for m in METRICHE_PRINCIPALI}
        off_g = {m: sum(agg[cfg][c].get("kg_off",{}).get(m,0) for c in agg[cfg])
                     / len(agg[cfg]) for m in METRICHE_PRINCIPALI}
        row_d = f"  {'':>4}  {'Δ':>7}  "
        row_d += "  ".join(f"{_delta(on_g, off_g, m):>10}" for m in METRICHE_PRINCIPALI)
        linee.append(row_d)
        linee.append("")

    return "\n".join(linee)

def scrivi_csv(agg: dict):
    """Scrive la tabella aggregata in formato CSV."""
    righe = []
    for cfg in sorted(agg):
        for cat in sorted(agg[cfg]):
            for mod_key, mod_label in [("kg_off", "KG-OFF"), ("kg_on", "KG-ON")]:
                vals = agg[cfg][cat].get(mod_key, {})
                riga = {
                    "configurazione": cfg,
                    "categoria": cat,
                    "modalita": mod_label,
                    **{m: round(vals.get(m, float("nan")), 4)
                       for m in METRICHE_PRINCIPALI}
                }
                righe.append(riga)

            # Riga delta
            on  = agg[cfg][cat].get("kg_on",  {})
            off = agg[cfg][cat].get("kg_off", {})
            riga_d = {
                "configurazione": cfg,
                "categoria": cat,
                "modalita": "Δ (ON-OFF)",
                **{m: round(on.get(m, 0) - off.get(m, 0), 4)
                   for m in METRICHE_PRINCIPALI}
            }
            righe.append(riga_d)

    with open(OUTPUT_CSV, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["configurazione","categoria","modalita"]
                                         + METRICHE_PRINCIPALI)
        w.writeheader()
        w.writerows(righe)

    print(f"\n[Output] CSV salvato: {OUTPUT_CSV}")

# Entry point

def main():
    parser = argparse.ArgumentParser(
        description="Ablation study: KG-ON vs KG-OFF su 4 configurazioni × 5 categorie"
    )
    parser.add_argument(
        "--config", nargs="+", choices=list(CONFIGS.keys()),
        default=list(CONFIGS.keys()),
        help="Configurazioni da eseguire (default: tutte)"
    )
    parser.add_argument(
        "--categorie", nargs="+", type=int, choices=[1,2,3,4,5],
        default=[1,2,3,4,5],
        help="Categorie del test set da eseguire (default: tutte)"
    )
    parser.add_argument(
        "--resume", action="store_true",
        help="Riprende da dove si era interrotto (legge ablation_risultati.json)"
    )
    parser.add_argument(
        "--solo-report", action="store_true",
        help="Salta l'esecuzione e genera solo il report dai risultati esistenti"
    )
    args = parser.parse_args()

    print("=" * 60)
    print("ABLATION STUDY — Knowledge Graph ON vs OFF")
    print(f"Configurazioni : {args.config}")
    print(f"Categorie      : {args.categorie}")
    print(f"Resume         : {args.resume}")
    print("=" * 60)

    if args.solo_report:
        if not OUTPUT_JSON.exists():
            print(f"[Errore] Nessun risultato trovato in {OUTPUT_JSON}")
            sys.exit(1)
        with open(OUTPUT_JSON, encoding="utf-8") as f:
            tutti = json.load(f)
    else:
        tutti = esegui_ablation(
            configs_da_eseguire=args.config,
            categorie_da_eseguire=args.categorie,
            resume=args.resume,
        )

    print("\n\nAggregazione risultati...")
    agg = aggrega_risultati(tutti)

    report = stampa_report(agg)
    print(report)

    with open(OUTPUT_TXT, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"\n[Output] Report testuale salvato: {OUTPUT_TXT}")

    scrivi_csv(agg)
    print(f"[Output] Risultati grezzi salvati: {OUTPUT_JSON}")
    print("\nFatto.")

if __name__ == "__main__":
    main()
