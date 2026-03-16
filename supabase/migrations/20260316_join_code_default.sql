-- Auto-generate join_code server-side so web editor and any client
-- that omits it still gets a valid code.
ALTER TABLE public.productions
  ALTER COLUMN join_code SET DEFAULT public.generate_join_code();
