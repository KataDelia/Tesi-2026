# 02_master_loop.R
# Estrazione XML, costruzione nodi e archi per Neo4j.
# Richiede che 01_build_metadata.R sia stato eseguito nella stessa sessione.
#
# Output principali:
#   df_nodi_Partizioni   → nodi strutturali (articoli, allegati)
#   df_nodi_Versione     → snapshot testuali con intervalli temporali
#   df_archi_VIGENTE     → Partizione -[:VIGENTE]-> Versione corrente
#   df_archi_EVOLVE_IN   → Versione -[:EVOLVE_IN]-> Versione successiva
#   df_archi_CITA        → Versione -[:CITA]-> Partizione citata
#   df_archi_RIMANDA_A   → Partizione -[:RIMANDA_A]-> Allegato
#   df_archi_APPARTIENE  → Partizione -[:APPARTIENE_A]-> Legge

source(here::here("00_setup.R"))

# ══════════════════════════════════════════════════════════════════════════════
# 0. GUARDIE E COSTANTI
# ══════════════════════════════════════════════════════════════════════════════

if (!exists("df", envir = .GlobalEnv) || !is.data.frame(df) || nrow(df) == 0) {
  stop("ERRORE: 'df' non trovato o vuoto. Esegui prima 01_build_metadata.R")
}

`%||%` <- function(a, b) if (length(a) > 0 && !is.null(a) && !all(is.na(a))) a else b

DATA_FINE_DEFAULT <- as.Date("9999-12-31")
DATA_INIZIO_MIN   <- as.Date("1900-01-01")

# Pattern semantici per la classificazione delle norme
PATTERN_ABROGATO_TOTALE   <- "(?i)^\\s*\\(\\s*abrogato\\s*\\)|(?i)^\\s*articolo\\s+abrogato"
PATTERN_ABROGATO_PARZIALE <- paste0(
  "(?i)comma\\s+abrogato|lettera\\s+abrogata|parole\\s+soppresse|",
  "numero\\s+abrogato|\\(\\(\\s*abrogato\\s*\\)\\)|ha\\s+disposto.*che.*abrogato"
)
PATTERN_SOLO_ABROGATO     <- "(?i)^\\s*\\(?abrogat[oa]\\)?\\s*\\.?\\s*$"
PATTERN_SOSTITUZIONE      <- "\\(\\("
PATTERN_INTEGRAZIONE      <- "(?i)è\\s+aggiunto|sono\\s+aggiunti|è\\s+inserito|sono\\s+inseriti"
PATTERN_PROROGA           <- "(?i)termine.*prorogato|termini.*prorogati|differito\\s+al"
PATTERN_SOSPENSIONE       <- "(?i)efficacia.*sospesa|sospeso\\s+fino\\s+al"
PATTERN_NOTA_TITOLO       <- "(?i)^\\s*(nota|note)\\b"

# ══════════════════════════════════════════════════════════════════════════════
# 1. FUNZIONI DI SUPPORTO
# ══════════════════════════════════════════════════════════════════════════════

# ── 1a. Timeline ──────────────────────────────────────────────────────────────

#' Costruisce la timeline cronologica dei file XML di un atto.
#' Ogni file rappresenta uno snapshot completo dell'atto in una data.
#' Il grouping è sull'atto intero, non per articolo: ogni articolo eredita
#' la finestra temporale del file XML che lo contiene.
#'
#' @param file_xml Vettore di percorsi file XML.
#' @param data_originale Data dell'atto (usata per i file ORIGINALE).
#' @return Tibble ordinato con colonne: percorso_file, nome_file, versione_id,
#'         valido_dal, valido_al, is_originale, stato_vigenza.
build_timeline <- function(file_xml, data_originale) {
  
  tl <- tibble::tibble(percorso_file = file_xml) |>
    dplyr::mutate(
      nome_file       = basename(percorso_file),
      is_originale    = stringr::str_detect(nome_file, "_ORIGINALE_"),
      versione_id_raw = suppressWarnings(
        as.integer(stringr::str_extract(nome_file, "(?<=_V)[0-9]+"))
      ),
      data_iso        = stringr::str_extract(
        nome_file, "(?<=_VIGENZA_)[0-9]{4}-[0-9]{2}-[0-9]{2}"
      ),
      data_inizio = dplyr::case_when(
        is_originale & !is.na(data_originale) ~ as.Date(data_originale),
        !is.na(data_iso)                       ~ as.Date(data_iso),
        TRUE                                   ~ as.Date(NA)
      ),
      versione_id = dplyr::case_when(
        !is.na(versione_id_raw) ~ versione_id_raw,
        is_originale            ~ 1L,
        TRUE                    ~ NA_integer_
      )
    )
  
  # Log file malformati
  malformati <- tl |> dplyr::filter(is.na(data_inizio) | is.na(versione_id))
  if (nrow(malformati) > 0) {
    warning(sprintf("  %d file malformati ignorati: %s",
                    nrow(malformati),
                    paste(malformati$nome_file, collapse = ", ")), call. = FALSE)
  }
  
  tl <- tl |>
    dplyr::filter(!is.na(data_inizio), !is.na(versione_id)) |>
    dplyr::arrange(data_inizio, versione_id) |>
    # Deduplicazione: se due file hanno stessa data e versione, tieni il primo
    dplyr::distinct(data_inizio, versione_id, .keep_all = TRUE) |>
    dplyr::mutate(
      valido_dal = as.Date(data_inizio),
      # valido_al = giorno prima dell'inizio della versione successiva
      # FIX rispetto all'originale: nessun group_by per articolo qui —
      # la finestra temporale è proprietà del FILE, non dell'articolo.
      valido_al  = dplyr::lead(valido_dal, default = DATA_FINE_DEFAULT) - 1,
      valido_al  = pmax(valido_dal, valido_al),   # evita date negative
      id_versione_successiva = dplyr::lead(versione_id),
      stato_vigenza = dplyr::case_when(
        valido_al >= DATA_FINE_DEFAULT - 1 ~ "VIGENTE",
        valido_al < Sys.Date()             ~ "STORICO",
        TRUE                               ~ "VIGENTE"
      )
    )
  
  tl
}

