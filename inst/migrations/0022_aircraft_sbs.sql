CREATE TABLE IF NOT EXISTS mbhlmaintenance.aircraft_sbs (
  aircraft_sb_id     SERIAL PRIMARY KEY,
  aircraft_id        INT NOT NULL REFERENCES mbhlcore.aircraft,
  sb_id              INT NOT NULL REFERENCES mbhlmaintenance.sbs,
  status             TEXT NOT NULL CHECK (status IN ('pre', 'post', 'na', 'unknown')),
  incorporated_date  DATE,
  incorporated_wo_id INT REFERENCES mbhlmaintenance.work_orders,
  reference_doc      TEXT,
  notes              TEXT,
  UNIQUE (aircraft_id, sb_id)
);
