# 03_export_neo4j.R
# Delta detection ed esportazione CSV per Neo4j con supporto sotto-strutture.

source(here::here("00_setup.R"))
source(here::here("00_functions.R"))

# Guardie

#' Verifica che un oggetto esista e sia un dataframe non vuoto.
verifica_df <- function(nome) {
  if (!exists(nome, envir = .GlobalEnv)) {
    stop(sprintf(
      "'%s' non trovato — esegui prima 01_build_metadata.R e 02_master_loop.R", nome
    ))
  }
  obj <- get(nome, envir = .GlobalEnv)
  if (!(is.data.frame(obj) || data.table::is.data.table(obj)) || nrow(obj) == 0) {
    stop(sprintf("'%s' è vuoto o non è un dataframe valido.", nome))
  }
  invisible(obj)
}

verifica_df("df_nodi_Legge")
verifica_df("df_nodi_Partizioni")
verifica_df("df_nodi_Versione")

# Guardia contro riesecuzioni nella stessa sessione.
if ("valido_dal:INT" %in% names(df_nodi_Versione)) {
  stop(paste(
    "ERRORE: df_nodi_Versione risulta già processato da 03_export_neo4j.R.",
    "Rieseguire 02_master_loop.R prima di procedere."
  ))
}

# Conversione iniziale a data.table
dt_versione   <- data.table::as.data.table(df_nodi_Versione)
dt_partizioni <- data.table::as.data.table(df_nodi_Partizioni)
dt_legge      <- data.table::as.data.table(df_nodi_Legge)

# Normalizzazione nodi Versione

#' Rinomina una colonna solo se esiste.
rinomina_se_esiste <- function(dt, old, new) {
  if (old %in% names(dt)) data.table::setnames(dt, old, new)
  invisible(dt)
}

# Normalizzazione nomi colonne.
nomi_attuali <- names(dt_versione)
nomi_puliti  <- nomi_attuali |>
  stringr::str_remove(":DATE$") |>
  stringr::str_remove(":INT$") |>
  stringr::str_remove(":ID\\([^)]+\\)$") |>
  stringr::str_replace("^stato_temporale$", "stato_vigenza")
data.table::setnames(dt_versione, nomi_attuali, nomi_puliti)

if (!"stato_vigenza" %in% names(dt_versione)) {
  dt_versione[, stato_vigenza := NA_character_]
}

if (!"partizione_id" %in% names(dt_versione)) {
  dt_versione[, versione_id := stringr::str_squish(versione_id)]
  # Usiamo .*$ per ignorare qualsiasi sporcizia dopo il numero di versione
  dt_versione[, partizione_id := sub("_V[0-9]+.*$", "", versione_id)]
}

# Conversione date.
if (is.integer(dt_versione$valido_dal) || is.numeric(dt_versione$valido_dal)) {
  dt_versione[, valido_dal := as.Date(as.character(valido_dal), format = "%Y%m%d")]
  dt_versione[, valido_al  := as.Date(as.character(valido_al),  format = "%Y%m%d")]
} else {
  dt_versione[, valido_dal := as.Date(valido_dal)]
  dt_versione[, valido_al  := as.Date(valido_al)]
}

message(sprintf("Nodi Versione caricati: %d record.", nrow(dt_versione)))

# ------------------------------------------------------------------------------
# DELTA DETECTION CON IMPRONTA NUCLEARE
# ------------------------------------------------------------------------------

message("Avvio delta detection ottimizzato (data.table)...")
t0 <- proc.time()

n_grezzo <- nrow(dt_versione)

# 1. Ordinamento stabile e sequenziale per Partizione e Linea Temporale
data.table::setorder(dt_versione, partizione_id, valido_dal, num_versione)

# 2. L'Opzione Nucleare: Creazione di un'impronta digitale
dt_versione[, fingerprint := {
  x <- stringr::str_to_lower(testo_puro)
  x <- stringr::str_replace_all(x, "[^a-z0-9]", "") # Mantiene solo lettere e numeri puri
  data.table::fifelse(is.na(x) | x == "", "testo_mancante", x)
}]

# 3. Rilevamento del cambio semantico rispetto alla versione precedente nello stesso articolo
dt_versione[, cambio := (
  fingerprint != data.table::shift(fingerprint, n = 1L, fill = "inizio_blocco", type = "lag")
), by = partizione_id]

# Forza la prima riga di ogni articolo a essere sempre un inizio gruppo
dt_versione[, row_idx := seq_len(.N), by = partizione_id]
dt_versione[row_idx == 1L, cambio := TRUE]

