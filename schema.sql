-- =============================================================
--  PADDY SPACE HOTEL — Supabase PostgreSQL Schema
--  Version: 1.0.0
--  Description: Full schema for hotel reservations, rooms,
--               guests, dining, staff, housekeeping, and audit.
-- =============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";


-- =============================================================
-- 1. ENUMS
-- =============================================================

CREATE TYPE reservation_status AS ENUM (
  'pending', 'confirmed', 'checked_in', 'checked_out', 'cancelled', 'no_show'
);

CREATE TYPE room_status AS ENUM (
  'available', 'occupied', 'maintenance', 'reserved', 'housekeeping'
);

CREATE TYPE room_type AS ENUM (
  'deluxe', 'junior_suite', 'grand_suite', 'penthouse'
);

CREATE TYPE payment_status AS ENUM (
  'unpaid', 'partial', 'paid', 'refunded'
);

CREATE TYPE dining_status AS ENUM (
  'pending', 'confirmed', 'seated', 'completed', 'cancelled', 'no_show'
);

CREATE TYPE user_role AS ENUM (
  'admin', 'manager', 'front_desk', 'housekeeping', 'concierge', 'chef'
);

CREATE TYPE housekeeping_status AS ENUM (
  'pending', 'in_progress', 'completed', 'skipped'
);

CREATE TYPE maintenance_priority AS ENUM (
  'low', 'medium', 'high', 'urgent'
);


-- =============================================================
-- 2. STAFF (defined first — referenced by other tables)
-- =============================================================

