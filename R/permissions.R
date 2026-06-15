#' Registre des permissions mbhlMaintenance
#'
#' Liste exhaustive de toutes les permissions du package, organisées par module.
#' Sert de source de vérité pour l'UI admin (génération dynamique des toggles)
#' et comme référence développeur.
#'
#' La structure dans `config_user` suit le format imbriqué:
#' `config_user$mbhlmaintenance$<module>$<permission>`
#'
#' `NULL` = accès refusé (default deny). Le rôle `dev` bypasse toutes les permissions.
#'
#' @export
mbhlmaintenance_permissions <- list(
    forecast = list(
        has_access = "Voir le forecast"
    ),
    work_orders = list(
        can_view       = "Voir les work orders",
        can_open       = "Ouvrir un W.O.",
        can_stage      = "Préparer un W.O. (staged)",
        can_add_task   = "Ajouter une tâche à un W.O. ouvert",
        can_close_task = "Signer/fermer une tâche",
        can_close      = "Fermer un W.O.",
        can_review     = "Réviser un W.O. (maintenance control)"
    ),
    inspections = list(
        has_access            = "Voir les inspections",
        can_create            = "Créer une inspection sur un avion/pièce",
        can_edit              = "Modifier une inspection existante",
        can_approve_extension = "Approuver une extension d'inspection",
        can_manage_packages   = "Créer/modifier des packages d'inspection",
        can_manage_deferrals  = "Créer/gérer des ajournements MEL/non-MEL",
        can_void_completion   = "Annuler une completion (correction)"
    ),
    catalog = list(
        can_review = "Réviser les entrées parts_catalog"
    )
)
