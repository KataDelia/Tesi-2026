# 03_export_neo4j.R
# Delta detection ed esportazione CSV per Neo4j.

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
  dt_versione[, partizione_id := sub("_V[0-9]+$", "", versione_id)]
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

# Delta detection

message("Avvio delta detection (data.table)...")
t0 <- proc.time()

n_grezzo <- nrow(dt_versione)

data.table::setorder(dt_versione, partizione_id, valido_dal)

# Normalizzazione robusta del testo.
dt_versione[, testo_norm := {
  x <- testo_puro
  x <- stringr::str_squish(x)
  x <- stringr::str_replace_all(x, "[\r\n\t]", " ")
  x <- stringr::str_replace_all(x, "\u00A0|\u200B|\uFEFF", " ")
  x <- stringr::str_replace_all(x, "[\\s]*[\\.,;:][\\s]*", " ")
  x <- stringr::str_replace_all(x, "\\s{2,}", " ")
  x <- stringr::str_squish(x)
  x <- stringr::str_to_lower(x)
  # Fix testo duplicato.
  n    <- nchar(x)
  meta <- substr(x, 1L, n %/% 2L)
  coda <- stringr::str_squish(substr(x, n %/% 2L + 2L, n))
  doppio <- n > 20L & n %% 2L == 0L & coda == meta
  x[doppio] <- meta[doppio]
  x
}]

# Identifica l'inizio di ogni blocco semantico.
dt_versione[, cambio := (
  testo_norm  != data.table::shift(testo_norm,  fill = "") |
    stato_norma != data.table::shift(stato_norma, fill = "") |
    seq_len(.N) == 1L
), by = partizione_id]

dt_versione[, gruppo := cumsum(cambio), by = partizione_id]

# Aggregazione per blocco.
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

# Ricalcolo valido_al.
data.table::setorder(dt_delta, partizione_id, valido_dal)
DATA_FINE <- as.Date("9999-12-31")
dt_delta[, valido_al := {
  next_dal <- data.table::shift(valido_dal, type = "lead", fill = DATA_FINE)
  data.table::fifelse(next_dal == DATA_FINE, DATA_FINE, next_dal - 1L)
}, by = partizione_id]
dt_delta[, valido_al := pmax(valido_dal, valido_al)]
dt_delta[, gruppo := NULL]

n_rimossi <- n_grezzo - nrow(dt_delta)
elapsed   <- (proc.time() - t0)[["elapsed"]]
message(sprintf(
  "Delta detection completata in %.1fs: %d → %d nodi Versione (-%d ridondanti, %.1f%%).",
  elapsed, n_grezzo, nrow(dt_delta),
  n_rimossi, n_rimossi / n_grezzo * 100
))

rm(dt_versione); gc(verbose = FALSE)

# Archi temporali

#' Converte una data in intero YYYYMMDD.
to_date_int <- function(d) as.integer(format(as.Date(d), "%Y%m%d"))

data.table::setkey(dt_delta, versione_id)

# Lookup date per i join.
dt_date_lookup <- dt_delta[, .(versione_id, valido_dal, valido_al)]
data.table::setkey(dt_date_lookup, versione_id)

# VIGENTE
dt_archi_VIGENTE <- dt_delta[stato_vigenza == "VIGENTE", .(
  `:START_ID(Partizione)` = partizione_id,
  `:END_ID(Versione)`     = versione_id,
  valido_dal              = to_date_int(valido_dal),
  valido_al               = to_date_int(valido_al)
)]

# Deduplicazione vigente.
n_pre_dedup <- nrow(dt_archi_VIGENTE)
dt_archi_VIGENTE <- dt_archi_VIGENTE[
  order(-valido_dal)
][!duplicated(`:START_ID(Partizione)`)]
n_dup_vigente <- n_pre_dedup - nrow(dt_archi_VIGENTE)
if (n_dup_vigente > 0) {
  warning(sprintf(
    "VIGENTE: rimossi %d archi duplicati (partizioni con piu versioni vigenti).",
    n_dup_vigente
  ), call. = FALSE)
}

# EVOLVE_IN
data.table::setorder(dt_delta, partizione_id, valido_dal)

dt_evolve_tmp <- dt_delta[, .(
  versione_id,
  target_successivo = data.table::shift(versione_id,   type = "lead"),
  azione_causante   = data.table::shift(tipo_modifica, type = "lead"),
  valido_dal,
  valido_al
), by = partizione_id]


