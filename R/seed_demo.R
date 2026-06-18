# ── Helpers internes ──────────────────────────────────────────────────────────

.read_seed_csv <- function(filename) {
    path <- system.file("seed", filename, package = "mbhlmaintenance")
    if (!nzchar(path)) {
        cli::cli_abort(
            "Fichier seed {.file {filename}} introuvable dans {.pkg mbhlmaintenance}.",
            "i" = "Le package est-il installé ? Lance {.code devtools::load_all()}."
        )
    }
    utils::read.csv(path, stringsAsFactors = FALSE, na.strings = c("", "NA"),
                    encoding = "UTF-8")
}

.bool_col <- function(x) toupper(trimws(x)) == "TRUE"

.build_lookup <- function(con, schema, table, key_col, val_col) {
    df <- DBI::dbGetQuery(
        con,
        sprintf('SELECT "%s", "%s" FROM "%s"."%s"', key_col, val_col, schema, table)
    )
    stats::setNames(df[[val_col]], df[[key_col]])
}

.already_seeded <- function(con, table) {
    n <- DBI::dbGetQuery(
        con,
        sprintf('SELECT COUNT(*) FROM "mbhlmaintenance"."%s"', table)
    )[[1]]
    n > 0L
}

.tbl_maint <- function(table) DBI::Id(schema = "mbhlmaintenance", table = table)


# ── Fonctions seed individuelles ──────────────────────────────────────────────

#' Seed demo: unités physiques individuelles (parts)
#' @param con Connexion ou pool DBI.
#' @export
seed_demo_parts_instances <- function(con) {
    if (.already_seeded(con, "parts")) {
        cli::cli_inform(c("v" = "parts déjà peuplée — ignorée."))
        return(invisible(NULL))
    }

    df      <- .read_seed_csv("parts_instances.csv")
    cat_lkp <- .build_lookup(con, "mbhlcore", "parts_catalog", "part_number", "catalog_id")

    df$catalog_id  <- cat_lkp[df$part_number]
    df$part_number <- NULL

    df$is_active        <- .bool_col(df$is_active)
    df$manufacture_date <- as.Date(df$manufacture_date)

    DBI::dbAppendTable(con, .tbl_maint("parts"), df)
    cli::cli_inform(c("v" = "{nrow(df)} unités insérées dans parts."))
    invisible(NULL)
}


