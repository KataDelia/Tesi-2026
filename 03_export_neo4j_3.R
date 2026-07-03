# 03_export_neo4j.R
# Delta detection, costruzione archi temporali, esportazione CSV per Neo4j.
# Richiede che 01_build_metadata.R e 02_master_loop.R siano stati eseguiti.
#
# Ottimizzazioni scalabilità:
#   - Delta detection con data.table (10-20x più veloce di dplyr su dataset grandi)
#   - Join e filtri con data.table keyed (O(log n) invece di O(n))
#   - Scrittura CSV con data.table::fwrite (parallela, molto più veloce di readr)
#   - gc() esplicito dopo ogni step pesante
#
# Output (in output_neo4j/):
#   nodi_Legge.csv        → nodi :Legge e :Legge;Codice
#   nodi_Partizioni.csv   → nodi :Norma;Articolo e :Norma;Allegato
#   nodi_Versione.csv     → snapshot testuali con intervalli temporali
#   archi_VIGENTE.csv     → Partizione -[:VIGENTE]-> Versione
#   archi_EVOLVE_IN.csv   → Versione -[:EVOLVE_IN]-> Versione
#   archi_CITA.csv        → Versione -[:CITA_NORMA]-> Partizione
#   archi_CITA_ATTO.csv   → Versione -[:CITA_ATTO]-> Legge
#   archi_RIMANDA_A.csv   → Partizione -[:RIMANDA_A]-> Partizione
#   archi_APPARTIENE.csv  → Partizione -[:APPARTIENE_A]-> Legge

source(here::here("00_setup.R"))
library(data.table)

# ══════════════════════════════════════════════════════════════════════════════
# 0. GUARDIE
# ══════════════════════════════════════════════════════════════════════════════

verifica_df <- function(nome) {
  if (!exists(nome, envir = .GlobalEnv)) {
    stop(sprintf("'%s' non trovato — esegui prima 01_build_metadata.R e 02_master_loop.R", nome))
  }
  obj <- get(nome, envir = .GlobalEnv)
  if (!(is.data.frame(obj) || is.data.table(obj)) || nrow(obj) == 0) {
    stop(sprintf("'%s' è vuoto o non è un dataframe valido.", nome))
  }
  invisible(obj)
}

verifica_df("df_nodi_Legge")
verifica_df("df_nodi_Partizioni")
verifica_df("df_nodi_Versione")

# Converti tutto in data.table subito per efficienza
dt_versione    <- data.table::as.data.table(df_nodi_Versione)
dt_partizioni  <- data.table::as.data.table(df_nodi_Partizioni)
dt_legge       <- data.table::as.data.table(df_nodi_Legge)

# ══════════════════════════════════════════════════════════════════════════════
# 1. NORMALIZZAZIONE NODI VERSIONE
# ══════════════════════════════════════════════════════════════════════════════

# Rinomina colonne con caratteri speciali verso nomi interni puliti
rinomina_se_esiste <- function(dt, old, new) {
  if (old %in% names(dt)) data.table::setnames(dt, old, new)
  invisible(dt)
}

rinomina_se_esiste(dt_versione, "versione_id:ID(Versione)", "versione_id")
rinomina_se_esiste(dt_versione, "valido_dal:DATE",          "valido_dal")
rinomina_se_esiste(dt_versione, "valido_al:DATE",           "valido_al")
rinomina_se_esiste(dt_versione, "num_versione:INT",         "num_versione")
rinomina_se_esiste(dt_versione, "stato_temporale",          "stato_vigenza")

if (!"stato_vigenza" %in% names(dt_versione)) {
  dt_versione[, stato_vigenza := NA_character_]
}
if (!"partizione_id" %in% names(dt_versione)) {
  dt_versione[, partizione_id := sub("_V[0-9]+$", "", versione_id)]
}

# Converti date
dt_versione[, valido_dal := as.Date(valido_dal)]
dt_versione[, valido_al  := as.Date(valido_al)]

message(sprintf("Nodi Versione caricati: %d record.", nrow(dt_versione)))

# ══════════════════════════════════════════════════════════════════════════════
# 2. DELTA DETECTION con data.table
# Elimina versioni ridondanti (stesso testo e stesso stato consecutivi).
# ══════════════════════════════════════════════════════════════════════════════

message("Avvio delta detection (data.table)...")
t0 <- proc.time()

n_grezzo <- nrow(dt_versione)

# Ordina per partizione e data
data.table::setorder(dt_versione, partizione_id, valido_dal)

