# 01_build_metadata.R
# Scansione delle cartelle normative, estrazione metadati da XML AKN/NIR,
# validazione URN e costruzione del dataframe degli atti (nodi :Legge).
#
# Output principali:
#   df                  → metadati base per il master loop
#   df_nodi_Legge       → nodi :Legge arricchiti per Neo4j (con AKN, ELI, alias)
#   df_urn_discrepanze  → log strutturato delle discrepanze URN (esportabile)
#   CODICI_PRINCIPALI   → whitelist degli atti principali con nome comune
#   global_nodi_*       → contenitori globali per 02_master_loop.R

source(here::here("00_setup.R"))

# 0. COSTANTI E CONFIGURAZIONE

# Pattern strutturale del nome cartella.
# Accetta maiuscole/minuscole, spazi, underscore e trattini nel tipo atto.
FOLDER_PATTERN <- "(?i)^([A-Z][A-Z_ -]+?)_(\\d{8})_(\\d+)$"

# Null-coalesce
`%||%` <- function(a, b) if (length(a) > 0 && !is.null(a) && !all(is.na(a))) a else b

# Whitelist degli atti principali (codici) con nome comune e codice breve.
CODICI_PRINCIPALI <- list(
  # Regio Decreto
  "regio.decreto:1930-10-19;1398"     = list(nome_comune = "Codice Penale",                          codice_breve = "c.p."),
  "regio.decreto:1940-10-28;1443"     = list(nome_comune = "Codice di Procedura Civile",             codice_breve = "c.p.c."),
  "regio.decreto:1930-10-19;1399"     = list(nome_comune = "Codice di Procedura Penale",             codice_breve = "c.p.p."),
  "regio.decreto:1941-02-20;303"      = list(nome_comune = "Codice Penale Militare di Guerra",       codice_breve = "c.p.m.g."),
  "regio.decreto:1941-09-09;1023"     = list(nome_comune = "Codice Penale Militare di Pace",         codice_breve = "c.p.m.p."),
  "regio.decreto:1941-12-18;1368"     = list(nome_comune = "Disposizioni attuazione c.p.c.",         codice_breve = "disp. att. c.p.c."),
  "regio.decreto:1942-03-16;262"      = list(nome_comune = "Codice Civile",                          codice_breve = "c.c."),
  "regio.decreto:1942-03-30;318"      = list(nome_comune = "Disposizioni attuazione c.c.",           codice_breve = "disp. att. c.c."),
  "regio.decreto:1942-03-30;327"      = list(nome_comune = "Codice della Navigazione",               codice_breve = "cod. nav."),
  
  # D.P.R.
  "d.p.r:1952-02-15;328"              = list(nome_comune = "Regolamento esecuzione Cod. Nav.",       codice_breve = "reg. cod. nav."),
  "d.p.r:1973-03-29;156"              = list(nome_comune = "Codice postale e telecomunicazioni",     codice_breve = "cod. post."),
  "d.p.r:1988-09-22;447"              = list(nome_comune = "Approvazione c.p.p.",                    codice_breve = "c.p.p. 1988"),
  "d.p.r:1992-12-16;495"              = list(nome_comune = "Regolamento esecuzione c.d.s.",          codice_breve = "reg. c.d.s."),
  "d.p.r:2010-10-05;207"              = list(nome_comune = "Regolamento esecuzione contratti pubbl.", codice_breve = "reg. contr. pubbl."),
  
  # Decreto Legislativo
  "decreto.legislativo:1989-07-28;271" = list(nome_comune = "Norme attuazione c.p.p.",               codice_breve = "norme att. c.p.p."),
  "decreto.legislativo:1992-04-30;285" = list(nome_comune = "Nuovo Codice della Strada",             codice_breve = "c.d.s."),
  "decreto.legislativo:1992-12-31;546" = list(nome_comune = "Disposizioni sul processo tributario",  codice_breve = "d.lgs. 546/92"),
  "decreto.legislativo:1994-02-18;29"  = list(nome_comune = "Testo Unico Impiego Pubblico",          codice_breve = "t.u.i.p."),
  "decreto.legislativo:2003-06-30;196" = list(nome_comune = "Codice della Privacy",                  codice_breve = "cod. privacy"),
  "decreto.legislativo:2003-08-01;259" = list(nome_comune = "Codice delle comunicazioni elettr.",    codice_breve = "c.c.e."),
  "decreto.legislativo:2003-09-08;269" = list(nome_comune = "Testo Unico Immigrazione",              codice_breve = "t.u.imm."),
  "decreto.legislativo:2004-01-22;42"  = list(nome_comune = "Codice dei beni culturali",             codice_breve = "cod. beni cult."),
  "decreto.legislativo:2005-02-10;30"  = list(nome_comune = "Codice della proprietà industriale",    codice_breve = "c.p.i."),
  "decreto.legislativo:2005-03-07;82"  = list(nome_comune = "Codice dell'amministrazione digitale",  codice_breve = "c.a.d."),
  "decreto.legislativo:2005-07-18;171" = list(nome_comune = "Codice della nautica da diporto",       codice_breve = "cod. nautica"),
  "decreto.legislativo:2005-09-06;206" = list(nome_comune = "Codice del consumo",                    codice_breve = "cod. consumo"),
  "decreto.legislativo:2005-09-07;209" = list(nome_comune = "Codice delle assicurazioni private",    codice_breve = "cod. ass."),
  "decreto.legislativo:2010-03-15;66"  = list(nome_comune = "Codice Ordinamento Militare",           codice_breve = "c.o.m."),
  "decreto.legislativo:2016-08-26;174" = list(nome_comune = "Codice della Giustizia Contabile",      codice_breve = "c.g.c.")
)

