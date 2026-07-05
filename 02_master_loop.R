# 02_master_loop.R
# Parsing XML e costruzione di nodi e archi per Neo4j.

source(here::here("00_setup.R"))
source(here::here("00_functions.R"))

if (!exists("df", envir = .GlobalEnv) || !is.data.frame(df) || nrow(df) == 0) {
  stop("'df' non trovato. Eseguire prima 01_build_metadata.R")
}

# Master loop

n_atti         <- nrow(df)
output_partial <- here::here("output_neo4j", "partial")

if (dir.exists(output_partial)) unlink(output_partial, recursive = TRUE)
dir.create(output_partial, recursive = TRUE, showWarnings = FALSE)
message(sprintf("Output parziale: %s", output_partial))

scrivi_partial <- function(lista, nome, j) {
  if (length(lista) == 0) return(invisible(NULL))
  path <- file.path(output_partial, sprintf("%s_%04d.csv", nome, j))
  dplyr::bind_rows(lista) |>
    data.table::as.data.table() |>
    data.table::fwrite(path, na = "", sep = ",", quote = TRUE)
}

for (j in seq_len(n_atti)) {
  
  atto_corrente <- df[j, ]
  atto_urn      <- atto_corrente[["urn:ID"]]
  
  message(sprintf("\n>>> [%d/%d] %s", j, n_atti, atto_corrente$titolo_rubrica))
  
  # File XML
  if (is.na(atto_corrente$cartella_codice) || atto_corrente$cartella_codice == "") {
    warning(sprintf("Path mancante: %s", atto_corrente$titolo_rubrica), call. = FALSE)
    next
  }
  
  file_xml <- list.files(atto_corrente$cartella_codice,
                         pattern = "\\.xml$", full.names = TRUE, recursive = TRUE)
  if (length(file_xml) == 0) {
    warning(sprintf("Nessun XML in: %s", atto_corrente$cartella_codice), call. = FALSE)
    next
  }
  
  # Timeline
  timeline_df <- build_timeline(file_xml, atto_corrente$data_originale)
  if (nrow(timeline_df) == 0) {
    warning(sprintf("Timeline vuota: %s", atto_corrente$titolo_rubrica), call. = FALSE)
    next
  }
  
  n_vigenti <- sum(timeline_df$stato_vigenza == "VIGENTE", na.rm = TRUE)
  if (n_vigenti == 0) {
    warning(sprintf("Nessuna versione VIGENTE: %s", atto_corrente$titolo_rubrica),
            call. = FALSE)
  }
  message(sprintf("   Timeline: %d file [%d originali | %d vigenti | %d storici]",
                  nrow(timeline_df),
                  sum(timeline_df$is_originale, na.rm = TRUE),
                  n_vigenti,
                  sum(timeline_df$stato_vigenza == "STORICO", na.rm = TRUE)))
  
  # Accumulatori
  nodi_Partizioni_list  <- list()
  nodi_Versione_list    <- list()
  archi_VIGENTE_list    <- list()
  archi_EVOLVE_IN_list  <- list()
  archi_CITA_list       <- list()
  archi_CITA_ATTO_list  <- list()
  archi_RIMANDA_A_list  <- list()
  archi_APPARTIENE_list <- list()
  vigenti_visti         <- character(0)
  partizioni_viste      <- new.env(hash = TRUE, parent = emptyenv())
  
  # Loop file XML
  for (i in seq_len(nrow(timeline_df))) {
    
    row_tl <- timeline_df[i, ]
    
    doc <- tryCatch({
      d <- xml2::read_xml(row_tl$percorso_file)
      xml2::xml_ns_strip(d)
      d
    }, error = function(e) {
      warning(sprintf("XML non leggibile: %s\n  %s",
                      row_tl$nome_file, e$message), call. = FALSE)
      NULL
    })
    if (is.null(doc)) next
    
    # XPath adattivo per allegati strutturati come <doc>.
    ha_allegati <- length(xml2::xml_find_all(doc, "//attachment/doc")) > 0
    
    tutti_nodi <- if (ha_allegati) {
      xml2::xml_find_all(doc, paste0(
        "//article[not(.//article)] | ",
        "//attachment/doc"
      ))
    } else {
      xml2::xml_find_all(doc, paste0(
        "//article[not(.//article)] | ",
        "//paragraph[not(.//paragraph)][not(ancestor::article)][not(ancestor::attachment)] | ",
        "//attachment/doc"
      ))
    }
    
    if (length(tutti_nodi) == 0) {
      warning(sprintf("Nessun nodo in: %s", row_tl$nome_file), call. = FALSE)
      next
    }
    message(sprintf("   [%d/%d] %s → %d nodi",
                    i, nrow(timeline_df), row_tl$nome_file, length(tutti_nodi)))
    
    # Loop nodi
    for (idx in seq_along(tutti_nodi)) {
      nodo_xml   <- tutti_nodi[[idx]]
      e_allegato <- identical(xml2::xml_name(xml2::xml_parent(nodo_xml)), "attachment")
      
      testo_completo <- extract_testo_nodo(nodo_xml)
      if (is.na(testo_completo) || nchar(testo_completo) < 5) next
      
      testo_incipit <- stringr::str_sub(testo_completo, 1, 120)
      testo_low     <- stringr::str_to_lower(testo_completo)
      titolo_nodo   <- xml2::xml_attr(nodo_xml, "name") %||%
        xml2::xml_attr(nodo_xml, "title") %||% ""
      
      if (isTRUE(stringr::str_detect(titolo_nodo, RX_NOTA_TITOLO)) ||
          isTRUE(stringr::str_detect(testo_incipit, RX_NOTA_TITOLO))) next
      
      # Identificazione
      if (e_allegato) {
        all_meta      <- extract_allegato_meta(xml2::xml_parent(nodo_xml))
        doc_name_raw  <- xml2::xml_attr(nodo_xml, "name") %||%
          xml2::xml_attr(nodo_xml, "eId") %||% "allegato"
        id_pulito     <- paste0("all_", stringr::str_sub(
          stringr::str_to_lower(stringr::str_replace_all(doc_name_raw, "[\\s\\-]+", "_")),
          1, 60
        ))
        numero_formattato <- all_meta$label
        tipo_partizione   <- "allegato"
        tipo_label        <- "Norma;Allegato"
        metodo_id         <- "allegato"
        
      } else if (identical(xml2::xml_name(nodo_xml), "paragraph") &&
                 identical(xml2::xml_name(xml2::xml_parent(nodo_xml)), "mainBody")) {
        eId_raw       <- xml2::xml_attr(nodo_xml, "eId") %||% paste0("par_", idx)
        id_pulito     <- paste0("par_", stringr::str_to_lower(
          stringr::str_replace_all(eId_raw, "[\\s\\-]+", "_")
        ))
        numero_formattato <- paste0("Par. ", eId_raw)
        tipo_partizione   <- "paragrafo"
        tipo_label        <- "Norma;Paragrafo"
        metodo_id         <- "strutturale"
        
      } else {
        id_info           <- extract_node_id(nodo_xml, testo_incipit)
        id_pulito         <- id_info$id_pulito
        numero_formattato <- id_info$numero_formattato
        metodo_id         <- id_info$metodo_id
        tipo_partizione   <- "articolo"
        tipo_label        <- "Norma;Articolo"
      }
      
      articolo_global_id <- paste0(atto_urn, "#", id_pulito)
      versione_global_id <- paste0(articolo_global_id, "_V", row_tl$versione_id)
      
      # Classificazione
      stato_norma   <- classifica_stato_norma(testo_completo, testo_low)
      tipo_modifica <- classifica_tipo_modifica(
        testo_completo, testo_low, row_tl$is_originale, stato_norma
      )
      testo_per_rag <- if (stato_norma == "ABROGATO") {
        paste0("[NORMA ABROGATA] ", testo_completo)
      } else {
        testo_completo
      }
      
      # Nodo Partizione
      if (!exists(articolo_global_id, envir = partizioni_viste, inherits = FALSE)) {
        assign(articolo_global_id, TRUE, envir = partizioni_viste)
        
        nodi_Partizioni_list[[length(nodi_Partizioni_list) + 1]] <- list(
          `partizione_id:ID(Partizione)` = articolo_global_id,
          numero                         = numero_formattato,
          titolo_atto                    = atto_corrente$titolo_rubrica,
          atto_appartenenza              = atto_urn,
          nome_comune_atto               = atto_corrente$nome_comune  %||% NA_character_,
          codice_breve_atto              = atto_corrente$codice_breve %||% NA_character_,
          tipo_partizione                = tipo_partizione,
          metodo_identificazione         = metodo_id,
          `:LABEL`                       = tipo_label
        )
        
        archi_APPARTIENE_list[[length(archi_APPARTIENE_list) + 1]] <- list(
          `:START_ID(Partizione)` = articolo_global_id,
          `:END_ID(Legge)`        = atto_urn
        )
      }
      
      # Nodo Versione
      nodi_Versione_list[[length(nodi_Versione_list) + 1]] <- list(
        versione_id       = versione_global_id,
        testo_puro        = testo_per_rag,
        numero            = numero_formattato,
        titolo_atto       = atto_corrente$titolo_rubrica,
        nome_comune_atto  = atto_corrente$nome_comune  %||% NA_character_,
        codice_breve_atto = atto_corrente$codice_breve %||% NA_character_,
        atto_appartenenza = atto_urn,
        valido_dal        = as.integer(format(row_tl$valido_dal, "%Y%m%d")),
        valido_al         = as.integer(format(row_tl$valido_al,  "%Y%m%d")),
        stato_temporale   = row_tl$stato_vigenza,
        num_versione      = as.integer(row_tl$versione_id),
        stato_norma       = stato_norma,
        tipo_modifica     = tipo_modifica,
        `:LABEL`          = "Versione"
      )
      
      # Arco VIGENTE
      if (row_tl$stato_vigenza == "VIGENTE" &&
          !articolo_global_id %in% vigenti_visti) {
        vigenti_visti <- c(vigenti_visti, articolo_global_id)
        archi_VIGENTE_list[[length(archi_VIGENTE_list) + 1]] <- list(
          `:START_ID(Partizione)` = articolo_global_id,
          `:END_ID(Versione)`     = versione_global_id,
          valido_dal              = as.integer(format(row_tl$valido_dal, "%Y%m%d")),
          valido_al               = as.integer(format(row_tl$valido_al,  "%Y%m%d"))
        )
      }
      
      # Arco EVOLVE_IN
      if (!is.na(row_tl$id_versione_successiva)) {
        versione_succ_id <- paste0(articolo_global_id, "_V",
                                   row_tl$id_versione_successiva)
        if (versione_succ_id != versione_global_id) {
          urn_mod <- if ("urn_legge_modificante" %in% names(timeline_df)) {
            row_succ <- timeline_df[
              timeline_df$versione_id == row_tl$id_versione_successiva, ]
            if (nrow(row_succ) > 0 && !is.na(row_succ$urn_legge_modificante[1])) {
              row_succ$urn_legge_modificante[1]
            } else NA_character_
          } else NA_character_
          
          archi_EVOLVE_IN_list[[length(archi_EVOLVE_IN_list) + 1]] <- list(
            `:START_ID(Versione)` = versione_global_id,
            `:END_ID(Versione)`   = versione_succ_id,
            tipo_azione           = tipo_modifica,
            urn_legge_modificante = urn_mod
          )
        }
      }
      
      # Archi RIMANDA_A
      if (e_allegato) {
        numeri_padre <- unique(c(
          extract_article_numbers(titolo_nodo),
          extract_article_numbers(testo_incipit)
        ))
        for (num_padre in numeri_padre) {
          archi_RIMANDA_A_list[[length(archi_RIMANDA_A_list) + 1]] <- list(
            `:START_ID(Partizione)` = paste0(atto_urn, "#art_", num_padre),
            `:END_ID(Partizione)`   = articolo_global_id
          )
        }
      }
      
      # Archi CITA
      urn_citati <- unique(xml2::xml_attr(
        xml2::xml_find_all(nodo_xml, ".//ref[@href]"), "href"
      ))
      urn_citati <- urn_citati[!is.na(urn_citati) & nchar(urn_citati) > 0]
      
      for (href_raw in urn_citati) {
        urn_norm <- normalizza_href_a_urn(href_raw)
        if (is.na(urn_norm)) next
        
        if (stringr::str_detect(urn_norm, "#")) {
          archi_CITA_list[[length(archi_CITA_list) + 1]] <- list(
            `:START_ID(Versione)` = versione_global_id,
            `:END_ID(Partizione)` = urn_norm,
            tipo_citazione        = "articolo"
          )
        } else {
          archi_CITA_ATTO_list[[length(archi_CITA_ATTO_list) + 1]] <- list(
            `:START_ID(Versione)` = versione_global_id,
            `:END_ID(Legge)`      = urn_norm,
            tipo_citazione        = "legge"
          )
        }
      }
      
    }
  }
  
  # Scrittura CSV parziali
  scrivi_partial(nodi_Partizioni_list,  "nodi_Partizioni",  j)
  scrivi_partial(nodi_Versione_list,    "nodi_Versione",    j)
  scrivi_partial(archi_VIGENTE_list,    "archi_VIGENTE",    j)
  scrivi_partial(archi_EVOLVE_IN_list,  "archi_EVOLVE_IN",  j)
  scrivi_partial(archi_CITA_list,       "archi_CITA",       j)
  scrivi_partial(archi_CITA_ATTO_list,  "archi_CITA_ATTO",  j)
  scrivi_partial(archi_RIMANDA_A_list,  "archi_RIMANDA_A",  j)
  scrivi_partial(archi_APPARTIENE_list, "archi_APPARTIENE", j)
  
  n_log <- list(
    partizioni = length(nodi_Partizioni_list),
    versioni   = length(nodi_Versione_list),
    vigente    = length(archi_VIGENTE_list),
    evolve     = length(archi_EVOLVE_IN_list),
    cita       = length(archi_CITA_list),
    cita_atto  = length(archi_CITA_ATTO_list),
    rimanda    = length(archi_RIMANDA_A_list),
    appartiene = length(archi_APPARTIENE_list)
  )
  
  rm(nodi_Partizioni_list, nodi_Versione_list,
     archi_VIGENTE_list, archi_EVOLVE_IN_list,
     archi_CITA_list, archi_CITA_ATTO_list,
     archi_RIMANDA_A_list, archi_APPARTIENE_list,
     partizioni_viste, vigenti_visti)
  gc(verbose = FALSE)
  
  message(sprintf(
    "<<< %d part. | %d vers. | %d VIGENTE | %d EVOLVE | %d CITA | %d CITA_ATTO | %d RIMANDA | %d APPART.",
    n_log$partizioni, n_log$versioni, n_log$vigente, n_log$evolve,
    n_log$cita, n_log$cita_atto, n_log$rimanda, n_log$appartiene
  ))
}

