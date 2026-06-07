CREATE TABLE IF NOT EXISTS mbhlmaintenance.inspection_extensions (
  extension_id         SERIAL PRIMARY KEY,
  inspection_id        INT NOT NULL REFERENCES mbhlmaintenance.inspections,
  original_due_airtime NUMERIC,
  original_due_cycles  INT,
  original_due_date    DATE,
  extended_to_airtime  NUMERIC,
  extended_to_cycles   INT,
  extended_to_date     DATE,
  justification        TEXT NOT NULL,
  approved_by          INT NOT NULL REFERENCES mbhlcore.personnel,
  approved_date        DATE NOT NULL,
  reference_doc        TEXT,
  is_active            BOOLEAN NOT NULL DEFAULT TRUE,
  notes                TEXT
);
