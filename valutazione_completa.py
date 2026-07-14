#!/usr/bin/env python3
"""
Valutazione automatica completa: 5 categorie × 4 configurazioni.

Configurazioni:
  C1 — baseline       : TOP_K=5,  no HyDE, no KW-exp
  C2 — top_k=10       : TOP_K=10, no HyDE, no KW-exp
  C3 — top_k10 + HyDE : TOP_K=10, HyDE=1,  no KW-exp
  C4 — top_k10 + KW   : TOP_K=10, no HyDE, KW-exp=1

Categorie:
  1 — codice e numero espliciti   (89 domande)
  2 — semantica senza numero      (30 domande)
  3 — vincolo temporale           (31 domande) — usa verifica temporale
  4 — nessun codice né numero     (30 domande)
  5 — evolutive                   (30 domande)

Uso:
  python3 valutazione_completa.py

Output: risultati/ cartella con 20 JSON + report_riepilogo.json
"""

import os, sys, json, importlib.util, math
from pathlib import Path
from statistics import mean

# Configurazione percorsi
BASE_DIR    = Path(__file__).parent
CHATBOT_PY  = BASE_DIR / "chatbot.py"
OUTPUT_DIR  = BASE_DIR / "risultati_completi"
OUTPUT_DIR.mkdir(exist_ok=True)

TEST_SETS = {
    "cat1": BASE_DIR / "test_set_100_verificato.json",
    "cat2": BASE_DIR / "test_set_categoria2.json",
    "cat3": BASE_DIR / "test_set_categoria3.json",
    "cat4": BASE_DIR / "test_set_categoria4.json",
    "cat5": BASE_DIR / "test_set_categoria5.json",
}

CONFIGURAZIONI = {
    "C1_baseline":   {"TOP_K": "5",  "USE_HYDE": "0", "USE_KW_EXP": "0", "SEARCH_SIZE": "8"},
    "C2_topk10":     {"TOP_K": "10", "USE_HYDE": "0", "USE_KW_EXP": "0", "SEARCH_SIZE": "8"},
    "C3_hyde":       {"TOP_K": "10", "USE_HYDE": "1", "USE_KW_EXP": "0", "SEARCH_SIZE": "8"},
    "C4_kwexp":      {"TOP_K": "10", "USE_HYDE": "0", "USE_KW_EXP": "1", "SEARCH_SIZE": "8"},
}

K_VALUES = [3, 5, 10]

# Caricamento chatbot
def carica_chatbot(path: Path, env: dict):
    """Carica chatbot.py con le variabili d'ambiente della configurazione."""
    for k, v in env.items():
        os.environ[k] = v
    spec   = importlib.util.spec_from_file_location("chatbot", path)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo

# Funzioni di matching
def _cade_nella_finestra(contesto: dict, atteso: dict) -> bool:
    dal_att = atteso.get("valido_dal_raw")
    al_att  = atteso.get("valido_al_raw")
    if not dal_att or not al_att:
        return True
    dal_ctx = contesto.get("valido_dal_raw")
    al_ctx  = contesto.get("valido_al_raw")
    if not dal_ctx:
        return False
    if not al_ctx or al_ctx >= 99991231:
        al_ctx = 99991231
    return int(dal_ctx) <= int(al_att) and int(al_ctx) >= int(dal_att)

def matcha(contesto: dict, atteso: dict) -> bool:
    cod_atteso = atteso.get("codice_breve_atto")
    num_atteso = atteso.get("numero_puro")
    if not num_atteso:
        if not cod_atteso:
            return True
        return contesto.get("codice_breve_atto", "") == cod_atteso
    if contesto.get("numero_puro", "") != num_atteso:
        return False
    if cod_atteso and contesto.get("codice_breve_atto", "") != cod_atteso:
        return False
    if atteso.get("valido_dal_raw") and atteso.get("valido_al_raw"):
        return _cade_nella_finestra(contesto, atteso)
    return True