#' Seed demo: journal des événements TSN/TSO (part_events)
#' @param con Connexion ou pool DBI.
#' @export
seed_demo_part_events <- function(con) {
    if (.already_seeded(con, "part_events")) {
        cli::cli_inform(c("v" = "part_events déjà peuplée — ignorée."))
        return(invisible(NULL))
    }

    df    <- .read_seed_csv("part_events.csv")
    today <- Sys.Date()

    # Lookups
    parts_df <- DBI::dbGetQuery(con, '
        SELECT p.part_id, pc.part_number, p.serial_number
        FROM mbhlmaintenance.parts p
        JOIN mbhlcore.parts_catalog pc USING (catalog_id)
    ')
    parts_df$key <- paste(parts_df$part_number, parts_df$serial_number, sep = "|||")
    part_lkp <- stats::setNames(parts_df$part_id, parts_df$key)

    ac_lkp   <- .build_lookup(con, "mbhlcore",        "aircraft",  "registration",  "aircraft_id")
    pers_lkp <- .build_lookup(con, "mbhlcore",        "personnel", "full_name",     "personnel_id")
    sn_lkp   <- .build_lookup(con, "mbhlmaintenance", "parts",     "serial_number", "part_id")

    df$part_id              <- part_lkp[paste(df$part_number, df$serial_number, sep = "|||")]
    df$aircraft_id          <- ac_lkp[df$aircraft_registration]
    df$personnel_id         <- pers_lkp[df$created_by_full_name]
    df$installed_on_part_id <- sn_lkp[df$installed_on_serial_number]

    df$personnel_id          <- as.integer(ifelse(is.na(df$personnel_id), 1L, df$personnel_id))
    df$days_ago              <- as.integer(df$days_ago)
    df$tsn_at_event          <- suppressWarnings(as.numeric(df$tsn_at_event))
    df$tso_at_event          <- suppressWarnings(as.numeric(df$tso_at_event))
    df$csn_at_event          <- suppressWarnings(as.integer(df$csn_at_event))
    df$cso_at_event          <- suppressWarnings(as.integer(df$cso_at_event))
    df$unit_airtime_at_event <- suppressWarnings(as.numeric(df$unit_airtime_at_event))
    df$unit_cycles_at_event  <- suppressWarnings(as.integer(df$unit_cycles_at_event))

    # Receive events — toutes les pièces
    recv <- data.frame(
        part_id               = df$part_id,
        event_type            = "receive",
        event_date            = today - df$days_ago - 1L,
        work_order_id         = NA_integer_,
        installed_on_id       = NA_integer_,
        installed_on_type     = NA_character_,
        unit_airtime_at_event = NA_real_,
        unit_cycles_at_event  = NA_integer_,
        part_tsn_at_event     = df$tsn_at_event,
        part_csn_at_event     = df$csn_at_event,
        part_tso_at_event     = df$tso_at_event,
        part_cso_at_event     = df$cso_at_event,
        part_ts_lsv_at_event  = NA_real_,
        part_cs_lsv_at_event  = NA_integer_,
        part_hobbs_at_event   = NA_real_,
        installed_on_part_id  = NA_integer_,
        position_id           = NA_integer_,
        is_anchor             = FALSE,
        anchor_note           = NA_character_,
        notes                 = NA_character_,
        created_by            = df$personnel_id,
        created_at            = as.POSIXct(today - df$days_ago - 1L),
        stringsAsFactors      = FALSE
    )

    # Install events — pièces assignées à un avion
    inst_df <- df[!is.na(df$aircraft_id), ]

    inst_ev <- data.frame(
        part_id               = inst_df$part_id,
        event_type            = "install",
        event_date            = today - inst_df$days_ago,
        work_order_id         = NA_integer_,
        installed_on_id       = as.integer(inst_df$aircraft_id),
        installed_on_type     = "aircraft",
        unit_airtime_at_event = inst_df$unit_airtime_at_event,
        unit_cycles_at_event  = inst_df$unit_cycles_at_event,
        part_tsn_at_event     = inst_df$tsn_at_event,
        part_csn_at_event     = inst_df$csn_at_event,
        part_tso_at_event     = inst_df$tso_at_event,
        part_cso_at_event     = inst_df$cso_at_event,
        part_ts_lsv_at_event  = NA_real_,
        part_cs_lsv_at_event  = NA_integer_,
        part_hobbs_at_event   = NA_real_,
        installed_on_part_id  = as.integer(inst_df$installed_on_part_id),
        position_id           = NA_integer_,
        is_anchor             = FALSE,
        anchor_note           = NA_character_,
        notes                 = NA_character_,
        created_by            = inst_df$personnel_id,
        created_at            = as.POSIXct(today - inst_df$days_ago),
        stringsAsFactors      = FALSE
    )

    events <- rbind(recv, inst_ev)
    events <- events[order(events$event_date), ]

    DBI::dbAppendTable(con, .tbl_maint("part_events"), events)
    n_recv <- sum(events$event_type == "receive")
    n_inst <- sum(events$event_type == "install")
    cli::cli_inform(c("v" = "{nrow(events)} événements insérés ({n_recv} receive, {n_inst} install)."))
    invisible(NULL)
}


#' Seed demo: airtime courant par appareil
#'
#' Peuple `aircraft_airtime` — base de calcul du forecast jusqu'à
#' l'intégration de logpage.
#' @param con Connexion ou pool DBI.
#' @export
seed_demo_aircraft_airtime <- function(con) {
    if (.already_seeded(con, "aircraft_airtime")) {
        cli::cli_inform(c("v" = "aircraft_airtime déjà peuplée — ignorée."))
        return(invisible(NULL))
    }

    today    <- Sys.Date()
    ac_lkp   <- .build_lookup(con, "mbhlcore", "aircraft",  "registration", "aircraft_id")
    pers_lkp <- .build_lookup(con, "mbhlcore", "personnel", "full_name",    "personnel_id")
    signer   <- as.integer(pers_lkp[["Sophie Charron"]])

    rows <- list(
        list(reg = "C-FLY1", airtime =  6850, cycles =  5100L),
        list(reg = "C-FLY2", airtime =  5200, cycles =  3900L),
        list(reg = "C-FLY3", airtime =  3150, cycles =  2350L),
        list(reg = "C-FLY4", airtime = 21500, cycles = 15800L),
        list(reg = "C-FLY5", airtime = 16200, cycles = 11900L),
        list(reg = "C-FLY6", airtime = 13100, cycles =  9600L),
        list(reg = "C-FLY7", airtime =  8500, cycles =  6200L),
        list(reg = "C-FLY8", airtime =  5100, cycles =  3750L),
        list(reg = "C-FLY9", airtime =  4900, cycles =  3600L)
    )

    df <- do.call(rbind, lapply(rows, function(r) {
        data.frame(
            aircraft_id     = as.integer(ac_lkp[[r$reg]]),
            current_airtime = r$airtime,
            current_cycles  = r$cycles,
            confirmed_date  = today,
            confirmed_by    = signer,
            updated_at      = as.POSIXct(today),
            stringsAsFactors = FALSE
        )
    }))

    DBI::dbAppendTable(con, .tbl_maint("aircraft_airtime"), df)
    cli::cli_inform(c("v" = "Airtime courant pour {nrow(df)} appareils."))
    invisible(NULL)
}


#' Seed demo: work orders (stubs pour inspection_completions)
#'
#' Crée des WOs complétés minimalistes. Nécessaires pour la FK de
#' `inspection_completions`.
#' @param con Connexion ou pool DBI.
#' @export
seed_demo_work_orders <- function(con) {
    if (.already_seeded(con, "work_orders")) {
        cli::cli_inform(c("v" = "work_orders déjà peuplée — ignorée."))
        return(invisible(NULL))
    }

    today    <- Sys.Date()
    ac_lkp   <- .build_lookup(con, "mbhlcore", "aircraft",  "registration", "aircraft_id")
    pers_lkp <- .build_lookup(con, "mbhlcore", "personnel", "full_name",    "personnel_id")
    rene_id  <- as.integer(pers_lkp[["René Bergeron"]])
    sophie_id <- as.integer(pers_lkp[["Sophie Charron"]])

    # reg, seq, days_ago, airtime, cycles
    specs <- list(
        list("C-FLY1", 1, 365,  6200,  4620),  # WO-DEMO-001
        list("C-FLY1", 2, 300,  6350,  4730),  # WO-DEMO-002  ← Annual
        list("C-FLY1", 3, 180,  6550,  4880),  # WO-DEMO-003
        list("C-FLY1", 4,  45,  6760,  5040),  # WO-DEMO-004  ← 100h (RED: 10h restantes)
        list("C-FLY2", 1, 360,  4620,  3450),  # WO-DEMO-005  ← Annual (RED: 5 jours)
        list("C-FLY2", 2, 200,  4920,  3680),  # WO-DEMO-006
        list("C-FLY2", 3,  30,  5170,  3870),  # WO-DEMO-007  ← 100h
        list("C-FLY3", 1, 390,  2750,  2050),  # WO-DEMO-008  ← Annual (RED: dépassé 25j)
        list("C-FLY3", 2, 200,  2950,  2200),  # WO-DEMO-009
        list("C-FLY3", 3,  20,  3130,  2330),  # WO-DEMO-010  ← 100h
        list("C-FLY4", 1, 500, 20050, 14700),  # WO-DEMO-011
        list("C-FLY4", 2, 200, 21000, 15400),  # WO-DEMO-012  ← Annual
        list("C-FLY4", 3, 120, 21300, 15620),  # WO-DEMO-013  ← A-Check
        list("C-FLY5", 1, 400, 14850, 10900),  # WO-DEMO-014
        list("C-FLY5", 2, 340, 15200, 11150),  # WO-DEMO-015  ← Annual (YELLOW: 25j)
        list("C-FLY5", 3, 180, 15950, 11700),  # WO-DEMO-016  ← A-Check (date: aujourd'hui)
        list("C-FLY6", 1, 400, 12000,  8800),  # WO-DEMO-017
        list("C-FLY6", 2, 200, 12600,  9250),  # WO-DEMO-018
        list("C-FLY6", 3, 100, 12850,  9430),  # WO-DEMO-019  ← A-Check + Annual
        list("C-FLY7", 1, 450,  7650,  5600),  # WO-DEMO-020  ← Annual (RED: dépassé 85j)
        list("C-FLY7", 2, 250,  8200,  6010),  # WO-DEMO-021  ← A-Check (RED date: dépassé 70j)
        list("C-FLY8", 1, 300,  4600,  3380),  # WO-DEMO-022  ← Annual
        list("C-FLY8", 2, 180,  4800,  3520),  # WO-DEMO-023
        list("C-FLY8", 3,  25,  5060,  3720),  # WO-DEMO-024  ← 100h
        list("C-FLY9", 1, 400,  4150,  3050),  # WO-DEMO-025
        list("C-FLY9", 2, 355,  4200,  3090),  # WO-DEMO-026  ← Annual (YELLOW: 10j)
        list("C-FLY9", 3,  35,  4870,  3575)   # WO-DEMO-027  ← 100h
    )

    df <- do.call(rbind, lapply(seq_along(specs), function(i) {
        s     <- specs[[i]]
        ac_id <- as.integer(ac_lkp[[s[[1]]]])
        dt    <- today - s[[3]]
        data.frame(
            wo_number         = sprintf("WO-DEMO-%03d", i),
            wo_type           = "aircraft",
            status            = "completed",
            aircraft_id       = ac_id,
            part_id           = NA_integer_,
            confirmed_airtime = as.numeric(s[[4]]),
            confirmed_cycles  = as.integer(s[[5]]),
            confirmed_date    = dt,
            entry_date        = dt,
            is_transcription  = FALSE,
            opened_by         = rene_id,
            opened_date       = as.POSIXct(dt),
            completed_by      = sophie_id,
            completed_date    = as.POSIXct(dt),
            notes             = NA_character_,
            stringsAsFactors  = FALSE
        )
    }))

    DBI::dbAppendTable(con, .tbl_maint("work_orders"), df)
    cli::cli_inform(c("v" = "{nrow(df)} work orders insérés."))
    invisible(NULL)
}


#' Seed demo: inspections et limites
#'
#' Crée les inspections avion (via `aircraft_id`) et composante (via `part_id`)
#' avec leurs limites. Les completions composante s'appuient sur `part_events`.
#' @param con Connexion ou pool DBI.
#' @export
seed_demo_inspections <- function(con) {
    if (.already_seeded(con, "inspections")) {
        cli::cli_inform(c("v" = "inspections déjà peuplée — ignorée."))
        return(invisible(NULL))
    }

    ac_lkp <- .build_lookup(con, "mbhlcore", "aircraft", "registration", "aircraft_id")

    parts_q <- DBI::dbGetQuery(con, "
        SELECT p.part_id, pc.part_number, p.serial_number
        FROM mbhlmaintenance.parts p
        JOIN mbhlcore.parts_catalog pc USING (catalog_id)
        WHERE p.serial_number IS NOT NULL
    ")
    part_lkp <- stats::setNames(
        parts_q$part_id,
        paste(parts_q$part_number, parts_q$serial_number, sep = "|||")
    )

    .ins <- function(aircraft_id = NULL, part_id = NULL, desc, ata = "05", limits) {
        insp_id <- DBI::dbGetQuery(con, "
            INSERT INTO mbhlmaintenance.inspections
              (aircraft_id, part_id, description, ata_chapter, is_active)
            VALUES ($1, $2, $3, $4, TRUE)
            RETURNING inspection_id
        ", list(aircraft_id, part_id, desc, ata))[[1L]]

        for (lim in limits) {
            DBI::dbExecute(con, "
                INSERT INTO mbhlmaintenance.inspection_limits
                  (inspection_id, limit_type, interval_value, interval_unit,
                   window_plus, window_minus)
                VALUES ($1, $2, $3, $4, $5, $6)
            ", list(
                insp_id, lim$type, lim$value, lim$unit,
                if (is.null(lim$wp)) NA_real_ else lim$wp,
                if (is.null(lim$wm)) NA_real_ else lim$wm
            ))
        }
        invisible(insp_id)
    }

    n <- 0L

    # ── HB08 : C-FLY1, C-FLY2, C-FLY3 ─────────────────────────────────────
    for (reg in c("C-FLY1", "C-FLY2", "C-FLY3")) {
        ac <- as.integer(ac_lkp[[reg]])
        .ins(aircraft_id = ac, desc = "100-Hour Inspection", ata = "05",
             limits = list(list(type = "airtime", value = 100, unit = "hours",
                                wp = 10, wm = 10)))
        .ins(aircraft_id = ac, desc = "Annual Inspection", ata = "05",
             limits = list(list(type = "date", value = 12, unit = "months",
                                wp = 30, wm = 30)))
        n <- n + 2L
    }

    # ── HF34 : C-FLY4 à C-FLY7 ─────────────────────────────────────────────
    for (reg in c("C-FLY4", "C-FLY5", "C-FLY6", "C-FLY7")) {
        ac <- as.integer(ac_lkp[[reg]])
        .ins(aircraft_id = ac, desc = "A-Check", ata = "05",
             limits = list(
                 list(type = "airtime", value = 500, unit = "hours", wp = 25, wm = 25),
                 list(type = "date",    value = 180, unit = "days",  wp =  7, wm =  7)
             ))
        .ins(aircraft_id = ac, desc = "Annual Inspection", ata = "05",
             limits = list(list(type = "date", value = 12, unit = "months",
                                wp = 30, wm = 30)))
        n <- n + 2L
    }

    # ── BU12 : C-FLY8, C-FLY9 ───────────────────────────────────────────────
    for (reg in c("C-FLY8", "C-FLY9")) {
        ac <- as.integer(ac_lkp[[reg]])
        .ins(aircraft_id = ac, desc = "100-Hour Inspection", ata = "05",
             limits = list(list(type = "airtime", value = 100, unit = "hours",
                                wp = 5, wm = 5)))
        .ins(aircraft_id = ac, desc = "Annual Inspection", ata = "05",
             limits = list(list(type = "date", value = 12, unit = "months",
                                wp = 30, wm = 30)))
        n <- n + 2L
    }

    # ── Moteurs HB08 — SYRINX-ENG-001 ───────────────────────────────────────
    for (sn in c("SYN-E-4821", "SYN-E-4822", "SYN-E-3109")) {
        pid <- as.integer(part_lkp[[paste("SYRINX-ENG-001", sn, sep = "|||")]])
        if (is.na(pid)) next
        .ins(part_id = pid, desc = "Engine TBO", ata = "72",
             limits = list(list(type = "airtime", value = 3600, unit = "hours")))
        n <- n + 1L
    }

    # ── Moteurs HF34 — 9381T16G34 (CT7-9B) ──────────────────────────────────
    for (sn in c("GE-E-791023", "GE-E-803445", "GE-E-792108",
                 "GE-E-819334", "GE-E-807621", "GE-E-831097", "GE-E-798456")) {
        pid <- as.integer(part_lkp[[paste("9381T16G34", sn, sep = "|||")]])
        if (is.na(pid)) next
        .ins(part_id = pid, desc = "Engine Hot Section / TBO", ata = "72",
             limits = list(list(type = "airtime", value = 5000, unit = "hours")))
        n <- n + 1L
    }

    # ── Hélices HF34 — REMIGE-PROP-001 ──────────────────────────────────────
    for (sn in c("REM-P-4401", "REM-P-4402", "REM-P-5103", "REM-P-5104",
                 "REM-P-6207", "REM-P-6208", "REM-P-6209", "REM-P-7301")) {
        pid <- as.integer(part_lkp[[paste("REMIGE-PROP-001", sn, sep = "|||")]])
        if (is.na(pid)) next
        .ins(part_id = pid, desc = "Propeller Overhaul", ata = "61",
             limits = list(
                 list(type = "airtime", value = 2400, unit = "hours"),
                 list(type = "date",    value =   72, unit = "months")
             ))
        n <- n + 1L
    }

    # ── Hélices HB08 — HC-E7A-6D/E43700K ────────────────────────────────────
    for (sn in c("KX52", "KX48")) {
        pid <- as.integer(part_lkp[[paste("HC-E7A-6D/E43700K", sn, sep = "|||")]])
        if (is.na(pid)) next
        .ins(part_id = pid, desc = "Propeller Overhaul", ata = "61",
             limits = list(
                 list(type = "airtime", value = 2400, unit = "hours"),
                 list(type = "date",    value =   72, unit = "months")
             ))
        n <- n + 1L
    }

    # ── Starter-Gen HB08 — SYRINX-STG-001 ───────────────────────────────────
    for (sn in c("STG-7741", "STG-7742", "STG-7743")) {
        pid <- as.integer(part_lkp[[paste("SYRINX-STG-001", sn, sep = "|||")]])
        if (is.na(pid)) next
        .ins(part_id = pid, desc = "Starter-Gen Bench Check", ata = "24",
             limits = list(list(type = "airtime", value = 500, unit = "hours")))
        n <- n + 1L
    }

    # ── FCU HB08 — SYRINX-FCU-001 ───────────────────────────────────────────
    for (sn in c("FCU-2201", "FCU-2202", "FCU-S301")) {
        pid <- as.integer(part_lkp[[paste("SYRINX-FCU-001", sn, sep = "|||")]])
        if (is.na(pid)) next
        .ins(part_id = pid, desc = "Fuel Control Unit Bench Check", ata = "73",
             limits = list(list(type = "airtime", value = 2000, unit = "hours")))
        n <- n + 1L
    }

    cli::cli_inform(c("v" = "{n} inspections insérées."))
    invisible(NULL)
}


#' Seed demo: completions d'inspections avion
#'
#' Historique de completions pour les inspections liées à `aircraft_id`.
#' Les inspections composante utilisent `part_events` comme baseline.
#' @param con Connexion ou pool DBI.
#' @export
seed_demo_inspection_completions <- function(con) {
    if (.already_seeded(con, "inspection_completions")) {
        cli::cli_inform(c("v" = "inspection_completions déjà peuplée — ignorée."))
        return(invisible(NULL))
    }

    pers_lkp <- .build_lookup(con, "mbhlcore", "personnel", "full_name", "personnel_id")
    rene_id  <- as.integer(pers_lkp[["René Bergeron"]])

    insp_q <- DBI::dbGetQuery(con, "
        SELECT i.inspection_id, a.registration, i.description
        FROM mbhlmaintenance.inspections i
        JOIN mbhlcore.aircraft a ON a.aircraft_id = i.aircraft_id
        WHERE i.aircraft_id IS NOT NULL AND i.is_active = TRUE
    ")
    insp_lkp <- stats::setNames(
        insp_q$inspection_id,
        paste(insp_q$registration, insp_q$description, sep = "|||")
    )

    wo_q <- DBI::dbGetQuery(con, "
        SELECT wo_id, wo_number, confirmed_date,
               confirmed_airtime, confirmed_cycles
        FROM mbhlmaintenance.work_orders
        WHERE wo_number LIKE 'WO-DEMO-%'
    ")
    .wo <- function(field, num) {
        idx <- match(num, wo_q$wo_number)
        if (is.na(idx)) return(NA)
        wo_q[[field]][[idx]]
    }

    # reg, description, wo_number
    specs <- list(
        list("C-FLY1", "100-Hour Inspection", "WO-DEMO-004"),  # RED  10h restantes
        list("C-FLY1", "Annual Inspection",   "WO-DEMO-002"),  # GREEN 65j
        list("C-FLY2", "100-Hour Inspection", "WO-DEMO-007"),  # GREEN 70h
        list("C-FLY2", "Annual Inspection",   "WO-DEMO-005"),  # RED   5j
        list("C-FLY3", "100-Hour Inspection", "WO-DEMO-010"),  # GREEN 80h
        list("C-FLY3", "Annual Inspection",   "WO-DEMO-008"),  # RED   dépassé 25j
        list("C-FLY4", "A-Check",             "WO-DEMO-013"),  # YELLOW 300h / 60j
        list("C-FLY4", "Annual Inspection",   "WO-DEMO-012"),  # GREEN 165j
        list("C-FLY5", "A-Check",             "WO-DEMO-016"),  # RED   date aujourd'hui
        list("C-FLY5", "Annual Inspection",   "WO-DEMO-015"),  # YELLOW 25j
        list("C-FLY6", "A-Check",             "WO-DEMO-019"),  # YELLOW 250h / 80j
        list("C-FLY6", "Annual Inspection",   "WO-DEMO-019"),  # GREEN 265j
        list("C-FLY7", "A-Check",             "WO-DEMO-021"),  # RED   dépassé 70j
        list("C-FLY7", "Annual Inspection",   "WO-DEMO-020"),  # RED   dépassé 85j
        list("C-FLY8", "100-Hour Inspection", "WO-DEMO-024"),  # GREEN 60h
        list("C-FLY8", "Annual Inspection",   "WO-DEMO-022"),  # GREEN 65j
        list("C-FLY9", "100-Hour Inspection", "WO-DEMO-027"),  # GREEN 70h
        list("C-FLY9", "Annual Inspection",   "WO-DEMO-026")   # YELLOW 10j
    )

    rows <- Filter(Negate(is.null), lapply(specs, function(s) {
        key     <- paste(s[[1]], s[[2]], sep = "|||")
        insp_id <- as.integer(insp_lkp[[key]])
        wo_id   <- as.integer(.wo("wo_id",             s[[3]]))
        at      <- as.numeric(.wo("confirmed_airtime", s[[3]]))
        cyc     <- as.integer(.wo("confirmed_cycles",  s[[3]]))
        dt      <- as.Date(  .wo("confirmed_date",     s[[3]]))

        if (is.na(insp_id) || is.na(wo_id)) {
            cli::cli_warn("Introuvable : {key} / {s[[3]]}")
            return(NULL)
        }
        data.frame(
            inspection_id            = insp_id,
            work_order_id            = wo_id,
            signed_by                = rene_id,
            signed_date              = dt,
            airtime_at_completion    = at,
            cycles_at_completion     = cyc,
            date_at_completion       = dt,
            is_in_progress           = FALSE,
            requires_dual_inspection = FALSE,
            requires_flight_test     = FALSE,
            is_voided                = FALSE,
            stringsAsFactors         = FALSE
        )
    }))

    df <- do.call(rbind, rows)
    DBI::dbAppendTable(con, .tbl_maint("inspection_completions"), df)
    cli::cli_inform(c("v" = "{nrow(df)} completions insérées."))
    invisible(NULL)
}


#' Seed demo: toutes les tables mbhlmaintenance
#'
#' Lance toutes les fonctions seed dans l'ordre. Idempotent — les tables
#' déjà peuplées sont ignorées.
#' @param con Connexion ou pool DBI.
#' @export
seed_demo_data_maintenance <- function(con) {
    seed_demo_parts_instances(con)
    seed_demo_part_events(con)
    seed_demo_aircraft_airtime(con)
    seed_demo_work_orders(con)
    seed_demo_inspections(con)
    seed_demo_inspection_completions(con)
    invisible(NULL)
}
