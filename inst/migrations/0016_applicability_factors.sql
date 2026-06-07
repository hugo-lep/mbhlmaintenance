CREATE TABLE IF NOT EXISTS mbhlmaintenance.applicability_factors (
  factor_id        SERIAL PRIMARY KEY,
  aircraft_type_id INT NOT NULL REFERENCES mbhlcore.aircraft_types,
  factor_type      TEXT NOT NULL
                   CHECK (factor_type IN ('mod', 'sb', 'config', 'pn_installed', 'jurisdiction', 'other')),
  factor_key       TEXT NOT NULL,
  label            TEXT NOT NULL,
  related_sb_id    INT,
  notes            TEXT
);
