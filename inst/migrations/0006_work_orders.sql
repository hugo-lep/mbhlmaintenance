CREATE TABLE IF NOT EXISTS mbhlmaintenance.work_orders (
  wo_id                SERIAL PRIMARY KEY,
  wo_number            TEXT NOT NULL,
  wo_type              TEXT NOT NULL CHECK (wo_type IN ('aircraft', 'shop', 'outsource')),
  status               TEXT NOT NULL
                       CHECK (status IN ('staged', 'open', 'closed', 'reviewed', 'completed')),
  aircraft_id          INT REFERENCES mbhlcore.aircraft,
  part_id              INT REFERENCES mbhlmaintenance.parts,
  confirmed_airtime    NUMERIC,
  confirmed_cycles     INT,
  confirmed_date       DATE,
  entry_date           DATE NOT NULL DEFAULT CURRENT_DATE,
  is_transcription     BOOLEAN NOT NULL DEFAULT FALSE,
  transcription_note   TEXT,
  airtime_confirmed_by INT REFERENCES mbhlcore.personnel,
  airtime_confirmed_at TIMESTAMP,
  staged_by            INT REFERENCES mbhlcore.personnel,
  staged_date          TIMESTAMP,
  opened_by            INT REFERENCES mbhlcore.personnel,
  opened_date          TIMESTAMP,
  closed_by            INT REFERENCES mbhlcore.personnel,
  closed_date          TIMESTAMP,
  reviewed_by          INT REFERENCES mbhlcore.personnel,
  reviewed_date        TIMESTAMP,
  completed_by         INT REFERENCES mbhlcore.personnel,
  completed_date       TIMESTAMP,
  notes                TEXT
);

-- FK rétroactives maintenant que work_orders existe
ALTER TABLE mbhlmaintenance.part_events
  ADD CONSTRAINT IF NOT EXISTS fk_part_events_wo
  FOREIGN KEY (work_order_id) REFERENCES mbhlmaintenance.work_orders;

ALTER TABLE mbhlmaintenance.inspection_completions
  ADD CONSTRAINT IF NOT EXISTS fk_inspection_completions_wo
  FOREIGN KEY (work_order_id) REFERENCES mbhlmaintenance.work_orders;
