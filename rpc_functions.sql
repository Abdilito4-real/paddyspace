-- ============================================================
--  PADDY SPACE — RLS Bypass RPC Functions  v2  (run in Supabase)
--  FIXES in this version:
--   1. create_reservation: removed AND status='available' constraint.
--      The date-overlap subquery is the correct availability check.
--      Filtering by status='available' caused ALL bookings to hit
--      the same room (first room found), making every reservation
--      appear to belong to the same guest ("aftyu ventures" etc.).
--   2. upsert_guest: now also updates first_name + last_name on
--      conflict, so returning guests always show current details.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. upsert_guest  (FIXED: updates name on conflict)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION upsert_guest(
  p_first_name TEXT,
  p_last_name  TEXT,
  p_email      TEXT,
  p_phone      TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM guests WHERE email = p_email;
  IF v_id IS NOT NULL THEN
    UPDATE guests
       SET first_name = p_first_name,
           last_name  = p_last_name,
           phone      = COALESCE(p_phone, phone),
           updated_at = NOW()
     WHERE id = v_id;
  ELSE
    INSERT INTO guests (first_name, last_name, email, phone)
    VALUES (p_first_name, p_last_name, p_email, p_phone)
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION upsert_guest(TEXT,TEXT,TEXT,TEXT) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 2. subscribe_newsletter
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION subscribe_newsletter(p_email TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO newsletter_subscribers (email, is_active)
  VALUES (p_email, TRUE)
  ON CONFLICT (email) DO UPDATE
    SET is_active = TRUE, unsubscribed_at = NULL;
END;
$$;
GRANT EXECUTE ON FUNCTION subscribe_newsletter(TEXT) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3. create_dining_reservation
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_dining_reservation(
  p_guest_name  TEXT,
  p_guest_phone TEXT     DEFAULT NULL,
  p_covers      SMALLINT DEFAULT 2,
  p_date        DATE     DEFAULT CURRENT_DATE,
  p_time        TIME     DEFAULT '19:00',
  p_occasion    TEXT     DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_table_id UUID;
BEGIN
  SELECT dt.id INTO v_table_id
    FROM dining_tables dt
   WHERE dt.is_active = TRUE AND dt.seats >= p_covers
   ORDER BY dt.seats ASC LIMIT 1;
  IF v_table_id IS NULL THEN
    SELECT id INTO v_table_id FROM dining_tables LIMIT 1;
  END IF;
  INSERT INTO dining_reservations (table_id, guest_name, guest_phone, covers,
    reservation_date, reservation_time, occasion, status)
  VALUES (v_table_id, p_guest_name, p_guest_phone, p_covers,
    p_date, p_time, p_occasion, 'pending');
END;
$$;
GRANT EXECUTE ON FUNCTION create_dining_reservation(TEXT,TEXT,SMALLINT,DATE,TIME,TEXT) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 4. create_reservation  (FIXED: removed AND status='available')
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_reservation(
  p_first_name       TEXT,
  p_last_name        TEXT,
  p_email            TEXT,
  p_phone            TEXT,
  p_room_type        room_type,
  p_check_in         DATE,
  p_check_out        DATE,
  p_special_requests TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_guest_id UUID;
  v_room_id  UUID;
  v_room_num TEXT;
  v_price    DECIMAL(12,2);
  v_nights   INT;
  v_total    DECIMAL(14,2);
  v_ref      TEXT;
BEGIN
  SELECT upsert_guest(p_first_name, p_last_name, p_email, p_phone) INTO v_guest_id;

  -- Find available room: date-overlap check is the sole availability gate.
  -- NOT filtering by room.status because status only changes on check-in/out.
  -- Pending/confirmed reservations for OTHER dates must not block a room.
  SELECT id, room_number, base_price
    INTO v_room_id, v_room_num, v_price
    FROM rooms
   WHERE room_type = p_room_type
     AND is_active = TRUE
     AND id NOT IN (
           SELECT room_id FROM reservations
            WHERE status NOT IN ('cancelled','no_show')
              AND check_in_date  < p_check_out
              AND check_out_date > p_check_in
         )
   ORDER BY room_number
   LIMIT 1;

  IF v_room_id IS NULL THEN
    RETURN json_build_object('success', FALSE, 'error',
      format('No %s available for %s to %s. Please try different dates.',
             p_room_type, p_check_in, p_check_out));
  END IF;

  v_nights := p_check_out - p_check_in;
  v_total  := v_price * v_nights;

  INSERT INTO reservations (guest_id, room_id, check_in_date, check_out_date,
    room_rate, total_amount, special_requests, status, source)
  VALUES (v_guest_id, v_room_id, p_check_in, p_check_out,
    v_price, v_total, p_special_requests, 'pending', 'website')
  RETURNING ref_code INTO v_ref;

  INSERT INTO audit_log (action, table_name, new_value)
  VALUES ('reservation.created', 'reservations',
    jsonb_build_object('ref', v_ref, 'guest', p_email, 'room', v_room_num,
                       'nights', v_nights, 'total', v_total));

  RETURN json_build_object('success', TRUE, 'ref_code', v_ref,
    'room_number', v_room_num, 'nights', v_nights, 'total', v_total);

EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', FALSE, 'error', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION create_reservation(TEXT,TEXT,TEXT,TEXT,room_type,DATE,DATE,TEXT) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 5. RLS policies
-- ─────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "dining_res_public_insert" ON dining_reservations;
CREATE POLICY "dining_res_public_insert" ON dining_reservations FOR INSERT WITH CHECK (TRUE);

DROP POLICY IF EXISTS "dining_areas_public" ON dining_areas;
CREATE POLICY "dining_areas_public" ON dining_areas FOR SELECT USING (is_active = TRUE);

DROP POLICY IF EXISTS "menu_public_read" ON menu_items;
CREATE POLICY "menu_public_read" ON menu_items FOR SELECT USING (is_available = TRUE);
