CREATE TABLE IF NOT EXISTS mbhlmaintenance.inspection_sources (
  source_id        SERIAL PRIMARY KEY,
  publication_id   INT REFERENCES mbhlcore.publications,
  source_type      TEXT NOT NULL CHECK (source_type IN ('mrb', 'cmm', 'alm', 'company', 'other')),
  source_name      TEXT NOT NULL,
  manufacturer     TEXT,
  aircraft_type_id INT REFERENCES mbhlcore.aircraft_types,
  catalog_id       INT REFERENCES mbhlcore.parts_catalog,
  document_version TEXT,
  effective_date   DATE,
  doc_ref          TEXT,
  notes            TEXT
);
