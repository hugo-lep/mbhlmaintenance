CREATE TABLE IF NOT EXISTS mbhlmaintenance.template_materials (
  material_id SERIAL PRIMARY KEY,
  template_id INT NOT NULL REFERENCES mbhlmaintenance.inspection_templates,
  catalog_id  INT REFERENCES mbhlcore.parts_catalog,
  description TEXT,
  quantity    NUMERIC NOT NULL DEFAULT 1,
  unit        TEXT,
  notes       TEXT
);
