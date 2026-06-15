#' Module — Catalogue de pièces
#'
#' Liste et révision des entrées `mbhlcore.parts_catalog`.
#' Filtrage SQL (pagination serveur), P/Ns alternatifs inline,
#' filtre par type d'avion via `parts_catalog_applicability`.
#' Permission `catalog.can_review` requise pour créer/modifier.
#'
#' @param id Identifiant de namespace Shiny.
#' @export
mod_catalog_ui <- function(id) {
    ns <- shiny::NS(id)

    shiny::tagList(
        # ── Barre de filtres ──────────────────────────────────────────────────
        bslib::card(
            bslib::card_body(
                padding = "0.5rem",
                bslib::layout_columns(
                    col_widths = c(4, 2, 2, 2, 2),
                    shiny::textInput(
                        ns("search"),
                        label       = NULL,
                        value       = "",
                        placeholder = "P/N, description, fabricant, alternate…"
                    ),
                    shiny::selectInput(
                        ns("aircraft_type"),
                        label   = NULL,
                        choices = c("Tous modèles A/C" = "0")
                    ),
                    shiny::selectInput(
                        ns("tracking_class"),
                        label   = NULL,
                        choices = c(
                            "Tous"           = "",
                            "Inventaire"     = "inventory",
                            "Actif (asset)"  = "asset",
                            "Consommable"    = "consumable"
                        )
                    ),
                    shiny::selectInput(
                        ns("review_status"),
                        label   = NULL,
                        choices = c(
                            "Tous les statuts" = "",
                            "⏳ À réviser" = "to_review",
                            "✅ Révisé"    = "reviewed"
                        )
                    ),
                    shiny::div(
                        style = "display:flex; gap:0.4rem; align-items:flex-end;",
                        shiny::selectInput(
                            ns("is_active"),
                            label   = NULL,
                            choices = c(
                                "Actifs seulement"   = "true",
                                "Inactifs seulement" = "false",
                                "Tous"               = ""
                            )
                        ),
                        shiny::uiOutput(ns("btn_add_ui"))
                    )
                )
            )
        ),

        # ── Table principale ──────────────────────────────────────────────────
        bslib::card(
            full_screen = TRUE,
            bslib::card_header(
                shiny::icon("boxes-stacked"), " Catalogue de pièces",
                shiny::span(
                    style = "font-size:0.8rem; font-weight:normal; color:var(--bs-secondary-color);",
                    shiny::textOutput(ns("row_count"), inline = TRUE)
                )
            ),
            bslib::card_body(
                padding = 0,
                DT::DTOutput(ns("tbl_catalog"), fill = TRUE)
            )
        )
    )
}