# 4. Calcolo del gruppo cumulativo
dt_versione[, gruppo := cumsum(cambio), by = partizione_id]

# 5. Contrazione dei nodi Versione identici
dt_delta <- dt_versione[, .(
  versione_id        = versione_id[1L],
  testo_puro         = testo_puro[1L],
  numero             = numero[1L],
  titolo_atto        = titolo_atto[1L],
  nome_comune_atto   = nome_comune_atto[1L],
  codice_breve_atto  = codice_breve_atto[1L],
  atto_appartenenza  = atto_appartenenza[1L],
  valido_dal         = min(valido_dal),
  valido_al          = max(valido_al, na.rm = TRUE),
  stato_vigenza      = stato_vigenza[.N],
  stato_norma        = stato_norma[1L],
  tipo_modifica      = tipo_modifica[1L],
  num_versione       = num_versione[1L],
  `:LABEL`           = "Versione"
), by = .(partizione_id, gruppo)]

# 6. Pulizia colonne di servizio
dt_delta[, gruppo := NULL]
dt_versione[, c("fingerprint", "cambio", "row_idx", "gruppo") := NULL]

n_rimossi <- n_grezzo - nrow(dt_delta)
elapsed   <- (proc.time() - t0)[["elapsed"]]
message(sprintf(
  "Delta detection completata in %.1fs: %d → %d nodi Versione (-%d ridondanti, %.1f%%).",
  elapsed, n_grezzo, nrow(dt_delta),
  n_rimossi, (n_rimossi / n_grezzo) * 100
))

rm(dt_versione); gc(verbose = FALSE)

# ------------------------------------------------------------------------------
# GENERAZIONE ARCHI TEMPORALI E STRUTTURALI
# ------------------------------------------------------------------------------

#' Converte una data in intero YYYYMMDD.
to_date_int <- function(d) as.integer(format(as.Date(d), "%Y%m%d"))

data.table::setkey(dt_delta, versione_id)

# Lookup date per i join.
dt_date_lookup <- unique(dt_delta[, .(versione_id, valido_dal, valido_al)], by = "versione_id")
data.table::setkey(dt_date_lookup, versione_id)

# 1. ARCO HA_VERSIONE
dt_archi_HA_VERSIONE <- dt_delta[
  order(partizione_id, valido_dal, num_versione), # Ordina per partizione e poi per data/versione crescente
  .SD[.N],                                        # Ora .N è CERTO di essere l'ultima versione
  by = partizione_id
][, .(
  `:START_ID(Partizione)` = partizione_id,
  `:END_ID(Versione)`     = versione_id,
  valido_dal              = to_date_int(valido_dal),
  valido_al               = to_date_int(valido_al),
  stato_vigenza           = stato_vigenza
)]

# 2. ARCO EVOLVE_IN
data.table::setorder(dt_delta, partizione_id, valido_dal)

dt_evolve_tmp <- dt_delta[, .(
  versione_id,
  target_successivo = data.table::shift(versione_id,   type = "lead"),
  azione_causante   = data.table::shift(tipo_modifica, type = "lead"),
  valido_dal,
  valido_al
), by = partizione_id]

dt_archi_EVOLVE_IN <- dt_evolve_tmp[
  !is.na(target_successivo) & versione_id != target_successivo,
  .(
    `:START_ID(Versione)` = versione_id,
    `:END_ID(Versione)`   = target_successivo,
    tipo_azione           = azione_causante,
    valido_dal            = to_date_int(valido_dal),
    valido_al             = to_date_int(valido_al)
  )
]

# Associa l'URN della legge modificante recuperandolo dai parziali
output_partial <- here::here("output_neo4j", "partial")
files_evolve_partial <- list.files(
  output_partial, pattern = "^archi_EVOLVE_IN_.*\\.csv$", full.names = TRUE
)

