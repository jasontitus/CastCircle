-- Idempotent: safe to re-run. Creates RPC functions for the join flow.
-- These use SECURITY DEFINER to bypass RLS.

-- 1. Look up production by join code
CREATE OR REPLACE FUNCTION public.lookup_production_by_join_code(lookup_code text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT row_to_json(p) 
  FROM productions p 
  WHERE p.join_code = upper(lookup_code) 
  LIMIT 1;
$$;

-- 2. Fetch cast members for a production
CREATE OR REPLACE FUNCTION public.fetch_cast_for_join(prod_id text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT coalesce(json_agg(row_to_json(cm)), '[]'::json)
  FROM cast_members cm
  WHERE cm.production_id = prod_id::uuid;
$$;

-- 3. Self-join a production
CREATE OR REPLACE FUNCTION public.join_production(
  prod_id text,
  char_name text DEFAULT '',
  display_name text DEFAULT '',
  member_role text DEFAULT 'actor'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result json;
BEGIN
  INSERT INTO cast_members (production_id, user_id, character_name, display_name, role, joined_at)
  VALUES (prod_id::uuid, auth.uid()::text, char_name, display_name, member_role, now())
  RETURNING row_to_json(cast_members.*) INTO result;
  RETURN result;
END;
$$;

-- 4. Claim an existing invitation
CREATE OR REPLACE FUNCTION public.claim_cast_invitation(member_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE cast_members
  SET user_id = auth.uid()::text,
      joined_at = now()
  WHERE id = member_id::uuid
    AND user_id IS NULL;
END;
$$;

-- Grant execute to authenticated users
GRANT EXECUTE ON FUNCTION public.lookup_production_by_join_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lookup_production_by_join_code(text) TO anon;
GRANT EXECUTE ON FUNCTION public.fetch_cast_for_join(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_production(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_cast_invitation(text) TO authenticated;

-- Also ensure RLS policies exist for direct queries as fallback
DO $$ BEGIN
  CREATE POLICY "auth_read_productions" ON productions FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "auth_read_cast" ON cast_members FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "auth_insert_cast" ON cast_members FOR INSERT TO authenticated WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "auth_update_cast" ON cast_members FOR UPDATE TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