# ── 1b. Estrazione ID articolo ────────────────────────────────────────────────

#' Estrae un ID stabile per un nodo strutturale AKN.
#' Priorità: (1) attributo eId/id strutturale, (2) numero nel testo, (3) hash incipit.
#' FIX rispetto all'originale: rimosso fallback su idx (posizionale e instabile).
#'
#' @return Lista con: id_pulito, numero_formattato, metodo_id
extract_node_id <- function(nodo_xml, testo_incipit, idx_fallback) {
  
  # (1) ID strutturale AKN (eId è lo standard AKN, id è il legacy NIR)
  id_strutturale <- xml2::xml_attr(nodo_xml, "eId") %||% xml2::xml_attr(nodo_xml, "id")
  
  if (!is.na(id_strutturale) && nchar(stringr::str_trim(id_strutturale)) > 0) {
    id_pulito <- id_strutturale |>
      stringr::str_to_lower() |>
      stringr::str_replace_all("[\\s\\-]+", "_") |>
      stringr::str_trim()
    
    num_estratto <- stringr::str_extract(id_pulito, "\\d+(?:_[a-z]+)?")
    numero_formattato <- if (!is.na(num_estratto)) {
      paste0("Art. ", stringr::str_replace_all(num_estratto, "_", "-"))
    } else {
      id_pulito
    }
    return(list(id_pulito = id_pulito, numero_formattato = numero_formattato, metodo_id = "strutturale"))
  }
  
  # (2a) Numero articolo dal testo incipit (formato standard)
  match_textual <- stringr::str_match(
    testo_incipit,
    "(?i)art(?:icolo|\\.)?\\s*(\\d+(?:[\\-\\.][a-z0-9]+)?)"
  )
  if (!is.na(match_textual[1, 1])) {
    num_art <- match_textual[1, 2]
    id_pulito <- paste0("art_", stringr::str_replace_all(num_art, "[\\-\\.]", "_"))
    return(list(
      id_pulito         = id_pulito,
      numero_formattato = paste0("Art. ", num_art),
      metodo_id         = "testuale"
    ))
  }
  
  # (2b) Numero disposizione dal testo incipit (formato disposizioni att.)
  # Es: "1." / "1-bis." all'inizio del paragrafo
  match_disp <- stringr::str_match(
    stringr::str_trim(testo_incipit),
    "^(\\d+(?:[\\-][a-z]+)?)\\.?"
  )
  if (!is.na(match_disp[1, 1])) {
    num_disp  <- match_disp[1, 2]
    id_pulito <- paste0("disp_", stringr::str_replace_all(num_disp, "-", "_"))
    return(list(
      id_pulito         = id_pulito,
      numero_formattato = paste0("Disp. ", num_disp),
      metodo_id         = "testuale_disp"
    ))
  }
  
  # (3) Fallback: hash deterministico dell'incipit (stabile tra versioni)
  # FIX: non più posizionale (idx) ma basato sul contenuto
  hash_incipit <- substr(digest::digest(testo_incipit, algo = "crc32"), 1, 8)
  list(
    id_pulito         = paste0("art_hash_", hash_incipit),
    numero_formattato = paste0("Art. [", hash_incipit, "]"),
    metodo_id         = "hash"
  )
}

# ── 1c. Metadati allegato ─────────────────────────────────────────────────────

#' Estrae i metadati di un allegato leggendo prima la meta AKN del <doc> figlio,
#' con fallback sugli attributi del tag <attachment>.
#' FIX rispetto all'originale: legge title dal <doc name="..."> e dalla meta AKN.
extract_allegato_meta <- function(attachment_node) {
  
  # Il <doc> figlio diretto contiene il titolo nell'attributo name
  doc_node  <- xml2::xml_find_first(attachment_node, "./doc")
  doc_name  <- if (!inherits(doc_node, "xml_missing")) {
    xml2::xml_attr(doc_node, "name") %||% ""
  } else ""
  
  # URN proprio dell'allegato dalla meta AKN del <doc>
  urn_allegato <- if (!inherits(doc_node, "xml_missing")) {
    n <- xml2::xml_find_first(doc_node, ".//FRBRWork/FRBRalias[@name='urn:nir']")
    if (!inherits(n, "xml_missing")) xml2::xml_attr(n, "value") else NA_character_
  } else NA_character_
  
  # ID dal tag <attachment> stesso
  raw_id <- xml2::xml_attr(attachment_node, "eId") %||%
    xml2::xml_attr(attachment_node, "id") %||%
    "all_generico"
  
  # Label finale: preferisce il nome del <doc>, poi l'id strutturale
  label_raw <- if (nchar(doc_name) > 0) doc_name else raw_id
  label_raw <- stringr::str_squish(label_raw)
  label_clean <- stringr::str_sub(label_raw, 1, 80)
  
  # Prefisso per gli ID delle partizioni figlie
  prefix <- paste0(
    stringr::str_to_lower(
      stringr::str_replace_all(
        stringr::str_sub(raw_id, 1, 30), "[\\s\\-]+", "_"
      )
    ), "-"
  )
  
  list(
    raw_id       = raw_id,
    urn_allegato = urn_allegato,
    label        = stringr::str_to_title(label_clean),
    prefix       = prefix
  )
}