if (length(files_evolve_partial) > 0) {
  dt_urn_raw <- data.table::rbindlist(
    lapply(files_evolve_partial, data.table::fread, na.strings = ""),
    fill = TRUE, use.names = TRUE
  )
  if ("urn_legge_modificante" %in% names(dt_urn_raw)) {
    dt_urn_lookup <- dt_urn_raw[
      !is.na(urn_legge_modificante),
      .(`:END_ID(Versione)`, urn_legge_modificante)
    ][!duplicated(`:END_ID(Versione)`)]
    
    dt_archi_EVOLVE_IN <- merge(
      dt_archi_EVOLVE_IN,
      dt_urn_lookup,
      by.x  = ":END_ID(Versione)",
      by.y  = ":END_ID(Versione)",
      all.x = TRUE
    )
    message(sprintf("  urn_legge_modificante su EVOLVE_IN: %d/%d valorizzati",
                    sum(!is.na(dt_archi_EVOLVE_IN$urn_legge_modificante)),
                    nrow(dt_archi_EVOLVE_IN)))
    rm(dt_urn_raw, dt_urn_lookup)
  } else {
    dt_archi_EVOLVE_IN[, urn_legge_modificante := NA_character_]
  }
} else {
  dt_archi_EVOLVE_IN[, urn_legge_modificante := NA_character_]
  message("  urn_legge_modificante: CSV parziali non trovati")
}
dt_archi_EVOLVE_IN <- unique(dt_archi_EVOLVE_IN)
rm(dt_evolve_tmp)

# 3. ARCO ABROGATO_DA
dt_urn_link <- dt_archi_EVOLVE_IN[, .(`:START_ID(Versione)`, urn_legge_modificante)]
data.table::setnames(dt_urn_link, ":START_ID(Versione)", "versione_id")

dt_delta_con_urn <- merge(dt_delta, dt_urn_link, by = "versione_id", all.x = TRUE)

dt_archi_ABROGATO <- dt_delta_con_urn[
  !is.na(urn_legge_modificante) & tipo_modifica == "abrogazione", 
  .(
    `:START_ID(Partizione)` = partizione_id,
    `:END_ID(Legge)`        = urn_legge_modificante,
    data_abrogazione        = to_date_int(valido_dal)
  )
]
rm(dt_delta_con_urn, dt_urn_link)

# ------------------------------------------------------------------------------
# ALLINEAMENTO STATI NORMATIVI CON GLI ARCHI TEMPORALI
# ------------------------------------------------------------------------------
message("Allineamento 'stato_norma' basato sugli archi effettivi...")

id_vigenti <- dt_archi_HA_VERSIONE[stato_vigenza == "VIGENTE", `:END_ID(Versione)`]

# L'abrogazione vince su tutto, il resto diventa ATTIVO o STORICO
dt_delta[, stato_norma := data.table::fcase(
  tipo_modifica == "abrogazione", "ABROGATO",
  tipo_modifica == "parzialmente_abrogato", "PARZIALMENTE ABROGATO",
  versione_id %in% id_vigenti, "ATTIVO",
  default = "STORICO"
)]

# ------------------------------------------------------------------------------
# COLLEGAMENTI ESTERNI (CITAZIONI E STRUTTURA)
# ------------------------------------------------------------------------------

# CITA_NORMA
if (exists("df_archi_CITA") && nrow(df_archi_CITA) > 0) {
  dt_cita <- data.table::as.data.table(df_archi_CITA)
  data.table::setnames(dt_cita,
                       c(":START_ID(Versione)", ":END_ID(Partizione)"),
                       c("versione_id", "end_partizione")
  )
  dt_date_lookup_dedup <- unique(dt_date_lookup, by = "versione_id")
  
  dt_archi_CITA <- dt_cita[
    versione_id %in% dt_date_lookup_dedup$versione_id
  ][dt_date_lookup_dedup, on = "versione_id", nomatch = 0L][, .(
    `:START_ID(Versione)` = versione_id,
    `:END_ID(Partizione)` = end_partizione,
    tipo_citazione,
    valido_dal = to_date_int(valido_dal),
    valido_al  = to_date_int(valido_al)
  )]
  dt_archi_CITA <- unique(dt_archi_CITA)
  rm(dt_cita, dt_date_lookup_dedup); gc(verbose = FALSE)
} else {
  dt_archi_CITA <- data.table::data.table(
    `:START_ID(Versione)` = character(), `:END_ID(Partizione)` = character(),
    tipo_citazione = character(), valido_dal = integer(), valido_al = integer()
  )
}

# CITA_ATTO
urn_leggi_validi <- dt_legge[["urn:ID"]]