# Testo normalizzato per confronto
dt_versione[, testo_norm := stringr::str_squish(testo_puro)]

# Identifica inizio di ogni nuovo blocco (testo o stato cambia rispetto al precedente)
dt_versione[, cambio := (
  testo_norm != data.table::shift(testo_norm, fill = "") |
    stato_norma != data.table::shift(stato_norma, fill = "") |
    data.table::rowid(partizione_id) == 1L
), by = partizione_id]

dt_versione[, gruppo := cumsum(cambio), by = partizione_id]

# Aggrega per blocco: tieni prima occorrenza, estendi valido_al all'ultima
dt_delta <- dt_versione[, .(
  versione_id       = versione_id[1L],
  testo_puro        = testo_puro[1L],
  numero            = numero[1L],
  titolo_atto       = titolo_atto[1L],
  nome_comune_atto  = nome_comune_atto[1L],
  codice_breve_atto = codice_breve_atto[1L],
  atto_appartenenza = atto_appartenenza[1L],
  valido_dal        = min(valido_dal),
  stato_vigenza     = stato_vigenza[.N],
  stato_norma       = stato_norma[1L],
  tipo_modifica     = tipo_modifica[1L],
  num_versione      = num_versione[1L],
  `:LABEL`          = "Versione"
), by = .(partizione_id, gruppo)]

# Ricalcola valido_al come giorno prima dell'inizio del blocco successivo
data.table::setorder(dt_delta, partizione_id, valido_dal)
dt_delta[, valido_al := data.table::shift(valido_dal, type = "lead",
                                          fill = as.Date("9999-12-31")) - 1L,
         by = partizione_id]
dt_delta[, valido_al := pmax(valido_dal, valido_al)]
dt_delta[, gruppo := NULL]

n_rimossi <- n_grezzo - nrow(dt_delta)
elapsed   <- (proc.time() - t0)[["elapsed"]]
message(sprintf(
  "Delta detection completata in %.1fs: %d → %d nodi Versione (-%d ridondanti, %.1f%%).",
  elapsed, n_grezzo, nrow(dt_delta),
  n_rimossi, n_rimossi / n_grezzo * 100
))

# Libera memoria
rm(dt_versione); gc(verbose = FALSE)

# ══════════════════════════════════════════════════════════════════════════════
# 3. COSTRUZIONE ARCHI TEMPORALI
# ══════════════════════════════════════════════════════════════════════════════

to_date_int <- function(d) as.integer(format(as.Date(d), "%Y%m%d"))

# Indice su versione_id per join veloci
data.table::setkey(dt_delta, versione_id)

# Lookup date per join (usato da CITA e CITA_ATTO)
dt_date_lookup <- dt_delta[, .(versione_id, valido_dal, valido_al)]
data.table::setkey(dt_date_lookup, versione_id)

# ── VIGENTE ────────────────────────────────────────────────────────────────
dt_archi_VIGENTE <- dt_delta[stato_vigenza == "VIGENTE", .(
  `:START_ID(Partizione)` = partizione_id,
  `:END_ID(Versione)`     = versione_id,
  `valido_dal:INT`        = to_date_int(valido_dal),
  `valido_al:INT`         = to_date_int(valido_al)
)]

# ── EVOLVE_IN ──────────────────────────────────────────────────────────────
data.table::setorder(dt_delta, partizione_id, valido_dal)
dt_archi_EVOLVE_IN <- dt_delta[, .(
  versione_id,
  target_successivo = data.table::shift(versione_id, type = "lead"),
  azione_causante   = data.table::shift(tipo_modifica, type = "lead"),
  valido_dal, valido_al
), by = partizione_id][!is.na(target_successivo), .(
  `:START_ID(Versione)` = versione_id,
  `:END_ID(Versione)`   = target_successivo,
  tipo_azione           = azione_causante,
  `valido_dal:INT`      = to_date_int(valido_dal),
  `valido_al:INT`       = to_date_int(valido_al)
)]

