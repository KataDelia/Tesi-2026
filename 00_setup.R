required_packages <- c(
  "here",
  "dplyr",
  "stringr",
  "xml2",
  "purrr",
  "httr2",
  "pbapply",
  "lubridate",
  "purrr",
  "readr")

# Installa solo quelli non ancora presenti
missing_packages <- required_packages[
  !required_packages %in% installed.packages()[, "Package"]
]

if (length(missing_packages) > 0) {
  message("Installazione pacchetti mancanti: ", paste(missing_packages, collapse = ", "))
  install.packages(missing_packages, dependencies = TRUE)
} else {
  message("Tutti i pacchetti sono già installati.")
}

# Caricamento
invisible(lapply(required_packages, library, character.only = TRUE))