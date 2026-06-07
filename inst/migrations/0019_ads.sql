CREATE TABLE IF NOT EXISTS mbhlmaintenance.ads (
  ad_id               SERIAL PRIMARY KEY,
  ad_number           TEXT NOT NULL,
  issuing_authority   TEXT NOT NULL CHECK (issuing_authority IN ('TC', 'FAA', 'EASA', 'other')),
  title               TEXT NOT NULL,
  effective_date      DATE,
  compliance_type     TEXT NOT NULL CHECK (compliance_type IN ('terminating', 'recurring')),
  ad_category         TEXT NOT NULL
                      CHECK (ad_category IN ('airframe', 'propeller', 'engine', 'component')),
  aircraft_type_id    INT REFERENCES mbhlcore.aircraft_types,
  catalog_id          INT REFERENCES mbhlcore.parts_catalog,
  applicable_variant  TEXT,
  applicable_msn_from TEXT,
  applicable_msn_to   TEXT,
  applicable_post_mod TEXT,
  applicable_pre_mod  TEXT,
  applicability_text  TEXT,
  referenced_sb_id    INT,
  doc_ref             TEXT,
  notes               TEXT
);