# ── 1d. Classificazione semantica ─────────────────────────────────────────────

#' Classifica lo stato di abrogazione di una norma dal testo.
#' FIX rispetto all'originale: separata la condizione "solo abrogato" (testo
#' brevissimo che contiene SOLO la parola abrogato) dalla ricerca generica
#' per evitare falsi positivi su articoli che *disciplinano* abrogazioni.
classifica_stato_norma <- function(testo_completo, testo_low) {
  
  # Abrogazione totale: il testo È la parola "abrogato" (con eventuale punteggiatura)
  is_solo_abrogato <- isTRUE(stringr::str_detect(testo_completo, PATTERN_SOLO_ABROGATO))
  
  # Abrogazione totale: incipit esplicito standard NIR
  is_incipit_abrogato <- isTRUE(stringr::str_detect(
    stringr::str_sub(testo_low, 1, 80), PATTERN_ABROGATO_TOTALE
  ))
  
  is_totale <- is_solo_abrogato || is_incipit_abrogato
  
  is_parziale <- if (is_totale) FALSE else {
    isTRUE(stringr::str_detect(testo_low, PATTERN_ABROGATO_PARZIALE))
  }
  
  dplyr::case_when(
    is_totale   ~ "ABROGATO",
    is_parziale ~ "PARZIALMENTE_ABROGATO",
    TRUE        ~ "ATTIVO"
  )
}

#' Classifica il tipo di modifica di una versione.
classifica_tipo_modifica <- function(testo_completo, testo_low, is_originale, stato_norma) {
  dplyr::case_when(
    isTRUE(is_originale)                                              ~ "originale",
    stato_norma %in% c("ABROGATO", "PARZIALMENTE_ABROGATO")          ~ "abrogazione",
    isTRUE(stringr::str_detect(testo_completo, PATTERN_SOSTITUZIONE)) ~ "sostituzione",
    isTRUE(stringr::str_detect(testo_low, PATTERN_INTEGRAZIONE))      ~ "integrazione",
    isTRUE(stringr::str_detect(testo_low, PATTERN_PROROGA))           ~ "proroga",
    isTRUE(stringr::str_detect(testo_low, PATTERN_SOSPENSIONE))       ~ "sospensione",
    TRUE                                                              ~ "modificato"
  )
}

# ── 1e. Estrazione numeri articolo da testo libero ───────────────────────────

#' Estrae i numeri di articolo citati in un testo libero.
#' Es: "artt. 3, 5 e 7" → c("3", "5", "7")
#' Nota: richiede il package digest (aggiungere in 00_setup.R se mancante).
extract_article_numbers <- function(text) {
  if (length(text) == 0 || is.na(text) || nchar(text) == 0) return(character())
  
  matched <- unlist(stringr::str_extract_all(
    text,
    "(?i)\\b(?:artt?\\.?|articoli?)\\s*([0-9]+(?:\\s*(?:,|e|ed)\\s*[0-9]+)*)"
  ))
  if (length(matched) == 0) return(character())
  
  digits <- stringr::str_extract_all(matched, "[0-9]+")
  unique(unlist(digits, use.names = FALSE))
}

# ── 1f. Normalizzazione URN citati ────────────────────────────────────────────