# 1. FUNZIONI DI SUPPORTO

#' Normalizza il tipo atto verso il formato URN NIR.
#' Es: "DECRETO LEGISLATIVO" → "decreto.legislativo"
normalize_act_type <- function(raw_type) {
  raw_type |>
    stringr::str_squish() |>
    stringr::str_replace_all("[_ -]+", ".") |>
    stringr::str_to_lower()
}

#' Valida una data in formato YYYYMMDD con controllo rigoroso.
#' Rileva casi come 19900231 che as.Date correggerebbe silenziosamente.
parse_folder_date <- function(raw_date_str) {
  d <- suppressWarnings(as.Date(raw_date_str, format = "%Y%m%d"))
  if (is.na(d)) return(NA_Date_)
  if (format(d, "%Y%m%d") != raw_date_str) return(NA_Date_)
  d
}

#' Estrae l'URN NIR dal blocco <FRBRWork> di un documento AKN.
#' Cerca <FRBRalias name="urn:nir" value="...">.
extract_urn_from_xml <- function(doc) {
  nodo <- xml2::xml_find_first(doc, "//FRBRWork/FRBRalias[@name='urn:nir']")
  if (inherits(nodo, "xml_missing")) return(NA_character_)
  stringr::str_trim(xml2::xml_attr(nodo, "value"))
}

#' Estrae i metadati AKN completi dal primo file XML valido di una cartella.
#' Restituisce una lista con: urn_xml, eli, titolo_akn, data_vigenza, data_atto
extract_akn_metadata <- function(folder_path) {
  file_xml <- list.files(folder_path, pattern = "\\.xml$",
                         full.names = TRUE, recursive = TRUE)
  if (length(file_xml) == 0) return(NULL)
  
  # File ordinati: preferisce l'originale o il più antico
  file_xml_ordinati <- sort(file_xml)
  
  for (fpath in file_xml_ordinati) {
    doc <- tryCatch({
      d <- xml2::read_xml(fpath)
      xml2::xml_ns_strip(d)
      d
    }, error = function(e) NULL)
    if (is.null(doc)) next
    
    urn_xml <- extract_urn_from_xml(doc)
    if (is.na(urn_xml)) next  # file senza meta AKN, prova il prossimo
    
    # Alias ELI
    nodo_eli <- xml2::xml_find_first(doc, "//FRBRWork/FRBRalias[@name='eli']")
    eli <- if (!inherits(nodo_eli, "xml_missing")) xml2::xml_attr(nodo_eli, "value") else NA_character_
    
    # Titolo completo
    nodo_titolo <- xml2::xml_find_first(doc, "//FRBRWork/FRBRname | //docTitle")
    titolo_akn <- if (!inherits(nodo_titolo, "xml_missing")) {
      stringr::str_squish(xml2::xml_text(nodo_titolo))
    } else NA_character_
    
    # Data entrata in vigore
    nodo_vigenza <- xml2::xml_find_first(
      doc, "//FRBRExpression/FRBRdate[@name='vigenza' or @name='entrata-in-vigore']"
    )
    data_vigenza <- if (!inherits(nodo_vigenza, "xml_missing")) {
      suppressWarnings(as.Date(xml2::xml_attr(nodo_vigenza, "date")))
    } else NA_Date_
    
    # Data atto da FRBRWork
    nodo_data_atto <- xml2::xml_find_first(doc, "//FRBRWork/FRBRdate")
    data_atto_akn <- if (!inherits(nodo_data_atto, "xml_missing")) {
      suppressWarnings(as.Date(xml2::xml_attr(nodo_data_atto, "date")))
    } else NA_Date_
    
    return(list(
      urn_xml      = urn_xml,
      eli          = eli,
      titolo_akn   = titolo_akn,
      data_vigenza = data_vigenza,
      data_atto    = data_atto_akn
    ))
  }
  
  NULL
}

