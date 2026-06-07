CREATE TABLE IF NOT EXISTS mbhlmaintenance.inspection_packages (
  package_id       SERIAL PRIMARY KEY,
  aircraft_id      INT REFERENCES mbhlcore.aircraft,
  aircraft_type_id INT REFERENCES mbhlcore.aircraft_types,
  name             TEXT NOT NULL,
  inspection_level TEXT,
  reference_doc    TEXT,
  use_checklist    BOOLEAN NOT NULL DEFAULT FALSE,
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  notes            TEXT
);
