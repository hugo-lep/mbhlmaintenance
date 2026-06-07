CREATE TABLE IF NOT EXISTS mbhlmaintenance.template_change_log (
  change_log_id      SERIAL PRIMARY KEY,
  template_id        INT NOT NULL REFERENCES mbhlmaintenance.inspection_templates,
  source_version     TEXT NOT NULL,
  change_description TEXT NOT NULL,
  changed_by         INT REFERENCES mbhlcore.personnel,
  changed_date       DATE NOT NULL DEFAULT CURRENT_DATE
);
