# 03_export_neo4j_2.R
# Delta detection, costruzione archi, esportazione CSV per Neo4j.
# Richiede che 02_master_loop_2.R sia stato eseguito nella stessa sessione.

source(here::here("00_setup.R"))

# 1. VERIFICA E COERENZA DEI DATAFRAME PROVENIENTI DALL'ETL

# 1.1 Verifica Nodi Legge
if (!exists("df") || nrow(df) == 0) {
  stop("df non trovato o vuoto — esegui prima 01_build_metadata.R e 02_master_loop_2.R")
}

# 1.2 Verifica e Pulizia Nodi Partizione (Articoli e Allegati unificati)
if (!exists("df_nodi_Partizioni") || nrow(df_nodi_Partizioni) == 0) {
  stop("df_nodi_Partizioni non trovato o vuoto — esegui prima 02_master_loop_2.R")
}

df_nodi_Partizioni <- df_nodi_Partizioni %>%
  dplyr::mutate(
    numero_articolo_puro = stringr::str_extract(`partizione_id:ID(Partizione)`, "\\d+$")
  )

# 1.3 Verifica Nodi Versione (Snapshot temporali del testo)
if (!exists("df_nodi_Versione") || nrow(df_nodi_Versione) == 0) {
  stop("df_nodi_Versione non trovato o vuoto — esegui prima 02_master_loop_2.R")
}

# Stati.
if (!"stato_vigenza" %in% names(df_nodi_Versione) && "stato_temporale" %in% names(df_nodi_Versione)) {
  df_nodi_Versione <- dplyr::rename(df_nodi_Versione, stato_vigenza = stato_temporale)
}
if (!"stato_vigenza" %in% names(df_nodi_Versione)) {
  df_nodi_Versione$stato_vigenza <- NA_character_
}

# partizione_id.
if (!"partizione_id" %in% names(df_nodi_Versione)) {
  col_id_name <- if ("versione_id:ID(Versione)" %in% names(df_nodi_Versione)) {
    "versione_id:ID(Versione)"
  } else {
    "versione_id"
  }
  df_nodi_Versione$partizione_id <- stringr::str_remove(df_nodi_Versione[[col_id_name]], "_V\\d+$")
}

# Normalizzazione delle date.
if ("valido_dal:DATE" %in% names(df_nodi_Versione)) {
  df_nodi_Versione <- dplyr::rename(df_nodi_Versione, valido_dal = `valido_dal:DATE`)
} else if ("valido_dal:INT" %in% names(df_nodi_Versione)) {
  df_nodi_Versione <- dplyr::rename(df_nodi_Versione, valido_dal = `valido_dal:INT`)
}

if ("valido_al:DATE" %in% names(df_nodi_Versione)) {
  df_nodi_Versione <- dplyr::rename(df_nodi_Versione, valido_al = `valido_al:DATE`)
} else if ("valido_al:INT" %in% names(df_nodi_Versione)) {
  df_nodi_Versione <- dplyr::rename(df_nodi_Versione, valido_al = `valido_al:INT`)
}

if ("versione_id:ID(Versione)" %in% names(df_nodi_Versione)) {
  df_nodi_Versione <- dplyr::rename(df_nodi_Versione, versione_id = `versione_id:ID(Versione)`)
}

# Controllo finale.
if (!"valido_dal" %in% names(df_nodi_Versione)) {
  stop("ERRORE CRITICO: Impossibile normalizzare 'valido_dal'. Verifica la struttura del dataframe in input.")
}

# 2. Delta detection

df_nodi_Versione_grezzo <- df_nodi_Versione