-- Linked to Supabase auth.users for authentication
CREATE TABLE staff (
  id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  first_name    VARCHAR(80)  NOT NULL,
  last_name     VARCHAR(80)  NOT NULL,
  role          user_role    NOT NULL DEFAULT 'admin',
  phone         VARCHAR(30),
  department    VARCHAR(60),
  is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Convenience view — current logged-in staff member
CREATE VIEW current_staff AS
  SELECT s.* FROM staff s WHERE s.id = auth.uid();


-- =============================================================
-- 3. ROOMS
-- =============================================================

CREATE TABLE rooms (
  id            UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  room_number   VARCHAR(10)   NOT NULL UNIQUE,
  room_type     room_type     NOT NULL,
  floor         SMALLINT      NOT NULL,
  size_sqm      DECIMAL(6,2),
  view          VARCHAR(60),                  -- 'City View', 'Garden View', 'Panoramic'
  max_occupancy SMALLINT      NOT NULL DEFAULT 2,
  base_price    DECIMAL(12,2) NOT NULL,       -- NGN per night
  status        room_status   NOT NULL DEFAULT 'available',
  amenities     TEXT[],                       -- ['minibar','jacuzzi','butler']
  description   TEXT,
  image_urls    TEXT[],
  is_active     BOOLEAN       NOT NULL DEFAULT TRUE,
  notes         TEXT,
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- =============================================================
-- 4. GUESTS
-- =============================================================

CREATE TABLE guests (
  id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  first_name      VARCHAR(80)   NOT NULL,
  last_name       VARCHAR(80)   NOT NULL,
  email           VARCHAR(255)  NOT NULL UNIQUE,
  phone           VARCHAR(30),
  country         VARCHAR(80),
  city            VARCHAR(80),
  id_type         VARCHAR(30),                -- 'passport','national_id','drivers_license'
  id_number       VARCHAR(60),
  date_of_birth   DATE,
  preferences     JSONB         DEFAULT '{}', -- {"pillow":"soft","floor":"high","dietary":"vegan"}
  vip_level       SMALLINT      DEFAULT 0,    -- 0=standard 1=silver 2=gold 3=platinum
  total_stays     INTEGER       DEFAULT 0,
  total_spend     DECIMAL(14,2) DEFAULT 0,
  newsletter_opt  BOOLEAN       DEFAULT FALSE,
  notes           TEXT,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- =============================================================
-- 5. RESERVATIONS
-- =============================================================

CREATE SEQUENCE reservation_seq START 41 INCREMENT 1;

CREATE TABLE reservations (
  id               UUID               PRIMARY KEY DEFAULT uuid_generate_v4(),
  ref_code         VARCHAR(12)        NOT NULL UNIQUE,
  guest_id         UUID               NOT NULL REFERENCES guests(id) ON DELETE RESTRICT,
  room_id          UUID               NOT NULL REFERENCES rooms(id)  ON DELETE RESTRICT,
  check_in_date    DATE               NOT NULL,
  check_out_date   DATE               NOT NULL,
  nights           SMALLINT           GENERATED ALWAYS AS (check_out_date - check_in_date) STORED,
  adults           SMALLINT           NOT NULL DEFAULT 1,
  children         SMALLINT           NOT NULL DEFAULT 0,
  room_rate        DECIMAL(12,2)      NOT NULL,   -- rate locked at booking time
  extras_total     DECIMAL(12,2)      NOT NULL DEFAULT 0,
  total_amount     DECIMAL(14,2)      NOT NULL,
  deposit_amount   DECIMAL(14,2)      DEFAULT 0,
  payment_status   payment_status     NOT NULL DEFAULT 'unpaid',
  status           reservation_status NOT NULL DEFAULT 'pending',
  source           VARCHAR(40)        DEFAULT 'website',  -- 'website','phone','walk_in','ota'
  special_requests TEXT,
  arrival_time     TIME,
  actual_checkin   TIMESTAMPTZ,
  actual_checkout  TIMESTAMPTZ,
  confirmed_at     TIMESTAMPTZ,
  confirmed_by     UUID               REFERENCES staff(id) ON DELETE SET NULL,
  cancelled_at     TIMESTAMPTZ,
  cancel_reason    TEXT,
  created_at       TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ        NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_valid_dates CHECK (check_out_date > check_in_date),
  CONSTRAINT chk_total       CHECK (total_amount >= 0)
);

-- Auto-generate reservation reference codes (PS-0041, PS-0042 …)
CREATE OR REPLACE FUNCTION fn_generate_ref_code()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.ref_code IS NULL OR NEW.ref_code = '' THEN
    NEW.ref_code := 'PS-' || LPAD(nextval('reservation_seq')::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reservation_ref
  BEFORE INSERT ON reservations
  FOR EACH ROW EXECUTE FUNCTION fn_generate_ref_code();


-- =============================================================
-- 6. RESERVATION EXTRAS (add-ons, spa, transfers, etc.)
-- =============================================================

CREATE TABLE reservation_extras (
  id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  reservation_id  UUID          NOT NULL REFERENCES reservations(id) ON DELETE CASCADE,
  name            VARCHAR(120)  NOT NULL,
  description     TEXT,
  quantity        SMALLINT      DEFAULT 1,
  unit_price      DECIMAL(12,2) NOT NULL,
  total_price     DECIMAL(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
  service_date    DATE,
  notes           TEXT,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- =============================================================
-- 7. DINING
-- =============================================================

CREATE TABLE dining_areas (
  id            UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
  name          VARCHAR(80)  NOT NULL,
  description   TEXT,
  capacity      SMALLINT,
  opening_time  TIME,
  closing_time  TIME,
  is_active     BOOLEAN      DEFAULT TRUE,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE dining_tables (
  id            UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  area_id       UUID        NOT NULL REFERENCES dining_areas(id) ON DELETE CASCADE,
  table_number  VARCHAR(10) NOT NULL,
  seats         SMALLINT    NOT NULL,
  is_active     BOOLEAN     DEFAULT TRUE,
  notes         TEXT,
  UNIQUE(area_id, table_number)
);

CREATE TABLE dining_reservations (
  id               UUID           PRIMARY KEY DEFAULT uuid_generate_v4(),
  guest_id         UUID           REFERENCES guests(id) ON DELETE SET NULL,
  table_id         UUID           NOT NULL REFERENCES dining_tables(id) ON DELETE RESTRICT,
  hotel_res_id     UUID           REFERENCES reservations(id) ON DELETE SET NULL,
  guest_name       VARCHAR(160),  -- for non-registered / walk-in guests
  guest_phone      VARCHAR(30),
  covers           SMALLINT       NOT NULL DEFAULT 2,
  reservation_date DATE           NOT NULL,
  reservation_time TIME           NOT NULL,
  occasion         VARCHAR(80),   -- 'anniversary','birthday','business'
  dietary_notes    TEXT,
  status           dining_status  NOT NULL DEFAULT 'pending',
  confirmed_at     TIMESTAMPTZ,
  seated_at        TIMESTAMPTZ,
  completed_at     TIMESTAMPTZ,
  notes            TEXT,
  created_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE TABLE menu_items (
  id            UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  area_id       UUID          NOT NULL REFERENCES dining_areas(id) ON DELETE CASCADE,
  name          VARCHAR(120)  NOT NULL,
  description   TEXT,
  category      VARCHAR(60),  -- 'starter','main','dessert','cocktail'
  price         DECIMAL(10,2) NOT NULL,
  currency      CHAR(3)       DEFAULT 'NGN',
  is_available  BOOLEAN       DEFAULT TRUE,
  is_signature  BOOLEAN       DEFAULT FALSE,
  allergens     TEXT[],
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- =============================================================
-- 8. HOUSEKEEPING & MAINTENANCE
-- =============================================================

CREATE TABLE housekeeping_tasks (
  id            UUID                PRIMARY KEY DEFAULT uuid_generate_v4(),
  room_id       UUID                NOT NULL REFERENCES rooms(id)  ON DELETE CASCADE,
  task_date     DATE                NOT NULL DEFAULT CURRENT_DATE,
  task_type     VARCHAR(40)         DEFAULT 'turndown',  -- 'turndown','checkout_clean','deep_clean'
  assigned_to   UUID                REFERENCES staff(id) ON DELETE SET NULL,
  status        housekeeping_status NOT NULL DEFAULT 'pending',
  started_at    TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ,
  notes         TEXT,
  created_at    TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

CREATE TABLE maintenance_reports (
  id            UUID                 PRIMARY KEY DEFAULT uuid_generate_v4(),
  room_id       UUID                 NOT NULL REFERENCES rooms(id)  ON DELETE CASCADE,
  reported_by   UUID                 REFERENCES staff(id) ON DELETE SET NULL,
  title         VARCHAR(160)         NOT NULL,
  description   TEXT,
  priority      maintenance_priority NOT NULL DEFAULT 'medium',
  resolved      BOOLEAN              DEFAULT FALSE,
  resolved_at   TIMESTAMPTZ,
  resolved_by   UUID                 REFERENCES staff(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ          NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ          NOT NULL DEFAULT NOW()
);


-- =============================================================
-- 9. NEWSLETTER SUBSCRIBERS
-- =============================================================

CREATE TABLE newsletter_subscribers (
  id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
  email           VARCHAR(255) NOT NULL UNIQUE,
  first_name      VARCHAR(80),
  source          VARCHAR(40)  DEFAULT 'website',
  subscribed_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  unsubscribed_at TIMESTAMPTZ,
  is_active       BOOLEAN      DEFAULT TRUE
);


-- =============================================================
-- 10. AUDIT LOG
-- =============================================================

CREATE TABLE audit_log (
  id          UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
  actor_id    UUID         REFERENCES auth.users(id) ON DELETE SET NULL,
  action      VARCHAR(80)  NOT NULL,   -- e.g. 'reservation.confirmed', 'room.status_changed'
  table_name  VARCHAR(60),
  record_id   UUID,
  old_value   JSONB,
  new_value   JSONB,
  ip_address  INET,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);


-- =============================================================
-- 11. INDEXES
-- =============================================================

-- Reservations
CREATE INDEX idx_res_guest        ON reservations(guest_id);
CREATE INDEX idx_res_room         ON reservations(room_id);
CREATE INDEX idx_res_status       ON reservations(status);
CREATE INDEX idx_res_dates        ON reservations(check_in_date, check_out_date);
CREATE INDEX idx_res_ref          ON reservations(ref_code);

-- Availability helper: find reservations overlapping a date range
CREATE INDEX idx_res_overlap      ON reservations(room_id, check_in_date, check_out_date)
  WHERE status NOT IN ('cancelled', 'no_show');

-- Guests
CREATE INDEX idx_guest_email      ON guests(email);
CREATE INDEX idx_guest_name_trgm  ON guests
  USING gin ((first_name || ' ' || last_name) gin_trgm_ops);

-- Rooms
CREATE INDEX idx_room_status      ON rooms(status);
CREATE INDEX idx_room_type        ON rooms(room_type);

-- Dining
CREATE INDEX idx_dining_res_date  ON dining_reservations(reservation_date);
CREATE INDEX idx_dining_status    ON dining_reservations(status);

-- Audit
CREATE INDEX idx_audit_actor      ON audit_log(actor_id);
CREATE INDEX idx_audit_record     ON audit_log(table_name, record_id);
CREATE INDEX idx_audit_created    ON audit_log(created_at DESC);


-- =============================================================
-- 12. TRIGGERS — updated_at
-- =============================================================

CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_rooms_upd           BEFORE UPDATE ON rooms                FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_guests_upd          BEFORE UPDATE ON guests               FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_reservations_upd    BEFORE UPDATE ON reservations         FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_dining_res_upd      BEFORE UPDATE ON dining_reservations  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_menu_upd            BEFORE UPDATE ON menu_items           FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_maintenance_upd     BEFORE UPDATE ON maintenance_reports  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_staff_upd           BEFORE UPDATE ON staff                FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- =============================================================
-- 13. TRIGGER — update guest lifetime stats on checkout
-- =============================================================

CREATE OR REPLACE FUNCTION fn_update_guest_stats()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'checked_out' AND OLD.status <> 'checked_out' THEN
    UPDATE guests
    SET
      total_stays = total_stays + 1,
      total_spend = total_spend + NEW.total_amount,
      updated_at  = NOW()
    WHERE id = NEW.guest_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guest_stats
  AFTER UPDATE ON reservations
  FOR EACH ROW EXECUTE FUNCTION fn_update_guest_stats();


-- =============================================================
-- 14. TRIGGER — free room on checkout, block on check-in
-- =============================================================

CREATE OR REPLACE FUNCTION fn_sync_room_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'checked_in' AND OLD.status <> 'checked_in' THEN
    UPDATE rooms SET status = 'occupied', updated_at = NOW() WHERE id = NEW.room_id;
  ELSIF NEW.status = 'checked_out' AND OLD.status <> 'checked_out' THEN
    UPDATE rooms SET status = 'housekeeping', updated_at = NOW() WHERE id = NEW.room_id;
  ELSIF NEW.status = 'cancelled' AND OLD.status NOT IN ('cancelled','checked_out') THEN
    UPDATE rooms SET status = 'available', updated_at = NOW() WHERE id = NEW.room_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_room_status_sync
  AFTER UPDATE ON reservations
  FOR EACH ROW EXECUTE FUNCTION fn_sync_room_status();


-- =============================================================
-- 15. FUNCTION — check room availability for date range
-- =============================================================

CREATE OR REPLACE FUNCTION fn_room_available(
  p_room_id       UUID,
  p_check_in      DATE,
  p_check_out     DATE,
  p_exclude_res   UUID DEFAULT NULL  -- exclude a reservation (for edits)
)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM reservations
    WHERE room_id = p_room_id
      AND status NOT IN ('cancelled', 'no_show')
      AND id <> COALESCE(p_exclude_res, uuid_nil())
      AND check_in_date  < p_check_out
      AND check_out_date > p_check_in
  );
$$;

-- Usage:
-- SELECT fn_room_available('room-uuid', '2026-03-20', '2026-03-23');


-- =============================================================
-- 16. VIEW — current occupancy summary
-- =============================================================

CREATE VIEW v_occupancy_today AS
SELECT
  r.room_type,
  COUNT(*)                                              AS total_rooms,
  COUNT(*) FILTER (WHERE r.status = 'occupied')        AS occupied,
  COUNT(*) FILTER (WHERE r.status = 'available')       AS available,
  COUNT(*) FILTER (WHERE r.status = 'maintenance')     AS maintenance,
  ROUND(
    100.0 * COUNT(*) FILTER (WHERE r.status = 'occupied') / NULLIF(COUNT(*), 0), 1
  )                                                     AS occupancy_pct
FROM rooms r
WHERE r.is_active = TRUE
GROUP BY r.room_type;


-- =============================================================
-- 17. VIEW — today's arrivals and departures
-- =============================================================

CREATE VIEW v_arrivals_today AS
SELECT
  res.ref_code,
  g.first_name || ' ' || g.last_name  AS guest_name,
  g.phone,
  g.vip_level,
  ro.room_number,
  ro.room_type,
  res.check_in_date,
  res.check_out_date,
  res.arrival_time,
  res.special_requests,
  res.status
FROM reservations res
JOIN guests g  ON g.id  = res.guest_id
JOIN rooms  ro ON ro.id = res.room_id
WHERE res.check_in_date = CURRENT_DATE
  AND res.status IN ('confirmed', 'pending');

CREATE VIEW v_departures_today AS
SELECT
  res.ref_code,
  g.first_name || ' ' || g.last_name  AS guest_name,
  ro.room_number,
  ro.room_type,
  res.check_out_date,
  res.total_amount,
  res.payment_status,
  res.status
FROM reservations res
JOIN guests g  ON g.id  = res.guest_id
JOIN rooms  ro ON ro.id = res.room_id
WHERE res.check_out_date = CURRENT_DATE
  AND res.status = 'checked_in';


-- =============================================================
-- 18. VIEW — revenue summary (month to date)
-- =============================================================

CREATE VIEW v_revenue_mtd AS
SELECT
  DATE_TRUNC('month', CURRENT_DATE)             AS period_start,
  SUM(res.total_amount)                         AS total_revenue,
  SUM(res.room_rate * res.nights)               AS room_revenue,
  SUM(res.extras_total)                         AS extras_revenue,
  COUNT(*)                                      AS total_reservations,
  COUNT(*) FILTER (WHERE res.status = 'checked_out') AS completed_stays
FROM reservations res
WHERE DATE_TRUNC('month', res.check_in_date) = DATE_TRUNC('month', CURRENT_DATE)
  AND res.status NOT IN ('cancelled', 'no_show');


-- =============================================================
-- 19. ROW LEVEL SECURITY (RLS)
-- =============================================================

ALTER TABLE rooms                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE guests                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE reservations           ENABLE ROW LEVEL SECURITY;
ALTER TABLE reservation_extras     ENABLE ROW LEVEL SECURITY;
ALTER TABLE dining_areas           ENABLE ROW LEVEL SECURITY;
ALTER TABLE dining_tables          ENABLE ROW LEVEL SECURITY;
ALTER TABLE dining_reservations    ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_items             ENABLE ROW LEVEL SECURITY;
ALTER TABLE housekeeping_tasks     ENABLE ROW LEVEL SECURITY;
ALTER TABLE maintenance_reports    ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE newsletter_subscribers ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log              ENABLE ROW LEVEL SECURITY;

-- Helper functions for policies
CREATE OR REPLACE FUNCTION fn_is_admin()
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM staff WHERE id = auth.uid() AND is_active = TRUE AND role = 'admin'
  );
$$;

CREATE OR REPLACE FUNCTION fn_get_staff_role()
RETURNS user_role LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT role FROM staff WHERE id = auth.uid();
$$;

-- ROOMS: public read (active only), staff write
CREATE POLICY "rooms_public_read"   ON rooms FOR SELECT USING (is_active = TRUE);
CREATE POLICY "rooms_admin_write"   ON rooms FOR ALL    USING (fn_is_admin());

-- GUESTS: staff only
CREATE POLICY "guests_admin_all"    ON guests FOR ALL USING (fn_is_admin());

-- RESERVATIONS: staff full access
CREATE POLICY "res_admin_all"       ON reservations       FOR ALL USING (fn_is_admin());
CREATE POLICY "extras_admin_all"    ON reservation_extras FOR ALL USING (fn_is_admin());

-- DINING AREAS & MENU: public read
CREATE POLICY "dining_areas_public" ON dining_areas FOR SELECT USING (is_active = TRUE);
CREATE POLICY "menu_public_read"    ON menu_items   FOR SELECT USING (is_available = TRUE);

-- DINING RESERVATIONS: public insert, staff full access
CREATE POLICY "dining_res_public_insert" ON dining_reservations FOR INSERT WITH CHECK (TRUE);
CREATE POLICY "dining_res_admin_all"     ON dining_reservations FOR ALL    USING (fn_is_admin());

-- HOUSEKEEPING: housekeeping + managers
CREATE POLICY "hk_admin"    ON housekeeping_tasks  FOR ALL USING (fn_is_admin());
CREATE POLICY "maint_admin" ON maintenance_reports FOR ALL USING (fn_is_admin());

-- NEWSLETTER: public insert only
CREATE POLICY "newsletter_public_insert" ON newsletter_subscribers FOR INSERT WITH CHECK (TRUE);
CREATE POLICY "newsletter_admin_read"    ON newsletter_subscribers FOR SELECT USING (fn_is_admin());

-- AUDIT LOG: admin read only
CREATE POLICY "audit_admin_read" ON audit_log FOR SELECT USING (fn_is_admin());

-- STAFF: self read; admin manages all
CREATE POLICY "staff_self_read"  ON staff FOR SELECT USING (id = auth.uid());
CREATE POLICY "staff_admin_all"  ON staff FOR ALL    USING (fn_is_admin());


-- =============================================================
-- 20. RPC FUNCTIONS (SECURITY DEFINER)
-- =============================================================

-- ── Public-facing (for website) ───────────────────────────

CREATE OR REPLACE FUNCTION upsert_guest(
  p_first_name VARCHAR, p_last_name VARCHAR, p_email VARCHAR, p_phone VARCHAR DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  _guest_id UUID; _sanitized_email VARCHAR;
BEGIN
  _sanitized_email := LOWER(TRIM(p_email));
  SELECT id INTO _guest_id FROM guests WHERE LOWER(email) = _sanitized_email;
  
  IF _guest_id IS NULL THEN
    INSERT INTO guests (first_name, last_name, email, phone)
    VALUES (p_first_name, p_last_name, _sanitized_email, p_phone)
    RETURNING id INTO _guest_id;
  ELSE
    -- Force update of names; preserve phone if new one is null, otherwise update
    UPDATE guests SET first_name = p_first_name, last_name = p_last_name, 
      phone = COALESCE(p_phone, phone), updated_at = NOW() WHERE id = _guest_id;
  END IF;
  RETURN _guest_id;
END;
$$;

CREATE OR REPLACE FUNCTION create_reservation(
  p_first_name VARCHAR, p_last_name VARCHAR, p_email VARCHAR, p_phone VARCHAR,
  p_room_type room_type, p_check_in DATE, p_check_out DATE, p_special_requests TEXT
)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  _guest_id UUID; _room_id UUID; _room_number VARCHAR; _room_rate DECIMAL;
  _nights INT; _total DECIMAL; _new_res_id UUID; _ref_code VARCHAR;
BEGIN
  _guest_id := upsert_guest(p_first_name, p_last_name, p_email, p_phone);
  IF _guest_id IS NULL THEN RAISE EXCEPTION 'Failed to create or find guest.'; END IF;

  SELECT id, base_price, room_number INTO _room_id, _room_rate, _room_number
  FROM rooms WHERE room_type = p_room_type AND status = 'available' AND fn_room_available(id, p_check_in, p_check_out)
  LIMIT 1;
  IF _room_id IS NULL THEN RAISE EXCEPTION 'No available rooms of type % for the selected dates.', p_room_type; END IF;

  _nights := p_check_out - p_check_in;
  _total := _nights * _room_rate;

  INSERT INTO reservations (guest_id, room_id, check_in_date, check_out_date, room_rate, total_amount, special_requests, source)
  VALUES (_guest_id, _room_id, p_check_in, p_check_out, _room_rate, _total, p_special_requests, 'website')
  RETURNING id, ref_code INTO _new_res_id, _ref_code;

  INSERT INTO audit_log (action, table_name, record_id, new_value)
  VALUES ('reservation.created', 'reservations', _new_res_id, jsonb_build_object('ref', _ref_code, 'guest', p_email));

  RETURN json_build_object('success', TRUE, 'ref_code', _ref_code, 'total', _total, 'room_number', _room_number);
END;
$$;

CREATE OR REPLACE FUNCTION subscribe_newsletter(p_email VARCHAR)
RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  INSERT INTO newsletter_subscribers (email, is_active) VALUES (p_email, TRUE)
  ON CONFLICT (email) DO UPDATE SET is_active = TRUE, unsubscribed_at = NULL;
$$;

CREATE OR REPLACE FUNCTION create_dining_reservation(
  p_guest_name VARCHAR, p_guest_phone VARCHAR, p_covers INT, p_date DATE, p_time TIME, p_occasion VARCHAR
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE _table_id UUID;
BEGIN
  SELECT t.id INTO _table_id FROM dining_tables t
  WHERE t.seats >= p_covers AND t.is_active = TRUE AND NOT EXISTS (
    SELECT 1 FROM dining_reservations dr WHERE dr.table_id = t.id AND dr.reservation_date = p_date
    AND dr.reservation_time BETWEEN (p_time - interval '1 hour 59 minutes') AND (p_time + interval '1 hour 59 minutes')
    AND dr.status NOT IN ('cancelled', 'no_show', 'completed')
  ) LIMIT 1;
  IF _table_id IS NULL THEN _table_id := (SELECT id FROM dining_tables LIMIT 1); END IF;
  INSERT INTO dining_reservations (table_id, guest_name, guest_phone, covers, reservation_date, reservation_time, occasion, status)
  VALUES (_table_id, p_guest_name, p_guest_phone, p_covers, p_date, p_time, p_occasion, 'pending');
END;
$$;

-- ── Admin-only ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_dashboard_stats_admin()
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER STABLE AS $$
DECLARE
  _pending_count INT; _active_guests INT; _total_guests INT; _occupancy JSON; _revenue JSON;
BEGIN
  IF NOT fn_is_admin() THEN RAISE EXCEPTION 'Permission denied: must be an admin.'; END IF;
  SELECT COUNT(*) INTO _pending_count FROM reservations WHERE status = 'pending';
  SELECT COUNT(DISTINCT guest_id) INTO _active_guests FROM reservations WHERE status = 'checked_in';
  SELECT COUNT(*) INTO _total_guests FROM guests;
  SELECT json_agg(t) INTO _occupancy FROM v_occupancy_today t;
  SELECT to_json(t) INTO _revenue FROM v_revenue_mtd t LIMIT 1;
  RETURN json_build_object('pending_count',_pending_count, 'active_guests',_active_guests, 'total_guests',_total_guests, 'occupancy',COALESCE(_occupancy,'[]'::json), 'revenue',COALESCE(_revenue,'{}'::json));
END;
$$;

CREATE OR REPLACE FUNCTION get_revenue_trend_admin()
RETURNS TABLE(month TEXT, total_revenue NUMERIC) LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT to_char(date_trunc('month', d.month), 'Month YYYY'), COALESCE(SUM(r.total_amount), 0)
  FROM generate_series(date_trunc('month', NOW() - interval '6 months'), date_trunc('month', NOW()), '1 month') as d(month)
  LEFT JOIN reservations r ON date_trunc('month', r.check_in_date) = d.month AND r.status NOT IN ('cancelled', 'no_show')
  WHERE fn_is_admin() GROUP BY d.month ORDER BY d.month;
$$;

CREATE OR REPLACE FUNCTION get_reservations_admin()
RETURNS TABLE (
  id UUID, ref_code VARCHAR, status reservation_status, check_in_date DATE, check_out_date DATE, nights SMALLINT, total_amount DECIMAL, payment_status payment_status, special_requests TEXT, arrival_time TIME, created_at TIMESTAMPTZ,
  guest_id UUID, guest_first VARCHAR, guest_last VARCHAR, guest_email VARCHAR, guest_phone VARCHAR, guest_vip SMALLINT, room_number VARCHAR, room_type room_type
) LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT r.id, r.ref_code, r.status, r.check_in_date, r.check_out_date, r.nights, r.total_amount, r.payment_status, r.special_requests, r.arrival_time, r.created_at,
    g.id, g.first_name, g.last_name, g.email, g.phone, g.vip_level, ro.room_number, ro.room_type
  FROM reservations r JOIN guests g ON r.guest_id = g.id JOIN rooms ro ON r.room_id = ro.id
  WHERE fn_is_admin() ORDER BY r.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION update_reservation_status_admin(p_id UUID, p_status reservation_status)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT fn_is_admin() THEN RETURN FALSE; END IF;
  UPDATE reservations SET status = p_status, updated_at = NOW() WHERE id = p_id;
  INSERT INTO audit_log (actor_id, action, table_name, record_id, new_value) VALUES (auth.uid(), 'reservation.status_changed', 'reservations', p_id, jsonb_build_object('status', p_status));
  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION get_rooms_admin()
RETURNS TABLE (id UUID, room_number VARCHAR, room_type room_type, status room_status, notes TEXT, current_guest TEXT)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT r.id, r.room_number, r.room_type, r.status, r.notes, (SELECT g.first_name || ' ' || g.last_name FROM reservations res JOIN guests g ON res.guest_id = g.id WHERE res.room_id = r.id AND res.status = 'checked_in' LIMIT 1)
  FROM rooms r WHERE fn_is_admin() ORDER BY r.room_number;
$$;

CREATE OR REPLACE FUNCTION update_room_status_admin(p_id UUID, p_status room_status, p_notes TEXT DEFAULT NULL)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN IF NOT fn_is_admin() THEN RETURN FALSE; END IF; UPDATE rooms SET status = p_status, notes = p_notes, updated_at = NOW() WHERE id = p_id; RETURN TRUE; END;
$$;

CREATE OR REPLACE FUNCTION get_guests_admin() RETURNS SETOF guests LANGUAGE sql SECURITY DEFINER STABLE AS $$ SELECT * FROM guests WHERE fn_is_admin() ORDER BY last_name, first_name; $$;

CREATE OR REPLACE FUNCTION get_guest_detail_admin(p_guest_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER STABLE AS $$
DECLARE _guest JSON; _history JSON;
BEGIN
  IF NOT fn_is_admin() THEN RAISE EXCEPTION 'Permission denied'; END IF;
  SELECT to_json(g) INTO _guest FROM guests g WHERE id = p_guest_id;
  SELECT json_agg(h) INTO _history FROM (SELECT r.ref_code, r.check_in_date, r.total_amount, r.status, ro.room_number FROM reservations r JOIN rooms ro ON r.room_id = ro.id WHERE r.guest_id = p_guest_id ORDER BY r.check_in_date DESC) h;
  RETURN json_build_object('guest', _guest, 'history', COALESCE(_history, '[]'::json));
END;
$$;

CREATE OR REPLACE FUNCTION update_guest_notes_admin(p_guest_id UUID, p_notes TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN IF NOT fn_is_admin() THEN RETURN FALSE; END IF; UPDATE guests SET notes = p_notes, updated_at = NOW() WHERE id = p_guest_id; RETURN TRUE; END;
$$;

CREATE OR REPLACE FUNCTION get_dining_reservations_admin()
RETURNS TABLE (id UUID, status dining_status, guest_name VARCHAR, guest_phone VARCHAR, covers SMALLINT, reservation_date DATE, reservation_time TIME, occasion VARCHAR, confirmed_at TIMESTAMPTZ, seated_at TIMESTAMPTZ, table_number VARCHAR, area_name VARCHAR)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT dr.id, dr.status, dr.guest_name, dr.guest_phone, dr.covers, dr.reservation_date, dr.reservation_time, dr.occasion, dr.confirmed_at, dr.seated_at, dt.table_number, da.name
  FROM dining_reservations dr JOIN dining_tables dt ON dr.table_id = dt.id JOIN dining_areas da ON dt.area_id = da.id
  WHERE fn_is_admin() AND dr.reservation_date >= CURRENT_DATE - interval '1 day' ORDER BY dr.reservation_date, dr.reservation_time;
$$;

CREATE OR REPLACE FUNCTION update_dining_status_admin(p_id UUID, p_status dining_status)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN IF NOT fn_is_admin() THEN RETURN FALSE; END IF; UPDATE dining_reservations SET status = p_status, updated_at = NOW() WHERE id = p_id; RETURN TRUE; END;
$$;

CREATE OR REPLACE FUNCTION get_audit_log_admin(p_limit INT DEFAULT 12) RETURNS SETOF audit_log LANGUAGE sql SECURITY DEFINER STABLE AS $$ SELECT * FROM audit_log WHERE fn_is_admin() ORDER BY created_at DESC LIMIT p_limit; $$;
CREATE OR REPLACE FUNCTION get_arrivals_today_admin() RETURNS SETOF v_arrivals_today LANGUAGE sql SECURITY DEFINER STABLE AS $$ SELECT * FROM v_arrivals_today WHERE fn_is_admin(); $$;
CREATE OR REPLACE FUNCTION get_departures_today_admin() RETURNS SETOF v_departures_today LANGUAGE sql SECURITY DEFINER STABLE AS $$ SELECT * FROM v_departures_today WHERE fn_is_admin(); $$;

-- =============================================================
-- 21. SEED DATA
-- =============================================================

-- Dining Areas
INSERT INTO dining_areas (name, description, capacity, opening_time, closing_time) VALUES
  ('La Salle Dorée',    'Two-Michelin-star West African fine dining',          60, '18:00', '23:00'),
  ('Rooftop Bar',       'Infinity pool bar with panoramic Lagos skyline',      80, '11:00', '02:00'),
  ('The Library Café',  'All-day café & light bites in our private library',   24, '07:00', '22:00');

-- Rooms
INSERT INTO rooms (room_number, room_type, floor, size_sqm, view, max_occupancy, base_price, amenities) VALUES
  ('101', 'deluxe',        1, 38,  'City View',      2, 85000,  ARRAY['king bed','marble bath','minibar','safe','smart TV']),
  ('102', 'deluxe',        1, 38,  'City View',      2, 85000,  ARRAY['king bed','marble bath','minibar','safe','smart TV']),
  ('103', 'deluxe',        1, 38,  'Garden View',    2, 85000,  ARRAY['king bed','marble bath','minibar','safe','smart TV']),
  ('104', 'deluxe',        1, 38,  'Garden View',    2, 85000,  ARRAY['king bed','marble bath','minibar','safe','smart TV']),
  ('201', 'junior_suite',  2, 62,  'Garden View',    3, 145000, ARRAY['king bed','sitting area','marble bath','minibar','butler call']),
  ('202', 'junior_suite',  2, 62,  'City View',      3, 145000, ARRAY['king bed','sitting area','marble bath','minibar','butler call']),
  ('203', 'deluxe',        2, 38,  'City View',      2, 85000,  ARRAY['king bed','marble bath','minibar','safe','smart TV']),
  ('312', 'deluxe',        3, 38,  'City View',      2, 85000,  ARRAY['king bed','marble bath','minibar','safe','smart TV']),
  ('401', 'grand_suite',   4, 115, 'Panoramic',      4, 320000, ARRAY['king bed','plunge pool','private terrace','butler','jacuzzi','private bar']),
  ('402', 'grand_suite',   4, 115, 'Panoramic',      4, 320000, ARRAY['king bed','plunge pool','private terrace','butler','jacuzzi','private bar']),
  ('501', 'penthouse',     5, 280, 'Full Panoramic',  6, 550000, ARRAY['master bedroom','2nd bedroom','private pool','chef service','personal butler','wine cellar']),
  ('502', 'penthouse',     5, 280, 'Full Panoramic',  6, 550000, ARRAY['master bedroom','2nd bedroom','private pool','chef service','personal butler','wine cellar']);

-- Room 312 is under maintenance
UPDATE rooms SET status = 'maintenance' WHERE room_number = '312';

-- Menu items (La Salle Dorée)
INSERT INTO menu_items (area_id, name, description, category, price, is_signature, allergens) VALUES
  ((SELECT id FROM dining_areas WHERE name = 'La Salle Dorée'),
   'Suya-cured Wagyu',       'A5 wagyu with house suya spice, zobo jus',                      'main',    38000, TRUE,  ARRAY['gluten','soy']),
  ((SELECT id FROM dining_areas WHERE name = 'La Salle Dorée'),
   'Ofada Risotto, Truffle', 'Ofada rice slow-cooked risotto-style, black truffle, parmesan', 'main',    24000, TRUE,  ARRAY['dairy','gluten']),
  ((SELECT id FROM dining_areas WHERE name = 'La Salle Dorée'),
   'Aged Jollof Consommé',   'Clarified smoked tomato & bell pepper broth, aged 72 hours',    'starter', 18000, FALSE, ARRAY[]::TEXT[]),
  ((SELECT id FROM dining_areas WHERE name = 'La Salle Dorée'),
   'Bitterleaf Soufflé',     'Warm bitterleaf & dark chocolate soufflé, palm wine crème',     'dessert', 14000, TRUE,  ARRAY['dairy','eggs','gluten']),
  ((SELECT id FROM dining_areas WHERE name = 'La Salle Dorée'),
   'Isi Ewu Tartare',        'Deconstructed goat head, utazi foam, crunchy agbalumo',         'starter', 16000, FALSE, ARRAY[]::TEXT[]);

-- Dining tables (La Salle Dorée)
INSERT INTO dining_tables (area_id, table_number, seats) VALUES
  ((SELECT id FROM dining_areas WHERE name = 'La Salle Dorée'), 'T01', 2),
  ((SELECT id FROM dining_areas WHERE name = 'La Salle Dorée'), 'T02', 4),
  ((SELECT id FROM dining_areas WHERE name = 'La Salle Dorée'), 'T03', 2),
  ((SELECT id FROM dining_areas WHERE name = 'La Salle Dorée'), 'T04', 6),
  ((SELECT id FROM dining_areas WHERE name = 'La Salle Dorée'), 'T05', 8),
  ((SELECT id FROM dining_areas WHERE name = 'La Salle Dorée'), 'T06', 4);


-- =============================================================
-- END OF SCHEMA — Paddy Space Hotel v1.0
-- =============================================================
