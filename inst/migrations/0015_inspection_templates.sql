CREATE TABLE IF NOT EXISTS mbhlmaintenance.inspection_templates (
  template_id                 SERIAL PRIMARY KEY,
  aircraft_type_id            INT REFERENCES mbhlcore.aircraft_types,
  catalog_id                  INT REFERENCES mbhlcore.parts_catalog,
  source_id                   INT REFERENCES mbhlmaintenance.inspection_sources,
  description                 TEXT NOT NULL,
  ata_chapter                 TEXT,
  ref_number                  TEXT,
  applicable_variant          TEXT,
  applicable_msn_from         TEXT,
  applicable_msn_to           TEXT,
  applicable_post_mod         TEXT,
  applicable_pre_mod          TEXT,
  applicability_text          TEXT,
  inspection_level            TEXT,
  zone                        TEXT,
  document_section            TEXT,
  ref_manual                  TEXT,
  skill_code                  TEXT,
  mhrs_access                 NUMERIC,
  mhrs_task                   NUMERIC,
  is_airworthiness_limitation BOOLEAN NOT NULL DEFAULT FALSE,
  interval_check_level        TEXT,
  version_added               TEXT,
  version_last_evaluated      TEXT,
  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  notes                       TEXT,
  CONSTRAINT chk_template_scope
    CHECK (aircraft_type_id IS NOT NULL OR catalog_id IS NOT NULL)
);

-- FK rétroactive maintenant que inspection_templates existe
ALTER TABLE mbhlmaintenance.inspections
  ADD CONSTRAINT IF NOT EXISTS fk_inspections_template
  FOREIGN KEY (master_template_id) REFERENCES mbhlmaintenance.inspection_templates;