df_nodi_Versione <- df_nodi_Versione_grezzo %>%
  
  dplyr::mutate(
    partizione_id = stringr::str_remove(versione_id, "_V\\d+$"),
    testo_norm    = stringr::str_squish(testo_puro)
  ) %>%
  
  dplyr::arrange(partizione_id, valido_dal) %>%
  dplyr::group_by(partizione_id) %>%
  dplyr::mutate(
    cambio_testo    = (testo_norm != dplyr::lag(testo_norm)),
    cambio_stato    = (stato_norma != dplyr::lag(stato_norma)),
    is_nuovo_blocco = dplyr::row_number() == 1 | (cambio_testo | cambio_stato)
  ) %>%
  dplyr::mutate(gruppo_versione = cumsum(is_nuovo_blocco)) %>%
  dplyr::group_by(partizione_id, gruppo_versione) %>%
  dplyr::summarise(
    versione_id        = dplyr::first(versione_id),
    testo_puro         = dplyr::first(testo_puro),
    
    valido_dal         = min(valido_dal),
    stato_vigenza      = dplyr::last(stato_vigenza),
    stato_norma        = dplyr::first(stato_norma),
    tipo_modifica      = dplyr::first(tipo_modifica),
    `num_versione:INT` = dplyr::first(`num_versione:INT`),
    `:LABEL`           = "Versione",
    .groups = "drop"
  ) %>%
  
  dplyr::arrange(partizione_id, valido_dal) %>%
  dplyr::group_by(partizione_id) %>%
  dplyr::mutate(
    valido_al = dplyr::lead(valido_dal, default = as.character("9999-12-31"))
  ) %>%
  dplyr::ungroup() %>%
  
  dplyr::select(-gruppo_versione)

# Metriche.
n_rimossi <- nrow(df_nodi_Versione_grezzo) - nrow(df_nodi_Versione)

message(sprintf(
  "Delta Detection completata: rimossi %d nodi versione ridondanti (%s%% del dataset complessivo).",
  n_rimossi,
  round(n_rimossi / nrow(df_nodi_Versione_grezzo) * 100, 1)
))

# 3. COSTRUZIONE ARCHI (RELAZIONI TEMPORALI E SEMANTICHE NEO4J)

format_date_to_int <- function(d) {
  as.integer(format(as.Date(d), "%Y%m%d"))
}

# VIGENTE.
df_archi_VIGENTE <- df_nodi_Versione %>%
  dplyr::filter(stato_vigenza == "VIGENTE") %>% 
  dplyr::transmute(
    `:START_ID(Partizione)` = partizione_id,
    `:END_ID(Versione)`     = versione_id,
    `valido_dal:INT`        = format_date_to_int(valido_dal),
    `valido_al:INT`         = format_date_to_int(valido_al)
  )

# EVOLVE_IN.
df_archi_EVOLVE_IN <- df_nodi_Versione %>%
  dplyr::arrange(partizione_id, valido_dal) %>%
  dplyr::group_by(partizione_id) %>%
  dplyr::mutate(
    prossimo_target = dplyr::lead(versione_id),
    azione_causante = dplyr::lead(tipo_modifica)
  ) %>%
  dplyr::ungroup() %>%
  dplyr::filter(!is.na(prossimo_target)) %>%
  dplyr::transmute(
    `:START_ID(Versione)` = versione_id,
    `:END_ID(Versione)`   = prossimo_target,
    tipo_azione           = azione_causante,
    `valido_dal:INT`      = format_date_to_int(valido_dal),
    `valido_al:INT`       = format_date_to_int(valido_al)
  )

if (!exists("format_date_to_int")) {
  format_date_to_int <- function(d) {
    if (is.null(d) || length(d) == 0) return(integer())
    as.integer(format(as.Date(d), "%Y%m%d"))
  }
}

# CITA.
if (exists("df_archi_CITA") && nrow(df_archi_CITA) > 0) {
  df_archi_CITA <- df_archi_CITA %>%
    dplyr::semi_join(df_nodi_Versione, by = c(":START_ID(Versione)" = "versione_id")) %>%
    dplyr::left_join(
      df_nodi_Versione %>%
        dplyr::select(versione_id, valido_dal, valido_al),
      by = c(":START_ID(Versione)" = "versione_id")
    ) %>%
    dplyr::mutate(
      `valido_dal:INT` = format_date_to_int(valido_dal),
      `valido_al:INT`  = format_date_to_int(valido_al)
    ) %>%
    dplyr::select(
      `:START_ID(Versione)`,
      `:END_ID(Partizione)`,
      tipo_citazione,
      `valido_dal:INT`,
      `valido_al:INT`
    ) %>%
    dplyr::distinct()
  
} else {
  df_archi_CITA <- tibble::tibble(
    `:START_ID(Versione)` = character(),
    `:END_ID(Partizione)` = character(),
    tipo_citazione        = character(),
    `valido_dal:INT`      = integer(),
    `valido_al:INT`       = integer()
  )
}

