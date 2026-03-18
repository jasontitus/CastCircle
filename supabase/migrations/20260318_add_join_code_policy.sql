-- Allow any authenticated user to look up productions by join code.
-- Required for the join flow: users who aren't yet cast members need
-- to find the production before they can join it.
CREATE POLICY "Authenticated users can read productions"
  ON productions
  FOR SELECT
  TO authenticated
  USING (true);

-- Also ensure authenticated users can read cast_members for productions
-- they're looking up (needed to show available character slots)
CREATE POLICY "Authenticated users can read cast members"
  ON cast_members
  FOR SELECT
  TO authenticated
  USING (true);

-- Allow authenticated users to insert themselves as cast members (self-join)
CREATE POLICY "Authenticated users can join productions"
  ON cast_members
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Allow users to update their own cast member row (claim invitation)
CREATE POLICY "Users can claim their invitation"
  ON cast_members
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id OR user_id IS NULL);