def is_evolutiva(voce: dict) -> bool:
    return any(r.get("min_versioni", 1) > 1 for r in voce.get("rilevanti", []))

def conta_versioni(contesti: list) -> dict:
    cont = {}
    for c in contesti:
        k = (c.get("numero_puro",""), c.get("codice_breve_atto",""))
        if k[0] and k[1]:
            cont[k] = cont.get(k, 0) + 1
    return cont

def gradi_evolutivo(contesti: list, rilevanti: list) -> list:
    conteggio = conta_versioni(contesti)
    gradi = []
    for c in contesti:
        chiave = (c.get("numero_puro",""), c.get("codice_breve_atto",""))
        grado = 0
        for r in rilevanti:
            num_r = r.get("numero_puro")
            cod_r = r.get("codice_breve_atto","")
            min_v = r.get("min_versioni", 1)
            if num_r:
                if chiave == (num_r, cod_r):
                    n = conteggio.get(chiave, 0)
                    grado = max(grado, r.get("grado",3) if n >= min_v else 1)
            else:
                if chiave[1] == cod_r:
                    grado = max(grado, r.get("grado", 1))
        gradi.append(grado)
    return gradi

def gradi_standard(contesti: list, rilevanti: list) -> list:
    gradi = []
    for c in contesti:
        grado = 0
        for r in rilevanti:
            if matcha(c, r):
                grado = max(grado, r.get("grado", 1))
        gradi.append(grado)
    return gradi

# Metriche
def precision_at_k(gradi, k):
    top = gradi[:k]
    return sum(1 for g in top if g > 0) / len(top) if top else 0.0

def recall_at_k(gradi, k, n_tot):
    if n_tot == 0: return 0.0
    return min(sum(1 for g in gradi[:k] if g > 0), n_tot) / n_tot

def mrr(gradi):
    for i, g in enumerate(gradi, 1):
        if g > 0: return 1.0 / i
    return 0.0

def dcg(gradi, k):
    return sum((2**g - 1) / math.log2(i+1) for i, g in enumerate(gradi[:k], 1))

def ndcg(gradi, rilevanti, k):
    d = dcg(gradi, k)
    ideale = sorted((r.get("grado",1) for r in rilevanti), reverse=True)
    idcg = dcg(ideale, k)
    return d / idcg if idcg > 0 else 0.0

# Valutazione di una singola domanda
def valuta(chatbot, voce: dict) -> dict:
    domanda   = voce["domanda"]
    rilevanti = voce["rilevanti"]
    start, end = chatbot.estrai_finestra(domanda)
    filtri     = chatbot.estrai_filtri(domanda)
    contesti, n_kw, n_knn = chatbot.esegui_ricerca(domanda, start, end, filtri)

    gradi = (gradi_evolutivo(contesti, rilevanti)
             if is_evolutiva(voce)
             else gradi_standard(contesti, rilevanti))

    n_tot = len(rilevanti)
    res = {
        "domanda": domanda,
        "n_contesti": len(contesti),
        "mrr": mrr(gradi),
        "contesti": [
            {"posizione": i+1,
             "numero_puro": c.get("numero_puro",""),
             "codice_breve_atto": c.get("codice_breve_atto",""),
             "valido_dal_raw": c.get("valido_dal_raw"),
             "valido_al_raw": c.get("valido_al_raw"),
             "grado_assegnato": gradi[i]}
            for i, c in enumerate(contesti)
        ],
    }
    for k in K_VALUES:
        res[f"precision@{k}"] = precision_at_k(gradi, k)
        res[f"recall@{k}"]    = recall_at_k(gradi, k, n_tot)
        res[f"ndcg@{k}"]      = ndcg(gradi, rilevanti, k)
    return res

