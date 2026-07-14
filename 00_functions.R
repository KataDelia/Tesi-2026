# 00_functions.R
# Funzioni condivise tra gli script di build.

`%||%` <- function(a, b) {
  if (length(a) > 0 && !is.null(a) && !all(is.na(a))) a else b
}

DATA_FINE_DEFAULT <- as.Date("9999-12-31")
DATA_INIZIO_MIN   <- as.Date("1900-01-01")
FOLDER_PATTERN    <- "(?i)^([A-Z][A-Z_ -]+?)_(\\d{8})_(\\d+)$"

# Pattern semantici per classificazione novelle legislative

RX_ABROGATO_TOTALE   <- "(?i)^\\s*\\(*(articolo|capo|titolo|sezione)?\\s*abrogato.*"
RX_ABROGATO_PARZIALE <- "(?i)(comma|lettera|parole|numero|\\(\\(.*\\)).*abrogato.*"
RX_SOLO_ABROGATO     <- "(?i)^\\s*\\(*abrogat[oa]\\)*\\s*\\.?\\s*$"
RX_SOPPRESSIONE      <- "(?i)è\\s+soppress[oa]|sono\\s+soppress[ei]"
RX_DEROGA            <- "(?i)\\bderoga\\b|\\bin\\s+deroga\\s+a\\b|non\\s+si\\s+applicano\\s+le\\s+disposizioni"
RX_INTERPRETAZIONE   <- "(?i)si\\s+interpreta\\s+nel\\s+senso\\s+che|interpretazione\\s+autentica"
RX_ESTENSIONE        <- "(?i)si\\s+applicano\\s+anche|estend[e|o|ono]\\s+l'applicabilità|estes[oa]\\s+a"
RX_SOSTITUZIONE      <- "\\(\\("
RX_INTEGRAZIONE      <- "(?i)è\\s+aggiunto|sono\\s+aggiunti|è\\s+inserito|sono\\s+inseriti"
RX_PROROGA           <- "(?i)termine.*prorogato|termini.*prorogati|differito\\s+al"
RX_SOSPENSIONE       <- "(?i)efficacia.*sospesa|sospeso\\s+fino\\s+al"
RX_NOTA_TITOLO       <- "(?i)^\\s*(nota|note)\\b"

# Alias tipo atto (tutto minuscolo, per normalizzazione URN NIR)
ALIAS_TIPO_ATTO <- c(
  "decretolegislativo"                  = "decreto.legislativo",
  "declegg"                             = "decreto.legislativo",
  "decreto"                             = "decreto.legislativo",
  "decretolegge"                        = "decreto.legge",
  "decleg"                              = "decreto.legge",
  "legge"                               = "legge",
  "regiodecreto"                        = "regio.decreto",
  "codice.civile"                       = "regio.decreto",
  "codicecivile"                        = "regio.decreto",
  "codice.penale"                       = "regio.decreto",
  "codicepenale"                        = "regio.decreto",
  "codice.navigazione"                  = "regio.decreto",
  "codicenavigazione"                   = "regio.decreto",
  "codice.procedura.civile"             = "regio.decreto",
  "codiceproceduraciville"              = "regio.decreto",
  "codice.procedura.penale"             = "regio.decreto",
  "codiceprocedurapenale"               = "regio.decreto",
  "decretodelpresidentedellarepubblica" = "decreto.del.presidente.della.repubblica",
  "dpr"                                 = "decreto.del.presidente.della.repubblica",
  "decretoministeriare"                 = "decreto.ministeriale",
  "dm"                                  = "decreto.ministeriale",
  "direttiva.ue"                        = "direttiva.ue",
  "direttivaue"                         = "direttiva.ue",
  "direttiva.ce"                        = "direttiva.ue",
  "direttivace"                         = "direttiva.ue"
)

