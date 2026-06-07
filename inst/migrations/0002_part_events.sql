CREATE TABLE IF NOT EXISTS mbhlmaintenance.part_events (
  event_id              SERIAL PRIMARY KEY,
  part_id               INT NOT NULL REFERENCES mbhlmaintenance.parts,
  event_type            TEXT NOT NULL
                        CHECK (event_type IN (
                          'receive', 'install', 'remove', 'overhaul',
                          'repair', 'scrap', 'send_to_shop', 'return_from_shop'
                        )),
  event_date            DATE NOT NULL,
  work_order_id         INT,
  installed_on_id       INT,
  installed_on_type     TEXT CHECK (installed_on_type IN ('aircraft', 'shop_wo')),
  unit_airtime_at_event NUMERIC,
  unit_cycles_at_event  INT,
  part_tsn_at_event     NUMERIC,
  part_csn_at_event     INT,
  part_tso_at_event     NUMERIC,
  part_cso_at_event     INT,
  part_ts_lsv_at_event  NUMERIC,
  part_cs_lsv_at_event  INT,
  part_hobbs_at_event   NUMERIC,
  installed_on_part_id  INT REFERENCES mbhlmaintenance.parts,
  position_id           INT REFERENCES mbhlcore.parts_catalog_positions,
  is_anchor             BOOLEAN NOT NULL DEFAULT FALSE,
  anchor_note           TEXT,
  notes                 TEXT,
  created_by            INT NOT NULL REFERENCES mbhlcore.personnel,
  created_at            TIMESTAMP NOT NULL DEFAULT NOW()
);
