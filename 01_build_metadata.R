# 01_build_metadata.R
# Estrazione metadati, validazione URN e preparazione dei dataframe.

source(here::here("00_setup.R"))
source(here::here("00_functions.R"))

plan(multisession, workers = max(1L, parallelly::availableCores() - 1L))

# Scansione directory

BASE_DIR <- here::here("Codici_Multivigente")

if (!dir.exists(BASE_DIR)) {
  stop("FATAL ERROR: Directory root non trovata: ", BASE_DIR)
}

all_dirs        <- setdiff(list.dirs(BASE_DIR, full.names = FALSE, recursive = FALSE), "")
available_codes <- sort(all_dirs[stringr::str_detect(all_dirs, FOLDER_PATTERN)])
ignored_dirs    <- setdiff(all_dirs, available_codes)

if (length(available_codes) == 0) {
  stop("NESSUN ATTO TROVATO: zero sottocartelle conformi al pattern in ", BASE_DIR)
}

if (length(ignored_dirs) > 0) {
  sample_mostrati <- head(ignored_dirs, 5)
  extra_count     <- length(ignored_dirs) - length(sample_mostrati)
  msg_scarti      <- paste(sample_mostrati, collapse = ", ")
  if (extra_count > 0) {
    msg_scarti <- paste0(msg_scarti, sprintf(" ... e altre %d.", extra_count))
  }
  warning(
    sprintf("Ignorate %d cartelle non conformi al pattern.\nEsempi: %s",
            length(ignored_dirs), msg_scarti),
    call. = FALSE
  )
}

message(sprintf("Scansione completata: %d atti trovati.", length(available_codes)))

# Estrazione metadati

message(sprintf("\n--- Estrazione metadati per %d atti (parallela) ---",
                length(available_codes)))

# Cache dei file XML
tutti_xml_cached <- list.files(BASE_DIR, pattern = "\\.xml$",
                               full.names = TRUE, recursive = TRUE)

database_atti <- furrr::future_map_dfr(
  available_codes,
  function(current_folder) {
    source(here::here("00_functions.R"), local = TRUE)
    build_act_metadata(
      folder_name = current_folder,
      folder_path = file.path(BASE_DIR, current_folder)
    )
  },
  .options = furrr::furrr_options(seed = TRUE)
)

if (nrow(database_atti) == 0) {
  stop("ERRORE CRITICO: nessun metadato estratto. Verificare i nomi delle cartelle.")
}

# Pre-check XML

message(sprintf("\nPre-check integrità su %d file XML in corso...",
                length(tutti_xml_cached)))
t0_check <- proc.time()

risultati_check <- furrr::future_map_dfr(
  tutti_xml_cached,
  function(f) {
    esito <- tryCatch({
      xml2::read_xml(f)
      list(path = f, valido = TRUE, motivo = NA_character_)
    }, error = function(e) {
      list(path = f, valido = FALSE, motivo = e$message)
    })
    as.data.frame(esito, stringsAsFactors = FALSE)
  },
  .options = furrr::furrr_options(seed = TRUE)
)

df_xml_corrotti <- risultati_check[!risultati_check$valido, ]
n_corrotti      <- nrow(df_xml_corrotti)
elapsed_check   <- (proc.time() - t0_check)[["elapsed"]]

if (n_corrotti == 0) {
  message(sprintf(
    "  Pre-check completato in %.1fs: tutti i file XML sono validi.", elapsed_check
  ))
} else {
  df_xml_corrotti$atto      <- basename(dirname(df_xml_corrotti$path))
  df_xml_corrotti$nome_file <- basename(df_xml_corrotti$path)
  impatto <- table(df_xml_corrotti$atto)
  
  warning(sprintf(
    "PRE-CHECK: %d file XML non validi in %d atti.\n%s",
    n_corrotti,
    length(impatto),
    paste(sprintf("  [%s] %d file corrotti", names(impatto), as.integer(impatto)),
          collapse = "\n")
  ), call. = FALSE)
  
  output_dir <- here::here("output_neo4j")
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  
  log_path <- file.path(output_dir, "xml_corrotti.csv")
  readr::write_csv(df_xml_corrotti, log_path)
  message(sprintf("  Log salvato in: %s", log_path))
  message("  ATTENZIONE: le versioni corrispondenti mancheranno dal grafo.")
  message("  Soluzione: eliminare i file corrotti e riscaricarli da Normattiva.")
}

# Discrepanze URN

df_urn_discrepanze <- database_atti |>
  dplyr::filter(!urn_match) |>
  dplyr::select(cartella_nome, urn_da_cartella, urn_da_xml, titolo_rubrica)

n_disc <- nrow(df_urn_discrepanze)

if (n_disc > 0) {
  warning(
    sprintf(
      "ATTENZIONE: %d atti con discrepanza URN tra nome cartella e XML.\n  %s",
      n_disc,
      paste(df_urn_discrepanze$cartella_nome, collapse = "\n  ")
    ),
    call. = FALSE
  )
} else {
  message("Validazione URN: nessuna discrepanza rilevata.")
}

# Riepilogo e output

n_codici <- sum(database_atti$is_codice, na.rm = TRUE)

message(sprintf(
  "\nEstrazione completata:\n  Atti totali      : %d\n  Codici principali: %d\n  Discrepanze URN  : %d",
  nrow(database_atti), n_codici, n_disc
))

if (n_codici > 0) {
  codici_trovati <- dplyr::filter(database_atti, is_codice)
  message("\nCodici principali rilevati:")
  message(paste(
    sprintf("  [%s] %s → %s",
            codici_trovati$codice_breve,
            codici_trovati$nome_comune,
            codici_trovati$titolo_rubrica),
    collapse = "\n"
  ))
}

# Dataframe principale
df <- database_atti |>
  dplyr::mutate(`urn:ID` = urn_atto) |>
  dplyr::select(
    `urn:ID`, urn_atto, titolo_rubrica, titolo_akn, eli,
    data_originale, data_vigenza_akn,
    nome_comune, codice_breve, is_codice,
    cartella_codice
  )

# Nodi :Legge per Neo4j
df_nodi_Legge <- df |>
  dplyr::transmute(
    `urn:ID`         = `urn:ID`,
    titolo_rubrica,
    titolo_akn,
    eli,
    data_originale   = as.character(data_originale),
    data_vigenza_akn = as.character(data_vigenza_akn),
    nome_comune,
    codice_breve,
    is_codice,
    `:LABEL`         = dplyr::if_else(is_codice, "Legge;Codice", "Legge")
  )

message(sprintf("'df' pronto: %d record.", nrow(df)))
message(sprintf(
  "'df_nodi_Legge' pronto: %d record (%d con label ;Codice).",
  nrow(df_nodi_Legge), n_codici
))

# Contenitori globali

global_nodi_Partizioni <- list()
global_nodi_Versione   <- list()
global_archi_VIGENTE   <- list()
global_archi_EVOLVE_IN <- list()
global_archi_CITA      <- list()
global_archi_RIMANDA_A <- list()

plan(sequential)

message("\nContenitori globali inizializzati.")

