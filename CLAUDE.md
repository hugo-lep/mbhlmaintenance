# Contexte de développement — MBHL Maintenance (`mbhlMaintenance`)

> Fichier autonome. Contient tout le contexte nécessaire pour travailler sur `mbhlMaintenance`
> sans accès à `plan.md` ni à la session Cowork.
> Dernière mise à jour: 2026-06-15

---

## 1. Vue d'ensemble du projet MBHL

**MBHL** est le module maintenance de la plateforme **AvnumbeRs**. Application Shiny (R + bslib) connectée à PostgreSQL, SaaS hébergé par avnumbers (un schema PostgreSQL par client).

**Trois volets:** `mbhlMaintenance` | `mbhlMagasin` | `mbhlComptable`

`mbhlCore` fournit la plomberie: connexion DB, entités partagées (aircraft, bases, companies, personnel, currencies), helpers.

**Écosystème packages:** avnumbers (app principale) · protegR2 (auth bslib) · bslibHL (UI framework) · s3db (S3 OVH + helpers DB) · logpage (pages de log — source de vérité airtime/cycles, migration vers PostgreSQL requise avant MBHL)

**Conventions DB:** snake_case, pas de préfixe sur les noms de tables — le schema `mbhlmaintenance` joue le rôle de séparation (ex: `mbhlmaintenance.work_orders`). Immutabilité des enregistrements passés (soft delete + is_voided).

**Convention de nommage R:** `config_user` (pas `user_config`) — la variable apparaît à côté de `config_global` dans RStudio. Respecter cette convention dans tout le code R de ce package.

---

## 2. Catalogue de pièces (`parts_catalog` + `parts`)

### 2.1 `parts_catalog` — le type de pièce (P/N)

```sql
parts_catalog                    -- dans le schema mbhlcore (partagé entre tous les volets)
────────────────────────────────────────────
catalog_id        SERIAL PRIMARY KEY
part_number       TEXT NOT NULL
description       TEXT NOT NULL
manufacturer      TEXT                         -- nullable (pièces génériques)

-- Classification métier (configurable par compagnie, FK vers mbhlcore.part_types)
part_type_id      INT NOT NULL REFERENCES part_types
                  -- ex: engine, propeller, rotable, consumable, avionics
                  -- aucune valeur par défaut — chaque compagnie configure ses propres types

-- Classification technique de gestion (fixe, détermine le comportement du système)
tracking_class    TEXT NOT NULL                -- 'inventory' | 'asset' | 'consumable'
                  -- inventory  = stock géré en quantité par lots
                  -- asset      = actif capitalisé, suivi individuel + valeur comptable
                  -- consumable = consommé à l'usage, pas de retour en stock
                  -- Les deux classifications coexistent sans redondance:
                  -- ex: moteur → part_type_id=engine ET tracking_class='asset'
                  -- Le lien pièce ↔ pool d'actifs comptable est dans mbhlComptable
                  --   (table asset_pool_catalog_items → mbhlcore.parts_catalog)

unit_of_measure   TEXT NOT NULL                -- 'each' | 'quart' | 'liter' | 'foot' | etc.

-- Durée de vie en étagère
has_shelf_life    BOOLEAN NOT NULL DEFAULT FALSE
shelf_life_days   INT                          -- nullable, si has_shelf_life = TRUE

-- Traçabilité individuelle
is_serialized     BOOLEAN NOT NULL DEFAULT FALSE
                  -- TRUE = chaque unité a un S/N fourni par le fabricant
                  -- active le suivi individuel (TSN/TSO/CSN/CSO) et la création de parts
lot_tracking      BOOLEAN NOT NULL DEFAULT FALSE  -- traçabilité par numéro de lot requise

-- Suivi TSN/TSO (seulement pertinent si is_serialized=TRUE ou suivi individuel requis)
track_tsn         BOOLEAN NOT NULL DEFAULT FALSE  -- Time Since New
track_tso         BOOLEAN NOT NULL DEFAULT FALSE  -- Time Since Overhaul
track_csn         BOOLEAN NOT NULL DEFAULT FALSE  -- Cycles Since New
track_cso         BOOLEAN NOT NULL DEFAULT FALSE  -- Cycles Since Overhaul
track_hobbs       BOOLEAN NOT NULL DEFAULT FALSE  -- Hobbs hours (heater, clim, APU — temps d'opération réel)

-- Logbook individuel
has_own_logbook   BOOLEAN NOT NULL DEFAULT FALSE  -- génère vue logbook pour unités individuelles
                                                  -- principalement moteurs et hélices

-- Matières dangereuses
is_hazmat         BOOLEAN NOT NULL DEFAULT FALSE

-- Révision
review_status     TEXT NOT NULL DEFAULT 'to_review'
                  CHECK (review_status IN ('to_review', 'reviewed'))
-- Non bloquant: une entrée peut être utilisée avant d'être révisée
-- Une erreur au catalogue se propage sur toutes les unités physiques du P/N

is_active         BOOLEAN NOT NULL DEFAULT TRUE
notes             TEXT
```

**Règle:** la présence de templates d'inspection avec limites airtime/cycles détermine implicitement si une pièce est "hard-time" (avec templates) ou "on-condition" (sans templates). Pas de champ `maintenance_type` — c'est redondant.

### 2.2 `parts` — les unités physiques individuelles

