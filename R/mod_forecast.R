#' Module — Forecast de maintenance
#'
#' Vue d'ensemble des prochaines échéances pour tous les appareils ou un
#' seul. Une ligne par inspection dans la table principale ; clic sur une
#' ligne ouvre un modal détaillant chaque limite individuellement.
#'
#' @param id  Identifiant de namespace Shiny.
#' @param refresh  Reactive signal — déclenche un rechargement des données.
#' @export
mod_forecast_ui <- function(id) {
    ns <- shiny::NS(id)

    shiny::tagList(
        # Barre de filtres
        bslib::card(
            bslib::card_body(
                padding = "0.5rem",
                bslib::layout_columns(
                    col_widths = c(3, 3, 3, 3),
                    shiny::selectInput(
                        ns("filter_aircraft"),
                        label   = NULL,
                        choices = c("Tous les appareils" = "0")
                    ),
                    shiny::selectInput(
                        ns("filter_status"),
                        label   = NULL,
                        choices = c(
                            "Tous les statuts"   = "",
                            "Dépassé / Urgent"   = "overdue",
                            "Bientôt dû (jaune)" = "yellow",
                            "OK"                 = "green"
                        )
                    ),
                    shiny::selectInput(
                        ns("filter_type"),
                        label   = NULL,
                        choices = c(
                            "Avion + composantes" = "",
                            "Avion seulement"     = "aircraft",
                            "Composantes seulement" = "component"
                        )
                    ),
                    shiny::div(
                        class = "d-flex align-items-center",
                        shiny::tags$small(
                            class = "text-secondary",
                            shiny::textOutput(ns("airtime_info"), inline = TRUE)
                        )
                    )
                )
            )
        ),

        # Table principale
        bslib::card(
            full_screen = TRUE,
            bslib::card_header(
                shiny::icon("calendar-check"), " Forecast maintenance",
                shiny::span(
                    style = "font-size:0.8rem; font-weight:normal; color:var(--bs-secondary-color);",
                    shiny::textOutput(ns("row_count"), inline = TRUE)
                )
            ),
            bslib::card_body(
                padding = 0,
                DT::DTOutput(ns("tbl"), fill = TRUE)
            )
        )
    )
}

