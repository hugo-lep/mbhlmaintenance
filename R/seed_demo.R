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


#' Seed demo: toutes les tables mbhlmaintenance
#'
#' Lance toutes les fonctions seed dans l'ordre. Idempotent — les tables
#' déjà peuplées sont ignorées.
#' @param con Connexion ou pool DBI.
#' @export
seed_demo_data_maintenance <- function(con) {
    seed_demo_parts_instances(con)
    invisible(NULL)
}
