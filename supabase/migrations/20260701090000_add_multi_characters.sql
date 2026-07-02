-- Shared/ensemble lines ("BOTH", "ALL", "MACBETH AND LENNOX") carry a list of
-- individual characters in the app (ScriptLine.multiCharacters), but the cloud
-- round-trip dropped it: joiners' character line counts and "my lines"
-- filtering missed those lines, so actors were never prompted to record them.
-- Nullable jsonb array of character names; null/absent = single-character line.
alter table public.script_lines
  add column if not exists multi_characters jsonb;