#' @rdname mod_forecast_ui
#' @export
mod_forecast_server <- function(id, refresh = NULL) {
    shiny::moduleServer(id, function(input, output, session) {

        pool <- session$userData$pool

        # ── Chargement de la liste d'appareils ────────────────────────────
        shiny::observe({
            if (!is.null(refresh)) refresh()

            rows <- DBI::dbGetQuery(pool, "
                SELECT a.aircraft_id, a.registration
                FROM   mbhlcore.aircraft a
                WHERE  a.is_active = TRUE
                ORDER  BY a.registration
            ")

            choices <- stats::setNames(as.character(rows$aircraft_id),
                                       rows$registration)
            shiny::updateSelectInput(session, "filter_aircraft",
                choices = c("Tous les appareils" = "0", choices))
        })

        # ── SQL forecast (une ligne par inspection × limite) ──────────────
        rv_limits <- shiny::reactive({
            if (!is.null(refresh)) refresh()

            ac_id <- as.integer(input$filter_aircraft %||% "0")
            if (is.na(ac_id)) ac_id <- 0L

            sql <- "
WITH
installed_parts AS (
    SELECT DISTINCT ON (pe.part_id)
        pe.part_id,
        pe.installed_on_id           AS aircraft_id,
        pe.unit_airtime_at_event     AS airtime_at_install,
        pe.part_tsn_at_event         AS tsn_at_install,
        pe.part_tso_at_event         AS tso_at_install,
        pe.event_date                AS install_date
    FROM mbhlmaintenance.part_events pe
    WHERE pe.event_type = 'install'
      AND pe.installed_on_type = 'aircraft'
    ORDER BY pe.part_id, pe.event_date DESC, pe.event_id DESC
),
last_completion AS (
    SELECT DISTINCT ON (inspection_id)
        inspection_id,
        airtime_at_completion,
        cycles_at_completion,
        date_at_completion,
        signed_date AS last_signed_date
    FROM mbhlmaintenance.inspection_completions
    WHERE is_voided = FALSE
    ORDER BY inspection_id, signed_date DESC, completion_id DESC
)
SELECT
    i.inspection_id,
    COALESCE(i.aircraft_id, ip.aircraft_id)   AS aircraft_id,
    a.registration,
    i.description,
    COALESCE(i.ata_chapter, '')               AS ata_chapter,
    CASE WHEN i.aircraft_id IS NOT NULL
         THEN 'aircraft' ELSE 'component'
    END                                        AS insp_type,
    pc.part_number,
    p.serial_number,
    -- Baseline
    lc.last_signed_date,
    COALESCE(lc.date_at_completion,     ip.install_date)       AS baseline_date,
    COALESCE(lc.airtime_at_completion,  ip.airtime_at_install) AS baseline_airtime,
    ip.tso_at_install,
    ip.tsn_at_install,
    ip.install_date,
    (lc.inspection_id IS NOT NULL) AS has_completion,
    -- Limite
    il.limit_id,
    il.limit_type,
    il.interval_value,
    il.interval_unit,
    il.window_plus,
    il.window_minus,
    -- État courant de l'appareil
    aa.current_airtime,
    aa.current_cycles,
    -- Next due
    CASE
        WHEN il.limit_type = 'date' THEN
            CASE il.interval_unit
                WHEN 'months' THEN
                    COALESCE(lc.date_at_completion, ip.install_date)
                    + (il.interval_value::INTEGER * INTERVAL '1 month')
                WHEN 'days' THEN
                    COALESCE(lc.date_at_completion, ip.install_date)
                    + (il.interval_value::INTEGER * INTERVAL '1 day')
                ELSE NULL
            END
        ELSE NULL
    END AS next_due_date,
    CASE
        WHEN il.limit_type = 'airtime' THEN
            CASE
                WHEN lc.airtime_at_completion IS NOT NULL THEN
                    lc.airtime_at_completion + il.interval_value
                WHEN ip.airtime_at_install IS NOT NULL THEN
                    ip.airtime_at_install + il.interval_value
                    - COALESCE(NULLIF(ip.tso_at_install, 0),
                               ip.tsn_at_install, 0)
                ELSE NULL
            END
        ELSE NULL
    END AS next_due_airtime
FROM mbhlmaintenance.inspections i
LEFT JOIN installed_parts              ip ON ip.part_id     = i.part_id
LEFT JOIN mbhlmaintenance.parts         p  ON p.part_id      = i.part_id
LEFT JOIN mbhlcore.parts_catalog       pc ON pc.catalog_id   = p.catalog_id
LEFT JOIN last_completion              lc ON lc.inspection_id = i.inspection_id
LEFT JOIN mbhlmaintenance.aircraft_airtime aa
       ON aa.aircraft_id = COALESCE(i.aircraft_id, ip.aircraft_id)
LEFT JOIN mbhlcore.aircraft             a
       ON a.aircraft_id  = COALESCE(i.aircraft_id, ip.aircraft_id)
JOIN  mbhlmaintenance.inspection_limits il
       ON il.inspection_id = i.inspection_id
WHERE i.is_active = TRUE
  AND COALESCE(i.aircraft_id, ip.aircraft_id) IS NOT NULL
  AND ($1 = 0 OR COALESCE(i.aircraft_id, ip.aircraft_id) = $1)
"
            df <- DBI::dbGetQuery(pool, sql, list(ac_id))

            # ── Calcul des valeurs restantes (côté R) ─────────────────────
            today <- Sys.Date()
            df$next_due_date <- as.Date(df$next_due_date)

            df$remaining_days  <- as.integer(df$next_due_date - today)
            df$remaining_hours <- df$next_due_airtime - df$current_airtime

            # Statut par ligne
            df$limit_status <- .forecast_limit_status(
                df$limit_type,
                df$remaining_days,
                df$remaining_hours
            )

            df
        })

        # ── Résumé par inspection (une ligne par inspection) ───────────────
        rv_summary <- shiny::reactive({
            df <- rv_limits()
            if (nrow(df) == 0L) return(.forecast_empty_summary())

            .forecast_aggregate(df)
        })

        # ── Infos airtime de l'appareil sélectionné ───────────────────────
        output$airtime_info <- shiny::renderText({
            ac_id <- as.integer(input$filter_aircraft %||% "0")
            if (is.na(ac_id) || ac_id == 0L) return("")

            row <- DBI::dbGetQuery(pool, "
                SELECT current_airtime, current_cycles, confirmed_date
                FROM   mbhlmaintenance.aircraft_airtime
                WHERE  aircraft_id = $1
            ", list(ac_id))

            if (nrow(row) == 0L) return("(airtime non confirmé)")
            sprintf("Airtime confirmé : %.1fh  |  %d cyc  —  %s",
                    row$current_airtime, row$current_cycles %||% 0L,
                    format(as.Date(row$confirmed_date), "%Y-%m-%d"))
        })

        # ── Rendu de la table ─────────────────────────────────────────────
        output$tbl <- DT::renderDT({
            s   <- rv_summary()
            flt <- input$filter_status
            typ <- input$filter_type

            if (!is.null(flt) && flt != "") {
                s <- s[s$status %in% .forecast_status_group(flt), ]
            }
            if (!is.null(typ) && typ != "") {
                s <- s[s$insp_type == typ, ]
            }

            # Trier : overdue en premier, puis red, yellow, green ; puis ATA
            s$sort_key <- match(s$status,
                                c("overdue", "red", "yellow", "green"),
                                nomatch = 5L)
            s <- s[order(s$sort_key, s$registration, s$ata_chapter), ]

            show_ac_col <- (as.integer(input$filter_aircraft %||% "0") == 0L)

            .forecast_build_dt(s, show_ac_col = show_ac_col,
                               ns = session$ns)
        }, server = FALSE)

        output$row_count <- shiny::renderText({
            s   <- rv_summary()
            flt <- input$filter_status
            typ <- input$filter_type
            if (!is.null(flt) && flt != "")
                s <- s[s$status %in% .forecast_status_group(flt), ]
            if (!is.null(typ) && typ != "")
                s <- s[s$insp_type == typ, ]
            sprintf("(%d inspection%s)", nrow(s), if (nrow(s) != 1) "s" else "")
        })

        # ── Clic sur une ligne → modal détail ────────────────────────────
        shiny::observeEvent(input$tbl_rows_selected, {
            row_idx <- input$tbl_rows_selected
            if (length(row_idx) == 0L) return()

            s   <- rv_summary()
            flt <- input$filter_status
            typ <- input$filter_type
            if (!is.null(flt) && flt != "")
                s <- s[s$status %in% .forecast_status_group(flt), ]
            if (!is.null(typ) && typ != "")
                s <- s[s$insp_type == typ, ]
            s$sort_key <- match(s$status,
                                c("overdue", "red", "yellow", "green"),
                                nomatch = 5L)
            s <- s[order(s$sort_key, s$registration, s$ata_chapter), ]

            if (row_idx > nrow(s)) return()
            insp_id <- s$inspection_id[row_idx]

            limits  <- rv_limits()[rv_limits()$inspection_id == insp_id, ]
            summary_row <- s[s$inspection_id == insp_id, ]

            shiny::showModal(.forecast_detail_modal(summary_row, limits))
        })
    })
}

# ── Helpers internes ───────────────────────────────────────────────────────────

# Calcule le statut (overdue/red/yellow/green) pour chaque limite
.forecast_limit_status <- function(limit_type, remaining_days, remaining_hours) {
    status <- rep("green", length(limit_type))

    for (i in seq_along(limit_type)) {
        if (limit_type[i] == "date" && !is.na(remaining_days[i])) {
            r <- remaining_days[i]
            status[i] <- if (r <= 0) "overdue"
                         else if (r <= 7) "red"
                         else if (r <= 30) "yellow"
                         else "green"
        } else if (limit_type[i] == "airtime" && !is.na(remaining_hours[i])) {
            r <- remaining_hours[i]
            status[i] <- if (r <= 0) "overdue"
                         else if (r <= 20) "red"
                         else if (r <= 100) "yellow"
                         else "green"
        }
    }
    status
}

# Ordre de sévérité : overdue > red > yellow > green
.forecast_status_rank <- c(overdue = 4L, red = 3L, yellow = 2L, green = 1L)

# Groupe de statuts pour le filtre
.forecast_status_group <- function(flt) {
    switch(flt,
        overdue = c("overdue", "red"),
        yellow  = "yellow",
        green   = "green",
        c("overdue", "red", "yellow", "green")
    )
}

# Agrège les lignes par inspection : trouve le pire statut + la limite urgente
.forecast_aggregate <- function(df) {
    insp_ids <- unique(df$inspection_id)

    rows <- lapply(insp_ids, function(id) {
        sub <- df[df$inspection_id == id, ]

        # Rang le plus élevé = limite la plus urgente
        ranks <- .forecast_status_rank[sub$limit_status]
        worst_idx <- which.max(ranks)
        worst <- sub[worst_idx, ]

        # Texte "Dernier fait"
        last_done_txt <- if (isTRUE(worst$has_completion[1])) {
            format(as.Date(worst$last_signed_date[1]), "%Y-%m-%d")
        } else if (!is.na(worst$install_date[1])) {
            paste0("Inst. ", format(as.Date(worst$install_date[1]), "%Y-%m-%d"))
        } else {
            "—"
        }

        # Texte "Prochain dû" et "Reste" de la limite urgente
        due_txt       <- .fmt_due(worst$limit_type, worst$next_due_date,
                                  worst$next_due_airtime)
        remaining_txt <- .fmt_remaining(worst$limit_type, worst$remaining_days,
                                        worst$remaining_hours)
        status        <- worst$limit_status

        # Partie info composante
        part_txt <- if (worst$insp_type == "component" &&
                        !is.na(worst$part_number)) {
            paste0(worst$part_number,
                   if (!is.na(worst$serial_number))
                       paste0(" / ", worst$serial_number) else "")
        } else ""

        data.frame(
            inspection_id  = id,
            registration   = worst$registration,
            ata_chapter    = worst$ata_chapter,
            description    = worst$description,
            insp_type      = worst$insp_type,
            part_txt       = part_txt,
            last_done_txt  = last_done_txt,
            due_txt        = due_txt,
            remaining_txt  = remaining_txt,
            status         = status,
            stringsAsFactors = FALSE
        )
    })

    do.call(rbind, rows)
}

.forecast_empty_summary <- function() {
    data.frame(
        inspection_id  = integer(0),
        registration   = character(0),
        ata_chapter    = character(0),
        description    = character(0),
        insp_type      = character(0),
        part_txt       = character(0),
        last_done_txt  = character(0),
        due_txt        = character(0),
        remaining_txt  = character(0),
        status         = character(0),
        stringsAsFactors = FALSE
    )
}

# Formate la valeur "prochain dû"
.fmt_due <- function(limit_type, next_due_date, next_due_airtime) {
    vapply(seq_along(limit_type), function(i) {
        if (limit_type[i] == "date" && !is.na(next_due_date[i]))
            format(as.Date(next_due_date[i]), "%Y-%m-%d")
        else if (limit_type[i] == "airtime" && !is.na(next_due_airtime[i]))
            sprintf("%.0fh", next_due_airtime[i])
        else "—"
    }, character(1L))
}

# Formate la valeur "reste"
.fmt_remaining <- function(limit_type, remaining_days, remaining_hours) {
    vapply(seq_along(limit_type), function(i) {
        if (limit_type[i] == "date" && !is.na(remaining_days[i])) {
            r <- remaining_days[i]
            if (r <= 0) sprintf("Dépassé %dj", abs(r))
            else sprintf("%dj", r)
        } else if (limit_type[i] == "airtime" && !is.na(remaining_hours[i])) {
            r <- remaining_hours[i]
            if (r <= 0) sprintf("Dépassé %.0fh", abs(r))
            else sprintf("%.0fh", r)
        } else {
            "—"
        }
    }, character(1L))
}

# Badge HTML coloré pour la colonne "Reste"
.fmt_remaining_badge <- function(status, remaining_txt) {
    col <- switch(status,
        overdue = "danger",
        red     = "danger",
        yellow  = "warning",
        green   = "success",
        "secondary"
    )
    sprintf('<span class="badge text-bg-%s">%s</span>', col, remaining_txt)
}

# Badge type inspection
.fmt_insp_type_badge <- function(insp_type) {
    if (insp_type == "component")
        '<span class="badge text-bg-secondary" title="Inspection composante">CMP</span>'
    else
        '<span class="badge text-bg-primary" title="Inspection avion">A/C</span>'
}

# Construit le DT principal
.forecast_build_dt <- function(s, show_ac_col, ns) {
    if (nrow(s) == 0L) {
        disp <- data.frame(
            Statut      = character(0),
            Appareil    = character(0),
            "ATA · Description" = character(0),
            Composante  = character(0),
            "Dernier fait" = character(0),
            "Prochain dû"  = character(0),
            Reste       = character(0),
            check.names = FALSE
        )
    } else {
        disp <- data.frame(
            Statut          = .fmt_insp_type_badge(s$insp_type),
            Appareil        = s$registration,
            "ATA · Description" = ifelse(
                s$ata_chapter != "",
                paste0(s$ata_chapter, " — ", s$description),
                s$description
            ),
            Composante      = s$part_txt,
            "Dernier fait"  = s$last_done_txt,
            "Prochain dû" = s$due_txt,
            Reste           = mapply(.fmt_remaining_badge,
                                     s$status, s$remaining_txt,
                                     USE.NAMES = FALSE),
            check.names = FALSE,
            stringsAsFactors = FALSE
        )
    }

    hidden_cols <- if (!show_ac_col) 1L else integer(0L)   # col index 1 = Appareil (0-based: 1)

    DT::datatable(
        disp,
        selection   = "single",
        rownames    = FALSE,
        escape      = FALSE,
        extensions  = "Buttons",
        options     = list(
            dom         = "t",
            pageLength  = -1,
            scrollY     = "calc(100vh - 220px)",
            scrollCollapse = TRUE,
            columnDefs  = c(
                list(list(targets = 0L, width = "60px")),
                if (!show_ac_col)
                    list(list(targets = 1L, visible = FALSE))
                else
                    NULL
            ),
            language    = list(
                emptyTable = "Aucune inspection pour les filtres sélectionnés."
            )
        ),
        class = "table table-sm table-hover"
    )
}

# Modal de détail (toutes les limites d'une inspection)
.forecast_detail_modal <- function(summary_row, limits) {
    title_txt <- paste0(
        if (summary_row$ata_chapter != "")
            paste0(summary_row$ata_chapter, " — ")
        else "",
        summary_row$description
    )

    sub_title <- if (summary_row$insp_type == "component" &&
                     summary_row$part_txt != "") {
        shiny::tags$small(class = "text-secondary d-block mb-2",
                          summary_row$part_txt)
    }

    # Tableau des limites
    lim_rows <- lapply(seq_len(nrow(limits)), function(i) {
        lim <- limits[i, ]
        type_lbl <- switch(lim$limit_type,
            date    = "Date",
            airtime = "Airtime",
            cycles  = "Cycles",
            hobbs   = "Hobbs",
            lim$limit_type
        )
        interval_txt <- sprintf("%g %s", lim$interval_value, lim$interval_unit)
        window_txt   <- if (!is.na(lim$window_plus) || !is.na(lim$window_minus)) {
            sprintf("±%.0f%s",
                    max(lim$window_plus %||% 0, lim$window_minus %||% 0,
                        na.rm = TRUE),
                    if (lim$limit_type == "date") "j" else "h")
        } else "—"

        due_txt  <- .fmt_due(lim$limit_type, lim$next_due_date,
                             lim$next_due_airtime)
        rem_txt  <- .fmt_remaining(lim$limit_type, lim$remaining_days,
                                   lim$remaining_hours)
        badge    <- .fmt_remaining_badge(lim$limit_status, rem_txt)

        # Baseline label
        baseline_lbl <- if (isTRUE(lim$has_completion)) {
            format(as.Date(lim$last_signed_date), "%Y-%m-%d")
        } else if (!is.na(lim$install_date)) {
            paste0("Inst. ", format(as.Date(lim$install_date), "%Y-%m-%d"))
        } else "—"

        shiny::tags$tr(
            shiny::tags$td(type_lbl),
            shiny::tags$td(interval_txt),
            shiny::tags$td(window_txt),
            shiny::tags$td(baseline_lbl),
            shiny::tags$td(due_txt),
            shiny::tags$td(shiny::HTML(badge))
        )
    })

    lim_table <- shiny::tags$table(
        class = "table table-sm table-bordered mb-0",
        shiny::tags$thead(
            shiny::tags$tr(
                shiny::tags$th("Type"),
                shiny::tags$th("Intervalle"),
                shiny::tags$th("Window"),
                shiny::tags$th("Base"),
                shiny::tags$th("Prochain dû"),
                shiny::tags$th("Reste")
            )
        ),
        shiny::tags$tbody(lim_rows)
    )

    # Info appareil
    ac_info <- shiny::tags$small(
        class = "text-secondary d-flex gap-3 mb-3",
        shiny::tags$span(shiny::icon("plane"), " ", summary_row$registration),
        if (!is.na(limits$current_airtime[1]))
            shiny::tags$span(shiny::icon("clock"), sprintf(" %.1fh", limits$current_airtime[1]))
        else NULL,
        if (!is.na(limits$current_cycles[1]))
            shiny::tags$span(sprintf("%d cyc", limits$current_cycles[1]))
        else NULL
    )

    shiny::modalDialog(
        title = title_txt,
        easyClose = TRUE,
        footer = shiny::modalButton("Fermer"),
        sub_title,
        ac_info,
        lim_table
    )
}