# ── CITA_NORMA (Versione → Partizione) ────────────────────────────────────
if (exists("df_archi_CITA") && nrow(df_archi_CITA) > 0) {
  dt_cita <- data.table::as.data.table(df_archi_CITA)
  data.table::setnames(dt_cita,
                       c(":START_ID(Versione)", ":END_ID(Partizione)"),
                       c("versione_id", "end_partizione")
  )
  # Filtra solo START esistenti dopo delta detection e aggiungi date
  dt_archi_CITA <- dt_cita[
    versione_id %in% dt_date_lookup$versione_id
  ][dt_date_lookup, on = "versione_id", nomatch = 0L]
  dt_archi_CITA <- dt_archi_CITA[, .(
    `:START_ID(Versione)` = versione_id,
    `:END_ID(Partizione)` = end_partizione,
    tipo_citazione,
    `valido_dal:INT`      = to_date_int(valido_dal),
    `valido_al:INT`       = to_date_int(valido_al)
  )]
  dt_archi_CITA <- unique(dt_archi_CITA)
  rm(dt_cita); gc(verbose = FALSE)
} else {
  dt_archi_CITA <- data.table::data.table(
    `:START_ID(Versione)` = character(), `:END_ID(Partizione)` = character(),
    tipo_citazione = character(), `valido_dal:INT` = integer(), `valido_al:INT` = integer()
  )
}

# ── CITA_ATTO (Versione → Legge) ──────────────────────────────────────────
if (exists("df_archi_CITA_ATTO") && nrow(df_archi_CITA_ATTO) > 0) {
  dt_cita_atto <- data.table::as.data.table(df_archi_CITA_ATTO)
  data.table::setnames(dt_cita_atto,
                       c(":START_ID(Versione)", ":END_ID(Legge)"),
                       c("versione_id", "end_legge")
  )
  urn_leggi_validi <- dt_legge[["urn:ID"]]
  dt_archi_CITA_ATTO <- dt_cita_atto[
    versione_id %in% dt_date_lookup$versione_id &
      end_legge   %in% urn_leggi_validi
  ][dt_date_lookup, on = "versione_id", nomatch = 0L]
  dt_archi_CITA_ATTO <- dt_archi_CITA_ATTO[, .(
    `:START_ID(Versione)` = versione_id,
    `:END_ID(Legge)`      = end_legge,
    tipo_citazione,
    `valido_dal:INT`      = to_date_int(valido_dal),
    `valido_al:INT`       = to_date_int(valido_al)
  )]
  dt_archi_CITA_ATTO <- unique(dt_archi_CITA_ATTO)
  rm(dt_cita_atto); gc(verbose = FALSE)
} else {
  dt_archi_CITA_ATTO <- data.table::data.table(
    `:START_ID(Versione)` = character(), `:END_ID(Legge)` = character(),
    tipo_citazione = character(), `valido_dal:INT` = integer(), `valido_al:INT` = integer()
  )
}

# ── RIMANDA_A ──────────────────────────────────────────────────────────────
partizione_col <- if ("partizione_id:ID(Partizione)" %in% names(dt_partizioni)) {
  "partizione_id:ID(Partizione)"
} else "partizione_id"

urn_partizioni_validi <- dt_partizioni[[partizione_col]]

if (exists("df_archi_RIMANDA_A") && nrow(df_archi_RIMANDA_A) > 0) {
  dt_archi_RIMANDA_A <- data.table::as.data.table(df_archi_RIMANDA_A)
  dt_archi_RIMANDA_A <- dt_archi_RIMANDA_A[
    `:START_ID(Partizione)` %in% urn_partizioni_validi &
      `:END_ID(Partizione)`   %in% urn_partizioni_validi
  ]
  dt_archi_RIMANDA_A <- unique(dt_archi_RIMANDA_A)
} else {
  dt_archi_RIMANDA_A <- data.table::data.table(
    `:START_ID(Partizione)` = character(),
    `:END_ID(Partizione)`   = character()
  )
}

# ── APPARTIENE_A ───────────────────────────────────────────────────────────
if (exists("df_archi_APPARTIENE") && nrow(df_archi_APPARTIENE) > 0) {
  dt_archi_APPARTIENE <- data.table::as.data.table(df_archi_APPARTIENE)
  dt_archi_APPARTIENE <- dt_archi_APPARTIENE[
    `:START_ID(Partizione)` %in% urn_partizioni_validi &
      `:END_ID(Legge)`        %in% urn_leggi_validi
  ]
  dt_archi_APPARTIENE <- unique(dt_archi_APPARTIENE)
} else {
  dt_archi_APPARTIENE <- data.table::data.table(
    `:START_ID(Partizione)` = character(),
    `:END_ID(Legge)`        = character()
  )
}

# ══════════════════════════════════════════════════════════════════════════════
# 4. PREPARAZIONE NODI PER EXPORT
# ══════════════════════════════════════════════════════════════════════════════