# Lista dei 40 codici principali con nome comune e abbreviazione
CODICI_PRINCIPALI <- list(
  # Regio Decreto (8)
  "regio.decreto:1930-10-19;1398"     = list(nome_comune = "Codice Penale",                                        codice_breve = "c.p."),
  "regio.decreto:1940-10-28;1443"     = list(nome_comune = "Codice di Procedura Civile",                           codice_breve = "c.p.c."),
  "regio.decreto:1941-02-20;303"      = list(nome_comune = "Codice Penale Militare di Guerra",                     codice_breve = "c.p.m.g."),
  "regio.decreto:1941-09-09;1023"     = list(nome_comune = "Codice Penale Militare di Pace",                       codice_breve = "c.p.m.p."),
  "regio.decreto:1941-12-18;1368"     = list(nome_comune = "Disposizioni attuazione codice di procedura civile",   codice_breve = "disp. att. c.p.c."),
  "regio.decreto:1942-03-16;262"      = list(nome_comune = "Codice Civile",                                        codice_breve = "c.c."),
  "regio.decreto:1942-03-30;318"      = list(nome_comune = "Disposizioni attuazione codice civile",                codice_breve = "disp. att. c.c."),
  "regio.decreto:1942-03-30;327"      = list(nome_comune = "Codice della Navigazione",                             codice_breve = "cod. nav."),
  # D.P.R. (5)
  "decreto.del.presidente.della.repubblica:1952-02-15;328" = list(nome_comune = "Regolamento esecuzione Codice Navale",        codice_breve = "reg. cod. nav."),
  "decreto.del.presidente.della.repubblica:1973-03-29;156" = list(nome_comune = "Codice postale e telecomunicazioni",          codice_breve = "cod. post."),
  "decreto.del.presidente.della.repubblica:1988-09-22;447" = list(nome_comune = "Approvazione codice procedura penale",        codice_breve = "c.p.p. 1988"),
  "decreto.del.presidente.della.repubblica:1992-12-16;495" = list(nome_comune = "Regolamento esecuzione codice della strada",  codice_breve = "reg. c.d.s."),
  "decreto.del.presidente.della.repubblica:2010-10-05;207" = list(nome_comune = "Regolamento esecuzione contratti pubblici",   codice_breve = "reg. contr. pubbl."),
  # Decreto Legislativo (25)
  "decreto.legislativo:1989-07-28;271" = list(nome_comune = "Norme attuazione codice procedura penale",            codice_breve = "norme att. c.p.p."),
  "decreto.legislativo:1992-04-30;285" = list(nome_comune = "Nuovo Codice della Strada",                           codice_breve = "c.d.s."),
  "decreto.legislativo:1992-12-31;546" = list(nome_comune = "Disposizioni sul processo tributario",                codice_breve = "d.lgs. 546/92"),
  "decreto.legislativo:2003-06-30;196" = list(nome_comune = "Codice della Privacy",                                codice_breve = "cod. privacy"),
  "decreto.legislativo:2003-08-01;259" = list(nome_comune = "Codice delle comunicazioni elettroniche",             codice_breve = "c.c.e."),
  "decreto.legislativo:2004-01-22;42"  = list(nome_comune = "Codice dei beni culturali",                           codice_breve = "cod. beni cult."),
  "decreto.legislativo:2005-02-10;30"  = list(nome_comune = "Codice della proprietà industriale",                  codice_breve = "c.p.i."),
  "decreto.legislativo:2005-03-07;82"  = list(nome_comune = "Codice dell'amministrazione digitale",                codice_breve = "c.a.d."),
  "decreto.legislativo:2005-07-18;171" = list(nome_comune = "Codice della nautica da diporto",                     codice_breve = "cod. nautica"),
  "decreto.legislativo:2005-09-06;206" = list(nome_comune = "Codice del consumo",                                  codice_breve = "cod. consumo"),
  "decreto.legislativo:2005-09-07;209" = list(nome_comune = "Codice delle assicurazioni private",                  codice_breve = "cod. ass."),
  "decreto.legislativo:2006-04-03;152" = list(nome_comune = "Norme in materia ambientale",                         codice_breve = "d.lgs. 152/06"),
  "decreto.legislativo:2006-04-11;198" = list(nome_comune = "Codice pari opportunità",                             codice_breve = "cod. parità"),
  "decreto.legislativo:2006-04-12;163" = list(nome_comune = "Codice dei contratti pubblici",                       codice_breve = "cod. appalti"),
  "decreto.legislativo:2010-03-15;66"  = list(nome_comune = "Codice Ordinamento Militare",                         codice_breve = "c.o.m."),
  "decreto.legislativo:2010-07-02;104" = list(nome_comune = "Codice del processo amministrativo",                  codice_breve = "c.p.a."),
  "decreto.legislativo:2011-05-23;79"  = list(nome_comune = "Codice della normativa statale",                      codice_breve = "d.lgs. 79/11"),
  "decreto.legislativo:2011-09-06;159" = list(nome_comune = "Codice delle leggi antimafia",                        codice_breve = "c.a.m."),
  "decreto.legislativo:2016-04-18;50"  = list(nome_comune = "Codice appalti 2016",                                 codice_breve = "d.lgs. 50/16"),
  "decreto.legislativo:2016-08-26;174" = list(nome_comune = "Codice della Giustizia Contabile",                    codice_breve = "c.g.c."),
  "decreto.legislativo:2017-07-03;117" = list(nome_comune = "Codice Terzo Settore",                                codice_breve = "c.t.s."),
  "decreto.legislativo:2018-01-02;1"   = list(nome_comune = "D.Lgs. 1/2018",                                       codice_breve = "d.lgs. 1/18"),
  "decreto.legislativo:2019-01-12;14"  = list(nome_comune = "D.Lgs. 14/2019",                                      codice_breve = "d.lgs. 14/19"),
  "decreto.legislativo:2023-03-31;36"  = list(nome_comune = "Codice appalti 2023",                                 codice_breve = "d.lgs. 36/23"),
  "decreto.legislativo:2025-11-27;184" = list(nome_comune = "Riordino normativo settoriale",                       codice_breve = "d.lgs. 184/25"),
  # Altri Decreti (2)
  "decreto:1989-09-30;334"             = list(nome_comune = "D.M. esecuzione c.p.p.",                              codice_breve = "d.m. 334/89"),
  "decreto:2010-01-13;33"              = list(nome_comune = "D.M. attuazione contratti",                           codice_breve = "d.m. 33/10")
)