if (exists("df_archi_CITA_ATTO") && nrow(df_archi_CITA_ATTO) > 0) {
  dt_cita_atto <- data.table::as.data.table(df_archi_CITA_ATTO)
  data.table::setnames(dt_cita_atto,
                       c(":START_ID(Versione)", ":END_ID(Legge)"),
                       c("versione_id", "end_legge")
  )
  dt_date_lookup_dedup <- unique(dt_date_lookup, by = "versione_id")
  
  dt_archi_CITA_ATTO <- dt_cita_atto[
    versione_id %in% dt_date_lookup_dedup$versione_id &
      end_legge %in% urn_leggi_validi
  ][dt_date_lookup_dedup, on = "versione_id", nomatch = 0L][, .(
    `:START_ID(Versione)` = versione_id,
    `:END_ID(Legge)`      = end_legge,
    tipo_citazione,
    valido_dal = to_date_int(valido_dal),
    valido_al  = to_date_int(valido_al)
  )]
  dt_archi_CITA_ATTO <- unique(dt_archi_CITA_ATTO)
  rm(dt_cita_atto, dt_date_lookup_dedup); gc(verbose = FALSE)
} else {
  dt_archi_CITA_ATTO <- data.table::data.table(
    `:START_ID(Versione)` = character(), `:END_ID(Legge)` = character(),
    tipo_citazione = character(), valido_dal = integer(), valido_al = integer()
  )
}

# RIMANDA_A, APPARTIENE e SOTTO_PARTIZIONE
partizione_col        <- if ("partizione_id:ID(Partizione)" %in% names(dt_partizioni)) {
  "partizione_id:ID(Partizione)"
} else "partizione_id"
urn_partizioni_validi <- dt_partizioni[[partizione_col]]

if (exists("df_archi_RIMANDA_A") && nrow(df_archi_RIMANDA_A) > 0) {
  dt_archi_RIMANDA_A <- data.table::as.data.table(df_archi_RIMANDA_A)
  dt_archi_RIMANDA_A <- unique(dt_archi_RIMANDA_A[
    `:START_ID(Partizione)` %in% urn_partizioni_validi &
      `:END_ID(Partizione)`   %in% urn_partizioni_validi
  ])
} else {
  dt_archi_RIMANDA_A <- data.table::data.table(
    `:START_ID(Partizione)` = character(), `:END_ID(Partizione)` = character()
  )
}

if (exists("df_archi_APPARTIENE") && nrow(df_archi_APPARTIENE) > 0) {
  dt_archi_APPARTIENE <- data.table::as.data.table(df_archi_APPARTIENE)
  dt_archi_APPARTIENE <- unique(dt_archi_APPARTIENE[
    `:START_ID(Partizione)` %in% urn_partizioni_validi &
      `:END_ID(Legge)`        %in% urn_leggi_validi
  ])
} else {
  dt_archi_APPARTIENE <- data.table::data.table(
    `:START_ID(Partizione)` = character(), `:END_ID(Legge)` = character()
  )
}

# Blocco di validazione: SOTTO_PARTIZIONE (gerarchia allegati)
if (exists("df_archi_SOTTO_PARTIZIONE") && nrow(df_archi_SOTTO_PARTIZIONE) > 0) {
  dt_archi_SOTTO_PARTIZIONE <- data.table::as.data.table(df_archi_SOTTO_PARTIZIONE)
  dt_archi_SOTTO_PARTIZIONE <- unique(dt_archi_SOTTO_PARTIZIONE[
    `:START_ID(Partizione)` %in% urn_partizioni_validi &
      `:END_ID(Partizione)`   %in% urn_partizioni_validi
  ])
} else {
  dt_archi_SOTTO_PARTIZIONE <- data.table::data.table(
    `:START_ID(Partizione)` = character(), `:END_ID(Partizione)` = character()
  )
}

# Nodi per export

# Nodi Versione
dt_versione_export <- dt_delta[, .(
  `versione_id:ID(Versione)` = versione_id,  testo_puro,
  numero,
  titolo_atto,
  nome_comune_atto,
  codice_breve_atto,
  atto_appartenenza,
  valido_dal        = to_date_int(valido_dal),
  valido_al         = to_date_int(valido_al),
  stato_vigenza,
  stato_norma,
  tipo_modifica,
  num_versione      = num_versione,
  `:LABEL`
)]

# Nodi Partizioni
if (!"numero_articolo_puro" %in% names(dt_partizioni)) {
  dt_partizioni[, numero_articolo_puro := stringr::str_extract(
    get(partizione_col), "\\d+$"
  )]
}

# Nodi Legge
if (!":LABEL" %in% names(dt_legge)) {
  dt_legge[, `:LABEL` := "Legge"]
}

# ------------------------------------------------------------------------------
# ESPORTAZIONE CSV DEFINITIVA
# ------------------------------------------------------------------------------

cartella_output <- here::here("output_neo4j")
if (!dir.exists(cartella_output)) {
  dir.create(cartella_output, recursive = TRUE, showWarnings = FALSE)
}