# Nodi Versione: aggiungi campi INT e rimuovi colonne interne
dt_versione_export <- dt_delta[, .(
  `versione_id:ID(Versione)` = versione_id,
  testo_puro,
  numero,
  titolo_atto,
  nome_comune_atto,
  codice_breve_atto,
  atto_appartenenza,
  `valido_dal:INT`   = to_date_int(valido_dal),
  `valido_al:INT`    = to_date_int(valido_al),
  stato_vigenza,
  stato_norma,
  tipo_modifica,
  `num_versione:INT` = num_versione,
  `:LABEL`
)]

# Nodi Partizioni: aggiungi numero_articolo_puro
if (!"numero_articolo_puro" %in% names(dt_partizioni)) {
  dt_partizioni[, numero_articolo_puro := stringr::str_extract(
    get(partizione_col), "\\d+$"
  )]
}

# Nodi Legge: label corretta
if (!":LABEL" %in% names(dt_legge)) {
  dt_legge[, `:LABEL` := "Legge"]
}

# ══════════════════════════════════════════════════════════════════════════════
# 5. ESPORTAZIONE CSV con data.table::fwrite (parallela, molto più veloce)
# ══════════════════════════════════════════════════════════════════════════════

cartella_output <- here::here("output_neo4j")
if (!dir.exists(cartella_output)) {
  dir.create(cartella_output, recursive = TRUE, showWarnings = FALSE)
}

message("Scrittura CSV in corso (data.table::fwrite)...")
t0 <- proc.time()

fwrite_safe <- function(dt, path) {
  data.table::fwrite(dt, path, na = "", showProgress = FALSE)
  message(sprintf("  Scritto: %s (%d righe)", basename(path), nrow(dt)))
}

fwrite_safe(dt_legge,              file.path(cartella_output, "nodi_Legge.csv"))
fwrite_safe(dt_partizioni,         file.path(cartella_output, "nodi_Partizioni.csv"))
fwrite_safe(dt_versione_export,    file.path(cartella_output, "nodi_Versione.csv"))
fwrite_safe(dt_archi_VIGENTE,      file.path(cartella_output, "archi_VIGENTE.csv"))
fwrite_safe(dt_archi_EVOLVE_IN,    file.path(cartella_output, "archi_EVOLVE_IN.csv"))
fwrite_safe(dt_archi_CITA,         file.path(cartella_output, "archi_CITA.csv"))
fwrite_safe(dt_archi_CITA_ATTO,    file.path(cartella_output, "archi_CITA_ATTO.csv"))
fwrite_safe(dt_archi_RIMANDA_A,    file.path(cartella_output, "archi_RIMANDA_A.csv"))
fwrite_safe(dt_archi_APPARTIENE,   file.path(cartella_output, "archi_APPARTIENE.csv"))

elapsed <- (proc.time() - t0)[["elapsed"]]
message(sprintf("Scrittura completata in %.1fs.", elapsed))

# ══════════════════════════════════════════════════════════════════════════════
# 6. REPORT FINALE
# ══════════════════════════════════════════════════════════════════════════════

n_codici <- sum(dt_legge$is_codice, na.rm = TRUE)

cat(sprintf("
=== REPORT EXPORT NEO4J ===

NODI
  :Legge              : %d  (di cui :Codice: %d)
  :Partizione         : %d
  :Versione (grezzi)  : %d
  :Versione (netti)   : %d  (-%d dopo delta detection, %.1f%%)

ARCHI
  [:VIGENTE]          : %d
  [:EVOLVE_IN]        : %d
  [:CITA_NORMA]       : %d
  [:CITA_ATTO]        : %d
  [:RIMANDA_A]        : %d
  [:APPARTIENE_A]     : %d

Output: %s
",
            nrow(dt_legge), n_codici,
            nrow(dt_partizioni),
            n_grezzo,
            nrow(dt_versione_export),
            n_rimossi,
            n_rimossi / n_grezzo * 100,
            nrow(dt_archi_VIGENTE),
            nrow(dt_archi_EVOLVE_IN),
            nrow(dt_archi_CITA),
            nrow(dt_archi_CITA_ATTO),
            nrow(dt_archi_RIMANDA_A),
            nrow(dt_archi_APPARTIENE),
            cartella_output
))

# Rendi disponibili come data.frame per compatibilità eventuale
df_nodi_Versione    <- as.data.frame(dt_versione_export)
df_nodi_Partizioni  <- as.data.frame(dt_partizioni)
df_archi_CITA_export      <- as.data.frame(dt_archi_CITA)
df_archi_CITA_ATTO_export <- as.data.frame(dt_archi_CITA_ATTO)

message("[OK] 03_export_neo4j.R completato.")