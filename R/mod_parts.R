#' Module — Registre des unités sérialisées
#'
#' Liste globale des unités physiques (`mbhlmaintenance.parts`) avec
#' filtres par avion, P/N et statut. Clic → logbook de l'unité.
#' Lecture seule — les événements (TSN/TSO) sont créés via les work orders.
#'
#' @param id Identifiant de namespace Shiny.
#' @export
mod_parts_ui <- function(id) {
    ns <- shiny::NS(id)

    shiny::tagList(
        bslib::card(
            bslib::card_body(
                padding = "0.5rem",
                bslib::layout_columns(
                    col_widths = c(4, 3, 3, 2),
                    shiny::textInput(
                        ns("search"),
                        label       = NULL,
                        value       = "",
                        placeholder = "P/N, S/N, ID interne, description…"
                    ),
                    shiny::selectInput(
                        ns("filter_aircraft"),
                        label   = NULL,
                        choices = c("Tous les appareils" = "")
                    ),
                    shiny::selectInput(
                        ns("filter_status"),
                        label   = NULL,
                        choices = c(
                            "Tous les statuts" = "",
                            "Installée"   = "installed",
                            "En stock"         = "spare",
                            "Mis au rebut"     = "scrapped"
                        )
                    ),
                    shiny::selectInput(
                        ns("filter_active"),
                        label   = NULL,
                        choices = c(
                            "Actives seulement" = "true",
                            "Inactives"         = "false",
                            "Toutes"            = ""
                        )
                    )
                )
            )
        ),

        bslib::card(
            full_screen = TRUE,
            bslib::card_header(
                shiny::icon("list"), " Unités sérialisées",
                shiny::span(
                    style = "font-size:0.8rem; font-weight:normal; color:var(--bs-secondary-color);",
                    shiny::textOutput(ns("row_count"), inline = TRUE)
                )
            ),
            bslib::card_body(
                padding = 0,
                DT::DTOutput(ns("tbl_parts"), fill = TRUE)
            )
        )
    )
}