# Consolidamento

message("\n=== Consolidamento CSV parziali ===")

leggi_partial <- function(prefisso, id_col = NULL) {
  files <- list.files(output_partial,
                      pattern    = paste0("^", prefisso, "_\\d+\\.csv$"),
                      full.names = TRUE)
  if (length(files) == 0) {
    message(sprintf("  Nessun file parziale: %s", prefisso))
    return(data.table::data.table())
  }
  dt <- data.table::rbindlist(
    lapply(files, data.table::fread, na.strings = ""),
    fill = TRUE, use.names = TRUE
  )
  if (!is.null(id_col) && id_col %in% names(dt)) unique(dt, by = id_col)
  else unique(dt)
}

df_nodi_Partizioni  <- as.data.frame(leggi_partial("nodi_Partizioni", "partizione_id:ID(Partizione)"))
df_nodi_Versione    <- as.data.frame(leggi_partial("nodi_Versione",   "versione_id:ID(Versione)"))
df_archi_VIGENTE    <- as.data.frame(leggi_partial("archi_VIGENTE"))
df_archi_EVOLVE_IN  <- as.data.frame(leggi_partial("archi_EVOLVE_IN"))
df_archi_CITA       <- as.data.frame(leggi_partial("archi_CITA"))
df_archi_CITA_ATTO  <- as.data.frame(leggi_partial("archi_CITA_ATTO"))
df_archi_RIMANDA_A  <- as.data.frame(leggi_partial("archi_RIMANDA_A"))
df_archi_APPARTIENE <- as.data.frame(leggi_partial("archi_APPARTIENE"))

message(sprintf(
  "\n=== Master loop completato ===\n  Partizioni  : %d\n  Versioni    : %d\n  VIGENTE     : %d\n  EVOLVE_IN   : %d\n  CITA_NORMA  : %d\n  CITA_ATTO   : %d\n  RIMANDA_A   : %d\n  APPARTIENE  : %d",
  nrow(df_nodi_Partizioni), nrow(df_nodi_Versione),
  nrow(df_archi_VIGENTE),   nrow(df_archi_EVOLVE_IN),
  nrow(df_archi_CITA),      nrow(df_archi_CITA_ATTO),
  nrow(df_archi_RIMANDA_A), nrow(df_archi_APPARTIENE)
))
