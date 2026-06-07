CREATE TABLE IF NOT EXISTS mbhlmaintenance.operator_overrides (
  override_id               SERIAL PRIMARY KEY,
  template_id               INT NOT NULL REFERENCES mbhlmaintenance.inspection_templates,
  aircraft_id               INT REFERENCES mbhlcore.aircraft,
  aircraft_type_id          INT REFERENCES mbhlcore.aircraft_types,
  override_type             TEXT NOT NULL
                            CHECK (override_type IN ('interval', 'superseded', 'excluded')),
  new_interval_value        NUMERIC,
  new_interval_unit         TEXT,
  justification             TEXT,
  superseded_by_template_id INT REFERENCES mbhlmaintenance.inspection_templates,
  exclusion_reason          TEXT,
  approved_by               INT REFERENCES mbhlcore.personnel,
  approved_date             DATE,
  reference_doc             TEXT,
  effective_from            DATE NOT NULL,
  effective_to              DATE,
  is_active                 BOOLEAN NOT NULL DEFAULT TRUE,
  notes                     TEXT,
  CONSTRAINT chk_override_scope
    CHECK (aircraft_id IS NOT NULL OR aircraft_type_id IS NOT NULL)
);