#' Costruisce i metadati dell'atto dal nome cartella, arricchiti con AKN e whitelist.
build_act_metadata <- function(folder_name, folder_path = NA_character_) {
  
  folder_name <- stringr::str_squish(folder_name)
  
  if (!is.na(folder_path) && !dir.exists(folder_path)) {
    warning(paste("Cartella inesistente, scartata:", folder_path), call. = FALSE)
    return(NULL)
  }
  
  # Parsing del nome cartella 
  matches <- stringr::str_match(folder_name, FOLDER_PATTERN)
  if (is.na(matches[1, 1])) {
    warning(paste("Scartata — non conforme al pattern:", folder_name), call. = FALSE)
    return(NULL)
  }
  
  raw_type   <- matches[1, 2]
  raw_date   <- matches[1, 3]
  act_number <- matches[1, 4]
  
  formatted_date <- parse_folder_date(raw_date)
  if (is.na(formatted_date)) {
    warning(paste("Data non valida in:", folder_name), call. = FALSE)
    return(NULL)
  }
  
  normalized_type <- normalize_act_type(raw_type)
  title_type <- raw_type |>
    stringr::str_replace_all("[_ -]+", " ") |>
    stringr::str_to_title()
  
  urn_da_cartella <- paste0(
    "urn:nir:stato:", normalized_type, ":",
    format(formatted_date, "%Y-%m-%d"), ";", act_number
  )
  
  formatted_title <- paste0(
    title_type, " n. ", act_number,
    " del ", format(formatted_date, "%d/%m/%Y")
  )
  
  # Estrazione metadati AKN 
  akn <- if (!is.na(folder_path)) extract_akn_metadata(folder_path) else NULL
  
  urn_xml      <- akn$urn_xml      %||% NA_character_
  eli          <- akn$eli          %||% NA_character_
  titolo_akn   <- akn$titolo_akn   %||% NA_character_
  data_vigenza <- akn$data_vigenza %||% NA_Date_
  data_atto    <- akn$data_atto    %||% NA_Date_
  
  # Validazione URN
  urn_xml_norm      <- stringr::str_to_lower(stringr::str_trim(urn_xml))
  urn_cartella_norm <- stringr::str_to_lower(stringr::str_trim(urn_da_cartella))
  urn_match         <- is.na(urn_xml_norm) || (urn_xml_norm == urn_cartella_norm)
  
  # L'URN autoritativo è quello XML se disponibile, altrimenti quello da cartella
  urn_finale <- dplyr::coalesce(urn_xml, urn_da_cartella)
  
  # Lookup whitelist codici 
  chiave_codice <- paste0(normalized_type, ":", format(formatted_date, "%Y-%m-%d"), ";", act_number)
  info_codice   <- CODICI_PRINCIPALI[[chiave_codice]]
  nome_comune   <- info_codice$nome_comune %||% NA_character_
  codice_breve  <- info_codice$codice_breve %||% NA_character_
  is_codice     <- !is.na(nome_comune)
  
  data.frame(
    urn_atto         = urn_finale,
    urn_da_cartella  = urn_da_cartella,
    urn_da_xml       = urn_xml,
    urn_match        = urn_match,
    cartella_nome    = folder_name,
    cartella_codice  = folder_path,
    tipo_atto_raw    = raw_type,
    tipo_atto_norm   = normalized_type,
    numero_atto      = as.integer(act_number),
    titolo_rubrica   = formatted_title,
    titolo_akn       = titolo_akn,
    eli              = eli,
    data_originale   = formatted_date,
    data_atto_akn    = data_atto,
    data_vigenza_akn = data_vigenza,
    nome_comune      = nome_comune,
    codice_breve     = codice_breve,
    is_codice        = is_codice,
    stringsAsFactors = FALSE
  )
}