# Funzioni Akoma Ntoso

get_akn_uri <- function(nodo, uri_padre_corrente) {
  if (is.null(nodo)) return(NA)
  meta_this <- xml2::xml_find_first(nodo, ".//meta/identification/FRBRWork/FRBRthis")
  if (!is.na(xml2::xml_attr(meta_this, "value"))) {
    return(xml2::xml_attr(meta_this, "value"))
  }
  eid <- xml2::xml_attr(nodo, "eId")
  if (is.na(eid)) eid <- xml2::xml_attr(nodo, "id")
  if (is.na(eid)) eid <- xml2::xml_name(nodo)
  sep <- if (grepl("[/#]$", uri_padre_corrente)) "" else "#"
  return(paste0(uri_padre_corrente, sep, eid))
}

#' Normalizza il tipo atto nel formato URN NIR.
normalize_act_type <- function(raw_type) {
  raw_type |>
    stringr::str_squish() |>
    stringr::str_replace_all("[_ -]+", ".") |>
    stringr::str_to_lower()
}

#' Valida una data YYYYMMDD.
parse_folder_date <- function(raw_date_str) {
  d <- suppressWarnings(as.Date(raw_date_str, format = "%Y%m%d"))
  if (is.na(d) || format(d, "%Y%m%d") != raw_date_str) return(NA_Date_)
  d
}

#' Estrae l'URN NIR dal blocco <FRBRWork>.
extract_urn_from_xml <- function(doc) {
  nodo <- xml2::xml_find_first(doc, "//FRBRWork/FRBRalias[@name='urn:nir']")
  if (inherits(nodo, "xml_missing")) return(NA_character_)
  stringr::str_trim(xml2::xml_attr(nodo, "value"))
}

