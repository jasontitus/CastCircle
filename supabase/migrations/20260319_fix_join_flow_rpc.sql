-- Fix join flow: create RPC functions that bypass RLS.
-- The previous migration partially applied the policies but the
-- RPC functions failed due to type mismatch.

-- Drop any leftover broken functions
DROP FUNCTION IF EXISTS public.fetch_cast_for_join(uuid);
DROP FUNCTION IF EXISTS public.fetch_cast_for_join(text);
DROP FUNCTION IF EXISTS public.join_production(text, text, text, text);
DROP FUNCTION IF EXISTS public.claim_cast_invitation(text);

-- Fetch cast members for a production (for the join flow)
CREATE OR REPLACE FUNCTION public.fetch_cast_for_join(prod_id text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_agg(row_to_json(cm))
  FROM cast_members cm
  WHERE cm.production_id::text = prod_id;
$$;

GRANT EXECUTE ON FUNCTION public.fetch_cast_for_join(text) TO authenticated;

-- Self-join: insert a new cast member with the caller's user_id
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
  VALUES (prod_id, auth.uid()::text, char_name, display_name, member_role, now())
  RETURNING row_to_json(cast_members.*) INTO result;
  RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.join_production(text, text, text, text) TO authenticated;

-- Claim an invitation (set user_id on an existing row with no user)
CREATE OR REPLACE FUNCTION public.claim_cast_invitation(
  member_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE cast_members
  SET user_id = auth.uid()::text,
      joined_at = now()
  WHERE id = member_id
    AND user_id IS NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION public.claim_cast_invitation(text) TO authenticated;