# 2. SCANSIONE DIRECTORY

BASE_DIR <- here::here("Codici_Multivigente")

if (!dir.exists(BASE_DIR)) {
  stop("FATAL ERROR: Directory root non trovata: ", BASE_DIR)
}

all_dirs        <- setdiff(list.dirs(BASE_DIR, full.names = FALSE, recursive = FALSE), "")
available_codes <- sort(all_dirs[stringr::str_detect(all_dirs, FOLDER_PATTERN)])
ignored_dirs    <- setdiff(all_dirs, available_codes)

if (length(available_codes) == 0) {
  stop("NESSUN ATTO TROVATO: Zero sottocartelle conformi al pattern in ", BASE_DIR)
}

if (length(ignored_dirs) > 0) {
  sample_mostrati <- head(ignored_dirs, 5)
  extra_count     <- length(ignored_dirs) - length(sample_mostrati)
  msg_scarti      <- paste(sample_mostrati, collapse = ", ")
  if (extra_count > 0) msg_scarti <- paste0(msg_scarti, " ... e altre ", extra_count, ".")
  warning(sprintf("Ignorate %d cartelle non conformi.\nEsempi: %s", length(ignored_dirs), msg_scarti),
          call. = FALSE)
}

message(sprintf("Scansione completata: %d atti trovati.", length(available_codes)))

# 3. ESTRAZIONE METADATI

message(sprintf("\n--- Estrazione metadati per %d atti ---", length(available_codes)))

database_atti <- purrr::map_dfr(available_codes, function(current_folder) {
  build_act_metadata(
    folder_name = current_folder,
    folder_path = file.path(BASE_DIR, current_folder)
  )
})

if (nrow(database_atti) == 0) {
  stop("ERRORE CRITICO: Nessun metadato estratto. Verifica i nomi delle cartelle.")
}

# 4. LOG DISCREPANZE URN

df_urn_discrepanze <- database_atti |>
  dplyr::filter(!urn_match) |>
  dplyr::select(cartella_nome, urn_da_cartella, urn_da_xml, titolo_rubrica)

n_disc <- nrow(df_urn_discrepanze)

if (n_disc > 0) {
  warning(
    sprintf("ATTENZIONE: %d atti con discrepanza URN tra nome cartella e XML.\n  %s",
            n_disc, paste(df_urn_discrepanze$cartella_nome, collapse = "\n  ")),
    call. = FALSE
  )
} else {
  message("Validazione URN: nessuna discrepanza rilevata.")
}

# 5. RIEPILOGO E PREPARAZIONE OUTPUT

n_codici <- sum(database_atti$is_codice, na.rm = TRUE)

message(sprintf(
  "\nEstrazione completata:\n  Atti totali      : %d\n  Codici principali: %d\n  Discrepanze URN  : %d",
  nrow(database_atti), n_codici, n_disc
))

if (n_codici > 0) {
  message("\nCodici principali rilevati:")
  database_atti |>
    dplyr::filter(is_codice) |>
    purrr::pwalk(function(nome_comune, codice_breve, titolo_rubrica, ...) {
      message(sprintf("  [%s] %s → %s", codice_breve, nome_comune, titolo_rubrica))
    })
}

# Dataframe principale per 02_master_loop.R
df <- database_atti |>
  dplyr::mutate(`urn:ID` = urn_atto) |>
  dplyr::select(
    `urn:ID`, urn_atto, titolo_rubrica, titolo_akn, eli,
    data_originale, data_vigenza_akn,
    nome_comune, codice_breve, is_codice,
    cartella_codice
  )

# Nodi :Legge arricchiti per Neo4j (usati in 03_export_neo4j.R)
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
message(sprintf("'df_nodi_Legge' pronto: %d record (%d con label ;Codice).", nrow(df_nodi_Legge), n_codici))

# 6. INIZIALIZZAZIONE CONTENITORI GLOBALI

global_nodi_Partizioni <- list()
global_nodi_Versione   <- list()
global_archi_VIGENTE   <- list()
global_archi_EVOLVE_IN <- list()
global_archi_CITA      <- list()
global_archi_RIMANDA_A <- list()

message("\nContenitori globali inizializzati. Pronto per 02_master_loop.R")
