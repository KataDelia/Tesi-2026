# 0. Funzioni e costanti

source(here::here("00_setup.R"))

FOLDER_PATTERN <- "^([A-Z_ ]+)_(\\d{8})_(\\d+)$"

normalize_act_type <- function(raw_type) {
  raw_type <- stringr::str_squish(raw_type)
  raw_type <- stringr::str_replace_all(raw_type, "[_ ]+", "_")
  stringr::str_to_lower(stringr::str_replace_all(raw_type, "_", "."))
}

#' Estrae i metadati normativi dal nome di una cartella standardizzata.
#'
#' @param folder_name Nome della cartella.
#' @param folder_path Percorso completo della cartella.
#' @return Dataframe con i metadati estratti.
build_act_metadata <- function(folder_name, folder_path = NA_character_) {

  folder_name <- stringr::str_squish(folder_name)

  if (!is.na(folder_path) && !dir.exists(folder_path)) {
    warning(paste("Cartella inesistente, scartata:", folder_path), call. = FALSE)
    return(NULL)
  }
  
  # Validazione del pattern e parsing dei campi base.
  matches <- stringr::str_match(folder_name, FOLDER_PATTERN)
  if (is.na(matches[1, 1])) {
    warning(paste("Scartata cartella non conforme:", folder_name), call. = FALSE)
    return(NULL) 
  }
  
  raw_type   <- matches[1, 2]
  raw_date   <- matches[1, 3]
  act_number <- matches[1, 4]
  
  # Parsing della data.
  formatted_date <- as.Date(raw_date, format = "%Y%m%d")
  if (is.na(formatted_date)) {
    warning(paste("Data impossibile (es. 30 Febbraio) in:", folder_name), call. = FALSE)
    return(NULL)
  }
  
  # Normalizzazione del tipo di provvedimento.
  normalized_type <- normalize_act_type(raw_type)
  title_type      <- stringr::str_to_title(stringr::str_replace_all(raw_type, "[_ ]+", " "))
  
  # Ricostruzione dell'URN NIR.
  generated_urn <- paste0(
    "urn:nir:stato:", normalized_type, ":",
    format(formatted_date, "%Y-%m-%d"), ";", act_number
  )
  
  # Titolo leggibile dell'atto.
  formatted_title <- paste0(
    title_type, " n. ", act_number, " del ", format(formatted_date, "%d/%m/%Y")
  )

  # Dataframe finale con i metadati normalizzati.
  
  data.frame(
    urn_atto            = generated_urn,
    cartella_nome       = folder_name,
    cartella_codice     = folder_path,
    tipo_atto_raw       = raw_type,
    tipo_atto_norm      = normalized_type,
    numero_atto         = as.integer(act_number),
    titolo_rubrica      = formatted_title,
    data_originale      = formatted_date,
    data_da_urn         = formatted_date,
    stringsAsFactors    = FALSE
  )
}

# 1. Scansione directory

BASE_DIR <- here::here("Codici_Multivigente")

# Interruzione critica se manca l'origine dati.
if (!dir.exists(BASE_DIR)) {
  stop(
    "FATAL ERROR: Directory root non trovata: ", BASE_DIR,
    "\nVerifica che la cartella esista e che la working directory sia corretta."
  )
}

# Lettura delle cartelle presenti.
all_dirs <- setdiff(list.dirs(BASE_DIR, full.names = FALSE, recursive = FALSE), "")

# Filtro dei codici conformi al pattern atteso.
available_codes <- sort(all_dirs[stringr::str_detect(all_dirs, FOLDER_PATTERN)])

# Arresto se non esistono atti validi.
if (length(available_codes) == 0) {
  stop(
    "NESSUN ATTO TROVATO: Zero sottocartelle conformi in ", BASE_DIR)
}

# Log sintetico per le cartelle escluse.
ignored_dirs <- setdiff(all_dirs, available_codes)

if (length(ignored_dirs) > 0) {
  sample_mostrati <- head(ignored_dirs, 5)
  extra_count     <- length(ignored_dirs) - length(sample_mostrati)
  
  msg_scarti <- paste(sample_mostrati, collapse = ", ")
  if (extra_count > 0) {
    msg_scarti <- paste0(msg_scarti, " ... e altre ", extra_count, ".")
  }
  
  warning(
    sprintf(
      "Ignorate %d cartelle non conformi al pattern.\nEsempi scartati: %s", 
      length(ignored_dirs), msg_scarti
    ),
    call. = FALSE
  )
}

message(sprintf("Scansione completata: %d atti pronti per l'estrazione metadati.", length(available_codes)))

# 2. Estrazione metadati

message(sprintf("\n--- Avvio estrazione batch per %d atti normativi ---", length(available_codes)))

database_atti <- purrr::map_dfr(available_codes, function(current_folder) {
  
  # Percorso completo della cartella corrente.
  current_working_dir <- file.path(BASE_DIR, current_folder)
  
  # Estrazione dei metadati.
  build_act_metadata(
    folder_name = current_folder,
    folder_path = current_working_dir
  )
})

# Arresto se non è stato estratto alcun record.
if (nrow(database_atti) == 0) {
  stop("ERRORE CRITICO: Il processo è terminato ma nessun metadato è stato estratto validamente.")
}

message(sprintf("Estrazione completata con successo! Generati %d record validi.", nrow(database_atti)))


# 3. Output per Neo4j

cartella_output <- here::here("output", "neo4j_import")
if (!dir.exists(cartella_output)) {
  dir.create(cartella_output, recursive = TRUE)
  message("Cartella output creata: ", cartella_output)
} else {
  message("Cartella output già esistente: ", cartella_output)
}

df <- database_atti %>%
  mutate(
    `urn:ID` = urn_atto
  ) %>%
  select(
    `urn:ID`,
    titolo_rubrica,
    data_originale,
    cartella_codice
  )

message(
  sprintf("Creato il dataframe 'df' con %d record normativi.", 
          nrow(df))
)

# Contenitori globali

global_nodi_Partizioni <- list()
global_nodi_Versione   <- list()
global_archi_VIGENTE   <- list()
global_archi_EVOLVE_IN <- list()
global_archi_CITA      <- list()
global_archi_RIMANDA_A <- list()