dt_archi_EVOLVE_IN <- dt_evolve_tmp[
  !is.na(target_successivo) &
    versione_id != target_successivo,
  .(
    `:START_ID(Versione)` = versione_id,
    `:END_ID(Versione)`   = target_successivo,
    tipo_azione           = azione_causante,
    valido_dal            = to_date_int(valido_dal),
    valido_al             = to_date_int(valido_al)
  )]

# Aggiunge urn_legge_modificante dai CSV parziali.
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
      by    = ":END_ID(Versione)",
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

# CITA_NORMA
if (exists("df_archi_CITA") && nrow(df_archi_CITA) > 0) {
  dt_cita <- data.table::as.data.table(df_archi_CITA)
  data.table::setnames(dt_cita,
                       c(":START_ID(Versione)", ":END_ID(Partizione)"),
                       c("versione_id", "end_partizione")
  )
  dt_archi_CITA <- dt_cita[
    versione_id %in% dt_date_lookup$versione_id
  ][dt_date_lookup, on = "versione_id", nomatch = 0L][, .(
    `:START_ID(Versione)` = versione_id,
    `:END_ID(Partizione)` = end_partizione,
    tipo_citazione,
    valido_dal = to_date_int(valido_dal),
    valido_al  = to_date_int(valido_al)
  )]
  dt_archi_CITA <- unique(dt_archi_CITA)
  rm(dt_cita); gc(verbose = FALSE)
} else {
  dt_archi_CITA <- data.table::data.table(
    `:START_ID(Versione)` = character(), `:END_ID(Partizione)` = character(),
    tipo_citazione = character(), `valido_dal:INT` = integer(), `valido_al:INT` = integer()
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
  dt_archi_CITA_ATTO <- dt_cita_atto[
    versione_id %in% dt_date_lookup$versione_id &
      end_legge   %in% urn_leggi_validi
  ][dt_date_lookup, on = "versione_id", nomatch = 0L][, .(
    `:START_ID(Versione)` = versione_id,
    `:END_ID(Legge)`      = end_legge,
    tipo_citazione,
    valido_dal = to_date_int(valido_dal),
    valido_al  = to_date_int(valido_al)
  )]
  dt_archi_CITA_ATTO <- unique(dt_archi_CITA_ATTO)
  rm(dt_cita_atto); gc(verbose = FALSE)
} else {
  dt_archi_CITA_ATTO <- data.table::data.table(
    `:START_ID(Versione)` = character(), `:END_ID(Legge)` = character(),
    tipo_citazione = character(), `valido_dal:INT` = integer(), `valido_al:INT` = integer()
  )
}

# MODIFICATO_DA rimosso.

# RIMANDA_A e APPARTIENE_A
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

# Nodi per export

# Nodi Versione
dt_versione_export <- dt_delta[, .(
  versione_id       = versione_id,
  testo_puro,
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

# Esportazione CSV

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

fwrite_safe(dt_legge,               file.path(cartella_output, "nodi_Legge.csv"))
fwrite_safe(dt_partizioni,          file.path(cartella_output, "nodi_Partizioni.csv"))
fwrite_safe(dt_versione_export,     file.path(cartella_output, "nodi_Versione.csv"))
fwrite_safe(dt_archi_VIGENTE,       file.path(cartella_output, "archi_VIGENTE.csv"))
fwrite_safe(dt_archi_EVOLVE_IN,     file.path(cartella_output, "archi_EVOLVE_IN.csv"))
fwrite_safe(dt_archi_CITA,          file.path(cartella_output, "archi_CITA.csv"))
fwrite_safe(dt_archi_CITA_ATTO,     file.path(cartella_output, "archi_CITA_ATTO.csv"))
fwrite_safe(dt_archi_RIMANDA_A,     file.path(cartella_output, "archi_RIMANDA_A.csv"))
fwrite_safe(dt_archi_APPARTIENE,    file.path(cartella_output, "archi_APPARTIENE.csv"))

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
            n_rimossi, n_rimossi / n_grezzo * 100,
            nrow(dt_archi_VIGENTE),
            nrow(dt_archi_EVOLVE_IN),
            nrow(dt_archi_CITA),
            nrow(dt_archi_CITA_ATTO),
            nrow(dt_archi_RIMANDA_A),
            nrow(dt_archi_APPARTIENE),
            cartella_output
))

# Rende disponibili come data.frame per compatibilità con script successivi
df_nodi_Versione          <- as.data.frame(dt_versione_export)
df_nodi_Partizioni        <- as.data.frame(dt_partizioni)
df_archi_CITA_export      <- as.data.frame(dt_archi_CITA)
df_archi_CITA_ATTO_export <- as.data.frame(dt_archi_CITA_ATTO)

message("[OK] 03_export_neo4j.R completato.")