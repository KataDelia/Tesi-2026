# 02_master_loop.R
# Estrazione XML, costruzione nodi e archi per Neo4j.
# Richiede che 01_build_metadata.R sia stato eseguito nella stessa sessione.

source(here::here("00_setup.R"))

# Null-coalesce.
`%||%` <- function(a, b) {
  if (length(a) > 0 && !is.null(a) && !all(is.na(a))) a else b
}

# Data di riferimento per la classificazione della vigenza.
data_oggi <- as.integer(format(Sys.Date(), "%Y%m%d"))

# Pattern costanti.
PATTERN_ABROGATO_TOTALE   <- "(?i)^\\s*\\(\\s*abrogato\\s*\\)|(?i)articolo\\s+abrogato"
PATTERN_ABROGATO_PARZIALE <- "(?i)comma\\s+abrogato|(?i)lettera\\s+abrogata|(?i)parole\\s+soppresse|(?i)numero\\s+abrogato|\\(\\(\\s*abrogato\\s*\\)\\)|(?i)ha\\s+disposto.*che.*abrogato"
PATTERN_SOSTITUZIONE      <- "\\(\\("
PATTERN_INTEGRAZIONE      <- "è\\s+aggiunto|sono\\s+aggiunti|è\\s+inserito|sono\\s+inseriti"
PATTERN_PROROGA           <- "termine.*prorogato|termini.*prorogati|differito\\s+al"
PATTERN_SOSPENSIONE       <- "efficacia.*sospesa|sospeso\\s+fino\\s+al"
PATTERN_RIMANDA_ARTICOLI  <- "(?i)artt?\\.?\\s*[0-9]+(?:\\s*(?:,|e|ed)\\s*[0-9]+)*(?:\\s*[,;]\\s*comma\\s*[0-9]+)?"
PATTERN_ALLEGATO_TITOLO   <- "(?i)\\ballegat[oa]\\b(?:\\s*n\\.?\\s*[0-9A-ZIVXLCDM-]+)?"
PATTERN_NOTA_TITOLO       <- "(?i)^\\s*(nota|note)\\b"

extract_attachment_label <- function(allegato_node, text_context = "") {
  # ID del nodo allegato.
  raw_id <- xml2::xml_attr(allegato_node, "id") %||% xml2::xml_attr(allegato_node, "eId") %||% "all_generico"
  
  # Titolo con fallback sul testo del nodo.
  raw_title <- xml2::xml_attr(allegato_node, "name") %||% 
    xml2::xml_attr(allegato_node, "title") %||% 
    stringr::str_sub(stringr::str_squish(xml2::xml_text(allegato_node)), 1, 60)
  
  label_source <- raw_title
  
  # Fallback sul contesto testuale.
  if (is.na(label_source) || label_source == "") {
    label_source <- text_context
  }
  if (is.na(label_source) || label_source == "") {
    label_source <- raw_id
  }
  
  # Normalizzazione della label.
  label_source <- stringr::str_squish(label_source)
  label_source <- stringr::str_replace(label_source, PATTERN_ALLEGATO_TITOLO, "All.")
  label_source <- stringr::str_replace_all(label_source, "[\\s_]+", " ")
  label_source <- stringr::str_trim(label_source)
  
  # Prefisso per l'ID.
  prefix_source <- raw_id
  
  if ((is.na(prefix_source) || prefix_source == "" || prefix_source == "all_generico") && 
      !is.na(label_source) && label_source != "") {
    prefix_source <- stringr::str_sub(label_source, 1, 30) 
  }
  
  # Valore finale del metadato.
  list(
    raw_id    = raw_id,
    raw_title = raw_title,
    label     = stringr::str_to_title(label_source),
    prefix    = paste0(stringr::str_to_lower(stringr::str_replace_all(prefix_source, "[\\s\\-]+", "_")), "-")
  )
}

extract_article_numbers <- function(text) {
  # Gestione di input vuoti.
  if (length(text) == 0 || is.na(text)) return(character())
  
  matched <- unlist(stringr::str_extract_all(
    text, 
    "(?i)\\b(?:artt?\\.?|articoli?)\\s*([0-9]+(?:\\s*(?:,|e|ed)\\s*[0-9]+)*)"
  ))
  
  if (length(matched) == 0) return(character())
  
  digits <- stringr::str_extract_all(matched, "[0-9]+")
  unique(unlist(digits, use.names = FALSE))
}