Créées **uniquement** pour les pièces à suivi individuel (lorsque `is_serialized = TRUE` ou qu'un identifiant interne est assigné par le système).

```sql
parts
────────────────────────────────────────────
part_id                 SERIAL PRIMARY KEY
catalog_id              INT NOT NULL REFERENCES parts_catalog

-- Identification
serial_number           TEXT             -- nullable: fourni par fabricant si is_serialized=TRUE
internal_id             TEXT             -- nullable: généré par système si is_serialized=FALSE
manufacture_date        DATE             -- nullable: date de fabrication (data plate, Form 1)
                                         -- utilisé comme baseline pour date_baseline='manufacture'
                                         -- ex: batterie ELT, beacon ULB — intervalle depuis date de fab.
                                         -- format: {prefix}-{YYYY}-{NNNNN}
                                         -- ex: PAS-2024-00342 (préfixe = config_global$mbhlCore$internal_part_id_prefix)
internal_marking        TEXT             -- tout numéro gravé/peint sur la pièce (libre)
origin_lot_id           INT REFERENCES store_lots  -- nullable: si issue d'un promote_to_unit

is_active               BOOLEAN NOT NULL DEFAULT TRUE
notes                   TEXT

UNIQUE (catalog_id, serial_number)       -- S/N unique par P/N (quand fourni)
```

**Consommables et inventaire sans suivi individuel:** pas de `parts`, uniquement des `store_lots` et transactions de quantité.

### 2.3 Positions d'installation (`parts_catalog_positions`)

Positions prédéfinies par type de pièce. Quand une pièce a plusieurs positions possibles sur un avion (ex: starter-gen LH ou RH), les options sont définies ici une seule fois et sélectionnées à l'installation — pas saisies à chaque fois. Nullable à l'installation si la pièce n'a qu'une position possible.

```sql
parts_catalog_positions
────────────────────────────────────────────
position_id             SERIAL PRIMARY KEY
catalog_id              INT NOT NULL REFERENCES parts_catalog
aircraft_type_id        INT REFERENCES aircraft_types   -- nullable (si spécifique à un type d'avion)
position_name           TEXT NOT NULL    -- ex: 'LH engine', 'RH engine', 'aft mount', 'fwd mount'
parent_position_id      INT REFERENCES parts_catalog_positions  -- nullable (positions imbriquées)
                                         -- ex: parent 'RH engine' pour 'RH engine / starter-gen'
is_active               BOOLEAN NOT NULL DEFAULT TRUE
```

### 2.4 Applicabilité par type d'avion (`parts_catalog_applicability`)

Many-to-many entre `parts_catalog` et `aircraft_types`. Dans le schema `mbhlcore`.
Migration `0012_parts_catalog_applicability.sql` — **déjà appliquée sur Pascan**.

```sql
parts_catalog_applicability          -- dans mbhlcore
────────────────────────────────────────────
catalog_id        INT NOT NULL REFERENCES parts_catalog
aircraft_type_id  INT NOT NULL REFERENCES aircraft_types
notes             TEXT                 -- ex: 'SAAB 340B seulement (pas SF34)'
PRIMARY KEY (catalog_id, aircraft_type_id)
```

**Règle:** une pièce sans entrée ici est considérée non restreinte à un type d'avion.
C'est via cette table que le filtre "type d'avion" de `mod_catalog` fonctionne.

### 2.5 P/Ns interchangeables (`parts_catalog_alternate_groups`)

Groupes de P/Ns interchangeables. Dans le schema `mbhlcore`.
Migration `0015_parts_catalog_alternate_groups.sql` — **déjà appliquée sur Pascan**.

```sql
parts_catalog_alternate_groups       -- dans mbhlcore
────────────────────────────────────────────
group_id     SERIAL PRIMARY KEY
description  TEXT NOT NULL    -- ex: 'Starter-gen AT400/AT401/AT402'
notes        TEXT

parts_catalog_alternate_memberships  -- dans mbhlcore
────────────────────────────────────────────
group_id    INT NOT NULL REFERENCES parts_catalog_alternate_groups
catalog_id  INT NOT NULL REFERENCES parts_catalog
notes       TEXT             -- ex: 'approuvé SAAB 340B seulement'
PRIMARY KEY (group_id, catalog_id)
```

**Principe fondamental:** aucun P/N "principal" — tous les membres sont égaux.
Chaque P/N reste son propre `catalog_id` indépendant.
**Invisible sur les documents** (PO, certifications, maintenance release → toujours le vrai P/N de la pièce physique).

**Usages:**
- `mod_catalog` : affiche les alternates inline dans la colonne P/N
- `mbhlMagasin` : recherche de stock avec case "inclure les alternates"
- `mbhlMaintenance` : analyse de fiabilité — pooler plusieurs catalog_ids d'un même groupe

### 2.6 Templates d'inspection — voir section 16

Le système de templates a été revu en profondeur. `parts_catalog_inspection_templates` est remplacé par `inspection_templates` (table unifiée couvrant les templates avion ET composante) + `inspection_sources` (documents de référence).

**Voir section 16** pour le schéma complet : sources, templates, ADs et SBs.

---

## 3. Journal des événements TSN/TSO (`part_events`)

```sql
part_events
───────────────────────────────────────────────────
event_id                SERIAL PRIMARY KEY
part_id                 INT NOT NULL REFERENCES parts
event_type              TEXT NOT NULL
                        -- 'receive' | 'install' | 'remove' | 'overhaul'
                        -- 'repair' | 'scrap' | 'send_to_shop' | 'return_from_shop'
event_date              DATE NOT NULL
work_order_id           INT REFERENCES work_orders  -- nullable

-- Sur quoi la pièce est installée
installed_on_id         INT              -- aircraft_id ou shop_wo_id
installed_on_type       TEXT             -- 'aircraft' | 'shop_wo' | NULL (en stock/transit)

-- Snapshot de l'unité hôte au moment de l'événement
unit_airtime_at_event   NUMERIC          -- airtime de l'avion/unité
unit_cycles_at_event    INT

-- Valeurs figées au moment de l'événement (selon les flags parts_catalog)
part_tsn_at_event       NUMERIC          -- Time Since New
part_csn_at_event       INT              -- Cycles Since New
part_tso_at_event       NUMERIC          -- Time Since Overhaul (reset si event_type='overhaul')
part_cso_at_event       INT              -- Cycles Since Overhaul (reset si event_type='overhaul')
part_ts_lsv_at_event    NUMERIC          -- Time Since Last Shop Visit (reset si 'return_from_shop')
part_cs_lsv_at_event    INT
part_hobbs_at_event     NUMERIC          -- lecture manuelle du compteur hobbs (si track_hobbs=TRUE)

-- Groupement physique (assemblages)
installed_on_part_id    INT REFERENCES parts   -- nullable — pièce parente physique
                                               -- ex: HMU installé SUR le moteur LH
                                               -- distinct de l'accumulation airtime (toujours via l'avion)
position_id             INT REFERENCES parts_catalog_positions  -- nullable
                                               -- nullable si la pièce n'a qu'une seule position possible
                                               -- positions prédéfinies par catalog_id + aircraft_type_id
                                               -- ex: starter-gen → 'LH engine' | 'RH engine'

-- Ancrage et recalcul
is_anchor               BOOLEAN NOT NULL DEFAULT FALSE  -- point de référence confirmé
anchor_note             TEXT

notes                   TEXT
created_by              INT NOT NULL REFERENCES personnel
created_at              TIMESTAMP NOT NULL DEFAULT NOW()
```

**Assemblages et "follows with" :**
Quand une pièce parente est retirée (ex: moteur LH), le système détecte toutes les pièces ayant
`installed_on_part_id = ce moteur` et présente une checklist : *"Ces pièces sont associées à ce
moteur — lesquelles suivent ?"* Les cases cochées génèrent automatiquement les `part_events` de
dépose correspondants. Les pièces non cochées restent associées à l'avion.

**Accumulation airtime/cycles :** toujours dérivée de l'avion (`aircraft_id`), indépendamment de
`installed_on_part_id`. L'airtime moteur comme base de calcul (pratique courante aux USA) est une
consideration future — non applicable au Canada (RAC), non prioritaire pour le MVP.

**Reset automatique sur overhaul:** quand `event_type = 'overhaul'`, TSO/CSO (et TS_LSV/CS_LSV si applicable) remis à zéro automatiquement. TSN et CSN continuent d'accumuler.

**TSN de départ non-zéro (pièces achetées usagées):** saisir manuellement à l'événement `receive`. Si inconnues → NULL (documenter).

**Recalcul à partir d'un ancre:**
1. Corriger `unit_airtime_at_event` de l'événement erroné
2. Marquer `is_anchor = TRUE`
3. Déclencher la fonction de recalcul → propage les nouveaux TSN/TSO sur tous les événements subséquents
Le recalcul ne touche jamais les enregistrements comptables associés.

**Cas remplacement (échange de pièce):**
- Part A retirée → `part_event: remove` (ses inspections deviennent inactives sur cet avion)
- Part B installée → `part_event: install` avec son TSO/CSN connu
- Le système recrée les inspections pour Part B depuis le template du catalog
- Next due = intervalle − TSO_actuel_de_B (ex: 3000h − 500h = 2500h restantes)
- Aucune `inspection_completions` pour le simple échange

---

## 4. Inspections

### 4.1 `inspections`

```sql
inspections
───────────────────────────────────────────
inspection_id           SERIAL PRIMARY KEY
aircraft_id             INT REFERENCES aircraft  -- nullable (inspection liée à un avion)
part_id                 INT REFERENCES parts     -- nullable (inspection liée à une pièce)
-- Note: l'un ou l'autre doit être non-NULL
description             TEXT NOT NULL
ata_chapter             TEXT
is_active               BOOLEAN NOT NULL DEFAULT TRUE
master_template_id      INT              -- référence au template d'origine (pour détection d'écarts)
notes                   TEXT
```

**Forecast de l'avion = requête dynamique:**
"Toutes les inspections actives des pièces actuellement installées sur cet avion + inspections directement liées à l'avion."
Le contexte avion est dérivé de `part_events` (quelle pièce est installée où en ce moment).

### 4.2 `inspection_limits` — N limites par inspection

**Principe fondamental:** une inspection peut avoir plusieurs limites (airtime, cycles, date, hobbs). C'est la **première limite atteinte** qui déclenche l'obligation d'intervenir.
Ex: "500h OU 12 mois", "3000 cycles OU 18 mois", "500h OU 3000 cycles OU 12 mois".

```sql
inspection_limits
───────────────────────────────────────────
limit_id                SERIAL PRIMARY KEY
inspection_id           INT NOT NULL REFERENCES inspections
limit_type              TEXT NOT NULL    -- 'airtime' | 'cycles' | 'date' | 'hobbs'
interval_value          NUMERIC NOT NULL
interval_unit           TEXT NOT NULL    -- 'hours' | 'months' | 'days' | 'cycles'
window_plus             NUMERIC          -- nullable (ex: +100 hrs)
window_minus            NUMERIC          -- nullable (ex: -100 hrs)
round_to_end_of_month   BOOLEAN NOT NULL DEFAULT FALSE
                        -- Pour limit_type='date' seulement
                        -- Ex: 2026-04-15 + 6 mois → 2026-10-31

applies_before_first_completion  BOOLEAN NOT NULL DEFAULT FALSE
                        -- TRUE = cette limite ne s'applique qu'avant la 1ère exécution (déclencheur initial)
                        -- Après la 1ère completion, cette limite devient inactive — seules les limites
                        -- récurrentes (applies_before_first_completion=FALSE) continuent de s'appliquer
                        -- S'applique à tous les limit_type ('hours', 'cycles', 'date')
                        -- Exemples:
                        --   6 YR from manufacture → 1er event seulement, puis 4 YR récurrent
                        --   30 000 cycles → 1er event seulement, puis 12 000 cycles récurrent
                        -- Si la valeur initiale est NULL (ex: manufacture_date inconnue):
                        --   système utilise la limite récurrente et documente l'absence de traçabilité

date_baseline           TEXT NOT NULL DEFAULT 'completion'
                        -- UNIQUEMENT pour limit_type='date' ET inspection liée à une pièce (part_id IS NOT NULL)
                        -- Pour inspections avion: toujours 'completion' (pas de choix)
                        -- Pour airtime/cycles: non applicable
                        -- 'completion'    → next_due depuis la date de signature du W.O.
                        -- 'certification' → next_due depuis cert_date (ex: date sur Form 1 d'atelier avionique)
                        --                   pièce peut être reçue et stockée plusieurs jours avant installation
                        -- 'install'       → next_due depuis la date d'installation sur l'avion
                        -- 'manufacture'   → next_due depuis parts.manufacture_date (date de fabrication)
                        --                   ex: batterie ELT, beacon ULB, float switch — intervalle depuis date de fab.
                        --                   saisie à la réception depuis la data plate ou Form 1
                        --                   Si manufacture_date = NULL → afficher avertissement et bloquer le calcul
                        --                   (forcer la saisie ou documenter "date inconnue" avant activation)
                        -- Cas SAAB fréquent: deux limites simultanées sur une même inspection
                        --   ex: 6 YR depuis fabrication + 4 YR depuis dernière exécution → premier atteint
                        --   Si manufacture_date inconnue, seule la limite 'completion' est calculable
```

### 4.3 `inspection_completions` — historique append-only

```sql
inspection_completions
───────────────────────────────────────────
completion_id           SERIAL PRIMARY KEY
inspection_id           INT NOT NULL REFERENCES inspections
work_order_id           INT NOT NULL REFERENCES work_orders
signed_by               INT NOT NULL REFERENCES personnel
signed_date             DATE NOT NULL

-- Valeurs RÉELLES au moment de la signature
airtime_at_completion   NUMERIC
cycles_at_completion    INT
date_at_completion      DATE NOT NULL
hobbs_at_completion     NUMERIC

cert_date               DATE    -- nullable: date sur le document externe (Form 1, rapport atelier avionique)
                                -- utilisé comme baseline quand date_baseline='certification'
                                -- saisi par le réviseur au reviewed step

-- Valeurs DUE au moment de la signature (nécessaire pour calcul window)
airtime_at_due          NUMERIC
cycles_at_due           INT
date_at_due             DATE
hobbs_at_due            NUMERIC

-- In progress
is_in_progress                  BOOLEAN NOT NULL DEFAULT FALSE
in_progress_started_airtime     NUMERIC   -- airtime au début des travaux (baseline si hors window)
in_progress_started_date        DATE
in_progress_note                TEXT

-- Dual inspection / flight test
requires_dual_inspection        BOOLEAN NOT NULL DEFAULT FALSE
dual_signed_by                  INT REFERENCES personnel
dual_signed_date                DATE
requires_flight_test            BOOLEAN NOT NULL DEFAULT FALSE
flight_test_satisfied_date      DATE

-- Corrections (immutabilité: on ne supprime jamais, on ajoute une correction)
is_voided                       BOOLEAN NOT NULL DEFAULT FALSE
voided_reason                   TEXT
voided_by                       INT REFERENCES personnel
voided_date                     DATE
superseded_by_completion_id     INT REFERENCES inspection_completions
```

**Logique de correction:** créer une nouvelle completion corrigée + marquer l'ancienne `is_voided = TRUE` avec lien vers la nouvelle. Next due calculé depuis la completion active la plus récente.

### 4.4 Logique next due selon le window (par limite)

```
Dans le window  → next_due = value_at_due + interval        (pas de pénalité)
Avant le window → next_due = value_at_completion + interval  (légère pénalité)
Après le window → next_due = value_at_completion + interval
```

**In progress:** next_due inchangé pendant les travaux partiels.
À la signature finale:
- Dans le window → next_due depuis `value_at_due`
- Hors window → next_due depuis `in_progress_started_*` (début des travaux)

**Affichage forecast:** pour chaque inspection, minimum des next_due de toutes les limites actives. Couleur vert/jaune/rouge selon la proximité.

---

## 5. Packages d'inspection

Regroupement de tâches partageant le même intervalle et effectuées ensemble.
Ex: "4000hrs inspection package", "B-check", "6 years check".

**Pourquoi:** évite 150 lignes identiques dans le forecast. Utile quand beaucoup de tâches partagent le même intervalle (ex: 4000 hrs). Si peu de tâches ont un intervalle donné, elles restent des tâches individuelles standalone.

**Forecast = deux types de lignes en parallèle:**
- **Tâche standalone** (sans package) → ligne directe avec son `next_due`
- **Package instance** → une ligne consolidée pour le package, avec son `next_due` (calculé depuis la tâche débutée le plus tôt). On drille pour voir les tâches individuelles.

**Deux modes:**

**Mode référence** (`use_checklist = FALSE`): une seule tâche dans le W.O., `work_performed` = *"4000hrs package completed as per Pascan MSA1234"*. Pour les packages faits en une shot.

**Mode checklist** (`use_checklist = TRUE`): les items génèrent des `wo_task_checklist_items`. Pour les checks progressifs (ex: B-check sur plusieurs nuits — l'avion peut revoler entre les sessions).
- **CW** (Complied With) — coché lors de la session courante
- **PCW** (Previously Complied With) — coché lors d'une session précédente du même W.O.
- **Remaining** — pas encore fait
(Dérivé automatiquement par l'UI par comparaison de dates — pas de champ séparé en DB)

```sql
inspection_packages
────────────────────────────────────────────
package_id              SERIAL PRIMARY KEY
aircraft_id             INT REFERENCES aircraft  -- nullable (si spécifique à un avion)
aircraft_type_id        INT                      -- nullable (si applicable à un type d'avion)
name                    TEXT NOT NULL            -- ex: "4000hrs inspection", "B-check", "LC1"
inspection_level        TEXT                     -- nullable, texte libre — ex: 'lvl 1', 'lvl 2', 'heavy'
                                                 -- même logique que inspection_templates.inspection_level
reference_doc           TEXT                     -- ex: "Pascan MSA1234"
use_checklist           BOOLEAN NOT NULL DEFAULT FALSE
is_active               BOOLEAN NOT NULL DEFAULT TRUE
notes                   TEXT
-- Les limites du package via inspection_limits (package_id)
-- Dans le forecast: une ligne par package (pas par inspection individuelle)

package_items     -- items du package (mode checklist seulement)
────────────────────────────────────────────
item_id                 SERIAL PRIMARY KEY
package_id              INT NOT NULL REFERENCES inspection_packages
inspection_id           INT REFERENCES inspections  -- nullable (lien vers l'inspection réelle)
item_number             INT NOT NULL             -- ordre d'affichage
description             TEXT NOT NULL
ata_chapter             TEXT
reference               TEXT
notes                   TEXT

aircraft_package_instances  -- exécution d'un package sur un avion
────────────────────────────────────────────
instance_id             SERIAL PRIMARY KEY
package_id              INT NOT NULL REFERENCES inspection_packages
aircraft_id             INT NOT NULL REFERENCES aircraft
status                  TEXT NOT NULL   -- 'upcoming' | 'in_progress' | 'completed'
-- in_progress = certaines tâches signées, d'autres non, l'avion a repris le service
-- Le package est fermé (completed) seulement quand toutes ses tâches sont signées

-- next_due du package (calculé depuis la tâche débutée le plus tôt)
next_due_airtime        NUMERIC
next_due_cycles         INT
next_due_date           DATE

started_airtime         NUMERIC      -- airtime au début des premiers travaux
started_date            DATE
completed_wo_id         INT REFERENCES work_orders   -- nullable
notes                   TEXT
```

**"In progress" sur package:** s'applique au package (pas aux tâches individuelles). Quand certaines tâches du package sont signées et d'autres non, l'avion repart en service et le package est marqué `in_progress`. Les tâches individuelles dans `inspections` gardent leur status propre, mais n'apparaissent pas dans le forecast — elles sont accessibles via drill-down dans le package.

**Export avion sortant:** toutes les inspections individuelles étant déjà dans `inspections`, un export CSV/PDF complet des tâches standalone + détail de chaque package est disponible à tout moment.

**Window sur package progressif (B-check multi-nuits):**
- Première tâche débutée dans le window → next due depuis le due original (pas de pénalité)
- Débutée avant le window → next due depuis le début des travaux (légère pénalité)
- Complété après le window → next due depuis la fin des travaux

---

## 6. Work Orders

### 6.1 Workflow des statuts

```
staged → open → closed → completed          (révision OK — tout est en ordre)
                       → reviewed           (items à clarifier — pending)
                            ↓
                         completed           (une fois les items clarifiés)
```

1. **staged** (optionnel): W.O. préparé d'avance par un planificateur. Tâches pré-remplies.
2. **open**: activation d'un staged, ou création directe. Tâches planifiées et non-planifiées (snags).
3. **closed**: toutes les tâches fermées (`can_close_task`) ou in_progress. L'avion ne peut pas voler avec un W.O. ouvert. Restriction: ne peut pas fermer si airtime/cycles non confirmés.
4. **reviewed**: maintenance control a révisé et trouvé des items à clarifier. Reste pending jusqu'à résolution, puis → completed.
5. **completed**: révision finale confirmée par maintenance control (`can_review_wo`):
   - Concordance title/description/work_performed dans chaque tâche
   - Statut des pièces installées (new, oh, repair, modified, inspected)
   - TSO/CSN accumulé sur les pièces installées
   - Référence documentaire adéquate pour chaque tâche
   - Statut des pièces retirées (unserviceable, damaged, time_limited, standby, scrap)
   - Confirmation du next due pour chaque tâche planifiée

### 6.2 `work_orders`

```sql
work_orders
────────────────────────────────────────────
wo_id                   SERIAL PRIMARY KEY
wo_number               TEXT NOT NULL    -- ex: WO-2024-0342 (format config_global$mbhlCore$wo_number_format)
wo_type                 TEXT NOT NULL    -- 'aircraft' | 'shop' | 'outsource'
status                  TEXT NOT NULL    -- 'staged' | 'open' | 'closed' | 'reviewed' | 'completed'

aircraft_id             INT REFERENCES aircraft   -- nullable (aircraft WO)
part_id                 INT REFERENCES parts      -- nullable (shop WO)

-- Airtime/cycles confirmés (obligatoire avant fermeture d'un aircraft WO)
confirmed_airtime       NUMERIC
confirmed_cycles        INT
confirmed_date          DATE             -- date réelle des travaux (peut être dans le passé)
entry_date              DATE NOT NULL DEFAULT CURRENT_DATE  -- date de saisie dans le système
is_transcription        BOOLEAN NOT NULL DEFAULT FALSE
transcription_note      TEXT

-- Confirmation airtime
airtime_confirmed_by    INT REFERENCES personnel
airtime_confirmed_at    TIMESTAMP

-- Cycle de vie
staged_by               INT REFERENCES personnel
staged_date             TIMESTAMP
opened_by               INT REFERENCES personnel
opened_date             TIMESTAMP
closed_by               INT REFERENCES personnel
closed_date             TIMESTAMP
reviewed_by             INT REFERENCES personnel   -- items à clarifier
reviewed_date           TIMESTAMP
completed_by            INT REFERENCES personnel   -- révision finale OK
completed_date          TIMESTAMP

notes                   TEXT
```

### 6.3 `wo_tasks`

```sql
wo_tasks
────────────────────────────────────────────
task_id                 SERIAL PRIMARY KEY
wo_id                   INT NOT NULL REFERENCES work_orders
task_number             INT NOT NULL     -- séquentiel dans le W.O.
task_type               TEXT NOT NULL    -- 'planned' | 'snag'
inspection_id           INT REFERENCES inspections  -- nullable (si planifiée)
status                  TEXT NOT NULL    -- 'open' | 'in_progress' | 'completed' | 'deferred'

ata_chapter             TEXT
reference               TEXT             -- AMM ref, SB, AD, etc.

-- Documentation terrain
title                   TEXT NOT NULL    -- titre court, lecture rapide (ex: "Starter-gen LH high time")
                                         -- N'APPARAÎT PAS sur la certification — usage interne seulement
description             TEXT             -- contexte/observations détaillées (optionnel)
                                         -- pour un snag: description du problème constaté
work_performed          TEXT             -- travaux effectués

-- Résultat
no_fault_found          BOOLEAN NOT NULL DEFAULT FALSE
                        -- task_type='planned' seulement
                        -- TRUE = inspection effectuée, rien d'anormal
                        -- ≠ "found serviceable" (conclusion d'une réparation)
                        -- Alimente module de fiabilité: taux NFF élevé → candidat prolongation

-- Signature (airtime/cycles viennent du W.O., pas de la tâche)
completed_by            INT REFERENCES personnel
completed_date          DATE

-- In progress
in_progress_note        TEXT
in_progress_airtime_started NUMERIC
in_progress_date_started    DATE

-- Dual inspection
requires_dual_inspection    BOOLEAN NOT NULL DEFAULT FALSE
dual_inspected_by           INT REFERENCES personnel
dual_inspected_date         DATE

-- Flight test
requires_flight_test        BOOLEAN NOT NULL DEFAULT FALSE
flight_test_satisfied_date  DATE
flight_test_by              INT REFERENCES personnel

notes                   TEXT
```

**UX — no_fault_found (❓ à valider au prototypage):**
- Option A: cocher NFF → auto-remplit work_performed (texte standard). Si modifié → NFF=FALSE.
- Option B: texte pré-rempli par défaut dès l'ouverture. NFF coché séparément.
- Option C: NFF complètement séparé de work_performed. Deux actions conscientes.
→ Décision à tester avec les utilisateurs terrain.

### 6.4 `wo_task_parts` — pièces utilisées dans une tâche

```sql
wo_task_parts
────────────────────────────────────────────
wo_task_part_id         SERIAL PRIMARY KEY
task_id                 INT NOT NULL REFERENCES wo_tasks
action                  TEXT NOT NULL    -- 'install' | 'remove'
part_id                 INT REFERENCES parts      -- nullable (pièces tracées individuellement)
lot_id                  INT REFERENCES store_lots -- nullable (pièces par lot)
quantity                INT NOT NULL DEFAULT 1    -- 1 pour tracées, variable pour lots
position_id             INT REFERENCES parts_catalog_positions  -- nullable
                                         -- nullable si la pièce n'a qu'une seule position possible
                                         -- même logique que part_events.position_id

part_status             TEXT NOT NULL
                        -- install: 'new' | 'oh' | 'repair' | 'modified' | 'inspected_tested' | 'serviceable'
                        -- remove:  'unserviceable' | 'damaged' | 'scheduled_removal' | 'standby' | 'scrap' | 'serviceable'
serviceable_until       TIMESTAMP
                        -- UNIQUEMENT si part_status='serviceable' à la dépose
                        -- = timestamp dépose + 24h
                        -- après 24h → status automatiquement promu à 'standby'
notes                   TEXT
```

**Règles métier:**
- `scheduled_removal` accessible UNIQUEMENT si `task_type='planned'` ET `inspection_id IS NOT NULL`
- Statuts pouvant être INSTALLÉS: `new` | `oh` | `repair` | `modified` | `inspected_tested` | `serviceable`
- Une pièce `unserviceable`, `damaged`, `standby`, `scrap` ou `scheduled_removal` ne peut pas être installée

### 6.5 Tables auxiliaires W.O.

```sql
wo_task_checklist_items
────────────────────────────────────────────
checklist_item_id       SERIAL PRIMARY KEY
task_id                 INT NOT NULL REFERENCES wo_tasks
item_order              INT NOT NULL
description             TEXT NOT NULL
is_checked              BOOLEAN NOT NULL DEFAULT FALSE
checked_by              INT REFERENCES personnel
checked_at              TIMESTAMP

wo_task_tools     -- outils calibrés utilisés dans une tâche (traçabilité réglementaire)
────────────────────────────────────────────
wo_task_tool_id         SERIAL PRIMARY KEY
task_id                 INT NOT NULL REFERENCES wo_tasks
tool_id                 INT NOT NULL REFERENCES calibrated_tools
notes                   TEXT

wo_outsource_docs -- fichiers attachés à un W.O. outsource (N par W.O.)
────────────────────────────────────────────
doc_id                  SERIAL PRIMARY KEY
wo_id                   INT NOT NULL REFERENCES work_orders
doc_ref                 TEXT NOT NULL    -- lien S3
doc_description         TEXT
uploaded_by             INT NOT NULL REFERENCES personnel
uploaded_date           TIMESTAMP NOT NULL DEFAULT NOW()
```

**Paperless:** Le papier est une *sortie* du système (généré à la demande), jamais une *entrée* à ré-encoder.

**Maintenance release:** collant journey log généré à la demande lors de la fermeture d'un W.O., PDF parfait pour imprimer sur feuille autocollante. Non stocké — régénéré à la volée.

**Retranscription:** `is_transcription = TRUE` + note. `confirmed_date` = date réelle des travaux. `entry_date` = date de saisie.

---

## 7. Extensions d'inspections

Report ponctuel d'une inspection au-delà de son échéance pour raisons opérationnelles. ≠ prolongation permanente d'intervalle (programme de fiabilité). TC ne les voit pas d'un bon œil — à utiliser avec parcimonie.

**Règles:** Non applicable aux items avec window. Requiert justification. Génère une entrée dans un registre consultable.

```sql
inspection_extensions
────────────────────────────────────────────
extension_id            SERIAL PRIMARY KEY
inspection_id           INT NOT NULL REFERENCES inspections
original_due_airtime    NUMERIC
original_due_cycles     INT
original_due_date       DATE
extended_to_airtime     NUMERIC
extended_to_cycles      INT
extended_to_date        DATE
justification           TEXT NOT NULL
approved_by             INT NOT NULL REFERENCES personnel
approved_date           DATE NOT NULL
reference_doc           TEXT             -- S3 link (doc TC ou interne autorisant l'extension)
is_active               BOOLEAN NOT NULL DEFAULT TRUE  -- FALSE une fois l'inspection complétée
notes                   TEXT
```

**Lien fiabilité:** extensions répétées sur un même item = signal pour dossier TC (programme d'allongement).

---

## 8. Ajournements de défectuosités — MEL (`deferrals`)

**Deux types selon la réglementation canadienne:**

**Avec MEL:** défectuosité correspond à un item listé dans le MEL approuvé.
- Actions possibles: **O** (Operational), **M** (Maintenance élémentaire), **M#** (signé par technicien licencié/ACA)

**Sans MEL:** processus plus complexe — vérifier RAC + documents manufacturier, documenter les références.

**Solution MBHL:** quand un technicien ferme une tâche snag avec status `'deferred'`, le système force immédiatement la saisie du deferral dans la même interface. Le deferral apparaît **automatiquement dans le forecast** dès sa création.

**Deux origines:**
- Depuis un W.O. (technicien): lié à un snag task
- Entrée manuelle (pilote → maintenance): sans W.O. formel

```sql
deferrals
────────────────────────────────────────────
deferral_id             SERIAL PRIMARY KEY
aircraft_id             INT NOT NULL REFERENCES aircraft
origin_type             TEXT NOT NULL    -- 'wo_task' | 'manual_entry'
snag_task_id            INT REFERENCES wo_tasks  -- nullable

defect_description      TEXT NOT NULL    -- ce qui a été trouvé (spécifique, ex: "RH nav light inopérante")
deferred_system         TEXT NOT NULL    -- système différé (scope MEL, ex: "Nav light system")
deferral_type           TEXT NOT NULL    -- 'mel' | 'non_mel'

-- Si MEL:
mel_item_ref            TEXT             -- numéro/section du MEL
mel_o_action_required   BOOLEAN NOT NULL DEFAULT FALSE
mel_m_action_type       TEXT             -- nullable: 'M' | 'M#'
mel_m_signed_by         INT REFERENCES personnel  -- nullable (si M#)
mel_m_signed_date       DATE

-- Si non-MEL:
regulatory_refs         TEXT             -- chapitres RAC consultés
manufacturer_refs       TEXT             -- POH, MOM, Flight Manual, etc.

-- Expiration
due_date                DATE             -- date d'expiration (nullable)
due_airtime             NUMERIC          -- limite airtime (nullable)

-- Résolution
is_active               BOOLEAN NOT NULL DEFAULT TRUE
closed_by_wo_id         INT REFERENCES work_orders
closed_date             DATE

-- Traçabilité
entered_by              INT NOT NULL REFERENCES personnel
entered_date            DATE NOT NULL
notes                   TEXT
```

---

## 9. Tableau de status interne des composantes (`component_internal_parts`)

**Deux niveaux :**
- **Template** (`component_internal_part_types` + `component_internal_part_acceptable_pns`) : définit quelles positions existent dans un type de composante, combien d'unités par position, et quels P/Ns sont acceptables (avec leur limite de vie respective)
- **Instance** (`component_internal_parts`) : les pièces physiques réellement installées dans une composante spécifique

**Règles :**
- CSN = 0 = pièce neuve (zéro cycles). ≠ inconnu. Si la traçabilité est inconnue, la pièce ne peut pas être installée.
- À l'onboarding d'une composante (ex: gear) : le système génère les cases à remplir selon `component_internal_part_types`. L'utilisateur saisit P/N + S/N + CSN pour chaque position. Si P/N non dans la liste acceptable → blocage.
- Forecast : une seule ligne pour la composante = min(tous les next_due internes, overhaul interval)

```sql
component_internal_part_types   -- positions internes par type de composante
────────────────────────────────────────────
type_id                 SERIAL PRIMARY KEY
parent_catalog_id       INT NOT NULL REFERENCES parts_catalog  -- le gear, moteur, etc.
position_name           TEXT NOT NULL   -- ex: 'Upper Link #1', 'Upper Link #2', 'Trunnion Pin LH'
quantity                INT NOT NULL DEFAULT 1  -- nb de positions (ex: 2 upper links)
life_limit_type         TEXT NOT NULL   -- 'cycles' | 'airtime'
notes                   TEXT

component_internal_part_acceptable_pns  -- P/Ns acceptables par position (life limit par P/N)
────────────────────────────────────────────
acceptable_id           SERIAL PRIMARY KEY
type_id                 INT NOT NULL REFERENCES component_internal_part_types
catalog_id              INT NOT NULL REFERENCES parts_catalog  -- P/N acceptable
life_limit_value        NUMERIC NOT NULL  -- limite de vie spécifique à ce P/N
                                          -- provient de l'ALM (par P/N)
```

Composantes complexes (moteurs, trains) contenant des pièces internes à vie limitée. Toutes accumulent cycles/airtime au même rythme que la composante parent.

**Principe:** pas de `part_events` individuels pour chaque pièce interne — on dérive leur accumulation de la composante parent.

```sql
component_internal_parts
────────────────────────────────────────────
internal_part_id        SERIAL PRIMARY KEY
parent_part_id          INT NOT NULL REFERENCES parts  -- composante parente
description             TEXT NOT NULL    -- ex: "1st stage HPT wheel"
part_number             TEXT
serial_number           TEXT             -- si connu
life_limit_type         TEXT NOT NULL    -- 'cycles' | 'airtime'
life_limit_value        NUMERIC NOT NULL -- ex: 8000
value_at_last_shop      NUMERIC NOT NULL -- valeur du parent (CSN ou TSN) au dernier shop visit
                                         -- base: accumulation = parent.csn - value_at_last_shop
is_active               BOOLEAN NOT NULL DEFAULT TRUE
notes                   TEXT
```

**Vie restante** = `life_limit_value - (parent.csn - value_at_last_shop)`

**Vue sommaire (remplace l'Excel actuel):**
```
Moteur CFM56-7B  |  S/N: E-12345  |  TSN: 12 345h  |  CSN: 8 234 cyc
──────────────────────────────────────────────────────────────────────
Pièce interne              Limite    Accumulé   Restant     % restant
1st stage turbine wheel     8 000     8 234     ⚠️ -234     DÉPASSÉ
HPT blade                  10 000     8 234      1 766       17.7%
LPT disc                   12 000     8 234      3 766       31.4%
```

**Mise à jour après shop visit:** mettre à jour `value_at_last_shop` pour les pièces remplacées.

---

## 10. Outils calibrés

Module dans `mbhlMaintenance`. Forecast d'outils distinct du forecast avion.

```sql
tool_types        -- types configurables par client
────────────────────────────────────────────
type_id                 SERIAL PRIMARY KEY
type_name               TEXT NOT NULL    -- ex: 'Clé dynamométrique', 'Multimètre'
is_active               BOOLEAN NOT NULL DEFAULT TRUE
notes                   TEXT

calibrated_tools
────────────────────────────────────────────
tool_id                 SERIAL PRIMARY KEY
tool_number             TEXT NOT NULL    -- identifiant physique gravé sur l'outil
description             TEXT NOT NULL
tool_type_id            INT NOT NULL REFERENCES tool_types
manufacturer            TEXT
model                   TEXT
base_id                 INT REFERENCES bases  -- base où l'outil se trouve actuellement
calibration_interval_months INT NOT NULL
status                  TEXT NOT NULL    -- 'calibrated' | 'in_calibration' | 'out_of_service'
is_active               BOOLEAN NOT NULL DEFAULT TRUE
notes                   TEXT

tool_calibrations -- historique append-only
────────────────────────────────────────────
calibration_id          SERIAL PRIMARY KEY
tool_id                 INT NOT NULL REFERENCES calibrated_tools
calibration_date        DATE NOT NULL
calibrated_by_personnel_id INT REFERENCES personnel  -- nullable (calibration interne)
calibrated_by_company_id   INT REFERENCES companies  -- nullable (laboratoire externe)
certificate_ref         TEXT             -- S3 (certificat de calibration)
next_due_date           DATE NOT NULL
notes                   TEXT
```

**Forecast outils:** liste séparée triée par `next_due_date`, filtrable par base, statut visuel vert/jaune/rouge.

**Lien W.O.:** `wo_task_tools` (traçabilité réglementaire — quels outils calibrés ont été utilisés dans quelle tâche).

---

## 11. Consommation d'huile (`log_oil_consumption`)

Suivi de la consommation d'huile par avion et par moteur. Utile pour détecter des tendances (augmentation = signe précoce de problème moteur).

Appartient à `mbhlMaintenance` (c'est principalement la maintenance qui entre ces données, pas les pilotes — même si le système supporte les deux).

```sql
log_oil_consumption
────────────────────────────────────────────
entry_id                SERIAL PRIMARY KEY
aircraft_id             INT NOT NULL REFERENCES aircraft
date                    DATE NOT NULL
airtime_at_entry        NUMERIC
engine_position         TEXT NOT NULL    -- 'L' | 'R' | 'C' (gauche, droit, centre)
oil_added_qty           NUMERIC NOT NULL
oil_unit                TEXT NOT NULL    -- 'litres' | 'quarts'
added_by                INT NOT NULL REFERENCES personnel
notes                   TEXT
```

---

## 12. Module de fiabilité (CI 605-002)

**Référence:** Circulaire d'information TC CI 605-002 — *Méthodes de contrôle de la fiabilité pour les modifications apportées au calendrier de maintenance* (2011-11-07).

**Principe:** TC permet à un exploitant de modifier ses intervalles de maintenance (allongement ou réduction) sans approbation ministérielle préalable, à condition d'avoir un **programme de fiabilité approuvé**.

**Monitoring silencieux:** le module collecte et agrège automatiquement les données du workflow normal. Aucune action supplémentaire requise des utilisateurs.

Sources de données:
- Déposes planifiées et non-planifiées (`part_events`)
- Heures/cycles à la dépose (TSN, TSO, CSN, CSO)
- Constatations d'atelier (shop W.O. — défaillance confirmée, no fault found, etc.)
- Historique des completions (`inspection_completions`)
- Résultats NFF par tâche (`wo_tasks.no_fault_found`)
- Interruptions mécaniques (`mechanical_interruptions`)

### 12.1 Tables dédiées

```sql
aircraft_configurations   -- configuration matérielle par avion (pour calcul FHU)
────────────────────────────────────────────
config_id               SERIAL PRIMARY KEY
aircraft_id             INT NOT NULL REFERENCES aircraft
catalog_id              INT NOT NULL REFERENCES parts_catalog  -- type de composante installée
units_per_aircraft      INT NOT NULL     -- nb d'unités installées (ex: 2 fans, 1 hélice)
effective_from          DATE NOT NULL
effective_to            DATE             -- nullable (configuration courante si NULL)
notes                   TEXT
-- Permet de filtrer les FH aux seuls avions ayant la composante analysée
-- Ex: SAABs avec deux modèles d'hélice → calculs séparés par configuration

mechanical_interruptions   -- cancellations/délais mécaniques
────────────────────────────────────────────
interruption_id         SERIAL PRIMARY KEY
wo_id                   INT NOT NULL REFERENCES work_orders  -- snag causant l'interruption
flight_ref              TEXT             -- référence au vol affecté (nullable — lien OTP si dispo)
interruption_type       TEXT NOT NULL    -- 'cancellation' | 'delay'
date                    DATE NOT NULL
notes                   TEXT
-- Saisi directement dans MBHL (pas dépendant du OTP)
-- Lié au snag W.O. pour traçabilité complète cause → interruption
```

### 12.2 Métriques calculées

| Métrique | Définition | Source |
|----------|-----------|--------|
| FH (Flying Hours) | Temps de vol roues-décollage à roues-atterrissage | logpage |
| FHU (Flying Hours Unit) | FH × units_per_aircraft (avions avec config active seulement) | logpage × `aircraft_configurations` |
| UR (Unscheduled Removal) | Dépose suite à défaillance ou défaut suspecté | `part_events` + snag W.O. |
| URR (Unscheduled Removal Rate) | (UR / FHU) × 1000 | calculé |
| MTBUR | FHU / UR | calculé |
| MI (Mechanical Interruption) | Cancellations ou délais techniques | `mechanical_interruptions` |
| MI Rate | Nb d'événements / 1000 départs planifiés | calculé |
| DR (Dispatch Reliability) | 100 × (départs − MI) / départs | calculé |
| MTBF | FH totales / nb défaillances | calculé |

### 12.3 Sorties

- Rapports par ATA (niveau 1 et 2) sur période configurable, avec comparaison de périodes
- Rapports par composante (P/N, nomenclature, units/A/C, UR, URR, MTBUR)
- Liste d'opportunités pour prolongation d'intervalle: composantes avec MTBUR >> TBO actuel, inspections avec taux NFF élevé

**Ce que ce n'est PAS:** pas une décision automatique. La modification formelle de l'intervalle reste soumise au processus TC.

**Données requises pour un dossier TC (CI 605-002 section 12):**
- 10% à 25% des unités de la flotte comme échantillons
- Rapports d'atelier satisfaisants après démontage au TBO courant
- Période d'essai = max 10% du TBO courant

---

## 12.4 Analyse de survie (Kaplan-Meier + Weibull)

**Principe:** analyse statistique des temps entre défaillances pour comprendre le comportement
réel des composantes et soutenir les décisions d'allongement d'intervalle (dossiers TC CI 605-002).
Monitoring silencieux — les données sont collectées via le workflow normal, aucune saisie
supplémentaire.

**Guardrails intégrés:**
- Avertissement si `n_failures < min_obs_threshold` (défaut: 20) — résultats affichés mais flagués
- Intervalles de confiance à 95% sur β et η (pas uniquement les estimates ponctuels)
- Résultats présentés comme "évidence statistique à l'appui d'un dossier TC", jamais comme
  recommandation automatique
- Données censurées à droite (pièces encore en service) gérées explicitement via KM et Weibull MLE
- Segmentation par cause de dépose pour éviter le mélange des modes de défaillance

### Classification des causes de dépose

```sql
reliability_failure_mode_library   -- bibliothèque de suggestions (pré-seeded, lecture seule)
────────────────────────────────────────
library_id          SERIAL PRIMARY KEY
code                TEXT NOT NULL    -- ex: 'brush_wear', 'bearing_failure', 'seal_leak', 'nff'
label               TEXT NOT NULL
is_scheduled_removal BOOLEAN NOT NULL DEFAULT FALSE
is_active           BOOLEAN NOT NULL DEFAULT TRUE

reliability_failure_modes   -- causes configurées par catalog_id
────────────────────────────────────────
failure_mode_id     SERIAL PRIMARY KEY
catalog_id          INT NOT NULL REFERENCES parts_catalog
library_id          INT REFERENCES reliability_failure_mode_library
                    -- nullable = cause custom créée de toute pièce
                    -- non-null = instanciée depuis la bibliothèque générique
label               TEXT NOT NULL    -- peut surcharger le label générique
is_scheduled_removal BOOLEAN NOT NULL DEFAULT FALSE
                    -- TRUE = dépose planifiée → censurée dans l'analyse (pas comptée comme panne)
is_active           BOOLEAN NOT NULL DEFAULT TRUE
notes               TEXT
```

**Workflow de configuration:** aucune cause prédéfinie par P/N à l'installation. À la première
utilisation, le système propose la bibliothèque comme suggestions. Un choix générique sélectionné
est instancié pour ce `catalog_id` — il peut ensuite être personnalisé. Les causes custom
(`library_id = NULL`) peuvent être créées de toute pièce.

**Classification dans le workflow W.O.:** ajout à la checklist de révision maintenance control
(step reviewed → completed), champ **non-bloquant**. Si non classifié, la dépose est incluse dans
les analyses avec `failure_mode_id = NULL` et peut être classifiée rétrospectivement.

```sql
part_removal_tags   -- enrichit part_events sans modifier la table core
────────────────────────────────────────
tag_id              SERIAL PRIMARY KEY
part_event_id       INT NOT NULL REFERENCES part_events   -- event_type='remove' seulement
failure_mode_id     INT REFERENCES reliability_failure_modes  -- nullable si non classifié
classified_by       INT REFERENCES personnel
classified_date     DATE
notes               TEXT
```

### Analyses

```sql
reliability_analyses   -- snapshot paramétré et reproductible
────────────────────────────────────────
analysis_id         SERIAL PRIMARY KEY
-- P/Ns couverts via reliability_analysis_catalogs (many-to-many)
-- supporte P/N unique ou groupe d'alternates poolés
failure_mode_id     INT REFERENCES reliability_failure_modes
                    -- nullable = toutes déposes UR (tous modes confondus)
time_unit           TEXT NOT NULL   -- 'airtime' | 'cycles'
period_from         DATE
period_to           DATE

-- Statistiques descriptives
n_total             INT NOT NULL
n_failures          INT NOT NULL     -- déposes UR non censurées
n_censored          INT NOT NULL     -- pièces encore en service au moment de l'analyse

-- Guardrail seuil
min_obs_threshold   INT NOT NULL DEFAULT 20
is_below_threshold  BOOLEAN NOT NULL   -- TRUE si n_failures < min_obs_threshold
                                       -- résultats Weibull affichés avec avertissement prominent

-- Kaplan-Meier (toujours calculé, même sous le seuil)
km_computed         BOOLEAN NOT NULL DEFAULT FALSE

-- Weibull (calculé même sous le seuil, mais flagué is_below_threshold)
weibull_fitted      BOOLEAN NOT NULL DEFAULT FALSE
weibull_beta        NUMERIC          -- paramètre de forme (β)
weibull_eta         NUMERIC          -- durée de vie caractéristique (η)
weibull_beta_ci_lower  NUMERIC       -- borne inférieure IC 95%
weibull_beta_ci_upper  NUMERIC       -- borne supérieure IC 95%
weibull_eta_ci_lower   NUMERIC
weibull_eta_ci_upper   NUMERIC
beta_interpretation    TEXT          -- dérivé automatiquement:
                                     -- β < 0.9  → 'early_failure'  (défauts précoces)
                                     -- 0.9 ≤ β ≤ 1.1 → 'random'   (pannes aléatoires)
                                     -- β > 1.1  → 'wear_out'       (usure progressive)

-- Qualité d'ajustement KM vs Weibull
gof_statistic       NUMERIC          -- Anderson-Darling
gof_interpretation  TEXT             -- 'good' | 'acceptable' | 'poor' (seuils configurables)

-- Framing TC (affiché avec tous les résultats, non modifiable)
tc_framing_note     TEXT NOT NULL DEFAULT
    'Ces résultats constituent une évidence statistique à l''appui d''un dossier TC
     (CI 605-002). Ils ne remplacent pas les exigences réglementaires (échantillon minimal,
     rapports d''atelier, période d''essai).'

created_by          INT NOT NULL REFERENCES personnel
created_at          TIMESTAMP NOT NULL DEFAULT NOW()
notes               TEXT             -- justification si pooling de plusieurs P/Ns

reliability_analysis_catalogs   -- P/Ns couverts (un ou plusieurs)
────────────────────────────────────────
analysis_id         INT NOT NULL REFERENCES reliability_analyses
catalog_id          INT NOT NULL REFERENCES parts_catalog
PRIMARY KEY (analysis_id, catalog_id)
-- Un seul entry = analyse par P/N individuel
-- Plusieurs entries = analyse poolée (ex: alternates interchangeables)
-- Documenter la justification du pooling dans reliability_analyses.notes
```

### Observations et courbe KM

```sql
reliability_observations   -- snapshot des observations (analyse reproductible)
────────────────────────────────────────
obs_id              SERIAL PRIMARY KEY
analysis_id         INT NOT NULL REFERENCES reliability_analyses
part_id             INT NOT NULL REFERENCES parts
part_event_id       INT REFERENCES part_events   -- nullable si pièce encore en service (censurée)
time_value          NUMERIC NOT NULL   -- TSO ou CSO au moment de l'événement
is_censored         BOOLEAN NOT NULL   -- TRUE = pièce encore en service
failure_mode_id     INT REFERENCES reliability_failure_modes  -- nullable si non classifié

-- Exclusion manuelle avec justification obligatoire
is_excluded         BOOLEAN NOT NULL DEFAULT FALSE
exclusion_reason    TEXT             -- obligatoire si is_excluded = TRUE
excluded_by         INT REFERENCES personnel

reliability_km_points   -- points de la courbe KM avec IC 95% (Greenwood)
────────────────────────────────────────
point_id            SERIAL PRIMARY KEY
analysis_id         INT NOT NULL REFERENCES reliability_analyses
t                   NUMERIC NOT NULL   -- temps (airtime ou cycles)
survival_prob       NUMERIC NOT NULL   -- S(t)
ci_lower            NUMERIC            -- borne inférieure IC 95%
ci_upper            NUMERIC            -- borne supérieure IC 95%
n_risk              INT NOT NULL       -- nb à risque juste avant t
n_events            INT NOT NULL       -- nb de pannes à t
n_censored_at_t     INT NOT NULL       -- nb censurés à t
```

### Sorties

- Courbe KM observée vs Weibull ajustée (visualisation qualité d'ajustement)
- β et η avec IC 95% + interprétation automatique (early failure / random / wear out)
- Probabilité de survie jusqu'à un âge donné : P(T > t)
- Âge auquel X% de la flotte risque une panne (percentile configurable)
- Intervalle de remplacement préventif optimal

**Lien avec la liste d'opportunités (section 12.3):** une analyse avec
`beta_interpretation = 'wear_out'` et MTBUR >> TBO courant remonte automatiquement dans les
opportunités de prolongation. La décision formelle reste dans `operator_overrides` une
fois le dossier TC approuvé.

---

## 13. Source des données airtime/cycles

**Pour Pascan:** `logpage` est la source de vérité pour les totaux airtime/cycles. Une fois logpage migré vers PostgreSQL, MBHL lira directement depuis ses tables (dans le schema du client). Pas de duplication.

**Pour d'autres clients (sans logpage):**
- Client avec log électronique: intégration à développer selon le système utilisé
- Client avec log papier sans logpage: page de saisie manuelle d'airtime/cycles dans MBHL (fallback universel)

---

## 14. MVP — Périmètre mbhlMaintenance

**Dans le MVP:**
- `parts_catalog` + `parts` (catalogue et unités individuelles)
- `part_events` (journal TSN/TSO)
- `inspections` + `inspection_limits` + `inspection_completions`
- `work_orders` + `wo_tasks` + `wo_task_parts`
- Forecast (requête dynamique depuis les données courantes)
- W.O. complet: staged → open → closed → reviewed → completed

**Hors MVP (architecture pensée dès le départ):**
- Module de fiabilité (CI 605-002)
- Outils calibrés (schéma conçu, développement différé)
- Ajournements MEL (structure en place, développement complet différé)

---

## 15. Gestion des permissions

### Structure de `config_user`

Format imbriqué — jamais de clés plates :
```r
config_user$mbhlmaintenance$forecast$has_access
config_user$mbhlmaintenance$work_orders$can_close
config_user$mbhlmaintenance$work_orders$can_review
```
`NULL` = accès refusé (default deny). Jamais `FALSE` — soit `TRUE`, soit absent.
`config_user$.role` contient le rôle protegR2 (`'dev'`|`'admin'`|`'user'`|...).

### Rôle `dev` — bypass total

`has_permission()` retourne toujours `TRUE` si `config_user$.role == "dev"`.
Raison : quand une nouvelle permission est ajoutée au registre, personne ne l'a encore.
Le dev peut tester immédiatement sans avoir à configurer les groupes.

### Moteur dans protegR2 (refactor en attente)

`build_user_permissions()`, `has_permission()`, `assert_permission()` seront dans `protegR2`.
Actuellement encore dans `mbhlcore/R/permissions.R` — migration à faire avant de câbler
les permissions dans les modules Shiny de mbhlMaintenance.

### Registre `mbhlmaintenance_permissions`

Chaque package exporte une liste nommée de toutes ses permissions — source de vérité
pour l'UI admin et pour ne rien oublier. Ajouter une permission = l'ajouter au registre.

```r
# R/permissions.R
mbhlmaintenance_permissions <- list(
    forecast = list(
        has_access = "Voir le forecast"
    ),
    work_orders = list(
        can_view   = "Voir les work orders",
        can_open   = "Ouvrir un W.O.",
        can_stage  = "Préparer un W.O. (staged)",
        can_add_task   = "Ajouter une tâche",
        can_close_task = "Signer/fermer une tâche",
        can_close  = "Fermer un W.O.",
        can_review = "Réviser un W.O. (maintenance control)"
    ),
    inspections = list(
        has_access        = "Voir les inspections",
        can_create        = "Créer une inspection",
        can_edit          = "Modifier une inspection",
        can_approve_extension = "Approuver une extension",
        can_manage_packages   = "Gérer les packages d'inspection",
        can_manage_deferrals  = "Gérer les ajournements MEL",
        can_void_completion   = "Annuler une completion"
    ),
    catalog = list(
        can_review = "Réviser les entrées parts_catalog"
    )
)
```

---

## 16. Questions ouvertes (ancien §15)

| # | Question | Statut |
|---|----------|--------|
| UX | Comportement NFF / work_performed | ❓ À valider au prototypage avec les techniciens |
| position | Texte libre ou liste par type d'avion pour `position` dans `wo_task_parts` | ✅ Texte libre avec autocomplete — aucune liste fixe |
| standby | Signataire externe — peut-il se connecter à l'application? | ❓ Pending |
| AD sort_order | L'ordre est partagé par type d'avion — UI pour définir/réordonner la liste à créer | ❓ À concevoir |
| SB procedure | Les SBs de type 'procedure' n'ont pas de pre/post sur l'avion — comment les afficher dans le listing? | ❓ À valider |

---

## 17. Templates d'inspection, ADs et SBs

### 16.1 Entité de référence — `aircraft_types` *(dans `mbhlCore`)*

Table des types d'aéronefs, utilisée comme référence dans les templates, ADs et SBs.

```sql
aircraft_types
────────────────────────────────────────────
type_id                 SERIAL PRIMARY KEY
icao_type               TEXT NOT NULL        -- ex: 'SF34', 'B190', 'AT43'
manufacturer            TEXT NOT NULL        -- ex: 'SAAB', 'Beechcraft', 'ATR'
model                   TEXT NOT NULL        -- ex: '340', '1900', '42'
variant                 TEXT                 -- nullable (ex: 'B', 'D' — NULL = tous variants)
notes                   TEXT
```

---

### 16.2 Sources des inspections (`inspection_sources`)

Un même avion peut avoir des inspections issues de plusieurs documents : MRB, CMMs (un par fabricant de composante), programme compagnie. Chaque document = une ligne.

```sql
inspection_sources
────────────────────────────────────────────
source_id               SERIAL PRIMARY KEY
publication_id          INT REFERENCES publications   -- nullable — lien vers mbhlCore.publications
                                             -- quand défini: cette source est le prolongement maintenance
                                             -- d'une publication suivie (MPD, CMM, AMM pour petits avions, etc.)
source_type             TEXT NOT NULL        -- 'mrb' | 'cmm' | 'alm' | 'company' | 'other'
                                             -- décrit le CONTENU (pas le type de document)
                                             -- ex: une AMM de petit avion peut avoir source_type='mrb'
                                             --     si elle contient les listes de tâches d'inspection
                                             -- 'alm' = Airworthiness Limitations Manual
                                             --         toutes les tâches ALM sont des AL (Airworthiness Limitations)
                                             -- Note: un même document peut générer plusieurs sources
                                             --       ex: MPD SAAB → une source 'mrb' + une source 'alm'
source_name             TEXT NOT NULL        -- ex: 'SAAB 340B MRB', 'Hamilton 14SF-23 CMM'
                                             --     'Dowty R408 CMM Issue 4', 'GE CT7-9B CMM'
manufacturer            TEXT                 -- ex: 'SAAB', 'Hamilton', 'Dowty', 'GE'
aircraft_type_id        INT REFERENCES aircraft_types   -- nullable
catalog_id              INT REFERENCES parts_catalog    -- nullable
document_version        TEXT                 -- ex: 'Rev 12', 'Issue 7'
effective_date          DATE
doc_ref                 TEXT                 -- S3 (copie du document)
notes                   TEXT
```

**Exemple SAAB 340B avec Hamilton:**
- 'SAAB 340B MRB Rev 12' → `aircraft_type_id = SAAB340B`, `catalog_id = NULL`
- 'Hamilton 14SF-23 CMM Issue 4' → `catalog_id = Hamilton 14SF-23`, `aircraft_type_id = NULL`
- 'Dowty R408 CMM Issue 7' → `catalog_id = Dowty R408` (autre SAAB avec Dowty)
- 'GE CT7-9B CMM' → `catalog_id = GE CT7-9B`

---

### 16.3 Bibliothèque unifiée de templates (`inspection_templates`)

Remplace `parts_catalog_inspection_templates`. Couvre les templates avion (MRB) ET composante (CMM) dans une seule table.

```sql
inspection_templates
────────────────────────────────────────────
template_id             SERIAL PRIMARY KEY
-- Scope — l'un ou l'autre (pas les deux)
aircraft_type_id        INT REFERENCES aircraft_types   -- nullable (template avion/MRB)
catalog_id              INT REFERENCES parts_catalog    -- nullable (template composante/CMM)

source_id               INT REFERENCES inspection_sources  -- nullable
description             TEXT NOT NULL
ata_chapter             TEXT
ref_number              TEXT         -- numéro de référence dans le document source
                                     -- ex: tâche MRB '05-10-01', CMM step '72-50-01'

-- Applicabilité (tous nullable — NULL = aucune restriction)
applicable_variant      TEXT         -- ex: 'B only', 'series 200' (texte libre)
applicable_msn_from     TEXT         -- plage MSN début (ex: '001')
applicable_msn_to       TEXT         -- plage MSN fin (ex: '150')
applicable_post_mod     TEXT         -- applicable uniquement si post-mod/SB (référence libre)
applicable_pre_mod      TEXT         -- applicable uniquement si pré-mod/SB (référence libre)
applicability_text      TEXT         -- texte brut complet pour les cas complexes

-- Niveau d'inspection (optionnel, texte libre, configurable par compagnie)
inspection_level        TEXT         -- nullable — ex: 'lvl 1', 'lvl 2', 'lvl 3', 'heavy'
                                     -- lvl 1 = line check rapide, lvl 2 = planification requise
                                     -- lvl 3 = support externe (NDT, etc.), heavy = avion immobilisé plusieurs semaines
                                     -- Filtre utile dans le forecast pour évaluer les ressources nécessaires

-- Référence documentaire
zone                    TEXT         -- nullable — zone physique sur l'avion (ex: '113', '451')
                                     -- tel que présenté dans le MPD/MRB (optionnel, pour référence)
document_section        TEXT         -- nullable — section du document source (texte libre)
                                     -- ex: 'System and Powerplant Program', 'Structural Program', 'Zonal Program'
                                     -- optionnel, spécifique au manufacturier, aucun impact sur la logique
ref_manual              TEXT         -- nullable — référence AMM ou autre manuel pour la procédure
                                     -- ex: 'AMM: 20-50-00-02'

-- Données de planification (optionnel, issues du MPD)
skill_code              TEXT         -- nullable — ex: 'EA' (Electrical/Avionics), 'AF' (Airframe), 'NDT'
                                     -- 'NDT' = inspection à sous-contracter (certification spécialisée requise)
mhrs_access             NUMERIC      -- nullable — man-hours pour l'ouverture des panneaux d'accès
mhrs_task               NUMERIC      -- nullable — man-hours pour la tâche elle-même

-- Airworthiness Limitation
is_airworthiness_limitation  BOOLEAN NOT NULL DEFAULT FALSE
                             -- AL (Airworthiness Limitation) au sens du RAC
                             -- Toutes les tâches d'un source ALM sont des AL
                             -- Un AL ne peut pas avoir d'extension ni de window
                             -- Ne peut pas être supprimé du programme de maintenance

-- Intervalles de type "check level" (ex: LC2 manufacturier)
interval_check_level    TEXT         -- nullable — ex: 'LC1', 'LC2'
                                     -- utilisé quand interval_unit = 'check'
                                     -- l'intervalle réel (FH) est défini dans operator_check_levels
                                     -- le template reste fidèle au MPD manufacturier

-- Gestion des révisions
version_added           TEXT         -- révision où cette tâche a été saisie pour la première fois
                                     -- ex: 'Rev 32' (premier batch = même valeur sur toutes les tâches)
version_last_evaluated  TEXT         -- dernière révision où cette tâche a été consciemment évaluée
                                     -- peut rester à 'Rev 32' si rien n'a changé depuis

is_active               BOOLEAN NOT NULL DEFAULT TRUE
notes                   TEXT
-- Limites via inspection_limits (template_id)
-- Changements via template_change_log (template_id)
```

**Comportement à l'installation d'une pièce (`part_event: install`):**
Le système recherche les templates actifs pour ce `catalog_id`, vérifie l'applicabilité, et génère les `inspections` + `inspection_limits` liés au `part_id`.

**Comportement à l'onboarding d'un avion:**
Le système propose tous les templates actifs pour ce `aircraft_type_id`. L'opérateur confirme ou exclut chaque template selon l'applicabilité (MSN, variant, mods). Les templates confirmés génèrent les `inspections` liées à l'`aircraft_id`.

**Programme de maintenance d'un avion = union de plusieurs calendriers:**
- Templates MRB → inspections airframe (via `aircraft_type_id`)
- Templates CMM hélice → actifs selon le modèle d'hélice installée (via `catalog_id`)
- Templates CMM moteur → actifs selon le modèle de moteur installé (via `catalog_id`)
- ADs → voir section 16.4

**Lien avec `inspections`:**
Le champ `master_template_id` (existant dans `inspections`) pointe vers `template_id`. Permet de détecter les écarts quand un template est mis à jour.

---

### 16.4 Facteurs d'applicabilité configurables (`applicability_factors`)

Système générique et configurable par type d'avion. Remplace les tables spécialisées MOD/SB pour l'applicabilité — certains manufacturiers utilisent des MODs + SBs (SAAB), d'autres uniquement des SBs (avion livré d'usine "POST-SB").

```sql
applicability_factors   -- facteurs configurables par aircraft_type
────────────────────────────────────────────
factor_id               SERIAL PRIMARY KEY
aircraft_type_id        INT NOT NULL REFERENCES aircraft_types
factor_type             TEXT NOT NULL   -- 'mod' | 'sb' | 'config' | 'pn_installed' | 'other'
factor_key              TEXT NOT NULL   -- clé unique lisible: 'MOD_1421' | 'SB_21-018' | 'smoking_config'
label                   TEXT NOT NULL   -- question à l'onboarding:
                                        -- "MOD 1421 (SB 21-018) incorporée?"
                                        -- "Aircraft flown SMOKING or NON-SMOKING?"
related_sb_id           INT REFERENCES sbs   -- nullable (si mod liée à un SB)
notes                   TEXT

aircraft_factor_answers  -- réponses par avion (onboarding + mises à jour)
────────────────────────────────────────────
answer_id               SERIAL PRIMARY KEY
aircraft_id             INT NOT NULL REFERENCES aircraft
factor_id               INT NOT NULL REFERENCES applicability_factors
answer                  TEXT NOT NULL   -- 'post' | 'pre' | 'yes' | 'no' | 'smoking' | 'non_smoking' | P/N value
incorporation_method    TEXT            -- nullable: 'factory' | 'sb' | 'other'
                                        -- 'factory' = avion livré avec cette config, SB jamais exécuté
incorporation_date      DATE            -- nullable
notes                   TEXT
UNIQUE (aircraft_id, factor_id)
```

**Exemples de facteurs SAAB 340B :**
- `factor_type='mod'`, `factor_key='MOD_1421'`, `related_sb_id=SB 21-018` → "MOD 1421 incorporée?"
- `factor_type='config'`, `factor_key='smoking_config'` → "SMOKING ou NON-SMOKING?"
- `factor_type='config'`, `factor_key='aircraft_config'` → "Passenger | Cargo/Freighter | Quick Change?"
- `factor_type='pn_installed'`, `factor_key='cockpit_filter_pn'` → "Quel P/N de filtre cockpit?"
- `factor_type='jurisdiction'`, `factor_key='regulatory_authority'` → "TC | FAA | EASA | other"
  ex: tâche 273508 "Non US operators" → applicable si jurisdiction ≠ FAA
  ex: différences RAC (Canada) vs FAA (USA) vs EASA dans les intervalles réglementaires

**Lien avec les templates :** `applicable_pre_mod` / `applicable_post_mod` dans `inspection_templates` référencent le `factor_key` (texte lisible, pas FK stricte). L'`applicability_text` capture les cas complexes pas encore structurés en facteurs.

**Cas avion livré POST-MOD d'usine :** `answer='post'`, `incorporation_method='factory'` — l'avion n'est pas POST-SB, mais il est bien POST-MOD.

---

### 16.5 Overrides opérateur (`operator_overrides`)

**Principe fondamental :** le template est toujours la référence manufacturier — intouchable. Le programme de maintenance de l'opérateur = template + overrides. Un override ne modifie jamais le template, il prend préséance dans le calcul du forecast.

**Trois usages :**
1. Intervalle opérateur différent du manufacturier (tightening ou extension)
2. Extension approuvée via programme de fiabilité (CI 605-002 / TC)
3. Tâche remplacée par une autre (choix de stratégie, ex: 243101 superseded by 243104)

```sql
operator_overrides
────────────────────────────────────────────
override_id             SERIAL PRIMARY KEY
template_id             INT NOT NULL REFERENCES inspection_templates
aircraft_id             INT REFERENCES aircraft        -- nullable (override pour un avion spécifique)
aircraft_type_id        INT REFERENCES aircraft_types  -- nullable (override pour tout le type)
-- au moins l'un des deux doit être non-NULL

override_type           TEXT NOT NULL
                        -- 'interval'   → change l'intervalle (tightening ou extension)
                        -- 'superseded' → cette tâche est remplacée par une autre
                        -- 'excluded'   → tâche exclue du programme (N/A opérateur)

-- Pour override_type = 'interval'
new_interval_value      NUMERIC
new_interval_unit       TEXT
justification           TEXT   -- ex: 'Vendor recommandation 12 mois', 'CI 605-002 approbation TC'

-- Pour override_type = 'superseded'
superseded_by_template_id INT REFERENCES inspection_templates
                        -- ex: template 243101 superseded by 243104 (choix opérateur)

-- Pour override_type = 'excluded'
exclusion_reason        TEXT

-- Traçabilité
approved_by             INT REFERENCES personnel
approved_date           DATE
reference_doc           TEXT             -- S3 (approbation TC, rapport fiabilité, etc.)
effective_from          DATE NOT NULL
effective_to            DATE             -- nullable (actif si NULL)
is_active               BOOLEAN NOT NULL DEFAULT TRUE
notes                   TEXT
```

**Calcul forecast :** le système vérifie d'abord si un override actif existe pour ce template + avion. Si oui → l'override s'applique. Sinon → le template manufacturier.

**Templates sans intervalle fixe (`interval_value IS NULL`) :** le système ne peut pas calculer de next_due. Ces templates sont automatiquement listés à l'onboarding comme "à compléter par l'opérateur" via `operator_overrides`. Pas de champ `requires_operator_override` — c'est dérivé de `interval_value IS NULL`. Le template reste une copie fidèle du manufacturier.

---

### 16.6 Airworthiness Directives

Les ADs ont besoin d'un traitement distinct des inspections normales car :
- Rapport de statut AD fréquemment demandé (TC, examinateurs)
- Sort order calqué sur le listing TC
- Suivi terminating vs recurring
- Suivi quantité installée (ex: 2 starter-gens → "1 of 2 installed")

#### `ads` — registre des ADs

```sql
ads
────────────────────────────────────────────
ad_id                   SERIAL PRIMARY KEY
ad_number               TEXT NOT NULL        -- ex: CF-2024-15, 2024-23-04, 2024-23-04 R1
issuing_authority       TEXT NOT NULL        -- 'TC' | 'FAA' | 'EASA' | 'other'
title                   TEXT NOT NULL
effective_date          DATE
compliance_type         TEXT NOT NULL        -- 'terminating' | 'recurring'
ad_category             TEXT NOT NULL        -- 'airframe' | 'propeller' | 'engine' | 'component'
                                             -- pour le groupement dans le rapport de statut AD

-- Scope (l'un ou l'autre ou les deux)
aircraft_type_id        INT REFERENCES aircraft_types   -- nullable
catalog_id              INT REFERENCES parts_catalog    -- nullable
-- aircraft_type_id seul  = AD airframe (tous les avions du type)
-- catalog_id seul        = AD composante (indépendant du type d'avion)
-- les deux               = AD composante spécifique à ce type d'avion

-- Applicabilité
applicable_variant      TEXT         -- nullable, texte libre
applicable_msn_from     TEXT         -- nullable
applicable_msn_to       TEXT         -- nullable
applicable_post_mod     TEXT         -- nullable (applicable si post-mod/SB référencé)
applicable_pre_mod      TEXT         -- nullable
applicability_text      TEXT         -- texte brut de l'applicabilité (toujours utile)

-- SB référencé (souvent: "comply with SB XXX")
referenced_sb_id        INT REFERENCES sbs   -- nullable

doc_ref                 TEXT         -- S3 (texte complet de l'AD)
notes                   TEXT
```

#### `aircraft_ads` — applicabilité et compliance par avion

```sql
aircraft_ads
────────────────────────────────────────────
aircraft_ad_id          SERIAL PRIMARY KEY
aircraft_id             INT NOT NULL REFERENCES aircraft
ad_id                   INT NOT NULL REFERENCES ads
sort_order              INT NOT NULL     -- ordre opérateur, calqué sur listing TC
                                         -- partagé entre tous les avions du même type

is_applicable           BOOLEAN NOT NULL DEFAULT TRUE
na_reason               TEXT             -- 'N/A by S/N' | 'N/A by P/N' | 'N/A by config' | etc.

-- Premier événement de compliance (optionnel — vieux ADs, opérateur précédent)
first_compliance_date   DATE             -- nullable
first_compliance_ref    TEXT             -- W.O., doc, enregistrements opérateur précédent
first_compliance_note   TEXT             -- ex: "C/W prior to effective date"

-- Recurring AD → lien vers l'inspection dans le forecast
inspection_id           INT REFERENCES inspections   -- nullable

-- Terminating AD → compliance directe
terminating_complied_date  DATE          -- nullable
terminating_complied_wo_id INT REFERENCES work_orders  -- nullable

UNIQUE (aircraft_id, ad_id)
notes                   TEXT
```

**Rapport de statut AD:**
- Ordonné par `sort_order` (correspondant au listing TC)
- Groupé par `ad_category` (airframe / propeller / engine / component)
- Pour chaque AD : applicable / N/A + raison, compliance status, next due (si recurring)
- **Composante non installée :** comparaison unités installées (`part_events`) vs `aircraft_configurations.units_per_aircraft` → affiche "1 of 2 installed — 1 unit not currently installed (removed W.O. XXX, YYYY-MM-DD)"
- **Historique de compliance préservé** même si la composante est actuellement déposée

---

### 16.5 Service Bulletins

Les SBs ne sont pas réglementaires. On ne suit pas tous les SBs — uniquement ceux qui ont un impact concret (programme de maintenance, procédures, applicabilité d'un AD).

**Types :**
- `modification` : changement physique (ex: nouveau GPS) → pre/post applicable
- `parts_update` : remplacement par un P/N différent → pre/post applicable (peut revenir en pre lors d'un échange de pièce)
- `procedure` : procédure maintenance ou pilote → pas de pre/post sur l'avion
- `other`

```sql
sbs  ← bibliothèque de SBs
────────────────────────────────────────────
sb_id                   SERIAL PRIMARY KEY
sb_number               TEXT NOT NULL        -- ex: '340-57-001', 'SB-14SF-23-001'
title                   TEXT NOT NULL
manufacturer            TEXT
aircraft_type_id        INT REFERENCES aircraft_types   -- nullable
catalog_id              INT REFERENCES parts_catalog    -- nullable
sb_type                 TEXT NOT NULL   -- 'modification' | 'parts_update' | 'procedure' | 'other'
doc_ref                 TEXT            -- S3
notes                   TEXT

aircraft_sbs  ← statut SB par avion
────────────────────────────────────────────
aircraft_sb_id          SERIAL PRIMARY KEY
aircraft_id             INT NOT NULL REFERENCES aircraft
sb_id                   INT NOT NULL REFERENCES sbs
status                  TEXT NOT NULL   -- 'pre' | 'post' | 'na' | 'unknown'
                                        -- les SBs de type 'procedure' n'utilisent pas pre/post
incorporated_date       DATE            -- nullable
incorporated_wo_id      INT REFERENCES work_orders   -- nullable
reference_doc           TEXT            -- nullable (S3)
notes                   TEXT
UNIQUE (aircraft_id, sb_id)
```

**Lien AD → SB :** `ads.referenced_sb_id` capture le cas fréquent "comply with SB XXX". Quand `aircraft_sbs.status = 'post'` pour ce SB → l'AD peut être marqué N/A (terminating complied via SB).

**Impact sur les inspections :** le statut SB d'un avion (pre/post) conditionne l'applicabilité des templates via `applicable_post_mod` / `applicable_pre_mod` dans `inspection_templates`.

---

### 16.6 Gestion des révisions de documents sources

Le suivi des révisions de documents est géré via le module `publications` de `mbhlCore` (voir section 17). `inspection_sources` pointe vers la publication parente — `publication_revision_log` remplace le besoin d'un `source_revision_log (n'existe pas — remplacé par publication_revision_log dans mbhlCore)` dédié.

#### `template_change_log` — historique des changements par tâche

Une ligne à chaque modification d'un template. Permet de retracer l'évolution d'une inspection spécifique.

```sql
template_change_log
────────────────────────────────────────────
change_log_id           SERIAL PRIMARY KEY
template_id             INT NOT NULL REFERENCES inspection_templates
source_version          TEXT NOT NULL    -- ex: 'Rev 39'
change_description      TEXT NOT NULL    -- ex: 'interval modified from 12000 FH to 8000 FH'
                                         --     'added at MRB Rev 39'
                                         --     'AMM reference updated to 20-50-00-03'
changed_by              INT REFERENCES personnel
changed_date            DATE NOT NULL DEFAULT CURRENT_DATE
```

**Workflow révision :**
1. Nouvelle révision disponible → créer une ligne `publication_revision_log` dans mbhlCore (version, date, résumé)
2. Tâches **ajoutées** → nouveau template avec `version_added = 'Rev 39'` + ligne change_log *"added at Rev 39"*
3. Tâches **modifiées** → mettre à jour le template + `version_last_evaluated = 'Rev 39'` + ligne change_log
4. Tâches **supprimées** → `is_active = FALSE` + `version_last_evaluated = 'Rev 39'` + ligne change_log
5. Tâches **inchangées** → aucune action requise (version_last_evaluated reste à sa valeur antérieure)

Les avions ayant un `inspections.master_template_id` pointant vers un template modifié sont automatiquement flagués pour révision.

---

### 16.7 Matériaux requis par template (`template_materials`)

Matériaux nécessaires pour exécuter une tâche d'inspection : pièces de remplacement, consommables (lubrifiant, séalant, filtres), outillage spécial, etc. Utile pour la planification (préparer les pièces avant d'ouvrir le W.O.) et le lien avec le volet magasin.

```sql
template_materials
────────────────────────────────────────────
material_id             SERIAL PRIMARY KEY
template_id             INT NOT NULL REFERENCES inspection_templates
catalog_id              INT REFERENCES parts_catalog   -- nullable (pièce connue au catalogue)
description             TEXT         -- nullable si catalog_id est renseigné, obligatoire sinon
                                     -- pour les consommables génériques ou matériaux non catalogués
quantity                NUMERIC NOT NULL DEFAULT 1
unit                    TEXT         -- nullable (hérite de parts_catalog.unit_of_measure si catalog_id renseigné)
notes                   TEXT
```

**Utilisation:** lors de la planification, le système peut générer automatiquement une liste de matériaux requis en agrégeant les `template_materials` de toutes les tâches d'un package ou W.O. préparé (`staged`). Lien direct avec l'inventaire du magasin pour vérifier la disponibilité avant de commencer les travaux.

---

## 18. Publications *(dans `mbhlCore`)*

Suivi de toutes les publications de référence utilisées par la compagnie (AMM, MPD, CMM, IPC, MEL, FCOM, etc.). Toutes les publications sont suivies ici — seules celles ayant un impact sur la maintenance planifiée ont des entrées dans `inspection_sources`.

```sql
publications
────────────────────────────────────────────
publication_id          SERIAL PRIMARY KEY
title                   TEXT NOT NULL        -- ex: 'SAAB 340B AMM', 'SAAB 340B MPD Rev 39',
                                             --     'Hamilton 14SF-23 CMM', 'Pascan MEL SAAB 340B'
pub_type                TEXT NOT NULL        -- 'amm' | 'mpd' | 'mrb' | 'cmm' | 'ipc' | 'mel'
                                             -- 'fcom' | 'alm' | 'other'
owner                   TEXT                 -- ex: 'SAAB', 'GE', 'Hamilton', 'TC', 'Pascan'
                                             -- pas nécessairement le manufacturier (ex: TC pour le MEL)
current_version         TEXT                 -- ex: 'Rev 39', 'Issue 4'
current_version_date    DATE
doc_ref                 TEXT                 -- S3 (version courante)
is_active               BOOLEAN NOT NULL DEFAULT TRUE
notes                   TEXT

publication_applicability  -- many-to-many: une publication peut s'appliquer à plusieurs types
────────────────────────────────────────────
applicability_id        SERIAL PRIMARY KEY
publication_id          INT NOT NULL REFERENCES publications
aircraft_type_id        INT REFERENCES aircraft_types    -- nullable
catalog_id              INT REFERENCES parts_catalog     -- nullable
-- au moins l'un des deux doit être non-NULL
-- ex: CMM d'une batterie applicable à deux modèles différents → deux lignes

publication_revision_log  -- historique des révisions évaluées
────────────────────────────────────────────
log_id                  SERIAL PRIMARY KEY
publication_id          INT NOT NULL REFERENCES publications
version                 TEXT NOT NULL        -- ex: 'Rev 39'
revision_date           DATE
summary                 TEXT                 -- ex: '25-60-01 AMM reference change'
doc_ref                 TEXT                 -- nullable — S3 (highlights de la révision)
evaluated_by            INT REFERENCES personnel
evaluated_date          DATE
notes                   TEXT
```

**Lien avec la maintenance planifiée :** quand une publication a un impact sur les templates d'inspection (MPD, CMM, AMM avec listes de tâches), une entrée `inspection_sources` est créée avec `publication_id` pointant vers cette publication. Le `publication_revision_log` sert alors de journal des révisions pour cette source — pas besoin d'un `source_revision_log (n'existe pas — remplacé par publication_revision_log dans mbhlCore)` séparé.

**Cas AMM de petit avion :** une AMM (pub_type='amm') peut avoir une entrée `inspection_sources` avec source_type='mrb' si elle contient les listes de tâches d'inspection (pas de MRB séparé).

---

## 19. Données de démonstration

### 19.1 Contexte fictif

- **Compagnie:** Nordex Air
- **Fabricant fictif:** Harfang Aviation (3 modèles)
- **Avions:**

| Modèle | Code ICAO | Inspiration | Catégorie |
|--------|-----------|-------------|-----------|
| Huard 208  | HB08 | Cessna Caravan | Monomoteur turbopropulseur |
| Harfang 340 | HF34 | SAAB 340 | Bimoteur régional |
| Busard 412  | BU12 | Bell 412 | Hélicoptère |

Noms d'oiseaux du Nord québécois — clairement fictifs, aucun risque de confusion avec
un vrai programme de maintenance.

### 19.2 État de la démo mbhlCore (déjà complété)

`mbhlCore::seed_demo_data(con)` est **entièrement fonctionnel** (Phase 6 mbhlCore ✅).
19 fonctions seed couvrant :
- Aircraft types : HB08 / HF34 / BU12 (codes internes)
- 9 appareils C-FLY1 à C-FLY9 (4 HF34 / 3 HB08 / 2 BU12, 1 inactif)
- Bases YUL / YHU / YVO, devises CAD/USD/EUR
- 9 membres du personnel (tous rôles couverts), 7 licences
- **874 pièces** dans `parts_catalog` (20 showcase + 854 dérivées, nomenclature anatomie d'oiseau)
- Groupes d'alternates : 1 groupe exemple (3 membres)
- 6 publications (AMM/IPC/MPD/FCOM/MEL)

### 19.3 Seed mbhlMaintenance (à faire)

À créer dans `inst/demo/` — fonctions seed basées sur les 874 pièces et 9 avions déjà en DB :

- `seed_demo_inspections(con)` — inspections avec limites variées (airtime, cycles, date)
- `seed_demo_inspection_completions(con)` — historique de completions (dates relatives)
- `seed_demo_work_orders(con)` — quelques W.O. à différents stades (open, closed, completed)
- `seed_demo_parts_instances(con)` — unités individuelles installées (moteurs, hélices)
- `seed_demo_part_events(con)` — journal TSN/TSO (installs, removes)

**Convention dates:** toutes relatives à `Sys.Date()` — la démo reste pertinente dans le temps.
**Idempotence:** chaque fonction vérifie si la table est déjà peuplée avant d'insérer (skip si oui).

### 19.4 Reset de la démo

```r
# À implémenter dans mbhlMaintenance
demo_reset_maintenance(con)   # efface + reseed les tables mbhlmaintenance seulement
                              # (ne touche pas aux tables mbhlcore)
```