#' @rdname mod_catalog_ui
#' @param refresh Signal réactif externe pour forcer un rechargement. Optionnel.
#' @export
mod_catalog_server <- function(id, refresh = NULL) {
    shiny::moduleServer(id, function(input, output, session) {
        ns <- session$ns

        pool <- session$userData$pool
        # TODO: rétablir protegR2 quand le moteur de permissions sera câblé
        # config_user <- protegR2::get_user_config(session)
        # can_review  <- protegR2::has_permission(
        #     config_user, "mbhlmaintenance", "catalog", "can_review"
        # )
        can_review <- TRUE

        # ── Types d'avion pour le filtre (chargé une seule fois) ─────────────
        shiny::observe({
            types <- DBI::dbGetQuery(pool, "
                SELECT type_id,
                       manufacturer || ' ' || model ||
                       COALESCE(' ' || variant, '') AS label
                FROM mbhlcore.aircraft_types
                ORDER BY manufacturer, model, variant
            ")
            choices <- c("Tous modèles A/C" = "0")
            if (nrow(types) > 0)
                choices <- c(choices, stats::setNames(
                    as.character(types$type_id), types$label
                ))
            shiny::updateSelectInput(session, "aircraft_type", choices = choices)
        })

        # ── Bouton Nouveau ────────────────────────────────────────────────────
        output$btn_add_ui <- shiny::renderUI({
            if (!can_review) return(NULL)
            shiny::actionButton(
                ns("btn_add"),
                label = shiny::icon("plus"),
                class = "btn-sm btn-primary",
                style = "white-space:nowrap;"
            )
        })

        # ── Déclencheur de rechargement ───────────────────────────────────────
        trigger <- shiny::reactiveVal(0L)
        shiny::observeEvent(refresh, trigger(trigger() + 1L), ignoreNULL = FALSE)

        # ── Recherche avec debounce (400ms) ───────────────────────────────────
        search_d <- shiny::debounce(shiny::reactive(trimws(input$search)), 400)

        # ── Requête SQL filtrée (retourne seulement les lignes utiles) ────────
        data_filtered <- shiny::reactive({
            trigger()
            shiny::req(pool)

            q         <- search_d()
            type_id   <- as.integer(input$aircraft_type %||% "0")
            tc        <- input$tracking_class %||% ""
            rs        <- input$review_status  %||% ""
            ia        <- input$is_active      %||% "true"

            DBI::dbGetQuery(pool, "
                WITH alternates AS (
                    -- Pour chaque catalog_id membre d'un groupe, agréger les autres P/Ns du groupe
                    SELECT
                        m1.catalog_id,
                        STRING_AGG(pc2.part_number, ', ' ORDER BY pc2.part_number) AS alternate_pns
                    FROM mbhlcore.parts_catalog_alternate_memberships m1
                    JOIN mbhlcore.parts_catalog_alternate_memberships m2
                        ON m2.group_id = m1.group_id AND m2.catalog_id <> m1.catalog_id
                    JOIN mbhlcore.parts_catalog pc2 ON pc2.catalog_id = m2.catalog_id
                    GROUP BY m1.catalog_id
                ),
                unit_counts AS (
                    SELECT catalog_id, COUNT(*) AS unit_count
                    FROM mbhlmaintenance.parts
                    WHERE is_active = TRUE
                    GROUP BY catalog_id
                )
                SELECT
                    pc.catalog_id,
                    pc.part_number,
                    pc.description,
                    COALESCE(pc.manufacturer, '') AS manufacturer,
                    pc.tracking_class,
                    pc.review_status,
                    pc.is_active,
                    COALESCE(a.alternate_pns, '') AS alternate_pns,
                    COALESCE(uc.unit_count, 0)   AS unit_count,
                    pc.notes,
                    pc.unit_of_measure,
                    pc.is_serialized,
                    pc.lot_tracking,
                    pc.track_tsn,
                    pc.track_tso,
                    pc.track_csn,
                    pc.track_cso,
                    pc.track_hobbs,
                    pc.has_shelf_life,
                    pc.shelf_life_days,
                    pc.has_own_logbook,
                    pc.is_hazmat
                FROM mbhlcore.parts_catalog pc
                LEFT JOIN alternates    a  ON a.catalog_id  = pc.catalog_id
                LEFT JOIN unit_counts   uc ON uc.catalog_id = pc.catalog_id
                WHERE
                    -- Recherche texte (P/N, description, fabricant, alternates)
                    ($1 = '' OR
                        pc.part_number  ILIKE '%' || $1 || '%' OR
                        pc.description  ILIKE '%' || $1 || '%' OR
                        pc.manufacturer ILIKE '%' || $1 || '%' OR
                        EXISTS (
                            SELECT 1
                            FROM mbhlcore.parts_catalog_alternate_memberships mx1
                            JOIN mbhlcore.parts_catalog_alternate_memberships mx2
                                ON mx2.group_id = mx1.group_id AND mx2.catalog_id <> mx1.catalog_id
                            JOIN mbhlcore.parts_catalog pc_alt ON pc_alt.catalog_id = mx2.catalog_id
                            WHERE mx1.catalog_id = pc.catalog_id
                              AND pc_alt.part_number ILIKE '%' || $1 || '%'
                        )
                    )
                    -- Filtre type d'avion
                    AND ($2 = 0 OR EXISTS (
                        SELECT 1 FROM mbhlcore.parts_catalog_applicability pca
                        WHERE pca.catalog_id = pc.catalog_id AND pca.aircraft_type_id = $2
                    ))
                    -- Filtre classe de suivi
                    AND ($3 = '' OR pc.tracking_class = $3)
                    -- Filtre statut de révision
                    AND ($4 = '' OR pc.review_status = $4)
                    -- Filtre actif/inactif
                    AND ($5 = '' OR pc.is_active = ($5 = 'true'))
                ORDER BY pc.part_number, pc.description
            ", list(q, type_id, tc, rs, ia))
        })

        # ── Compteur ──────────────────────────────────────────────────────────
        output$row_count <- shiny::renderText({
            n <- nrow(data_filtered())
            if (is.null(n) || n == 0L) return("(aucun résultat)")
            sprintf("(%d entrées)", n)
        })

        # ── Table DT ─────────────────────────────────────────────────────────
        output$tbl_catalog <- DT::renderDT({
            df <- data_filtered()
            shiny::req(nrow(df) > 0L)

            display <- data.frame(
                catalog_id    = df$catalog_id,
                pn_display    = .fmt_pn(df$part_number, df$alternate_pns),
                description   = df$description,
                manufacturer  = df$manufacturer,
                tracking      = .label_tracking_class(df$tracking_class),
                units         = ifelse(df$unit_count == 0L, "—", as.character(df$unit_count)),
                review        = ifelse(df$review_status == "reviewed", "✅ Révisé", "⏳ À réviser"),
                actif         = ifelse(df$is_active, "✓", "—"),
                stringsAsFactors = FALSE
            )

            DT::datatable(
                display,
                rownames  = FALSE,
                escape    = FALSE,   # pour le HTML dans pn_display
                selection = "single",
                class     = "table-sm table-hover",
                style     = "bootstrap5",
                colnames  = c("ID", "P/N", "Description", "Fabricant",
                              "Classe", "Unités", "Révision", "Actif"),
                options   = list(
                    pageLength = 25,
                    scrollX    = TRUE,
                    dom        = "tip",
                    columnDefs = list(
                        list(visible = FALSE, targets = 0),
                        list(className = "dt-center", targets = c(5, 6, 7)),
                        list(width = "180px", targets = 1),
                        list(width = "80px",  targets = c(5, 6, 7))
                    ),
                    language = list(
                        emptyTable   = "Aucune pièce trouvée",
                        info         = "_START_-_END_ sur _TOTAL_ pièces",
                        infoEmpty    = "0 pièce",
                        infoFiltered = "(filtré sur _MAX_)",
                        paginate     = list(previous = "Préc.", `next` = "Suiv.")
                    )
                )
            )
        }, server = TRUE)

        # ── Sélection → modal de détail ───────────────────────────────────────
        selected_row <- shiny::reactive({
            sel <- input$tbl_catalog_rows_selected
            if (length(sel) == 0L) return(NULL)
            data_filtered()[sel, ]
        })

        shiny::observeEvent(input$tbl_catalog_rows_selected, {
            row <- selected_row()
            if (is.null(row)) return()
            .catalog_show_modal(ns, row, can_review)
        })

        # ── Bouton Nouveau ────────────────────────────────────────────────────
        shiny::observeEvent(input$btn_add, {
            .catalog_show_modal(ns, row = NULL, can_review = can_review)
        })

        # ── Sauvegarde ────────────────────────────────────────────────────────
        shiny::observeEvent(input$modal_save, {
            # protegR2::assert_permission(
            #     config_user, "mbhlmaintenance", "catalog", "can_review"
            # )
            is_new <- nchar(trimws(input$modal_catalog_id %||% "")) == 0L
            pn     <- trimws(input$modal_part_number  %||% "")
            desc   <- trimws(input$modal_description  %||% "")

            if (nchar(pn) == 0L || nchar(desc) == 0L) {
                shiny::showNotification("P/N et description sont obligatoires.",
                                        type = "error", duration = 4)
                return()
            }

            tryCatch({
                params <- list(
                    pn,
                    desc,
                    .nullify(input$modal_manufacturer),
                    input$modal_tracking_class,
                    input$modal_unit_of_measure,
                    isTRUE(input$modal_is_serialized),
                    isTRUE(input$modal_lot_tracking),
                    isTRUE(input$modal_track_tsn),
                    isTRUE(input$modal_track_tso),
                    isTRUE(input$modal_track_csn),
                    isTRUE(input$modal_track_cso),
                    isTRUE(input$modal_track_hobbs),
                    isTRUE(input$modal_has_shelf_life),
                    isTRUE(input$modal_has_own_logbook),
                    isTRUE(input$modal_is_hazmat),
                    .nullify(input$modal_notes)
                )

                if (is_new) {
                    DBI::dbExecute(pool, "
                        INSERT INTO mbhlcore.parts_catalog (
                            part_number, description, manufacturer,
                            tracking_class, unit_of_measure,
                            is_serialized, lot_tracking,
                            track_tsn, track_tso, track_csn, track_cso, track_hobbs,
                            has_shelf_life, has_own_logbook, is_hazmat,
                            review_status, is_active, notes
                        ) VALUES (
                            $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,
                            'to_review', TRUE, $16
                        )", params)
                    shiny::showNotification("Pièce ajoutée.", type = "message")
                } else {
                    DBI::dbExecute(pool, "
                        UPDATE mbhlcore.parts_catalog SET
                            part_number     = $1,  description    = $2,
                            manufacturer    = $3,  tracking_class = $4,
                            unit_of_measure = $5,  is_serialized  = $6,
                            lot_tracking    = $7,  track_tsn      = $8,
                            track_tso       = $9,  track_csn      = $10,
                            track_cso       = $11, track_hobbs    = $12,
                            has_shelf_life  = $13, has_own_logbook = $14,
                            is_hazmat       = $15, review_status  = $17,
                            notes           = $16
                        WHERE catalog_id = $18
                    ", c(params, list(
                        input$modal_review_status,
                        as.integer(input$modal_catalog_id)
                    )))
                    shiny::showNotification("Pièce mise à jour.", type = "message")
                }

                shiny::removeModal()
                trigger(trigger() + 1L)

            }, error = function(e) {
                shiny::showNotification(paste("Erreur:", conditionMessage(e)),
                                        type = "error", duration = 6)
            })
        })

        # ── Toggle is_active ──────────────────────────────────────────────────
        shiny::observeEvent(input$modal_deactivate, {
            row <- selected_row()
            shiny::req(!is.null(row))
            # protegR2::assert_permission(
            #     config_user, "mbhlmaintenance", "catalog", "can_review"
            # )
            DBI::dbExecute(pool,
                "UPDATE mbhlcore.parts_catalog SET is_active = $1 WHERE catalog_id = $2",
                list(!isTRUE(row$is_active), as.integer(row$catalog_id))
            )
            shiny::removeModal()
            trigger(trigger() + 1L)
        })

        invisible(NULL)
    })
}

# ── Helpers internes ──────────────────────────────────────────────────────────

`%||%` <- function(x, y) if (is.null(x)) y else x

.nullify <- function(x) {
    if (is.null(x) || (is.character(x) && nchar(trimws(x)) == 0L)) NULL else trimws(x)
}

.label_tracking_class <- function(x) {
    lbl <- c(inventory = "Inventaire", asset = "Actif", consumable = "Consommable")
    unname(ifelse(x %in% names(lbl), lbl[x], x))
}

#' @noRd
.fmt_pn <- function(pn, alts) {
    has_alt <- nchar(alts) > 0L
    ifelse(
        has_alt,
        paste0(
            "<strong>", pn, "</strong>",
            "<br><small style='color:var(--bs-secondary-color);'>",
            "Alt. : ", alts,
            "</small>"
        ),
        paste0("<strong>", pn, "</strong>")
    )
}

#' @noRd
.catalog_show_modal <- function(ns, row, can_review) {
    is_new <- is.null(row)
    title  <- if (is_new) "Nouvelle pièce" else paste0("P/N ", row$part_number)

    v <- list(
        catalog_id      = if (is_new) "" else as.character(row$catalog_id),
        part_number     = if (is_new) "" else row$part_number,
        description     = if (is_new) "" else row$description,
        manufacturer    = if (is_new) "" else row$manufacturer,
        tracking_class  = if (is_new) "inventory" else row$tracking_class,
        unit_of_measure = if (is_new) "each" else row$unit_of_measure,
        is_serialized   = if (is_new) FALSE else isTRUE(row$is_serialized),
        lot_tracking    = if (is_new) FALSE else isTRUE(row$lot_tracking),
        track_tsn       = if (is_new) FALSE else isTRUE(row$track_tsn),
        track_tso       = if (is_new) FALSE else isTRUE(row$track_tso),
        track_csn       = if (is_new) FALSE else isTRUE(row$track_csn),
        track_cso       = if (is_new) FALSE else isTRUE(row$track_cso),
        track_hobbs     = if (is_new) FALSE else isTRUE(row$track_hobbs),
        has_shelf_life  = if (is_new) FALSE else isTRUE(row$has_shelf_life),
        has_own_logbook = if (is_new) FALSE else isTRUE(row$has_own_logbook),
        is_hazmat       = if (is_new) FALSE else isTRUE(row$is_hazmat),
        review_status   = if (is_new) "to_review" else row$review_status,
        is_active       = if (is_new) TRUE else isTRUE(row$is_active),
        alternate_pns   = if (is_new) "" else (if (is.null(row$alternate_pns)) "" else row$alternate_pns),
        notes           = if (is_new) "" else (if (is.null(row$notes)) "" else row$notes)
    )

    footer <- if (!can_review) {
        shiny::modalButton("Fermer")
    } else {
        shiny::tagList(
            if (!is_new) shiny::actionButton(
                ns("modal_deactivate"),
                label = if (v$is_active) "Désactiver" else "Réactiver",
                class = if (v$is_active) "btn-outline-warning" else "btn-outline-success"
            ),
            shiny::modalButton("Annuler"),
            shiny::actionButton(ns("modal_save"),
                                label = if (is_new) "Créer" else "Enregistrer",
                                class = "btn-primary")
        )
    }

    shiny::showModal(shiny::modalDialog(
        title     = title,
        size      = "l",
        footer    = footer,
        easyClose = TRUE,

        shiny::tags$input(type = "hidden", id = ns("modal_catalog_id"), value = v$catalog_id),

        # Alternates (lecture seule — gérés dans mbhlCore)
        if (!is_new && nchar(v$alternate_pns) > 0L)
            shiny::div(
                class = "alert alert-secondary py-1 mb-3",
                style = "font-size:0.85rem;",
                shiny::tags$strong("Alternates : "), v$alternate_pns
            ),

        # Identité
        bslib::layout_columns(
            col_widths = c(4, 8),
            shiny::textInput(ns("modal_part_number"), "P/N *", value = v$part_number,
                             placeholder = "ex: 200-360-001-107"),
            shiny::textInput(ns("modal_description"), "Description *", value = v$description)
        ),
        bslib::layout_columns(
            col_widths = c(4, 4, 4),
            shiny::textInput(ns("modal_manufacturer"), "Fabricant",
                             value = v$manufacturer, placeholder = "ex: Honeywell"),
            shiny::selectInput(ns("modal_tracking_class"), "Classe de suivi *",
                choices  = c("Inventaire" = "inventory", "Actif" = "asset",
                             "Consommable" = "consumable"),
                selected = v$tracking_class),
            shiny::textInput(ns("modal_unit_of_measure"), "Unité *",
                             value = v$unit_of_measure, placeholder = "each, liter, foot…")
        ),

        shiny::hr(),

        # Traçabilité
        shiny::tags$p(shiny::tags$strong("Traçabilité"), style = "margin-bottom:0.5rem;"),
        bslib::layout_columns(
            col_widths = c(3, 3, 3, 3),
            shiny::checkboxInput(ns("modal_is_serialized"),   "Numéro de série (S/N)", v$is_serialized),
            shiny::checkboxInput(ns("modal_lot_tracking"),    "Suivi par lot",            v$lot_tracking),
            shiny::checkboxInput(ns("modal_has_shelf_life"),  "Date de péremption",  v$has_shelf_life),
            shiny::checkboxInput(ns("modal_is_hazmat"),       "Matière dangereuse",  v$is_hazmat)
        ),

        shiny::tags$p(shiny::tags$strong("Accumulateurs (TSN/TSO)"), style = "margin-bottom:0.5rem;"),
        bslib::layout_columns(
            col_widths = c(2, 2, 2, 2, 2, 2),
            shiny::checkboxInput(ns("modal_track_tsn"),       "TSN (airtime)", v$track_tsn),
            shiny::checkboxInput(ns("modal_track_tso"),       "TSO (airtime)", v$track_tso),
            shiny::checkboxInput(ns("modal_track_csn"),       "CSN (cycles)",  v$track_csn),
            shiny::checkboxInput(ns("modal_track_cso"),       "CSO (cycles)",  v$track_cso),
            shiny::checkboxInput(ns("modal_track_hobbs"),     "Hobbs",         v$track_hobbs),
            shiny::checkboxInput(ns("modal_has_own_logbook"), "Logbook propre", v$has_own_logbook)
        ),

        shiny::hr(),

        # Statut révision
        bslib::layout_columns(
            col_widths = c(4, 8),
            if (can_review && !is_new) {
                shiny::selectInput(
                    ns("modal_review_status"), "Statut de révision",
                    choices  = c("À réviser" = "to_review", "Révisé" = "reviewed"),
                    selected = v$review_status
                )
            } else {
                shiny::div(
                    shiny::tags$label("Statut de révision"),
                    shiny::tags$p(
                        if (v$review_status == "reviewed") "✅ Révisé"
                        else "⏳ À réviser",
                        style = "margin:0; padding-top:0.375rem;"
                    )
                )
            },
            shiny::div()
        ),

        shiny::textAreaInput(ns("modal_notes"), "Notes", value = v$notes, rows = 2),

        if (!can_review)
            shiny::tags$small(
                shiny::icon("lock"),
                " Lecture seule — permission «catalog.can_review» requise.",
                style = "color:var(--bs-secondary-color);"
            )
    ))
}