#' Normalizza un href AKN verso il formato urn:nir usato come ID nel grafo.
#' I <ref href> in AKN usano percorsi /akn/it/act/... o urn:nir direttamente.
#' FIX rispetto all'originale: la semplice sostituzione ~ → # produceva
#' ID che non esistevano nel grafo. Ora si tenta la conversione completa.
normalizza_href_a_urn <- function(href) {
  href <- stringr::str_trim(href)
  if (is.na(href) || href == "") return(NA_character_)
  
  # Normalizza separatore ~ → #
  href <- stringr::str_replace_all(href, "~", "#")
  
  # Separa base URN dal frammento (tutto ciò che segue #)
  parti    <- stringr::str_split_fixed(href, "#", 2)
  urn_base <- stringr::str_trim(parti[1, 1])
  frammento <- stringr::str_trim(parti[1, 2])
  
  # ── Normalizzazione tipo atto ──────────────────────────────────────────────
  # Converte camelCase → dot.case e alias nome comune → tipo NIR standard
  # Es: "decretoLegislativo" → "decreto.legislativo"
  #     "codice.civile"      → "regio.decreto" (via alias)
  ALIAS_TIPO <- c(
    "decretolegislativo"                       = "decreto.legislativo",
    "declegg"                                  = "decreto.legislativo",
    "decretolegge"                             = "decreto.legge",
    "decleg"                                   = "decreto.legge",
    "legge"                                    = "legge",
    "regiodecreto"                             = "regio.decreto",
    "codice.civile"                            = "regio.decreto",
    "codicecivile"                             = "regio.decreto",
    "codice.penale"                            = "regio.decreto",
    "codicepenale"                             = "regio.decreto",
    "codice.navigazione"                       = "regio.decreto",
    "codicenavigazione"                        = "regio.decreto",
    "codice.procedura.civile"                  = "regio.decreto",
    "codiceproceduraciville"                   = "regio.decreto",
    "codice.procedura.penale"                  = "regio.decreto",
    "codiceprocedurapenale"                    = "regio.decreto",
    "decretodelPresidentedellaRepubblica"      = "decreto.del.presidente.della.repubblica",
    "decretodelpresidenredellarepubblica"      = "decreto.del.presidente.della.repubblica",
    "dpr"                                      = "decreto.del.presidente.della.repubblica",
    "decretoministeriare"                      = "decreto.ministeriale",
    "decretoминisteriаle"                      = "decreto.ministeriale",
    "dm"                                       = "decreto.ministeriale",
    "direttiva.ue"                             = "direttiva.ue",
    "direttivaue"                              = "direttiva.ue",
    "direttiva.ce"                             = "direttiva.ue",
    "direttivace"                              = "direttiva.ue"
  )
  
  normalizza_tipo <- function(tipo_raw) {
    # camelCase → dot.case
    tipo_dot    <- gsub("([a-z])([A-Z])", "\\1.\\2", tipo_raw)
    tipo_low    <- tolower(tipo_dot)
    tipo_no_sep <- tolower(gsub("[._\\-]", "", tipo_raw))
    tipo_orig   <- tolower(tipo_raw)
    
    # Lookup sicura: restituisce NULL se la chiave non esiste
    lookup <- function(k) {
      v <- ALIAS_TIPO[k]   # [ singolo ritorna lista con NA se assente
      if (length(v) == 1 && !is.na(names(v)) && !is.na(v[[1]])) v[[1]] else NULL
    }
    
    lookup(tipo_low) %||%
      lookup(tipo_no_sep) %||%
      lookup(tipo_orig) %||%
      tipo_low
  }
  
  # ── Normalizzazione frammento ──────────────────────────────────────────────
  normalizza_frammento <- function(f) {
    if (is.na(f) || f == "") return("")
    
    f_low <- stringr::str_to_lower(stringr::str_squish(f))
    
    # Frammento "main" o "!main" → documento intero, nessun frammento
    if (f_low %in% c("main", "!main", "")) return("")
    
    # Caso 1: contiene "art" seguito da numero
    m_art <- stringr::str_match(
      f_low,
      "art(?:icolo)?[\\._]?\\s*([0-9]+(?:[_\\.\\-][a-z0-9]+)?)"
    )
    if (!is.na(m_art[1, 2])) {
      num <- stringr::str_replace_all(m_art[1, 2], "[.\\-]", "_")
      return(paste0("art_", num))
    }
    
    # Caso 2: contiene "allegat"
    m_all <- stringr::str_match(f_low, "allegat[oa]?[\\._\\s]?([0-9a-z._\\-]*)")
    if (!is.na(m_all[1, 1])) {
      suf <- stringr::str_trim(m_all[1, 2] %||% "")
      suf <- stringr::str_replace_all(suf, "[.\\-\\s]+", "_")
      suf <- stringr::str_replace_all(suf, "_+", "_")
      suf <- stringr::str_remove_all(suf, "^_|_$")
      return(paste0("allegato", if (nchar(suf) > 0) paste0("_", suf) else ""))
    }
    
    # Caso 3: già formato pulito
    if (stringr::str_detect(f_low, "^[a-z][a-z0-9_]*$")) return(f_low)
    
    # Caso 4: generico
    f_low |>
      stringr::str_replace_all("[\\s\\.]+", "_") |>
      stringr::str_replace_all("[^a-z0-9_]", "") |>
      stringr::str_replace_all("_+", "_") |>
      stringr::str_remove_all("^_|_$")
  }
  
  # ── Branch: già in formato urn:nir ────────────────────────────────────────
  if (stringr::str_starts(urn_base, "urn:nir")) {
    
    # Estrai e normalizza il tipo dall'URN
    # Formato: urn:nir:<giurisdizione>:<tipo>:<data>;<numero>
    m_urn <- stringr::str_match(
      urn_base,
      "^(urn:nir:[^:]+):([^:]+):([^;]+);(.+)$"
    )
    if (!is.na(m_urn[1, 1])) {
      prefisso <- m_urn[1, 2]   # "urn:nir:stato"
      tipo_raw <- m_urn[1, 3]
      data_raw <- m_urn[1, 4]
      numero   <- m_urn[1, 5]
      
      tipo_norm <- normalizza_tipo(tipo_raw)
      urn_norm  <- paste0(prefisso, ":", tipo_norm, ":", data_raw, ";", numero)
      
      frag_norm <- normalizza_frammento(frammento)
      if (nchar(frag_norm) > 0) return(paste0(urn_norm, "#", frag_norm))
      return(urn_norm)
    }
    
    # URN malformato: restituisce così com'è
    return(urn_base)
  }
  
  # ── Branch: formato /akn/it/act/... ───────────────────────────────────────
  # Gestisce sia date complete (2016-08-26) che parziali (solo anno: 2017)
  m_akn <- stringr::str_match(
    urn_base,
    "^/akn/[^/]+/act/([^/]+)/([^/]+)/([0-9]{4}(?:-[0-9]{2}-[0-9]{2})?)/([^/!#]+)(?:[/!](.+))?$"
  )
  
  if (!is.na(m_akn[1, 1])) {
    tipo_raw   <- m_akn[1, 2]
    # giurisdizione m_akn[1,3] ignorata nell'URN NIR
    data_raw   <- m_akn[1, 4]   # può essere "2017" o "2017-03-15"
    numero     <- m_akn[1, 5]
    parte      <- m_akn[1, 6] %||% ""
    
    tipo_norm       <- normalizza_tipo(tipo_raw)
    urn_ricostruito <- paste0("urn:nir:stato:", tipo_norm, ":", data_raw, ";", numero)
    
    frag_candidato <- if (nchar(frammento) > 0) frammento else {
      stringr::str_remove(parte, "^!?main/?")
    }
    frag_norm <- normalizza_frammento(frag_candidato)
    
    if (nchar(frag_norm) > 0) return(paste0(urn_ricostruito, "#", frag_norm))
    return(urn_ricostruito)
  }
  
  # Formato non riconosciuto
  href
}

