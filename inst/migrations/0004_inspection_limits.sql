CREATE TABLE IF NOT EXISTS mbhlmaintenance.inspection_limits (
  limit_id                        SERIAL PRIMARY KEY,
  inspection_id                   INT NOT NULL REFERENCES mbhlmaintenance.inspections,
  limit_type                      TEXT NOT NULL
                                  CHECK (limit_type IN ('airtime', 'cycles', 'date', 'hobbs')),
  interval_value                  NUMERIC NOT NULL,
  interval_unit                   TEXT NOT NULL
                                  CHECK (interval_unit IN ('hours', 'months', 'days', 'cycles')),
  window_plus                     NUMERIC,
  window_minus                    NUMERIC,
  round_to_end_of_month           BOOLEAN NOT NULL DEFAULT FALSE,
  applies_before_first_completion BOOLEAN NOT NULL DEFAULT FALSE,
  date_baseline                   TEXT NOT NULL DEFAULT 'completion'
                                  CHECK (date_baseline IN (
                                    'completion', 'certification', 'install', 'manufacture'
                                  ))
);
