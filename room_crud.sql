-- ================================================================
--  PADDY SPACE — Room Management CRUD Functions
--  Run in: Supabase Dashboard → SQL Editor → New Query
-- ================================================================

-- 1. Create room
CREATE OR REPLACE FUNCTION create_room_admin(
  p_room_number   TEXT,
  p_room_type     room_type,
  p_floor         SMALLINT,
  p_size_sqm      DECIMAL  DEFAULT NULL,
  p_view          TEXT     DEFAULT NULL,
  p_max_occupancy SMALLINT DEFAULT 2,
  p_base_price    DECIMAL  DEFAULT 85000,
  p_amenities     TEXT[]   DEFAULT NULL,
  p_description   TEXT     DEFAULT NULL,
  p_notes         TEXT     DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  IF EXISTS (SELECT 1 FROM rooms WHERE room_number = p_room_number AND is_active = TRUE) THEN
    RETURN json_build_object('success', FALSE, 'error', format('Room %s already exists.', p_room_number));
  END IF;
  INSERT INTO rooms (room_number, room_type, floor, size_sqm, view,
    max_occupancy, base_price, amenities, description, notes, status, is_active)
  VALUES (p_room_number, p_room_type, p_floor, p_size_sqm, p_view,
    p_max_occupancy, p_base_price, p_amenities, p_description, p_notes, 'available', TRUE)
  RETURNING id INTO v_id;
  INSERT INTO audit_log (action, table_name, record_id, new_value)
  VALUES ('room.created', 'rooms', v_id,
    jsonb_build_object('room_number', p_room_number, 'type', p_room_type));
  RETURN json_build_object('success', TRUE, 'id', v_id, 'room_number', p_room_number);
END;
$$;
GRANT EXECUTE ON FUNCTION create_room_admin(TEXT,room_type,SMALLINT,DECIMAL,TEXT,SMALLINT,DECIMAL,TEXT[],TEXT,TEXT) TO anon, authenticated;


-- 2. Update room
CREATE OR REPLACE FUNCTION update_room_admin(
  p_id            UUID,
  p_room_number   TEXT,
  p_room_type     room_type,
  p_floor         SMALLINT,
  p_size_sqm      DECIMAL  DEFAULT NULL,
  p_view          TEXT     DEFAULT NULL,
  p_max_occupancy SMALLINT DEFAULT 2,
  p_base_price    DECIMAL  DEFAULT 85000,
  p_amenities     TEXT[]   DEFAULT NULL,
  p_description   TEXT     DEFAULT NULL,
  p_notes         TEXT     DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE rooms SET
    room_number = p_room_number, room_type = p_room_type, floor = p_floor,
    size_sqm = p_size_sqm, view = p_view, max_occupancy = p_max_occupancy,
    base_price = p_base_price, amenities = p_amenities,
    description = p_description, notes = p_notes, updated_at = NOW()
  WHERE id = p_id;
  INSERT INTO audit_log (action, table_name, record_id, new_value)
  VALUES ('room.updated', 'rooms', p_id,
    jsonb_build_object('room_number', p_room_number, 'price', p_base_price));
  RETURN FOUND;
END;
$$;
GRANT EXECUTE ON FUNCTION update_room_admin(UUID,TEXT,room_type,SMALLINT,DECIMAL,TEXT,SMALLINT,DECIMAL,TEXT[],TEXT,TEXT) TO anon, authenticated;


-- 3. Toggle availability
CREATE OR REPLACE FUNCTION toggle_room_availability_admin(p_id UUID)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_current room_status;
  v_new     room_status;
  v_num     TEXT;
BEGIN
  SELECT status, room_number INTO v_current, v_num FROM rooms WHERE id = p_id;
  IF v_current = 'occupied' THEN
    RETURN json_build_object('success', FALSE, 'error', format('Room %s is currently occupied.', v_num));
  END IF;
  v_new := CASE
    WHEN v_current IN ('available','housekeeping','reserved') THEN 'maintenance'::room_status
    WHEN v_current = 'maintenance' THEN 'available'::room_status
    ELSE v_current END;
  UPDATE rooms SET status = v_new, updated_at = NOW() WHERE id = p_id;
  INSERT INTO audit_log (action, table_name, record_id, new_value)
  VALUES ('room.status_changed', 'rooms', p_id,
    jsonb_build_object('from', v_current, 'to', v_new, 'room', v_num));
  RETURN json_build_object('success', TRUE, 'new_status', v_new, 'room_number', v_num);
END;
$$;
GRANT EXECUTE ON FUNCTION toggle_room_availability_admin(UUID) TO anon, authenticated;


-- 4. Soft-delete room
CREATE OR REPLACE FUNCTION delete_room_admin(p_id UUID)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_num    TEXT;
  v_status room_status;
  v_active BIGINT;
BEGIN
  SELECT room_number, status INTO v_num, v_status FROM rooms WHERE id = p_id;
  IF v_status = 'occupied' THEN
    RETURN json_build_object('success', FALSE,
      'error', format('Room %s is occupied. Check out the guest first.', v_num));
  END IF;
  SELECT COUNT(*) INTO v_active FROM reservations
  WHERE room_id = p_id AND status IN ('pending','confirmed','checked_in')
    AND check_out_date >= CURRENT_DATE;
  IF v_active > 0 THEN
    RETURN json_build_object('success', FALSE,
      'error', format('Room %s has %s active reservation(s). Cancel them first.', v_num, v_active));
  END IF;
  UPDATE rooms SET is_active = FALSE, updated_at = NOW() WHERE id = p_id;
  INSERT INTO audit_log (action, table_name, record_id, new_value)
  VALUES ('room.deleted', 'rooms', p_id, jsonb_build_object('room_number', v_num));
  RETURN json_build_object('success', TRUE, 'room_number', v_num);
END;
$$;
GRANT EXECUTE ON FUNCTION delete_room_admin(UUID) TO anon, authenticated;