# ── 1g. Estrazione testo nodo ─────────────────────────────────────────────────

#' Estrae il testo di un nodo AKN privilegiando i tag semantici (<p>, <content>)
#' rispetto all'estrazione grezza di tutto il testo del nodo.
extract_testo_nodo <- function(nodo_xml) {
  # Tag semantici AKN in ordine di preferenza
  nodi_testo <- xml2::xml_find_all(nodo_xml, ".//p | .//content | .//intro | .//wrap")
  testi      <- xml2::xml_text(nodi_testo)
  testo      <- stringr::str_squish(paste(testi[nchar(testi) > 0], collapse = " "))
  
  # Fallback sul testo grezzo del nodo
  if (is.na(testo) || nchar(testo) < 5) {
    testo <- stringr::str_squish(xml2::xml_text(nodo_xml))
  }
  
  # Limite caratteri: nessuna norma utile supera 10k caratteri
  # Riduce memoria e velocizza il parsing su nodi molto grandi
  if (!is.na(testo) && nchar(testo) > 10000) {
    testo <- stringr::str_sub(testo, 1, 10000)
  }
  
  testo
}

# ══════════════════════════════════════════════════════════════════════════════
# 2. MASTER LOOP
# ══════════════════════════════════════════════════════════════════════════════

n_atti <- nrow(df)

# Strategia memory-safe: scrivi CSV parziali per atto invece di accumulare in RAM.
# Evita swap su dataset grandi (Codice Civile + tutti i codici > 10GB RAM con accumulo).
output_partial <- here::here("output_neo4j", "partial")
if (dir.exists(output_partial)) {
  unlink(output_partial, recursive = TRUE)  # pulizia run precedenti
}
dir.create(output_partial, recursive = TRUE, showWarnings = FALSE)
message(sprintf("Cartella output parziale: %s", output_partial))

# Funzione helper: scrivi lista come CSV parziale se non vuota
scrivi_partial <- function(lista, nome, j) {
  if (length(lista) == 0) return(invisible(NULL))
  path <- file.path(output_partial, sprintf("%s_%04d.csv", nome, j))
  dplyr::bind_rows(lista) |>
    data.table::as.data.table() |>
    data.table::fwrite(path, na = "")
}