# RIMANDA_A.
if (exists("df_archi_RIMANDA_A") && nrow(df_archi_RIMANDA_A) > 0) {
  partizione_col_id <- if ("partizione_id:ID(Partizione)" %in% names(df_nodi_Partizioni)) {
    "partizione_id:ID(Partizione)"
  } else {
    "partizione_id"
  }
  
  df_archi_RIMANDA_A <- df_archi_RIMANDA_A %>% 
    dplyr::semi_join(df_nodi_Partizioni, by = c(":START_ID(Partizione)" = partizione_col_id)) %>%
    dplyr::semi_join(df_nodi_Partizioni, by = c(":END_ID(Partizione)" = partizione_col_id)) %>%
    dplyr::distinct()
  
} else {
  df_archi_RIMANDA_A <- tibble::tibble(
    `:START_ID(Partizione)` = character(),
    `:END_ID(Partizione)`   = character()
  )
}


# 4. Esportazione CSV

cartella_output <- here::here("output_neo4j")
if (!dir.exists(cartella_output)) {
  dir.create(cartella_output, recursive = TRUE, showWarnings = FALSE)
  message("Creata nuova directory di output: ", cartella_output)
}

if (!exists("format_date_to_int")) {
  format_date_to_int <- function(d) {
    if (is.null(d) || length(d) == 0) return(integer())
    as.integer(format(as.Date(d), "%Y%m%d"))
  }
}

# Nodi Versione per l'export.
df_nodi_Versione_export <- df_nodi_Versione %>%
  dplyr::transmute(
    `versione_id:ID(Versione)` = versione_id,
    testo_puro,
    `valido_dal:INT`           = format_date_to_int(valido_dal),
    `valido_al:INT`            = format_date_to_int(valido_al),
    stato_vigenza,
    stato_norma,
    tipo_modifica,
    `num_versione:INT`,
    `:LABEL`
  )

# Label Partizione.
if (!":LABEL" %in% names(df_nodi_Partizioni)) {
  df_nodi_Partizioni <- df_nodi_Partizioni %>% 
    dplyr::mutate(`:LABEL` = "Partizione")
}

# Scrittura CSV.
message("Scrittura dei file CSV in corso...")

readr::write_csv(df,                     file.path(cartella_output, "nodi_Legge.csv"),      na = "")
readr::write_csv(df_nodi_Partizioni,     file.path(cartella_output, "nodi_Partizioni.csv"), na = "")
readr::write_csv(df_nodi_Versione_export,file.path(cartella_output, "nodi_Versione.csv"),   na = "")
readr::write_csv(df_archi_VIGENTE,       file.path(cartella_output, "archi_VIGENTE.csv"),   na = "")
readr::write_csv(df_archi_EVOLVE_IN,     file.path(cartella_output, "archi_EVOLVE_IN.csv"), na = "")
readr::write_csv(df_archi_CITA,          file.path(cartella_output, "archi_CITA.csv"),      na = "")
readr::write_csv(df_archi_RIMANDA_A,     file.path(cartella_output, "archi_RIMANDA_A.csv"), na = "")


# 5. Report finale

message("\n=== REPORT GENERAZIONE DATASET NEO4J ===")
cat(sprintf("Nodi (:Legge)             : %d\n",   nrow(df)))
cat(sprintf("Nodi (:Partizione)        : %d\n",   nrow(df_nodi_Partizioni)))
cat(sprintf("Nodi (:Versione) grezzi   : %d\n",   nrow(df_nodi_Versione_grezzo)))
cat(sprintf("Nodi (:Versione) netti    : %d  (-%d dopo delta detection)\n\n",
            nrow(df_nodi_Versione_export),
            nrow(df_nodi_Versione_grezzo) - nrow(df_nodi_Versione_export)))

cat(sprintf("Archi [:VIGENTE]          : %d\n",   nrow(df_archi_VIGENTE)))
cat(sprintf("Archi [:EVOLVE_IN]        : %d\n",   nrow(df_archi_EVOLVE_IN)))
cat(sprintf("Archi [:CITA]             : %d\n",   nrow(df_archi_CITA)))
cat(sprintf("Archi [:RIMANDA_A]        : %d\n\n", nrow(df_archi_RIMANDA_A)))

message(sprintf("[OK] ETL Completato con successo. CSV pronti per l'ingestione massiva (neo4j-admin import) in:\n%s", cartella_output))