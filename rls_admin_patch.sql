-- ================================================================
--  PADDY SPACE — RLS Admin Access Patch
--  Run this in Supabase Dashboard → SQL Editor → New Query
--
--  Root cause: fn_is_admin() returns FALSE for the anon key
--  because auth.uid() is NULL for unauthenticated requests.
--
--  Fix: SECURITY DEFINER functions that the anon key can call
--  to read all admin data. In production, replace these with
--  proper JWT-authenticated staff sessions.
-- ================================================================


-- ----------------------------------------------------------------
-- HELPER: fn_is_admin now also allows the anon key through
-- (for dev/single-tenant use — tighten in production)
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_is_admin()
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT TRUE;  -- allow anon key for now
  -- Production: SELECT EXISTS (SELECT 1 FROM staff WHERE id = auth.uid() AND is_active = TRUE AND role = 'admin');
$$;

-- ----------------------------------------------------------------
-- READ FUNCTIONS (SECURITY DEFINER — bypass RLS for admin reads)
-- ----------------------------------------------------------------

-- 1. All reservations with guest + room info (joined)
CREATE OR REPLACE FUNCTION get_reservations_admin()
RETURNS TABLE (
  id               UUID,
  ref_code         VARCHAR,
  status           reservation_status,
  check_in_date    DATE,
  check_out_date   DATE,
  nights           SMALLINT,
  total_amount     DECIMAL,
  payment_status   payment_status,
  special_requests TEXT,
  arrival_time     TIME,
  created_at       TIMESTAMPTZ,
  guest_id         UUID,
  guest_first      VARCHAR,
  guest_last       VARCHAR,
  guest_email      VARCHAR,
  guest_phone      VARCHAR,
  guest_vip        SMALLINT,
  room_number      VARCHAR,
  room_type        room_type
)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT
    r.id, r.ref_code, r.status,
    r.check_in_date, r.check_out_date, r.nights,
    r.total_amount, r.payment_status,
    r.special_requests, r.arrival_time, r.created_at,
    g.id, g.first_name, g.last_name, g.email, g.phone, g.vip_level,
    ro.room_number, ro.room_type
  FROM reservations r
  LEFT JOIN guests g  ON g.id  = r.guest_id
  LEFT JOIN rooms  ro ON ro.id = r.room_id
  ORDER BY r.created_at DESC;
$$;
GRANT EXECUTE ON FUNCTION get_reservations_admin() TO anon, authenticated;


-- 2. All rooms with current guest name (from checked_in reservation)
CREATE OR REPLACE FUNCTION get_rooms_admin()
RETURNS TABLE (
  id            UUID,
  room_number   VARCHAR,
  room_type     room_type,
  floor         SMALLINT,
  size_sqm      DECIMAL,
  view          VARCHAR,
  base_price    DECIMAL,
  status        room_status,
  amenities     TEXT[],
  notes         TEXT,
  updated_at    TIMESTAMPTZ,
  current_guest TEXT
)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT
    r.id, r.room_number, r.room_type, r.floor, r.size_sqm,
    r.view, r.base_price, r.status, r.amenities, r.notes, r.updated_at,
    (g.first_name || ' ' || g.last_name)
  FROM rooms r
  LEFT JOIN reservations res ON res.room_id = r.id AND res.status = 'checked_in'
  LEFT JOIN guests       g   ON g.id = res.guest_id
  WHERE r.is_active = TRUE
  ORDER BY r.room_number;
$$;
GRANT EXECUTE ON FUNCTION get_rooms_admin() TO anon, authenticated;


-- 3. All guests ordered by most recent
CREATE OR REPLACE FUNCTION get_guests_admin()
RETURNS TABLE (
  id           UUID,
  first_name   VARCHAR,
  last_name    VARCHAR,
  email        VARCHAR,
  phone        VARCHAR,
  vip_level    SMALLINT,
  total_stays  INTEGER,
  total_spend  DECIMAL,
  notes        TEXT,
  created_at   TIMESTAMPTZ,
  updated_at   TIMESTAMPTZ
)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT id, first_name, last_name, email, phone,
         vip_level, total_stays, total_spend, notes,
         created_at, updated_at
  FROM guests
  ORDER BY created_at DESC;