for (j in seq_len(n_atti)) {
  
  atto_corrente <- df[j, ]
  atto_urn      <- atto_corrente[["urn:ID"]]
  
  message(sprintf("\n>>> [%d/%d] %s", j, n_atti, atto_corrente$titolo_rubrica))
  
  # ── Raccolta file XML ──────────────────────────────────────────────────────
  if (is.na(atto_corrente$cartella_codice) || atto_corrente$cartella_codice == "") {
    warning(sprintf("Path mancante per: %s", atto_corrente$titolo_rubrica), call. = FALSE)
    next
  }
  
  file_xml <- list.files(atto_corrente$cartella_codice,
                         pattern = "\\.xml$", full.names = TRUE, recursive = TRUE)
  if (length(file_xml) == 0) {
    warning(sprintf("Nessun XML in: %s", atto_corrente$cartella_codice), call. = FALSE)
    next
  }
  
  # ── Timeline ───────────────────────────────────────────────────────────────
  timeline_df <- build_timeline(file_xml, atto_corrente$data_originale)
  
  if (nrow(timeline_df) == 0) {
    warning(sprintf("Timeline vuota per: %s", atto_corrente$titolo_rubrica), call. = FALSE)
    next
  }
  
  n_vigenti <- sum(timeline_df$stato_vigenza == "VIGENTE", na.rm = TRUE)
  if (n_vigenti == 0) {
    warning(sprintf("Nessuna versione VIGENTE per: %s", atto_corrente$titolo_rubrica), call. = FALSE)
  } else if (n_vigenti > 1) {
    warning(sprintf("%d versioni VIGENTI sovrapposte per: %s", n_vigenti, atto_corrente$titolo_rubrica), call. = FALSE)
  }
  
  message(sprintf("   Timeline: %d file [%d originali | %d vigenti | %d storici]",
                  nrow(timeline_df),
                  sum(timeline_df$is_originale, na.rm = TRUE),
                  n_vigenti,
                  sum(timeline_df$stato_vigenza == "STORICO", na.rm = TRUE)))
  
  # ── Accumulatori locali per questo atto ───────────────────────────────────
  nodi_Partizioni_list  <- list()
  nodi_Versione_list    <- list()
  archi_VIGENTE_list    <- list()
  archi_EVOLVE_IN_list  <- list()
  archi_CITA_list       <- list()
  archi_CITA_ATTO_list  <- list()
  archi_RIMANDA_A_list  <- list()
  archi_APPARTIENE_list <- list()
  
  # Traccia gli articolo_global_id già visti per costruire APPARTIENE_A una sola volta
  partizioni_viste <- character(0)
  
  # ── Loop sui file XML (uno per versione temporale) ─────────────────────────
  for (i in seq_len(nrow(timeline_df))) {
    
    row_tl <- timeline_df[i, ]
    
    doc <- tryCatch({
      d <- xml2::read_xml(row_tl$percorso_file)
      xml2::xml_ns_strip(d)
      d
    }, error = function(e) {
      warning(sprintf("XML non leggibile: %s\n  %s", row_tl$nome_file, e$message), call. = FALSE)
      NULL
    })
    if (is.null(doc)) next
    
    # ── Selezione nodi strutturali ───────────────────────────────────────────
    # XPath non-ricorsivo per evitare duplicati.
    # Gestisce sia strutture con <article> (codici principali) che con
    # <paragraph> (disposizioni di attuazione, testi con struttura diversa).
    # - article[not(.//article)]: articoli foglia
    # - paragraph[not(.//paragraph)]: paragrafi foglia (disp. att.)
    # - attachment/doc: allegati con meta AKN propria
    tutti_nodi <- xml2::xml_find_all(
      doc,
      paste0(
        "//article[not(.//article)] | ",
        "//paragraph[not(.//paragraph)][not(ancestor::article)] | ",
        "//attachment/doc"
      )
    )
    
    if (length(tutti_nodi) == 0) {
      warning(sprintf("Nessun nodo strutturale in: %s", row_tl$nome_file), call. = FALSE)
      next
    }
    
    message(sprintf("   [%d/%d] %s → %d nodi",
                    i, nrow(timeline_df), row_tl$nome_file, length(tutti_nodi)))
    
    # ── Loop interno sui nodi ────────────────────────────────────────────────
    for (idx in seq_along(tutti_nodi)) {
      nodo_xml <- tutti_nodi[[idx]]
      
      # Determina se è un allegato (il nodo è un <doc> figlio di <attachment>)
      e_allegato <- identical(xml2::xml_name(xml2::xml_parent(nodo_xml)), "attachment")
      
      # ── Testo ─────────────────────────────────────────────────────────────
      testo_completo <- extract_testo_nodo(nodo_xml)
      if (is.na(testo_completo) || nchar(testo_completo) < 5) next
      
      testo_incipit <- stringr::str_sub(testo_completo, 1, 120)
      testo_low     <- stringr::str_to_lower(testo_completo)
      
      # Salta le note
      titolo_nodo <- xml2::xml_attr(nodo_xml, "name") %||%
        xml2::xml_attr(nodo_xml, "title") %||% ""
      if (isTRUE(stringr::str_detect(titolo_nodo, PATTERN_NOTA_TITOLO)) ||
          isTRUE(stringr::str_detect(testo_incipit, PATTERN_NOTA_TITOLO))) next
      
      # ── ID e label ────────────────────────────────────────────────────────
      if (e_allegato) {
        # Allegato: legge la meta dal <doc> stesso
        attachment_padre <- xml2::xml_parent(nodo_xml)
        all_meta         <- extract_allegato_meta(attachment_padre)
        id_prefisso      <- all_meta$prefix
        tipo_partizione  <- "allegato"
        tipo_label       <- "Norma;Allegato"
        
        # Per gli allegati l'ID strutturale è nell'attributo name del <doc>
        doc_name_raw <- xml2::xml_attr(nodo_xml, "name") %||% ""
        id_pulito_allegato <- paste0(
          id_prefisso,
          stringr::str_to_lower(stringr::str_replace_all(doc_name_raw, "[\\s\\-]+", "_")) |>
            stringr::str_sub(1, 50)
        )
        numero_formattato  <- all_meta$label
        
        articolo_global_id <- paste0(atto_urn, "#", id_pulito_allegato)
        
      } else {
        # Articolo normale
        id_prefisso     <- ""
        tipo_partizione <- "articolo"
        tipo_label      <- "Norma;Articolo"
        
        id_info <- extract_node_id(nodo_xml, testo_incipit, idx)
        id_pulito_art      <- id_info$id_pulito
        numero_formattato  <- id_info$numero_formattato
        metodo_id          <- id_info$metodo_id
        
        articolo_global_id <- paste0(atto_urn, "#", id_pulito_art)
      }
      
      versione_global_id <- paste0(articolo_global_id, "_V", row_tl$versione_id)
      
      # ── Classificazione semantica ──────────────────────────────────────────
      stato_norma   <- classifica_stato_norma(testo_completo, testo_low)
      tipo_modifica <- classifica_tipo_modifica(
        testo_completo, testo_low, row_tl$is_originale, stato_norma
      )
      
      # FIX rispetto all'originale: testo completo mantenuto anche per norme
      # abrogate — necessario per rispondere a domande storiche.
      testo_per_rag <- if (stato_norma == "ABROGATO") {
        paste0("[NORMA ABROGATA] ", testo_completo)
      } else {
        testo_completo
      }
      
      # ── Nodo Partizione (strutturale, invariante nel tempo) ────────────────
      # Aggiunto solo alla prima occorrenza per evitare duplicati
      if (!articolo_global_id %in% partizioni_viste) {
        partizioni_viste <- c(partizioni_viste, articolo_global_id)
        
        nodi_Partizioni_list[[length(nodi_Partizioni_list) + 1]] <- list(
          `partizione_id:ID(Partizione)` = articolo_global_id,
          numero                         = numero_formattato,
          titolo_atto                    = atto_corrente$titolo_rubrica,
          atto_appartenenza              = atto_urn,
          nome_comune_atto               = atto_corrente$nome_comune %||% NA_character_,
          codice_breve_atto              = atto_corrente$codice_breve %||% NA_character_,
          tipo_partizione                = tipo_partizione,
          metodo_identificazione         = if (e_allegato) "allegato" else metodo_id,
          `:LABEL`                       = tipo_label
        )
        
        # Arco APPARTIENE_A (Partizione → Legge)
        # FIX rispetto all'originale: aggiunto arco esplicito mancante
        archi_APPARTIENE_list[[length(archi_APPARTIENE_list) + 1]] <- list(
          `:START_ID(Partizione)` = articolo_global_id,
          `:END_ID(Legge)`        = atto_urn
        )
      }
      
      # ── Nodo Versione (snapshot temporale) ────────────────────────────────
      nodi_Versione_list[[length(nodi_Versione_list) + 1]] <- list(
        `versione_id:ID(Versione)` = versione_global_id,
        testo_puro                 = testo_per_rag,
        numero                     = numero_formattato,
        titolo_atto                = atto_corrente$titolo_rubrica,
        nome_comune_atto           = atto_corrente$nome_comune %||% NA_character_,
        codice_breve_atto          = atto_corrente$codice_breve %||% NA_character_,
        atto_appartenenza          = atto_urn,
        `valido_dal:DATE`          = as.character(row_tl$valido_dal),
        `valido_al:DATE`           = as.character(row_tl$valido_al),
        stato_temporale            = row_tl$stato_vigenza,
        `num_versione:INT`         = as.integer(row_tl$versione_id),
        stato_norma                = stato_norma,
        tipo_modifica              = tipo_modifica,
        `:LABEL`                   = "Versione"
      )
      
      # ── Arco VIGENTE (solo per la versione corrente) ───────────────────────
      if (row_tl$stato_vigenza == "VIGENTE") {
        archi_VIGENTE_list[[length(archi_VIGENTE_list) + 1]] <- list(
          `:START_ID(Partizione)` = articolo_global_id,
          `:END_ID(Versione)`     = versione_global_id
        )
      }
      
      # ── Arco EVOLVE_IN (versione → versione successiva) ───────────────────
      if (!is.na(row_tl$id_versione_successiva)) {
        versione_succ_id <- paste0(articolo_global_id, "_V", row_tl$id_versione_successiva)
        archi_EVOLVE_IN_list[[length(archi_EVOLVE_IN_list) + 1]] <- list(
          `:START_ID(Versione)` = versione_global_id,
          `:END_ID(Versione)`   = versione_succ_id,
          tipo_azione           = tipo_modifica
        )
      }
      
      # ── Archi RIMANDA_A (allegato → articolo padre) ────────────────────────
      if (e_allegato) {
        # Cerca riferimenti ad articoli nel titolo o nel testo dell'allegato
        numeri_padre <- unique(c(
          extract_article_numbers(titolo_nodo),
          extract_article_numbers(testo_incipit)
        ))
        for (num_padre in numeri_padre) {
          art_padre_id <- paste0(atto_urn, "#art_", num_padre)
          archi_RIMANDA_A_list[[length(archi_RIMANDA_A_list) + 1]] <- list(
            `:START_ID(Partizione)` = art_padre_id,
            `:END_ID(Partizione)`   = articolo_global_id
          )
        }
      }
      
      # ── Archi CITA (citazioni <ref> nel testo) ─────────────────────────────
      ref_nodes  <- xml2::xml_find_all(nodo_xml, ".//ref[@href]")
      urn_citati <- xml2::xml_attr(ref_nodes, "href")
      urn_citati <- unique(urn_citati[!is.na(urn_citati) & nchar(urn_citati) > 0])
      
      for (href_raw in urn_citati) {
        urn_norm <- normalizza_href_a_urn(href_raw)
        if (is.na(urn_norm)) next
        
        tipo_citazione <- dplyr::case_when(
          stringr::str_detect(urn_norm, "#")          ~ "articolo",
          stringr::str_starts(urn_norm, "urn:nir")    ~ "legge",
          TRUE                                        ~ "esterno"
        )
        
        # Separa citazioni a Partizione specifica (con #) da citazioni all'atto intero
        if (stringr::str_detect(urn_norm, "#")) {
          # CITA_NORMA: citazione a un articolo specifico → END su Partizione
          archi_CITA_list[[length(archi_CITA_list) + 1]] <- list(
            `:START_ID(Versione)` = versione_global_id,
            `:END_ID(Partizione)` = urn_norm,
            tipo_citazione        = tipo_citazione
          )
        } else {
          # CITA_ATTO: citazione generica all'atto intero → END su Legge
          archi_CITA_ATTO_list[[length(archi_CITA_ATTO_list) + 1]] <- list(
            `:START_ID(Versione)` = versione_global_id,
            `:END_ID(Legge)`      = urn_norm,
            tipo_citazione        = "legge"
          )
        }
      }
      
    } # fine loop nodi
  } # fine loop file XML
  
  # ── Scrittura CSV parziale per atto (memory-safe) ────────────────────────
  scrivi_partial(nodi_Partizioni_list,  "nodi_Partizioni",  j)
  scrivi_partial(nodi_Versione_list,    "nodi_Versione",    j)
  scrivi_partial(archi_VIGENTE_list,    "archi_VIGENTE",    j)
  scrivi_partial(archi_EVOLVE_IN_list,  "archi_EVOLVE_IN",  j)
  scrivi_partial(archi_CITA_list,       "archi_CITA",       j)
  scrivi_partial(archi_CITA_ATTO_list,  "archi_CITA_ATTO",  j)
  scrivi_partial(archi_RIMANDA_A_list,  "archi_RIMANDA_A",  j)
  scrivi_partial(archi_APPARTIENE_list, "archi_APPARTIENE", j)
  
  # Libera memoria esplicitamente dopo ogni atto
  rm(nodi_Partizioni_list, nodi_Versione_list,
     archi_VIGENTE_list, archi_EVOLVE_IN_list,
     archi_CITA_list, archi_CITA_ATTO_list,
     archi_RIMANDA_A_list, archi_APPARTIENE_list)
  gc(verbose = FALSE)
  
  message(sprintf(
    "<<< [%s]: %d partizioni | %d versioni | %d VIGENTE | %d EVOLVE | %d CITA_NORMA | %d CITA_ATTO | %d RIMANDA | %d APPARTIENE",
    atto_corrente$titolo_rubrica,
    length(nodi_Partizioni_list), length(nodi_Versione_list),
    length(archi_VIGENTE_list), length(archi_EVOLVE_IN_list),
    length(archi_CITA_list), length(archi_CITA_ATTO_list), length(archi_RIMANDA_A_list),
    length(archi_APPARTIENE_list)
  ))
}

