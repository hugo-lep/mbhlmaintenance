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


#' Seed demo: toutes les tables mbhlmaintenance
#'
#' Lance toutes les fonctions seed dans l'ordre. Idempotent — les tables
#' déjà peuplées sont ignorées.
#' @param con Connexion ou pool DBI.
#' @export
seed_demo_data_maintenance <- function(con) {
    seed_demo_parts_instances(con)
    seed_demo_part_events(con)
    invisible(NULL)
}
