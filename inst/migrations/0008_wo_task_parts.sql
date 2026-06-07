CREATE TABLE IF NOT EXISTS mbhlmaintenance.wo_task_parts (
  wo_task_part_id   SERIAL PRIMARY KEY,
  task_id           INT NOT NULL REFERENCES mbhlmaintenance.wo_tasks,
  action            TEXT NOT NULL CHECK (action IN ('install', 'remove')),
  part_id           INT REFERENCES mbhlmaintenance.parts,
  lot_id            INT,
  quantity          INT NOT NULL DEFAULT 1,
  position_id       INT REFERENCES mbhlcore.parts_catalog_positions,
  part_status       TEXT NOT NULL
                    CHECK (part_status IN (
                      'new', 'oh', 'repair', 'modified', 'inspected_tested', 'serviceable',
                      'unserviceable', 'damaged', 'scheduled_removal', 'standby', 'scrap'
                    )),
  serviceable_until TIMESTAMP,
  notes             TEXT
);