# ══════════════════════════════════════════════════════════════════════════════
# 3. CONSOLIDAMENTO GLOBALE
# FIX rispetto all'originale: singolo c() finale invece di append() in loop
# ══════════════════════════════════════════════════════════════════════════════

message("\n=== Consolidamento globale da CSV parziali (data.table) ... ===")

# Funzione helper: leggi e consolida tutti i CSV parziali di un tipo
leggi_partial <- function(prefisso, id_col = NULL) {
  files <- list.files(output_partial, 
                      pattern = paste0("^", prefisso, "_\\d+\\.csv$"),
                      full.names = TRUE)
  if (length(files) == 0) {
    message(sprintf("  Nessun file parziale per: %s", prefisso))
    return(data.table::data.table())
  }
  dt <- data.table::rbindlist(
    lapply(files, data.table::fread, na.strings = ""),
    fill = TRUE, use.names = TRUE
  )
  if (!is.null(id_col) && id_col %in% names(dt)) {
    dt <- unique(dt, by = id_col)
  } else {
    dt <- unique(dt)
  }
  dt
}

df_nodi_Partizioni  <- leggi_partial("nodi_Partizioni",  "partizione_id:ID(Partizione)")
df_nodi_Versione    <- leggi_partial("nodi_Versione",    "versione_id:ID(Versione)")
df_archi_VIGENTE    <- leggi_partial("archi_VIGENTE")
df_archi_EVOLVE_IN  <- leggi_partial("archi_EVOLVE_IN")
df_archi_CITA       <- leggi_partial("archi_CITA")
df_archi_CITA_ATTO  <- leggi_partial("archi_CITA_ATTO")
df_archi_RIMANDA_A  <- leggi_partial("archi_RIMANDA_A")
df_archi_APPARTIENE <- leggi_partial("archi_APPARTIENE")