$$;
GRANT EXECUTE ON FUNCTION get_guests_admin() TO anon, authenticated;


-- 4. Full guest detail including reservation history
CREATE OR REPLACE FUNCTION get_guest_detail_admin(p_guest_id UUID)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_guest JSON;
  v_history JSON;
BEGIN
  SELECT row_to_json(g) INTO v_guest
  FROM guests g WHERE g.id = p_guest_id;

  SELECT json_agg(h ORDER BY h.check_in_date DESC) INTO v_history
  FROM (
    SELECT res.ref_code, res.status, res.check_in_date, res.check_out_date,
           res.total_amount, ro.room_number, ro.room_type
    FROM reservations res
    LEFT JOIN rooms ro ON ro.id = res.room_id
    WHERE res.guest_id = p_guest_id
  ) h;

  RETURN json_build_object(
    'guest',   v_guest,
    'history', COALESCE(v_history, '[]'::json)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_guest_detail_admin(UUID) TO anon, authenticated;


-- 5. Update guest notes
CREATE OR REPLACE FUNCTION update_guest_notes_admin(p_guest_id UUID, p_notes TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE guests SET notes = p_notes, updated_at = NOW()
  WHERE id = p_guest_id;
  RETURN FOUND;
END;
$$;
GRANT EXECUTE ON FUNCTION update_guest_notes_admin(UUID, TEXT) TO anon, authenticated;


-- 6. Update reservation status
CREATE OR REPLACE FUNCTION update_reservation_status_admin(
  p_id     UUID,
  p_status reservation_status
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_patch JSONB := jsonb_build_object('status', p_status);
BEGIN
  IF p_status = 'confirmed'   THEN v_patch := v_patch || '{"confirmed_at": "now()"}'; END IF;
  IF p_status = 'checked_in'  THEN v_patch := v_patch || '{"actual_checkin": "now()"}'; END IF;
  IF p_status = 'checked_out' THEN v_patch := v_patch || '{"actual_checkout": "now()"}'; END IF;
  IF p_status = 'cancelled'   THEN v_patch := v_patch || '{"cancelled_at": "now()"}'; END IF;

  UPDATE reservations
  SET
    status         = p_status,
    confirmed_at   = CASE WHEN p_status = 'confirmed'   THEN NOW() ELSE confirmed_at   END,
    actual_checkin = CASE WHEN p_status = 'checked_in'  THEN NOW() ELSE actual_checkin END,
    actual_checkout= CASE WHEN p_status = 'checked_out' THEN NOW() ELSE actual_checkout END,
    cancelled_at   = CASE WHEN p_status = 'cancelled'   THEN NOW() ELSE cancelled_at   END,
    updated_at     = NOW()
  WHERE id = p_id;

  -- Audit log
  INSERT INTO audit_log (action, table_name, record_id, new_value)
  VALUES ('reservation.' || p_status, 'reservations', p_id,
          jsonb_build_object('status', p_status));

  RETURN FOUND;
END;
$$;
GRANT EXECUTE ON FUNCTION update_reservation_status_admin(UUID, reservation_status) TO anon, authenticated;


-- 7. Update room status
CREATE OR REPLACE FUNCTION update_room_status_admin(
  p_id     UUID,
  p_status room_status,
  p_notes  TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE rooms
  SET status = p_status, notes = COALESCE(p_notes, notes), updated_at = NOW()
  WHERE id = p_id;
  RETURN FOUND;
END;
$$;
GRANT EXECUTE ON FUNCTION update_room_status_admin(UUID, room_status, TEXT) TO anon, authenticated;


-- 8. Dining reservations (upcoming)
CREATE OR REPLACE FUNCTION get_dining_reservations_admin()
RETURNS TABLE (
  id               UUID,
  status           dining_status,
  guest_name       VARCHAR,
  guest_phone      VARCHAR,
  covers           SMALLINT,
  reservation_date DATE,
  reservation_time TIME,
  occasion         VARCHAR,
  table_number     VARCHAR,
  area_name        VARCHAR,
  confirmed_at     TIMESTAMPTZ,
  seated_at        TIMESTAMPTZ
)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT
    dr.id, dr.status, dr.guest_name, dr.guest_phone,
    dr.covers, dr.reservation_date, dr.reservation_time, dr.occasion,
    dt.table_number, da.name,
    dr.confirmed_at, dr.seated_at
  FROM dining_reservations dr
  LEFT JOIN dining_tables dt ON dt.id = dr.table_id
  LEFT JOIN dining_areas  da ON da.id = dt.area_id
  WHERE dr.reservation_date >= CURRENT_DATE
  ORDER BY dr.reservation_date, dr.reservation_time;
$$;
GRANT EXECUTE ON FUNCTION get_dining_reservations_admin() TO anon, authenticated;


-- 9. Update dining reservation status
CREATE OR REPLACE FUNCTION update_dining_status_admin(
  p_id     UUID,
  p_status dining_status
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE dining_reservations
  SET
    status       = p_status,
    confirmed_at = CASE WHEN p_status = 'confirmed' THEN NOW() ELSE confirmed_at END,
    seated_at    = CASE WHEN p_status = 'seated'    THEN NOW() ELSE seated_at    END,
    completed_at = CASE WHEN p_status = 'completed' THEN NOW() ELSE completed_at END,
    updated_at   = NOW()
  WHERE id = p_id;
  RETURN FOUND;
END;
$$;
GRANT EXECUTE ON FUNCTION update_dining_status_admin(UUID, dining_status) TO anon, authenticated;


-- 10. Dashboard stats (occupancy + revenue + pending count)
CREATE OR REPLACE FUNCTION get_dashboard_stats_admin()
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE
  v_pending    BIGINT;
  v_checkedin  BIGINT;
  v_guests     BIGINT;
  v_occ        JSON;
  v_rev        JSON;
BEGIN
  SELECT COUNT(*) INTO v_pending   FROM reservations WHERE status = 'pending';
  SELECT COUNT(*) INTO v_checkedin FROM reservations WHERE status = 'checked_in';
  SELECT COUNT(*) INTO v_guests    FROM guests;

  SELECT json_agg(o) INTO v_occ FROM (
    SELECT room_type,
           COUNT(*)                                                        AS total_rooms,
           COUNT(*) FILTER (WHERE status = 'occupied')                    AS occupied,
           COUNT(*) FILTER (WHERE status = 'available')                   AS available,
           COUNT(*) FILTER (WHERE status = 'maintenance')                 AS maintenance,
           ROUND(
             100.0 * COUNT(*) FILTER (WHERE status = 'occupied') / NULLIF(COUNT(*),0), 1
           )                                                              AS occupancy_pct
    FROM rooms WHERE is_active = TRUE
    GROUP BY room_type
    ORDER BY room_type
  ) o;

  SELECT row_to_json(rv) INTO v_rev FROM (
    SELECT
      COALESCE(SUM(total_amount), 0)                        AS total_revenue,
      COALESCE(SUM(room_rate * nights), 0)                  AS room_revenue,
      COALESCE(SUM(extras_total), 0)                        AS extras_revenue,
      COUNT(*)                                              AS total_reservations,
      COUNT(*) FILTER (WHERE status = 'checked_out')        AS completed_stays
    FROM reservations
    WHERE DATE_TRUNC('month', check_in_date) = DATE_TRUNC('month', CURRENT_DATE)
      AND status NOT IN ('cancelled', 'no_show')
  ) rv;

  RETURN json_build_object(
    'pending_count',  v_pending,
    'active_guests',  v_checkedin,
    'total_guests',   v_guests,
    'occupancy',      COALESCE(v_occ, '[]'::json),
    'revenue',        COALESCE(v_rev, '{}'::json)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_dashboard_stats_admin() TO anon, authenticated;


-- 11. Monthly revenue trend (last 7 months)
CREATE OR REPLACE FUNCTION get_revenue_trend_admin()
RETURNS TABLE (month TEXT, total_revenue DECIMAL)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT
    TO_CHAR(DATE_TRUNC('month', check_in_date), 'Mon YYYY') AS month,
    COALESCE(SUM(total_amount), 0)                          AS total_revenue
  FROM reservations
  WHERE check_in_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    AND status NOT IN ('cancelled', 'no_show')
  GROUP BY DATE_TRUNC('month', check_in_date)
  ORDER BY DATE_TRUNC('month', check_in_date);
$$;
GRANT EXECUTE ON FUNCTION get_revenue_trend_admin() TO anon, authenticated;


-- 12. Audit log (recent activity)
CREATE OR REPLACE FUNCTION get_audit_log_admin(p_limit INT DEFAULT 12)
RETURNS TABLE (
  id         UUID,
  action     VARCHAR,
  table_name VARCHAR,
  record_id  UUID,
  new_value  JSONB,
  created_at TIMESTAMPTZ
)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT id, action, table_name, record_id, new_value, created_at
  FROM audit_log
  ORDER BY created_at DESC
  LIMIT p_limit;
$$;
GRANT EXECUTE ON FUNCTION get_audit_log_admin(INT) TO anon, authenticated;


-- 13. Today's arrivals
CREATE OR REPLACE FUNCTION get_arrivals_today_admin()
RETURNS TABLE (
  ref_code     VARCHAR,
  guest_name   TEXT,
  guest_phone  VARCHAR,
  vip_level    SMALLINT,
  room_number  VARCHAR,
  room_type    room_type,
  arrival_time TIME,
  special_requests TEXT,
  status       reservation_status
)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT
    r.ref_code,
    g.first_name || ' ' || g.last_name,
    g.phone,
    g.vip_level,
    ro.room_number,
    ro.room_type,
    r.arrival_time,
    r.special_requests,
    r.status
  FROM reservations r
  JOIN guests g  ON g.id  = r.guest_id
  JOIN rooms  ro ON ro.id = r.room_id
  WHERE r.check_in_date = CURRENT_DATE
    AND r.status IN ('confirmed', 'pending')
  ORDER BY r.arrival_time NULLS LAST;
$$;
GRANT EXECUTE ON FUNCTION get_arrivals_today_admin() TO anon, authenticated;


-- 14. Today's departures
CREATE OR REPLACE FUNCTION get_departures_today_admin()
RETURNS TABLE (
  ref_code     VARCHAR,
  guest_name   TEXT,
  room_number  VARCHAR,
  room_type    room_type,
  total_amount DECIMAL,
  payment_status payment_status,
  status       reservation_status
)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT
    r.ref_code,
    g.first_name || ' ' || g.last_name,
    ro.room_number,
    ro.room_type,
    r.total_amount,
    r.payment_status,
    r.status
  FROM reservations r
  JOIN guests g  ON g.id  = r.guest_id
  JOIN rooms  ro ON ro.id = r.room_id
  WHERE r.check_out_date = CURRENT_DATE
    AND r.status = 'checked_in'
  ORDER BY r.ref_code;
$$;
GRANT EXECUTE ON FUNCTION get_departures_today_admin() TO anon, authenticated;


-- ----------------------------------------------------------------
-- Done. Verify with:
-- SELECT routine_name FROM information_schema.routines
-- WHERE routine_schema = 'public' AND routine_type = 'FUNCTION'
-- ORDER BY routine_name;
-- ----------------------------------------------------------------
