CREATE TABLE IF NOT EXISTS mbhlmaintenance.inspections (
  inspection_id      SERIAL PRIMARY KEY,
  aircraft_id        INT REFERENCES mbhlcore.aircraft,
  part_id            INT REFERENCES mbhlmaintenance.parts,
  description        TEXT NOT NULL,
  ata_chapter        TEXT,
  is_active          BOOLEAN NOT NULL DEFAULT TRUE,
  master_template_id INT,
  notes              TEXT,
  CONSTRAINT chk_inspection_scope
    CHECK (aircraft_id IS NOT NULL OR part_id IS NOT NULL)
);