# Converti a data.frame per compatibilità con 03_export_neo4j.R
df_nodi_Partizioni  <- as.data.frame(df_nodi_Partizioni)
df_nodi_Versione    <- as.data.frame(df_nodi_Versione)
df_archi_VIGENTE    <- as.data.frame(df_archi_VIGENTE)
df_archi_EVOLVE_IN  <- as.data.frame(df_archi_EVOLVE_IN)
df_archi_CITA       <- as.data.frame(df_archi_CITA)
df_archi_CITA_ATTO  <- as.data.frame(df_archi_CITA_ATTO)
df_archi_RIMANDA_A  <- as.data.frame(df_archi_RIMANDA_A)
df_archi_APPARTIENE <- as.data.frame(df_archi_APPARTIENE)

message(sprintf(
  "\n=== Master loop completato ===\n  Partizioni  : %d\n  Versioni    : %d\n  VIGENTE     : %d\n  EVOLVE_IN   : %d\n  CITA_NORMA  : %d\n  CITA_ATTO   : %d\n  RIMANDA_A   : %d\n  APPARTIENE  : %d",
  nrow(df_nodi_Partizioni), nrow(df_nodi_Versione),
  nrow(df_archi_VIGENTE), nrow(df_archi_EVOLVE_IN),
  nrow(df_archi_CITA), nrow(df_archi_CITA_ATTO), nrow(df_archi_RIMANDA_A),
  nrow(df_archi_APPARTIENE)
))