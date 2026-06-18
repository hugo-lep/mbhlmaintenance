-- Airtime et cycles courants par appareil.
-- Source de vérité temporaire jusqu'à l'intégration de logpage.
-- Mis à jour manuellement ou via l'interface MBHL.
CREATE TABLE IF NOT EXISTS mbhlmaintenance.aircraft_airtime (
    aircraft_id     INT NOT NULL PRIMARY KEY REFERENCES mbhlcore.aircraft,
    current_airtime NUMERIC NOT NULL,
    current_cycles  INT,
    confirmed_date  DATE NOT NULL,
    confirmed_by    INT REFERENCES mbhlcore.personnel,
    updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);
