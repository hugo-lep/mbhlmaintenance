CREATE TABLE IF NOT EXISTS mbhlmaintenance.package_items (
  item_id       SERIAL PRIMARY KEY,
  package_id    INT NOT NULL REFERENCES mbhlmaintenance.inspection_packages,
  inspection_id INT REFERENCES mbhlmaintenance.inspections,
  item_number   INT NOT NULL,
  description   TEXT NOT NULL,
  ata_chapter   TEXT,
  reference     TEXT,
  notes         TEXT
);
