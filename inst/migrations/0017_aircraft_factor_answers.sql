CREATE TABLE IF NOT EXISTS mbhlmaintenance.aircraft_factor_answers (
  answer_id            SERIAL PRIMARY KEY,
  aircraft_id          INT NOT NULL REFERENCES mbhlcore.aircraft,
  factor_id            INT NOT NULL REFERENCES mbhlmaintenance.applicability_factors,
  answer               TEXT NOT NULL,
  incorporation_method TEXT CHECK (incorporation_method IN ('factory', 'sb', 'other')),
  incorporation_date   DATE,
  notes                TEXT,
  UNIQUE (aircraft_id, factor_id)
);