# Aggregazione
def aggrega(per_domanda: list) -> dict:
    validi = [r for r in per_domanda if "errore" not in r]
    agg = {"n_domande": len(per_domanda), "n_valide": len(validi),
           "n_errori": len(per_domanda) - len(validi)}
    if validi:
        agg["mrr_medio"] = round(mean(r["mrr"] for r in validi), 4)
        for k in K_VALUES:
            agg[f"precision@{k}_media"] = round(mean(r[f"precision@{k}"] for r in validi), 4)
            agg[f"recall@{k}_medio"]    = round(mean(r[f"recall@{k}"]    for r in validi), 4)
            agg[f"ndcg@{k}_medio"]      = round(mean(r[f"ndcg@{k}"]      for r in validi), 4)
    return agg

# Main
def main():
    if not CHATBOT_PY.exists():
        print(f"ERRORE: {CHATBOT_PY} non trovato.")
        sys.exit(1)

    riepilogo = {}

    for nome_conf, env in CONFIGURAZIONI.items():
        print(f"\n{'='*60}")
        print(f"CONFIGURAZIONE: {nome_conf}")
        print(f"  TOP_K={env['TOP_K']} | HyDE={env['USE_HYDE']} | KW-EXP={env['USE_KW_EXP']}")
        print(f"{'='*60}")

        print("Caricamento chatbot...", end=" ", flush=True)
        try:
            chatbot = carica_chatbot(CHATBOT_PY, env)
            print("OK")
        except Exception as e:
            print(f"ERRORE: {e}")
            continue

        riepilogo[nome_conf] = {}

        for nome_cat, path_test in TEST_SETS.items():
            if not path_test.exists():
                print(f"  {nome_cat}: file non trovato ({path_test}), salto.")
                continue

            with open(path_test, encoding="utf-8") as f:
                test_set = json.load(f)

            print(f"\n  {nome_cat} ({len(test_set)} domande)...")
            per_domanda = []
            for i, voce in enumerate(test_set, 1):
                print(f"    [{i:>2}/{len(test_set)}] {voce['domanda'][:50]}...", flush=True)
                try:
                    per_domanda.append(valuta(chatbot, voce))
                except Exception as e:
                    print(f"    ERRORE: {e}")
                    per_domanda.append({"domanda": voce["domanda"], "errore": str(e)})

            agg = aggrega(per_domanda)
            riepilogo[nome_conf][nome_cat] = agg

            # Salva risultato dettagliato
            output_file = OUTPUT_DIR / f"{nome_conf}_{nome_cat}.json"
            with open(output_file, "w", encoding="utf-8") as f:
                json.dump({"configurazione": nome_conf, "categoria": nome_cat,
                           "env": env, "aggregato": agg, "per_domanda": per_domanda},
                          f, indent=2, ensure_ascii=False)

            print(f"    MRR={agg.get('mrr_medio','?')} | "
                  f"R@5={agg.get('recall@5_medio','?')} | "
                  f"nDCG@5={agg.get('ndcg@5_medio','?')}")

    # Salva riepilogo
    riepilogo_file = OUTPUT_DIR / "report_riepilogo.json"
    with open(riepilogo_file, "w", encoding="utf-8") as f:
        json.dump(riepilogo, f, indent=2, ensure_ascii=False)

    # Stampa tabella finale
    print(f"\n\n{'='*80}")
    print("RIEPILOGO FINALE")
    print(f"{'='*80}")
    header = f"{'Config':<20} {'Cat':<6} {'MRR':>6} {'R@5':>6} {'nDCG@5':>8} {'R@10':>6} {'nDCG@10':>9}"
    print(header)
    print("-" * 80)
    for conf, cats in riepilogo.items():
        for cat, agg in cats.items():
            print(f"{conf:<20} {cat:<6} "
                  f"{agg.get('mrr_medio',0):>6.4f} "
                  f"{agg.get('recall@5_medio',0):>6.4f} "
                  f"{agg.get('ndcg@5_medio',0):>8.4f} "
                  f"{agg.get('recall@10_medio',0):>6.4f} "
                  f"{agg.get('ndcg@10_medio',0):>9.4f}")

    print(f"\nRisultati salvati in: {OUTPUT_DIR}")
    print(f"Riepilogo: {riepilogo_file}")

if __name__ == "__main__":
    main()
