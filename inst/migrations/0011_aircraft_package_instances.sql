CREATE TABLE IF NOT EXISTS mbhlmaintenance.aircraft_package_instances (
  instance_id      SERIAL PRIMARY KEY,
  package_id       INT NOT NULL REFERENCES mbhlmaintenance.inspection_packages,
  aircraft_id      INT NOT NULL REFERENCES mbhlcore.aircraft,
  status           TEXT NOT NULL CHECK (status IN ('upcoming', 'in_progress', 'completed')),
  next_due_airtime NUMERIC,
  next_due_cycles  INT,
  next_due_date    DATE,
  started_airtime  NUMERIC,
  started_date     DATE,
  completed_wo_id  INT REFERENCES mbhlmaintenance.work_orders,
  notes            TEXT
);