message("Scrittura CSV in corso (data.table::fwrite)...")
t0 <- proc.time()

#' Scrive un data.table in CSV.
fwrite_safe <- function(dt, path) {
  if (nrow(dt) == 0) {
    message(sprintf("  Saltato (vuoto): %s", basename(path)))
    return(invisible(NULL))
  }
  data.table::fwrite(dt, path, na = "", sep = ",",
                     quote = TRUE,
                     showProgress = FALSE)
  message(sprintf("  Scritto: %-35s (%d righe)", basename(path), nrow(dt)))
}

fwrite_safe(dt_legge,                  file.path(cartella_output, "nodi_Legge.csv"))
fwrite_safe(dt_partizioni,             file.path(cartella_output, "nodi_Partizioni.csv"))
fwrite_safe(dt_versione_export,        file.path(cartella_output, "nodi_Versione.csv"))
fwrite_safe(dt_archi_HA_VERSIONE,      file.path(cartella_output, "archi_HA_VERSIONE.csv"))
fwrite_safe(dt_archi_EVOLVE_IN,        file.path(cartella_output, "archi_EVOLVE_IN.csv"))
fwrite_safe(dt_archi_ABROGATO,         file.path(cartella_output, "archi_ABROGATO_DA.csv"))
fwrite_safe(dt_archi_CITA,             file.path(cartella_output, "archi_CITA.csv"))
fwrite_safe(dt_archi_CITA_ATTO,        file.path(cartella_output, "archi_CITA_ATTO.csv"))
fwrite_safe(dt_archi_RIMANDA_A,        file.path(cartella_output, "archi_RIMANDA_A.csv"))
fwrite_safe(dt_archi_APPARTIENE,       file.path(cartella_output, "archi_APPARTIENE.csv"))
fwrite_safe(dt_archi_SOTTO_PARTIZIONE, file.path(cartella_output, "archi_SOTTO_PARTIZIONE.csv"))

elapsed <- (proc.time() - t0)[["elapsed"]]
message(sprintf("Scrittura completata in %.1fs.", elapsed))

# Report finale

n_codici <- sum(dt_legge$is_codice, na.rm = TRUE)

cat(sprintf("
=== REPORT EXPORT NEO4J ===

NODI
  :Legge              : %d  (di cui :Codice: %d)
  :Partizione         : %d
  :Versione (grezzi)  : %d
  :Versione (netti)   : %d  (-%d dopo delta detection, %.1f%%)

ARCHI
  [:HA_VERSIONE]      : %d
  [:EVOLVE_IN]        : %d
  [:ABROGATO_DA]      : %d
  [:CITA_NORMA]       : %d
  [:CITA_ATTO]        : %d
  [:RIMANDA_A]        : %d
  [:APPARTIENE_A]     : %d
  [:SOTTO_ELEMENTO_DI]: %d

Output: %s
",
            nrow(dt_legge), n_codici,
            nrow(dt_partizioni),
            n_grezzo,
            nrow(dt_versione_export),
            n_rimossi, n_rimossi / n_grezzo * 100,
            nrow(dt_archi_HA_VERSIONE),
            nrow(dt_archi_EVOLVE_IN),
            nrow(dt_archi_ABROGATO),
            nrow(dt_archi_CITA),
            nrow(dt_archi_CITA_ATTO),
            nrow(dt_archi_RIMANDA_A),
            nrow(dt_archi_APPARTIENE),
            nrow(dt_archi_SOTTO_PARTIZIONE),
            cartella_output
))

# Rende disponibili come data.frame per compatibilità con script successivi
df_nodi_Versione          <- as.data.frame(dt_versione_export)
df_nodi_Partizioni        <- as.data.frame(dt_partizioni)
df_archi_CITA_export      <- as.data.frame(dt_archi_CITA)
df_archi_CITA_ATTO_export <- as.data.frame(dt_archi_CITA_ATTO)
df_archi_EVOLVE_IN        <- as.data.frame(dt_archi_EVOLVE_IN)
df_archi_HA_VERSIONE      <- as.data.frame(dt_archi_HA_VERSIONE)
df_archi_APPARTIENE       <- as.data.frame(dt_archi_APPARTIENE)
df_archi_RIMANDA_A        <- as.data.frame(dt_archi_RIMANDA_A)
df_archi_SOTTO_PARTIZIONE <- as.data.frame(dt_archi_SOTTO_PARTIZIONE)

message("[OK] 03_export_neo4j.R completato.")