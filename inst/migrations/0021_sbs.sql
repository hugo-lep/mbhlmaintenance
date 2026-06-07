CREATE TABLE IF NOT EXISTS mbhlmaintenance.sbs (
  sb_id            SERIAL PRIMARY KEY,
  sb_number        TEXT NOT NULL,
  title            TEXT NOT NULL,
  manufacturer     TEXT,
  aircraft_type_id INT REFERENCES mbhlcore.aircraft_types,
  catalog_id       INT REFERENCES mbhlcore.parts_catalog,
  sb_type          TEXT NOT NULL
                   CHECK (sb_type IN ('modification', 'parts_update', 'procedure', 'other')),
  doc_ref          TEXT,
  notes            TEXT
);

-- FK rétroactives maintenant que sbs existe
ALTER TABLE mbhlmaintenance.applicability_factors
  ADD CONSTRAINT IF NOT EXISTS fk_applicability_factors_sb
  FOREIGN KEY (related_sb_id) REFERENCES mbhlmaintenance.sbs;

ALTER TABLE mbhlmaintenance.ads
  ADD CONSTRAINT IF NOT EXISTS fk_ads_sb
  FOREIGN KEY (referenced_sb_id) REFERENCES mbhlmaintenance.sbs;
