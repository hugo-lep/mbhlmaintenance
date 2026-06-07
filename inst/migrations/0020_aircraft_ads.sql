CREATE TABLE IF NOT EXISTS mbhlmaintenance.aircraft_ads (
  aircraft_ad_id             SERIAL PRIMARY KEY,
  aircraft_id                INT NOT NULL REFERENCES mbhlcore.aircraft,
  ad_id                      INT NOT NULL REFERENCES mbhlmaintenance.ads,
  sort_order                 INT NOT NULL,
  is_applicable              BOOLEAN NOT NULL DEFAULT TRUE,
  na_reason                  TEXT,
  first_compliance_date      DATE,
  first_compliance_ref       TEXT,
  first_compliance_note      TEXT,
  inspection_id              INT REFERENCES mbhlmaintenance.inspections,
  terminating_complied_date  DATE,
  terminating_complied_wo_id INT REFERENCES mbhlmaintenance.work_orders,
  notes                      TEXT,
  UNIQUE (aircraft_id, ad_id)
);