is_note_partizione <- function(nodo_xml, testo_incipit) {
  titolo <- xml2::xml_attr(nodo_xml, "title") %||% xml2::xml_attr(nodo_xml, "name") %||% ""
  
  isTRUE(stringr::str_detect(titolo, PATTERN_NOTA_TITOLO)) || 
    isTRUE(stringr::str_detect(testo_incipit, PATTERN_NOTA_TITOLO))
}

is_allegato_partizione <- function(nodo_xml, testo_incipit) {
  titolo <- xml2::xml_attr(nodo_xml, "title") %||% xml2::xml_attr(nodo_xml, "name") %||% ""
  
  testo_safe <- ifelse(is.na(testo_incipit), "", testo_incipit)
  contesto <- paste(titolo, testo_safe, sep = " ")
  
  isTRUE(stringr::str_detect(contesto, PATTERN_ALLEGATO_TITOLO))
}

# Master loop

# Controllo di sicurezza.
if (!exists("df", envir = .GlobalEnv) || !is.data.frame(df)) {
  stop(
    "ERRORE COMPATIBILITÀ: Il dataframe 'df' non esiste nella sessione corrente o non è un dataframe valido. Assicurati di aver eseguito 01_build_metadata.R"
  )
}

n_atti <- nrow(df)

for (j in seq_len(n_atti)) {
  
  atto_corrente <- df[j, ]
  atto_urn      <- atto_corrente[["urn:ID"]]
  
  message(sprintf("\n>>> [%d/%d] Inizio elaborazione: %s",
                  j, n_atti, atto_corrente$titolo_rubrica))
  
  # Raccolta file XML.
  if (is.na(atto_corrente$cartella_codice) || atto_corrente$cartella_codice == "") {
    warning(sprintf("Path della cartella mancante per l'atto: %s", atto_corrente$titolo_rubrica), call. = FALSE)
    next
  }
  
  file_xml <- list.files(
    atto_corrente$cartella_codice,
    pattern    = "\\.xml$",
    full.names = TRUE,
    recursive  = TRUE
  )
  
  if (length(file_xml) == 0) {
    warning(sprintf("Nessun file XML trovato per l'atto: %s (Cartella: %s)", 
                    atto_corrente$titolo_rubrica, atto_corrente$cartella_codice), call. = FALSE)
    next
  }
  
  # Costruzione timeline cronologica.
  raw_timeline <- tibble::tibble(percorso_file = file_xml) %>%
    dplyr::mutate(
      nome_file       = basename(percorso_file),
      versione_id_raw = as.integer(stringr::str_extract(nome_file, "(?<=_V)[0-9]+")),
      data_iso        = stringr::str_extract(nome_file, "(?<=_VIGENZA_)[0-9]{4}-[0-9]{2}-[0-9]{2}"),
      is_originale    = stringr::str_detect(nome_file, "_ORIGINALE_")
    )
  
  timeline_df <- raw_timeline %>%
    dplyr::mutate(
      data_inizio = dplyr::case_when(
        is_originale & !is.na(atto_corrente$data_originale) ~ as.Date(atto_corrente$data_originale),
        !is.na(data_iso) ~ as.Date(data_iso), 
        TRUE ~ as.Date(NA)
      ),
      versione_id = dplyr::case_when(
        !is.na(versione_id_raw) ~ versione_id_raw,
        is_originale ~ 1L,
        TRUE ~ NA_integer_
      )
    ) %>%
    dplyr::arrange(data_inizio, versione_id)
  
  # Controllo post-parsing.
  record_corrotti <- timeline_df %>% 
    dplyr::filter(is.na(data_inizio) | is.na(versione_id))
  
  if (nrow(record_corrotti) > 0) {
    warning(sprintf("Trovati %d file malformati in %s. File ignorati: %s", 
                    nrow(record_corrotti), 
                    atto_corrente$titolo_rubrica, 
                    paste(record_corrotti$nome_file, collapse = ", ")), call. = FALSE)
  }
  
  # Filtro dei record validi.
  timeline_df <- timeline_df %>%
    dplyr::filter(!is.na(data_inizio), !is.na(versione_id))
  
  if (nrow(timeline_df) == 0) {
    warning(sprintf("Timeline vuota o corrotta dopo il filtraggio per: %s", atto_corrente$titolo_rubrica), call. = FALSE)
    next
  }
  
  n_file_timeline <- nrow(timeline_df)
  
  # Ordinamento e generazione intervalli temporali.
  timeline_df <- timeline_df %>%
    dplyr::mutate(
      id_temporaneo = stringr::str_extract(nome_file, "^.*?(?=_V[0-9]|_VIGENZA)")
    ) %>%
    dplyr::group_by(id_temporaneo) %>% 
    dplyr::arrange(data_inizio, versione_id) %>%
    dplyr::mutate(
      valido_dal = as.Date(data_inizio),
      valido_al_grezzo = dplyr::lead(valido_dal, default = as.Date("2099-12-31")) - 1,
      valido_al = pmax(valido_dal, valido_al_grezzo),
      id_versione_successiva = dplyr::lead(versione_id)
    ) %>%
    dplyr::ungroup() %>%
    dplyr::select(-valido_al_grezzo, -id_temporaneo)
  
  # Classificazione della vigenza.
  timeline_df <- timeline_df %>%
    dplyr::mutate(
      stato_vigenza = dplyr::case_when(
        valido_al == as.Date("2099-12-31") ~ "VIGENTE",
        valido_al < Sys.Date()             ~ "STORICO",
        TRUE                               ~ "VIGENTE"
      )
    )
  
  # Verifica coerenza della timeline.
  n_vigenti <- sum(timeline_df$stato_vigenza == "VIGENTE", na.rm = TRUE)
  
  if (n_vigenti == 0) {
    warning(sprintf("ANOMALIA: Nessuna versione VIGENTE trovata per l'atto: %s\nI file XML potrebbero essere incompleti o obsoleti.", 
                    atto_corrente$titolo_rubrica), call. = FALSE)
  } else if (n_vigenti > 1) {
    warning(sprintf("ANOMALIA: %d versioni VIGENTI rilevate contemporaneamente per: %s\nVerificare potenziali sovrapposizioni di date nei file di vigenza.", 
                    n_vigenti, atto_corrente$titolo_rubrica), call. = FALSE)
  }
  
  # Riepilogo dello stato temporale dell'atto.
  message(sprintf("   Timeline stabilita: %d versioni totali [Originali: %d | Vigenti: %d | Storiche: %d]",
                  nrow(timeline_df),
                  sum(timeline_df$is_originale, na.rm = TRUE),
                  n_vigenti,
                  sum(timeline_df$stato_vigenza == "STORICO", na.rm = TRUE)))
  
  # Accumulatori locali.
  
  nodi_Partizioni_list <- list()
  nodi_Versione_list   <- list()
  
  archi_VIGENTE_list   <- list()
  archi_EVOLVE_IN_list <- list()
  archi_CITA_list      <- list()
  archi_RIMANDA_A_list <- list()
 
  # Loop di estrazione XML.
  
  for (i in seq_len(n_file_timeline)) {
    
    row               <- timeline_df[i, ]
    path_singolo_file <- row$percorso_file
    
    # 3a. Parsing sicuro del file XML
    doc <- tryCatch(
      xml2::read_xml(path_singolo_file),
      error = function(e) {
        warning(sprintf("File XML non valido o corrotto, salto l'elemento: %s\nErrore: %s", 
                        row$nome_file, e$message), call. = FALSE)
        NULL
      }
    )
    
    # Chiusura pulita della condizione di fallback
    if (is.null(doc)) {
      next
    }
    
    # Rimuoviamo i namespace per semplificare drammaticamente le query XPath
    xml2::xml_ns_strip(doc)
    
    # 3b. ESTRAZIONE STRUTTURALE COMPATTA
    
    # Troviamo gli allegati per le statistiche
    allegati <- xml2::xml_find_all(doc, "//attachment")
    
    # Includi gli allegati piatti come blocchi singoli.
    tutti_nodi <- xml2::xml_find_all(doc, "//article | //section | //attachment[not(.//article or .//section)]")
    
    n_tutti_nodi <- length(tutti_nodi)
    n_allegati   <- length(allegati)
    
    message(sprintf("   [%d/%d] Elaborazione file: %s | Elementi trovati: %d | Allegati: %d",
                    i, n_file_timeline, row$nome_file, n_tutti_nodi, n_allegati))
    
    # Nessun nodo strutturale trovato.
    if (n_tutti_nodi == 0) {
      warning(sprintf("Nessun nodo strutturale (article/section/attachment) trovato in %s", row$nome_file), call. = FALSE)
      next
    }
    
    # Loop interno sulle partizioni.
    for (idx in seq_along(tutti_nodi)) {
      nodo_xml <- tutti_nodi[[idx]]
      
      tipo_partizione <- "articolo"
      tipo_label      <- "Articolo"
      id_allegato_prefisso <- ""
      
      # Estrazione del testo e dell'incipit.
      nodi_testo <- xml2::xml_find_all(nodo_xml, ".//p | .//corpo")
      testi_p    <- xml2::xml_text(nodi_testo)
      
      testo_completo <- stringr::str_squish(paste(testi_p, collapse = " "))
      
      # Fallback sul testo completo del nodo.
      if (is.na(testo_completo) || testo_completo == "") {
        testo_completo <- stringr::str_squish(xml2::xml_text(nodo_xml))
      }
      
      if (is.na(testo_completo) || nchar(testo_completo) < 5) {
        next
      }
      
      testo_incipit <- stringr::str_sub(testo_completo, 1, 100)
      testo_low     <- stringr::str_to_lower(testo_completo)
      testo_low_inc <- stringr::str_sub(testo_low, 1, 100)
      
      if (is_note_partizione(nodo_xml, testo_incipit)) {
        next
      }
      
      allegato_padre <- xml2::xml_find_first(nodo_xml, "./ancestor::attachment")
      e_dentro_allegato <- !inherits(allegato_padre, "xml_missing")
      e_sezione_allegato <- is_allegato_partizione(nodo_xml, testo_incipit)
      
      id_allegato_prefisso <- ""
      
      if (e_dentro_allegato || e_sezione_allegato) {
        allegato_meta <- if (e_dentro_allegato) {
          extract_attachment_label(allegato_padre, testo_incipit)
        } else {
          extract_attachment_label(nodo_xml, testo_incipit)
        }
        
        id_allegato_prefisso <- allegato_meta$prefix
        if (is.null(id_allegato_prefisso) || is.na(id_allegato_prefisso)) {
          id_allegato_prefisso <- ""
        }
        
        tipo_partizione <- "allegato"
        tipo_label      <- "Norma;Allegato"
      } else {
        tipo_partizione <- "articolo"
        tipo_label      <- "Norma;Articolo"
      }
    
      id_strutturale <- xml2::xml_attr(nodo_xml, "id") %||% xml2::xml_attr(nodo_xml, "eId")
      metodo_id <- "strutturale"
      
      if (isTRUE(id_strutturale != "")) {
        id_pulito <- stringr::str_replace_all(stringr::str_to_lower(id_strutturale), "[\\s\\-]+", "_")
        
        num_estratto <- stringr::str_extract(id_pulito, "\\d+(?:_[a-z]+)?")
        numero_formattato <- if (!is.na(num_estratto)) {
          paste0("Art. ", stringr::str_replace_all(num_estratto, "_", "-"))
        } else {
          id_pulito
        }
        
      } else {
        match_textual <- stringr::str_match(testo_incipit, "(?i)art(?:icolo|\\.)?\\s*(\\d+(?:-[a-z]+)?)")
        
        if (!is.na(match_textual[1, 1])) {
          metodo_id <- "testuale"
          num_art <- match_textual[1, 2]
          id_pulito <- paste0("art_", stringr::str_replace_all(num_art, "-", "_"))
          numero_formattato <- paste0("Art. ", num_art)
        } else {
          metodo_id <- "fallback"
          id_pulito <- paste0("art_", idx)
          numero_formattato <- paste0("Art. ", idx)
        }
      }
      
      id_locale <- paste0(id_allegato_prefisso, id_pulito)
      
      if (id_allegato_prefisso != "") {
        etichetta_allegato <- stringr::str_to_title(stringr::str_replace(id_allegato_prefisso, "-$", ""))
        numero_formattato <- paste0(numero_formattato, " (", etichetta_allegato, ")")
      }
      
      # Classificazione semantica e preparazione RAG.
      is_totale <- isTRUE(stringr::str_detect(testo_low_inc, PATTERN_ABROGATO_TOTALE)) || 
        (isTRUE(stringr::str_detect(testo_low, "abrogato")) && nchar(testo_completo) < 150)
      
      is_parziale <- FALSE
      if (!is_totale) {
        is_parziale <- isTRUE(stringr::str_detect(testo_low, PATTERN_ABROGATO_PARZIALE))
      }
      
      stato_norma <- dplyr::case_when(
        is_totale   ~ "ABROGATO",
        is_parziale ~ "PARZIALMENTE_ABROGATO",
        TRUE        ~ "ATTIVO"
      )
      
      testo_per_rag <- dplyr::case_when(
        is_totale ~ paste0("NORMA ABROGATA - ", stringr::str_sub(testo_completo, 1, 150)),
        TRUE      ~ testo_completo
      )
      
      # Tipo di modifica semantica.
      tipo_modifica <- dplyr::case_when(
        isTRUE(row$is_originale)                                          ~ "originale",
        is_totale | is_parziale                                           ~ "abrogazione", 
        
        isTRUE(stringr::str_detect(testo_completo, PATTERN_SOSTITUZIONE)) ~ "sostituzione",
        isTRUE(stringr::str_detect(testo_low, PATTERN_INTEGRAZIONE))      ~ "integrazione",
        isTRUE(stringr::str_detect(testo_low, PATTERN_PROROGA))           ~ "proroga",
        isTRUE(stringr::str_detect(testo_low, PATTERN_SOSPENSIONE))       ~ "sospensione",
        TRUE                                                              ~ "modificato"
      )
      
      articolo_global_id <- paste0(atto_urn, "#", id_locale)
      versione_global_id <- paste0(articolo_global_id, "_V", row$versione_id)
      
      # Nodo strutturale.
      nodi_Partizioni_list[[length(nodi_Partizioni_list) + 1]] <- list(
        `partizione_id:ID(Partizione)` = articolo_global_id,
        numero                         = numero_formattato,
        titolo_atto                    = atto_corrente$titolo_rubrica,
        atto_appartenenza              = atto_urn,
        tipo_partizione                = tipo_partizione,
        metodo_identificazione         = metodo_id,
        `:LABEL`                       = tipo_label 
      )
      
      # Nodo temporale.
      nodi_Versione_list[[length(nodi_Versione_list) + 1]] <- list(
        `versione_id:ID(Versione)` = versione_global_id,
        testo_puro                 = testo_per_rag,
        `valido_dal:DATE`          = as.character(row$valido_dal), 
        `valido_al:DATE`           = as.character(row$valido_al),  
        
        stato_temporale            = row$stato_vigenza,
        `num_versione:INT`         = as.integer(row$versione_id),
        stato_norma                = stato_norma,
        tipo_modifica              = tipo_modifica,
        `:LABEL`                   = "Versione"
      )
      
      # Archi del grafo.
      if (isTRUE(row$stato_vigenza == "VIGENTE")) {
        archi_VIGENTE_list[[length(archi_VIGENTE_list) + 1]] <- list(
          `:START_ID(Partizione)` = articolo_global_id,
          `:END_ID(Versione)`     = versione_global_id
        )
      }
      
      if (!is.na(row$id_versione_successiva)) {
        versione_successiva_id <- paste0(articolo_global_id, "_V", row$id_versione_successiva)
        archi_EVOLVE_IN_list[[length(archi_EVOLVE_IN_list) + 1]] <- list(
          `:START_ID(Versione)` = versione_global_id,
          `:END_ID(Versione)`   = versione_successiva_id
        )
      }
      
      if (tipo_partizione == "allegato") {
        match_padre <- extract_article_numbers(testo_incipit)
        
        if (length(match_padre) == 0) {
          match_padre <- extract_article_numbers(testo_completo)
        }
        
        if (length(match_padre) > 0) {
          for (num_padre in match_padre) {
            art_padre_id <- paste0(atto_urn, "#art_", num_padre)
            
            archi_RIMANDA_A_list[[length(archi_RIMANDA_A_list) + 1]] <- list(
              `:START_ID(Partizione)` = art_padre_id,
              `:END_ID(Partizione)`   = articolo_global_id
            )
          }
        }
      }
      
      # Citazioni incrociate native.
      ref_nodes  <- xml2::xml_find_all(nodo_xml, ".//ref")
      urn_citati <- xml2::xml_attr(ref_nodes, "href")
      urn_citati <- unique(stringr::str_trim(urn_citati[!is.na(urn_citati) & urn_citati != ""]))
      
      if (length(urn_citati) > 0) {
        for (urn_target in urn_citati) {
          urn_target_norm <- stringr::str_replace_all(urn_target, "~", "#")
          
          tipo_citazione <- dplyr::case_when(
            stringr::str_detect(urn_target_norm, "#")        ~ "articolo",
            stringr::str_detect(urn_target_norm, "^urn:nir") ~ "legge",
            TRUE                                             ~ "esterno"
          )
          
          archi_CITA_list[[length(archi_CITA_list) + 1]] <- list(
            `:START_ID(Versione)`   = versione_global_id,
            `:END_ID(Partizione)`   = urn_target_norm, 
            tipo_citazione          = tipo_citazione
          )
        }
      }
    }
  }
  
  # Consolidamento locale.
  
  if (length(nodi_Partizioni_list) > 0) {
    global_nodi_Partizioni <- append(global_nodi_Partizioni, nodi_Partizioni_list)
  }
  if (length(nodi_Versione_list) > 0) {
    global_nodi_Versione <- append(global_nodi_Versione, nodi_Versione_list)
  }
  if (length(archi_VIGENTE_list) > 0) {
    global_archi_VIGENTE <- append(global_archi_VIGENTE, archi_VIGENTE_list)
  }
  if (length(archi_EVOLVE_IN_list) > 0) {
    global_archi_EVOLVE_IN <- append(global_archi_EVOLVE_IN, archi_EVOLVE_IN_list)
  }
  if (length(archi_CITA_list) > 0) {
    global_archi_CITA <- append(global_archi_CITA, archi_CITA_list)
  }
  if (length(archi_RIMANDA_A_list) > 0) {
    global_archi_RIMANDA_A <- append(global_archi_RIMANDA_A, archi_RIMANDA_A_list)
  }
  
  # Log diagnostici dell'atto corrente.
  message(sprintf(
    "<<< Completato [%s]: %d partizioni | %d versioni | %d VIGENTE | %d EVOLVE | %d CITA | %d RIMANDA", 
    atto_corrente$titolo_rubrica,
    length(nodi_Partizioni_list),
    length(nodi_Versione_list),
    length(archi_VIGENTE_list),
    length(archi_EVOLVE_IN_list),
    length(archi_CITA_list),
    length(archi_RIMANDA_A_list)
  ))
  
  if (length(archi_RIMANDA_A_list) == 0 && any(timeline_df$is_originale, na.rm = TRUE)) {
    message(sprintf(
      "   Diagnostica RIMANDA_A: nessun match generato per %s. Verificare i riferimenti negli allegati.",
      atto_corrente$titolo_rubrica
    ))
  }
  
}

message("\n=== Master loop completato. Avvio consolidamento globale e deduplicazione... ===")

# Costruzione dei dataframe finali per Neo4j.

df_nodi_Partizioni <- dplyr::bind_rows(global_nodi_Partizioni) %>%
  dplyr::distinct(`partizione_id:ID(Partizione)`, .keep_all = TRUE)

df_nodi_Versione   <- dplyr::bind_rows(global_nodi_Versione) %>%
  dplyr::distinct(`versione_id:ID(Versione)`, .keep_all = TRUE)

df_archi_VIGENTE   <- dplyr::bind_rows(global_archi_VIGENTE) %>% dplyr::distinct()
df_archi_EVOLVE_IN <- dplyr::bind_rows(global_archi_EVOLVE_IN) %>% dplyr::distinct()
df_archi_CITA      <- dplyr::bind_rows(global_archi_CITA) %>% dplyr::distinct()
df_archi_RIMANDA_A <- dplyr::bind_rows(global_archi_RIMANDA_A) %>% dplyr::distinct()

message("=== Script 02 Completato con successo! ===")

