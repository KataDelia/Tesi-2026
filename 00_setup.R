# 00_setup.R
# Gestione dipendenze del progetto

required_packages <- unique(c(
  "here",       # gestione path relativi
  "dplyr",      # manipolazione dati
  "stringr",    # manipolazione stringhe
  "xml2",       # parsing XML/HTML
  "purrr",      # programmazione funzionale
  "httr2",      # richieste HTTP
  "pbapply",    # apply con progress bar
  "lubridate",  # gestione date
  "readr",      # importazione dati
  "digest",     # hashing
  "data.table", # manipolazione dati ad alte prestazioni
  "future",     # parallelizzazione
  "furrr",      # map parallele con purrr
  "tibble",     # tibble per build_timeline
  "memoise",    # cache in-memory per extract_akn_metadata
  "parallelly"  # rilevamento core disponibili
))

if (!requireNamespace("pak", quietly = TRUE)) install.packages("pak")

missing_packages <- setdiff(required_packages, installed.packages()[, "Package"])
if (length(missing_packages) > 0) {
  message("Installazione pacchetti mancanti: ", paste(missing_packages, collapse = ", "))
  pak::pak(missing_packages)
} else {
  message("Tutti i pacchetti sono già installati.")
}

invisible(lapply(required_packages, library, character.only = TRUE))