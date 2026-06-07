CREATE TABLE IF NOT EXISTS mbhlmaintenance.parts (
  part_id          SERIAL PRIMARY KEY,
  catalog_id       INT NOT NULL REFERENCES mbhlcore.parts_catalog,
  serial_number    TEXT,
  internal_id      TEXT,
  manufacture_date DATE,
  internal_marking TEXT,
  origin_lot_id    INT,
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  notes            TEXT,
  UNIQUE (catalog_id, serial_number)
);