#' Estrae i metadati AKN dal primo XML valido della cartella.
.extract_akn_metadata_impl <- function(folder_path) {
  file_xml <- list.files(folder_path, pattern = "\\.xml$",
                         full.names = TRUE, recursive = TRUE)
  if (length(file_xml) == 0) return(NULL)

  for (fpath in sort(file_xml)) {
    doc <- tryCatch({
      d <- xml2::read_xml(fpath)
      xml2::xml_ns_strip(d)
      d
    }, error = function(e) NULL)
    if (is.null(doc)) next

    urn_xml <- extract_urn_from_xml(doc)
    if (is.na(urn_xml)) next

    nodo_eli <- xml2::xml_find_first(doc, "//FRBRWork/FRBRalias[@name='eli']")
    eli <- if (!inherits(nodo_eli, "xml_missing")) {
      xml2::xml_attr(nodo_eli, "value")
    } else NA_character_

    nodo_titolo <- xml2::xml_find_first(doc, "//FRBRWork/FRBRname | //docTitle")
    titolo_akn <- if (!inherits(nodo_titolo, "xml_missing")) {
      stringr::str_squish(xml2::xml_text(nodo_titolo))
    } else NA_character_

    nodo_vigenza <- xml2::xml_find_first(
      doc, "//FRBRExpression/FRBRdate[@name='vigenza' or @name='entrata-in-vigore']"
    )
    data_vigenza <- if (!inherits(nodo_vigenza, "xml_missing")) {
      suppressWarnings(as.Date(xml2::xml_attr(nodo_vigenza, "date")))
    } else NA_Date_

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

extract_akn_metadata <- memoise::memoise(.extract_akn_metadata_impl)

#' Costruisce i metadati dell'atto a partire dalla cartella.
build_act_metadata <- function(folder_name, folder_path = NA_character_) {

  folder_name <- stringr::str_squish(folder_name)

  if (!is.na(folder_path) && !dir.exists(folder_path)) {
    warning(paste("Cartella inesistente, scartata:", folder_path), call. = FALSE)
    return(NULL)
  }

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
  title_type <- stringr::str_to_title(
    stringr::str_replace_all(raw_type, "[_ -]+", " ")
  )

  urn_da_cartella <- paste0(
    "urn:nir:stato:", normalized_type, ":",
    format(formatted_date, "%Y-%m-%d"), ";", act_number
  )
  formatted_title <- paste0(
    title_type, " n. ", act_number,
    " del ", format(formatted_date, "%d/%m/%Y")
  )

  akn          <- if (!is.na(folder_path)) extract_akn_metadata(folder_path) else NULL
  urn_xml      <- akn$urn_xml      %||% NA_character_
  eli          <- akn$eli          %||% NA_character_
  titolo_akn   <- akn$titolo_akn   %||% NA_character_
  data_vigenza <- akn$data_vigenza %||% NA_Date_
  data_atto    <- akn$data_atto    %||% NA_Date_

  urn_xml_norm      <- stringr::str_to_lower(stringr::str_trim(urn_xml))
  urn_cartella_norm <- stringr::str_to_lower(stringr::str_trim(urn_da_cartella))
  urn_match         <- is.na(urn_xml_norm) || (urn_xml_norm == urn_cartella_norm)
  urn_finale        <- dplyr::coalesce(urn_xml, urn_da_cartella)

  chiave_codice <- paste0(
    normalized_type, ":", format(formatted_date, "%Y-%m-%d"), ";", act_number
  )
  info_codice  <- CODICI_PRINCIPALI[[chiave_codice]]
  nome_comune  <- info_codice$nome_comune  %||% NA_character_
  codice_breve <- info_codice$codice_breve %||% NA_character_
  is_codice    <- !is.na(nome_comune)

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

#' Costruisce la timeline cronologica dei file XML di un atto.
build_timeline <- function(file_xml, data_originale) {
  tl <- tibble::tibble(percorso_file = file_xml) |>
    dplyr::mutate(
      nome_file       = basename(percorso_file),
      is_originale    = stringr::str_detect(nome_file, "_ORIGINALE_"),
      versione_id_raw = suppressWarnings(
        as.integer(stringr::str_extract(nome_file, "(?<=_V)[0-9]+"))
      ),
      data_iso = stringr::str_extract(
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

  malformati <- dplyr::filter(tl, is.na(data_inizio) | is.na(versione_id))
  if (nrow(malformati) > 0) {
    warning(sprintf("  %d file malformati ignorati: %s",
                    nrow(malformati),
                    paste(malformati$nome_file, collapse = ", ")), call. = FALSE)
  }

  tl <- tl |>
    dplyr::filter(!is.na(data_inizio), !is.na(versione_id)) |>
    dplyr::arrange(data_inizio, versione_id) |>
    dplyr::distinct(data_inizio, versione_id, .keep_all = TRUE)

  # URN della legge modificante dal file più recente
  tl$urn_legge_modificante <- NA_character_
  file_ordinati <- sort(tl$percorso_file)
  ultimo_file   <- file_ordinati[length(file_ordinati)]

  tryCatch({
    doc_last <- xml2::read_xml(ultimo_file)
    xml2::xml_ns_strip(doc_last)

    refs  <- xml2::xml_find_all(doc_last, "//references/passiveRef")
    hrefs <- xml2::xml_attr(refs, "href")
    eids  <- xml2::xml_attr(refs, "eId")

    urn_lookup <- setNames(
      sapply(hrefs, function(h) {
        if (is.na(h) || h == "") return(NA_character_)
        m <- regmatches(h, regexpr(
          "/akn/it/act/([^/]+)/([^/]+)/([0-9]{4}-[0-9]{2}-[0-9]{2})/([^/]+)/!main", h
        ))
        if (length(m) == 0 || m == "") return(NA_character_)
        parts <- strsplit(m, "/")[[1]]
        parts <- parts[parts != ""]
        if (length(parts) < 7) return(NA_character_)
        sprintf("urn:nir:%s:%s:%s;%s",
                tolower(parts[5]), tolower(gsub("_", ".", parts[4])),
                parts[6], parts[7])
      }),
      eids
    )

    for (k in seq_len(nrow(tl))) {
      if (tl$versione_id[k] > 1L) {
        source_id <- paste0("rp", tl$versione_id[k] - 1L)
        if (source_id %in% names(urn_lookup)) {
          urn <- urn_lookup[[source_id]]
          if (!is.na(urn) && nchar(urn) > 0) tl$urn_legge_modificante[k] <- urn
        }
      }
    }
  }, error = function(e) {
    warning(sprintf("Impossibile estrarre URN modificanti: %s", e$message), call. = FALSE)
  })

  tl |>
    dplyr::mutate(
      valido_dal             = as.Date(data_inizio),
      valido_al              = pmax(
        valido_dal,
        dplyr::lead(valido_dal, default = DATA_FINE_DEFAULT) - 1
      ),
      id_versione_successiva = dplyr::lead(versione_id),
      stato_vigenza          = dplyr::case_when(
        valido_al >= DATA_FINE_DEFAULT - 1 ~ "VIGENTE",
        valido_al < Sys.Date()             ~ "STORICO",
        TRUE                               ~ "VIGENTE"
      )
    )
}

#' Estrae un identificatore stabile per un nodo strutturale AKN.
extract_node_id <- function(nodo_xml, testo_incipit) {
  id_strutturale <- xml2::xml_attr(nodo_xml, "eId") %||% xml2::xml_attr(nodo_xml, "id")

  if (!is.na(id_strutturale) && nchar(stringr::str_trim(id_strutturale)) > 0) {
    id_pulito <- id_strutturale |>
      stringr::str_to_lower() |>
      stringr::str_replace_all("[\\s\\-]+", "_") |>
      stringr::str_trim()
    # Tronca suffissi numerici anomali mantenendo i bis/ter
    id_pulito <- sub("^(art_[0-9]+)[0-9]+$", "\\1", id_pulito)

    num_estratto <- stringr::str_extract(id_pulito, "\\d+(?:_[a-z]+)?")
    numero_formattato <- if (!is.na(num_estratto)) {
      paste0("Art. ", stringr::str_replace_all(num_estratto, "_", "-"))
    } else id_pulito

    return(list(id_pulito = id_pulito, numero_formattato = numero_formattato,
                metodo_id = "strutturale"))
  }

  m_art <- stringr::str_match(
    testo_incipit,
    "(?i)art(?:icolo|\\.)?\\s*(\\d+(?:[\\-\\.][a-z0-9]+)?)"
  )
  if (!is.na(m_art[1, 1])) {
    num_art   <- m_art[1, 2]
    id_pulito <- paste0("art_", stringr::str_replace_all(num_art, "[\\-\\.]", "_"))
    return(list(id_pulito = id_pulito,
                numero_formattato = paste0("Art. ", num_art),
                metodo_id = "testuale"))
  }

  m_disp <- stringr::str_match(
    stringr::str_trim(testo_incipit), "^(\\d+(?:[\\-][a-z]+)?)\\.?"
  )
  if (!is.na(m_disp[1, 1])) {
    num_disp  <- m_disp[1, 2]
    id_pulito <- paste0("disp_", stringr::str_replace_all(num_disp, "-", "_"))
    return(list(id_pulito = id_pulito,
                numero_formattato = paste0("Disp. ", num_disp),
                metodo_id = "testuale_disp"))
  }

  hash_incipit <- substr(digest::digest(testo_incipit, algo = "crc32"), 1, 8)
  list(id_pulito         = paste0("art_hash_", hash_incipit),
       numero_formattato = paste0("Art. [", hash_incipit, "]"),
       metodo_id         = "hash")
}

#' Estrae i metadati di un nodo allegato.
extract_allegato_meta <- function(attachment_node) {
  doc_node <- xml2::xml_find_first(attachment_node, "./doc")
  doc_name <- if (!inherits(doc_node, "xml_missing")) {
    xml2::xml_attr(doc_node, "name") %||% ""
  } else ""

  urn_allegato <- if (!inherits(doc_node, "xml_missing")) {
    n <- xml2::xml_find_first(doc_node, ".//FRBRWork/FRBRalias[@name='urn:nir']")
    if (!inherits(n, "xml_missing")) xml2::xml_attr(n, "value") else NA_character_
  } else NA_character_

  raw_id <- xml2::xml_attr(attachment_node, "eId") %||%
    xml2::xml_attr(attachment_node, "id")  %||%
    "all_generico"

  label_raw   <- if (nchar(doc_name) > 0) doc_name else raw_id
  label_clean <- stringr::str_sub(stringr::str_squish(label_raw), 1, 80)

  prefix <- paste0(
    stringr::str_to_lower(
      stringr::str_replace_all(stringr::str_sub(raw_id, 1, 30), "[\\s\\-]+", "_")
    ), "-"
  )

  list(raw_id = raw_id, urn_allegato = urn_allegato,
       label  = stringr::str_to_title(label_clean), prefix = prefix)
}

#' Classifica lo stato di abrogazione di una norma.
classifica_stato_norma <- function(testo_completo, testo_low) {
  is_solo_abrogato    <- isTRUE(stringr::str_detect(testo_completo, RX_SOLO_ABROGATO))
  is_incipit_abrogato <- isTRUE(stringr::str_detect(
    stringr::str_sub(testo_low, 1, 80), RX_ABROGATO_TOTALE
  ))
  is_totale   <- is_solo_abrogato || is_incipit_abrogato
  is_parziale <- if (is_totale) FALSE else {
    isTRUE(stringr::str_detect(testo_low, RX_ABROGATO_PARZIALE))
  }
  dplyr::case_when(
    is_totale   ~ "ABROGATO",
    is_parziale ~ "PARZIALMENTE_ABROGATO",
    TRUE        ~ "ATTIVO"
  )
}

#' Classifica il tipo di modifica di una versione.
classifica_tipo_modifica <- function(testo_completo, testo_low,
                                     is_originale, stato_norma) {
  is_parziale <- stringr::str_detect(
    testo_low, "(?i)(comma|lettera|numero|punto|alinea)\\s+[^\\s]+\\s+abrogat"
  )
  dplyr::case_when(
    isTRUE(is_originale)                                         ~ "originale",
    isTRUE(stato_norma == "ABROGATO" && is_parziale)             ~ "parzialmente_abrogato",
    isTRUE(stato_norma == "PARZIALMENTE_ABROGATO")               ~ "parzialmente_abrogato",
    isTRUE(stato_norma == "ABROGATO")                            ~ "abrogazione",
    isTRUE(stringr::str_detect(testo_low, RX_SOPPRESSIONE))      ~ "soppressione",
    isTRUE(stringr::str_detect(testo_completo, RX_SOSTITUZIONE))  ~ "sostituzione",
    isTRUE(stringr::str_detect(testo_low, RX_INTEGRAZIONE))      ~ "integrazione",
    isTRUE(stringr::str_detect(testo_low, RX_DEROGA))            ~ "deroga",
    isTRUE(stringr::str_detect(testo_low, RX_PROROGA))           ~ "proroga",
    isTRUE(stringr::str_detect(testo_low, RX_SOSPENSIONE))       ~ "sospensione",
    isTRUE(stringr::str_detect(testo_low, RX_INTERPRETAZIONE))   ~ "interpretazione_autentica",
    isTRUE(stringr::str_detect(testo_low, RX_ESTENSIONE))        ~ "estensione",
    TRUE                                                         ~ "modificato"
  )
}

#' Estrae i numeri di articolo citati nel testo.
extract_article_numbers <- function(text) {
  if (length(text) == 0 || is.na(text) || nchar(text) == 0) return(character())
  matched <- unlist(stringr::str_extract_all(
    text,
    "(?i)\\b(?:artt?\\.?|articoli?)\\s*([0-9]+(?:\\s*(?:,|e|ed)\\s*[0-9]+)*)"
  ))
  if (length(matched) == 0) return(character())
  unique(unlist(stringr::str_extract_all(matched, "[0-9]+"), use.names = FALSE))
}

#' Normalizza un href AKN nel formato urn:nir.
normalizza_href_a_urn <- function(href) {
  href <- stringr::str_trim(href)
  if (is.na(href) || href == "") return(NA_character_)

  href  <- stringr::str_replace_all(href, "~", "#")
  parti <- stringr::str_split_fixed(href, "#", 2)
  urn_base  <- stringr::str_trim(parti[1, 1])
  frammento <- stringr::str_trim(parti[1, 2])

  normalizza_tipo <- function(tipo_raw) {
    tipo_low    <- tolower(tipo_raw)
    tipo_no_sep <- tolower(gsub("[._\\-]", "", tipo_raw))
    ALIAS_TIPO_ATTO[tipo_low]    %||%
      ALIAS_TIPO_ATTO[tipo_no_sep] %||%
      tolower(gsub("([a-z])([A-Z])", "\\1.\\2", tipo_raw))
  }

  normalizza_frammento <- function(f) {
    if (is.na(f) || f == "") return("")
    f_low <- stringr::str_to_lower(stringr::str_squish(f))
    if (f_low %in% c("main", "!main", "")) return("")

    m_art <- stringr::str_match(
      f_low, "art(?:icolo)?[\\._]?\\s*([0-9]+(?:[_\\.\\-][a-z0-9]+)?)"
    )
    if (!is.na(m_art[1, 2])) {
      return(paste0("art_", stringr::str_replace_all(m_art[1, 2], "[.\\-]", "_")))
    }

    m_all <- stringr::str_match(f_low, "allegat[oa]?[\\._\\s]?([0-9a-z._\\-]*)")
    if (!is.na(m_all[1, 1])) {
      suf <- stringr::str_trim(m_all[1, 2] %||% "") |>
        stringr::str_replace_all("[.\\-\\s]+", "_") |>
        stringr::str_replace_all("_+", "_") |>
        stringr::str_remove_all("^_|_$")
      return(paste0("allegato", if (nchar(suf) > 0) paste0("_", suf) else ""))
    }

    if (stringr::str_detect(f_low, "^[a-z][a-z0-9_]*$")) return(f_low)

    f_low |>
      stringr::str_replace_all("[\\s\\.]+", "_") |>
      stringr::str_replace_all("[^a-z0-9_]", "") |>
      stringr::str_replace_all("_+", "_") |>
      stringr::str_remove_all("^_|_$")
  }

  if (stringr::str_starts(urn_base, "urn:nir")) {
    m_urn <- stringr::str_match(urn_base, "^(urn:nir:[^:]+):([^:]+):([^;]+);(.+)$")
    if (!is.na(m_urn[1, 1])) {
      urn_norm  <- paste0(m_urn[1, 2], ":", normalizza_tipo(m_urn[1, 3]),
                          ":", m_urn[1, 4], ";", m_urn[1, 5])
      frag_norm <- normalizza_frammento(frammento)
      return(if (nchar(frag_norm) > 0) paste0(urn_norm, "#", frag_norm) else urn_norm)
    }
    return(urn_base)
  }

  m_akn <- stringr::str_match(
    urn_base,
    "^/akn/[^/]+/act/([^/]+)/([^/]+)/([0-9]{4}(?:-[0-9]{2}-[0-9]{2})?)/([^/!#]+)(?:[/!](.+))?$"
  )
  if (!is.na(m_akn[1, 1])) {
    urn_ric   <- paste0("urn:nir:stato:", normalizza_tipo(m_akn[1, 2]),
                        ":", m_akn[1, 4], ";", m_akn[1, 5])
    frag_cand <- if (nchar(frammento) > 0) frammento else
      stringr::str_remove(m_akn[1, 6] %||% "", "^!?main/?")
    frag_norm <- normalizza_frammento(frag_cand)
    return(if (nchar(frag_norm) > 0) paste0(urn_ric, "#", frag_norm) else urn_ric)
  }

  href
}

#' Estrae il testo di un nodo AKN, con fallback e deduplicazione.
extract_testo_nodo <- function(nodo_xml) {
  xpath_testo <- paste0(
    ".//p[not(ancestor::section)][not(ancestor::note)]",
    "[not(ancestor::passiveModifications)][not(ancestor::activeModifications)] | ",
    ".//content[not(.//p)][not(ancestor::section)][not(ancestor::note)]",
    "[not(ancestor::passiveModifications)][not(ancestor::activeModifications)]"
  )
  nodi_testo <- xml2::xml_find_all(nodo_xml, xpath_testo)
  testi <- xml2::xml_text(nodi_testo)
  testo <- stringr::str_squish(paste(testi[nchar(testi) > 0], collapse = "\n\n"))

  # Fallback: testo grezzo del nodo
  if (is.na(testo) || nchar(testo) < 5) {
    testo <- stringr::str_squish(xml2::xml_text(nodo_xml))
  }

  # Deduplicazione: rimuove testo duplicato nella seconda metà (artefatto del multivigente)
  if (!is.na(testo) && nchar(testo) > 20) {
    n    <- nchar(testo)
    meta <- stringr::str_squish(substr(testo, 1L, n %/% 2L))
    coda <- stringr::str_squish(substr(testo, n %/% 2L + 1L, n))
    if (nchar(meta) > 10 && stringr::str_starts(coda, stringr::fixed(meta))) {
      testo <- meta
    }
  }

  if (!is.na(testo) && nchar(testo) > 100000) testo <- stringr::str_sub(testo, 1, 100000)
  testo
}

#' [DEPRECATA] Estrae le modifiche attive dall'atto.
estrai_modificato_da <- function(doc, versione_global_id) {
  nodi_mod <- xml2::xml_find_all(doc, "//activeModifications/textualMod")
  if (length(nodi_mod) == 0) return(list())

  lifecycle_lookup <- tryCatch({
    eventi <- xml2::xml_find_all(doc, "//lifecycle/eventRef")
    if (length(eventi) == 0) return(list())
    setNames(
      as.list(suppressWarnings(as.Date(xml2::xml_attr(eventi, "date")))),
      xml2::xml_attr(eventi, "source")
    )
  }, error = function(e) list())

  purrr::compact(purrr::map(nodi_mod, function(mod) {
    dest_href <- xml2::xml_attr(
      xml2::xml_find_first(mod, "./destination"), "href"
    ) %||% ""

    if (is.na(dest_href) || dest_href == "" ||
        stringr::str_detect(dest_href, "^#")) return(NULL)

    tipo_mod_attr <- xml2::xml_attr(mod, "type") %||% ""
    new_node      <- xml2::xml_find_first(mod, "./new")
    testo_new     <- if (!inherits(new_node, "xml_missing")) {
      stringr::str_sub(stringr::str_squish(xml2::xml_text(new_node)), 1, 200)
    } else ""

    tipo_intervento <- dplyr::case_when(
      stringr::str_detect(tipo_mod_attr, "(?i)insertion")    ~ "inserimento",
      stringr::str_detect(tipo_mod_attr, "(?i)substitution") ~ "sostituzione",
      stringr::str_detect(tipo_mod_attr, "(?i)repeal")       ~ "abrogazione",
      stringr::str_detect(testo_new,     "(?i)abrogat")      ~ "abrogazione",
      stringr::str_detect(testo_new,     "(?i)soppresso")    ~ "soppressione",
      stringr::str_detect(testo_new,     "(?i)sostituito")   ~ "sostituzione",
      stringr::str_detect(testo_new,     "(?i)aggiunto")     ~ "inserimento",
      TRUE                                                   ~ "modifica"
    )

    urn_modificante <- normalizza_href_a_urn(dest_href)
    if (is.na(urn_modificante) || urn_modificante == "") return(NULL)

    source_node <- xml2::xml_find_first(mod, "./source")
    source_href <- if (!inherits(source_node, "xml_missing")) {
      xml2::xml_attr(source_node, "href") %||% ""
    } else ""

    evento_idx <- suppressWarnings(
      as.integer(stringr::str_extract(source_href, "(?<=eventRef_)\\d+"))
    )
    data_gu_raw <- if (!is.na(evento_idx)) {
      eventi_tutti <- xml2::xml_find_all(doc, "//lifecycle/eventRef")
      if (evento_idx + 1L <= length(eventi_tutti)) {
        suppressWarnings(
          as.Date(xml2::xml_attr(eventi_tutti[[evento_idx + 1L]], "date"))
        )
      } else NA_character_
    } else NA_character_

    data_gu <- if (!is.null(data_gu_raw) && !is.na(data_gu_raw)) {
      as.integer(format(as.Date(data_gu_raw), "%Y%m%d"))
    } else NA_integer_

    list(
      `:START_ID(Versione)` = versione_global_id,
      `:END_ID(Legge)`      = stringr::str_remove(urn_modificante, "#.*$"),
      tipo_intervento       = tipo_intervento,
      testo_modifica        = testo_new,
      data_pubblicazione_gu = data_gu
    )
  }))
}

#' Estrae le modifiche passive ricevute dall'atto.
estrai_passive_modifications <- function(doc) {
  eventi  <- xml2::xml_find_all(doc, "//lifecycle/eventRef")
  date_gu <- suppressWarnings(as.Date(xml2::xml_attr(eventi, "date")))

  nodi_pass <- xml2::xml_find_all(doc, "//passiveModifications/textualMod")
  if (length(nodi_pass) == 0) return(list())

  purrr::compact(lapply(nodi_pass, function(mod) {
    tipo_attr <- xml2::xml_attr(mod, "type") %||% ""
    new_node  <- xml2::xml_find_first(mod, "./new")

    testo_new <- if (!inherits(new_node, "xml_missing")) {
      stringr::str_squish(xml2::xml_text(new_node))
    } else ""

    if (nchar(testo_new) < 5) return(NULL)

    tipo_ricevuta <- dplyr::case_when(
      stringr::str_detect(tipo_attr, "(?i)insertion")    ~ "inserimento",
      stringr::str_detect(tipo_attr, "(?i)substitution") ~ "sostituzione",
      stringr::str_detect(tipo_attr, "(?i)repeal")       ~ "abrogazione",
      stringr::str_detect(testo_new, "(?i)abrogat")      ~ "abrogazione",
      stringr::str_detect(testo_new, "(?i)soppresso")    ~ "soppressione",
      TRUE                                               ~ "modifica"
    )

    eid     <- xml2::xml_attr(mod, "eId") %||% ""
    idx     <- suppressWarnings(as.integer(stringr::str_extract(eid, "\\d+$")))
    data_gu <- if (!is.na(idx) && (idx + 1L) <= length(date_gu)) {
      as.integer(format(date_gu[idx + 1L], "%Y%m%d"))
    } else NA_integer_

    list(
      tipo_modifica_ricevuta  = tipo_ricevuta,
      data_gu_modifica        = data_gu,
      testo_modifica_ricevuta = stringr::str_sub(testo_new, 1, 300)
    )
  }))
}

#' Estrae la gerarchia strutturale (libro, parte, titolo, capo, sezione) di un nodo.
extract_gerarchia <- function(nodo_xml) {
  gerarchia <- list(
    libro_num = NA_character_, libro_titolo   = NA_character_,
    parte_num = NA_character_, parte_titolo   = NA_character_,
    titolo_num = NA_character_, titolo_titolo = NA_character_,
    capo_num  = NA_character_, capo_titolo    = NA_character_,
    sezione_num = NA_character_, sezione_titolo = NA_character_
  )

  estrai_dati_struttura <- function(xpath_ancestor) {
    nodo_padre <- xml2::xml_find_first(nodo_xml, xpath_ancestor)
    if (inherits(nodo_padre, "xml_missing")) return(c(NA_character_, NA_character_))
    num_node     <- xml2::xml_find_first(nodo_padre, "./num")
    heading_node <- xml2::xml_find_first(nodo_padre, "./heading")
    c(
      if (!inherits(num_node,     "xml_missing")) stringr::str_squish(xml2::xml_text(num_node))     else NA_character_,
      if (!inherits(heading_node, "xml_missing")) stringr::str_squish(xml2::xml_text(heading_node)) else NA_character_
    )
  }

  for (livello in list(
    list(key = c("libro_num",   "libro_titolo"),   xpath = "./ancestor::book"),
    list(key = c("parte_num",   "parte_titolo"),   xpath = "./ancestor::part"),
    list(key = c("titolo_num",  "titolo_titolo"),  xpath = "./ancestor::title"),
    list(key = c("capo_num",    "capo_titolo"),    xpath = "./ancestor::chapter"),
    list(key = c("sezione_num", "sezione_titolo"), xpath = "./ancestor::section")
  )) {
    dati <- estrai_dati_struttura(livello$xpath)
    gerarchia[[livello$key[1]]] <- dati[1]
    gerarchia[[livello$key[2]]] <- dati[2]
  }

  gerarchia
}