#' @rdname mod_parts_ui
#' @param refresh Signal réactif externe pour forcer un rechargement. Optionnel.
#' @export
mod_parts_server <- function(id, refresh = NULL) {
    shiny::moduleServer(id, function(input, output, session) {
        ns   <- session$ns
        pool <- session$userData$pool

        # ── Avions actifs pour le filtre ──────────────────────────────────────
        shiny::observe({
            ac <- DBI::dbGetQuery(pool, "
                SELECT aircraft_id, registration
                FROM mbhlcore.aircraft
                WHERE is_active = TRUE
                ORDER BY registration
            ")
            choices <- c("Tous les appareils" = "")
            if (nrow(ac) > 0)
                choices <- c(choices, stats::setNames(
                    as.character(ac$aircraft_id), ac$registration
                ))
            shiny::updateSelectInput(session, "filter_aircraft", choices = choices)
        })

        trigger  <- shiny::reactiveVal(0L)
        shiny::observeEvent(refresh, trigger(trigger() + 1L), ignoreNULL = FALSE)

        search_d <- shiny::debounce(shiny::reactive(trimws(input$search)), 400)

        # ── Requête principale ────────────────────────────────────────────────
        data_filtered <- shiny::reactive({
            trigger()
            shiny::req(pool)

            q      <- search_d()
            ac_raw <- input$filter_aircraft %||% ""
            ac_id  <- if (nzchar(ac_raw)) as.integer(ac_raw) else 0L
            status <- input$filter_status %||% ""
            ia     <- input$filter_active %||% "true"

            DBI::dbGetQuery(pool, "
                WITH last_event AS (
                    SELECT DISTINCT ON (part_id)
                        part_id,
                        event_type,
                        installed_on_id,
                        installed_on_type
                    FROM mbhlmaintenance.part_events
                    ORDER BY part_id, event_date DESC, event_id DESC
                ),
                part_status AS (
                    SELECT
                        p.part_id,
                        CASE
                            WHEN le.event_type = 'install' THEN 'installed'
                            WHEN le.event_type = 'scrap'   THEN 'scrapped'
                            ELSE 'spare'
                        END AS status,
                        CASE
                            WHEN le.event_type = 'install' AND le.installed_on_type = 'aircraft'
                            THEN le.installed_on_id
                        END AS aircraft_id
                    FROM mbhlmaintenance.parts p
                    LEFT JOIN last_event le ON le.part_id = p.part_id
                )
                SELECT
                    p.part_id,
                    pc.part_number,
                    pc.description,
                    COALESCE(p.serial_number, '') AS serial_number,
                    COALESCE(p.internal_id,   '') AS internal_id,
                    ps.status,
                    COALESCE(a.registration,  '') AS aircraft_registration,
                    p.is_active
                FROM mbhlmaintenance.parts p
                JOIN mbhlcore.parts_catalog  pc USING (catalog_id)
                JOIN part_status             ps ON ps.part_id = p.part_id
                LEFT JOIN mbhlcore.aircraft  a  ON a.aircraft_id = ps.aircraft_id
                WHERE
                    ($1 = '' OR
                        pc.part_number  ILIKE '%' || $1 || '%' OR
                        p.serial_number ILIKE '%' || $1 || '%' OR
                        p.internal_id   ILIKE '%' || $1 || '%' OR
                        pc.description  ILIKE '%' || $1 || '%'
                    )
                    AND ($2 = 0 OR ps.aircraft_id = $2)
                    AND ($3 = '' OR ps.status = $3)
                    AND ($4 = '' OR p.is_active = ($4 = 'true'))
                ORDER BY pc.part_number, p.serial_number
            ", list(q, ac_id, status, ia))
        })

        output$row_count <- shiny::renderText({
            n <- nrow(data_filtered())
            if (is.null(n) || n == 0L) return("(aucun résultat)")
            sprintf("(%d unités)", n)
        })

        output$tbl_parts <- DT::renderDT({
            df <- data_filtered()
            shiny::req(nrow(df) > 0L)

            display <- data.frame(
                part_id              = df$part_id,
                part_number          = df$part_number,
                description          = df$description,
                serial_number        = df$serial_number,
                status_display       = .fmt_part_status(df$status),
                aircraft_registration = ifelse(
                    nchar(df$aircraft_registration) > 0,
                    df$aircraft_registration, "—"
                ),
                stringsAsFactors = FALSE
            )

            DT::datatable(
                display,
                rownames  = FALSE,
                escape    = FALSE,
                selection = "single",
                class     = "table-sm table-hover",
                style     = "bootstrap5",
                colnames  = c("ID", "P/N", "Description", "S/N",
                              "Statut", "Appareil"),
                options   = list(
                    pageLength = 25,
                    scrollX    = TRUE,
                    dom        = "tip",
                    columnDefs = list(
                        list(visible = FALSE, targets = 0),
                        list(className = "dt-center", targets = c(4, 5)),
                        list(width = "160px", targets = 1),
                        list(width = "100px", targets = c(3, 4, 5))
                    ),
                    language = list(
                        emptyTable   = "Aucune unité trouvée",
                        info         = "_START_-_END_ sur _TOTAL_ unités",
                        infoEmpty    = "0 unité",
                        infoFiltered = "(filtré sur _MAX_)",
                        paginate     = list(previous = "Préc.", `next` = "Suiv.")
                    )
                )
            )
        }, server = TRUE)

        # ── Sélection → logbook modal ─────────────────────────────────────────
        logbook_part <- shiny::reactiveVal(NULL)

        shiny::observeEvent(input$tbl_parts_rows_selected, {
            sel <- input$tbl_parts_rows_selected
            if (length(sel) == 0L) return()
            row <- data_filtered()[sel, ]
            logbook_part(row)

            id_label <- if (nchar(row$serial_number) > 0)
                paste0("S/N ", row$serial_number)
            else
                paste0("ID ", row$internal_id)

            shiny::showModal(shiny::modalDialog(
                title     = paste0(row$part_number, " — ", id_label),
                size      = "xl",
                footer    = shiny::modalButton("Fermer"),
                easyClose = TRUE,

                # En-tête statut
                shiny::div(
                    class = "d-flex gap-3 align-items-center mb-3",
                    shiny::HTML(.fmt_part_status(row$status)),
                    if (nchar(row$aircraft_registration) > 0)
                        shiny::tags$span(
                            class = "text-secondary",
                            shiny::icon("plane"), " ", row$aircraft_registration
                        ),
                    shiny::tags$span(
                        class = "text-secondary small",
                        row$description
                    )
                ),

                shiny::tags$h6("Logbook"),
                shiny::uiOutput(ns("logbook_content"))
            ))
        })

        # ── Contenu du logbook (rendu après ouverture du modal) ───────────────
        output$logbook_content <- shiny::renderUI({
            row <- logbook_part()
            shiny::req(!is.null(row))

            events <- DBI::dbGetQuery(pool, "
                SELECT
                    pe.event_type,
                    pe.event_date,
                    COALESCE(a.registration, '') AS aircraft_registration,
                    pe.unit_airtime_at_event,
                    pe.unit_cycles_at_event,
                    pe.part_tsn_at_event,
                    pe.part_tso_at_event,
                    pe.part_csn_at_event,
                    pe.part_cso_at_event,
                    pers.full_name        AS created_by,
                    COALESCE(p2.serial_number, '') AS installed_on_sn,
                    pe.is_anchor,
                    COALESCE(pe.notes, '') AS notes
                FROM mbhlmaintenance.part_events pe
                LEFT JOIN mbhlcore.aircraft   a    ON a.aircraft_id   = pe.installed_on_id
                                                   AND pe.installed_on_type = 'aircraft'
                LEFT JOIN mbhlcore.personnel  pers ON pers.personnel_id = pe.created_by
                LEFT JOIN mbhlmaintenance.parts p2  ON p2.part_id = pe.installed_on_part_id
                WHERE pe.part_id = $1
                ORDER BY pe.event_date DESC, pe.event_id DESC
            ", list(row$part_id))

            if (nrow(events) == 0L)
                return(shiny::p("Aucun événement enregistré.",
                                class = "text-secondary"))

            rows_html <- apply(events, 1, function(r) {
                evt   <- .fmt_event_type(r[["event_type"]])
                anchor <- if (isTRUE(as.logical(r[["is_anchor"]])))
                    " <span class='badge bg-warning text-dark ms-1'>ancre</span>" else ""
                loc <- if (nchar(r[["aircraft_registration"]]) > 0)
                    r[["aircraft_registration"]]
                else if (nchar(r[["installed_on_sn"]]) > 0)
                    paste0("sur S/N ", r[["installed_on_sn"]])
                else "—"

                tsn <- if (!is.na(r[["part_tsn_at_event"]]))
                    sprintf("TSN %.1fh", as.numeric(r[["part_tsn_at_event"]])) else ""
                tso <- if (!is.na(r[["part_tso_at_event"]]))
                    sprintf("TSO %.1fh", as.numeric(r[["part_tso_at_event"]])) else ""
                csn <- if (!is.na(r[["part_csn_at_event"]]))
                    sprintf("CSN %d", as.integer(r[["part_csn_at_event"]])) else ""
                accum <- paste(Filter(nchar, c(tsn, tso, csn)), collapse = " | ")

                note_html <- if (nchar(r[["notes"]]) > 0)
                    paste0("<br><small class='text-secondary'>", r[["notes"]], "</small>") else ""

                sprintf(
                    "<tr>
                      <td>%s</td>
                      <td>%s%s</td>
                      <td class='text-center'>%s</td>
                      <td>%s</td>
                      <td class='text-secondary small'>%s</td>
                    </tr>%s",
                    r[["event_date"]],
                    evt, anchor,
                    loc,
                    accum,
                    r[["created_by"]],
                    note_html
                )
            })

            shiny::HTML(paste0(
                "<div class='table-responsive'>",
                "<table class='table table-sm table-hover'>",
                "<thead><tr>",
                "<th>Date</th><th>Événement</th>",
                "<th class='text-center'>Localisation</th>",
                "<th>Accumulateurs</th><th>Saisi par</th>",
                "</tr></thead><tbody>",
                paste(rows_html, collapse = ""),
                "</tbody></table></div>"
            ))
        })

        invisible(NULL)
    })
}

# ── Helpers internes ──────────────────────────────────────────────────────────

#' @noRd
.fmt_part_status <- function(status) {
    vapply(status, function(s) {
        switch(s,
            installed = "<span class='badge bg-success'>Installée</span>",
            scrapped  = "<span class='badge bg-danger'>Mis au rebut</span>",
            "<span class='badge bg-secondary'>En stock</span>"
        )
    }, character(1L), USE.NAMES = FALSE)
}

#' @noRd
.fmt_event_type <- function(x) {
    switch(x,
        receive          = "Réception",
        install          = "Installation",
        remove           = "Dépose",
        overhaul         = "Overhaul",
        repair           = "Réparation",
        scrap            = "Mise au rebut",
        send_to_shop     = "Envoi atelier",
        return_from_shop = "Retour atelier",
        x
    )
}
