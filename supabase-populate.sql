-- Populate test data for Slick Lough
-- Run in Supabase SQL Editor after supabase-schema.sql

-- ── Participants ───────────────────────────────────────────────────────────────
-- (all participants across all events, with gender)
insert into participants (username, gender) values
  ('Matou',       'M'),
  ('Théotime',    'M'),
  ('Bonickel',    'M'),
  ('Charlélie',   'M'),
  ('Guillaume',   'M'),
  ('David',       'M'),
  ('Drovich',     'M'),
  ('Julien',      'M'),
  ('Hugo',        'M'),
  ('Clémence',    'F'),
  ('Karim',       'M'),
  ('Dani',        'F'),
  ('Abel',        'M'),
  ('RémiL',       'M'),
  ('Marjolaine',  'F'),
  ('Emma',        'F'),
  ('Dylan',       'M'),
  ('Banouch',     'M'),
  ('Harry',       'M'),
  ('Max',         'M'),
  ('Alix',        'M'),
  ('Clément',     'M'),
  ('Eliott',      'M'),
  ('Flo',         'M'),
  ('Jade',        'F'),
  ('Camille',     'M'),
  ('Constance',   'F'),
  ('Geogeo',      'M'),
  ('Gu',          'M'),
  ('Pierre',      'M'),
  ('Lisa',        'F'),
  ('Lou',         'F')
on conflict (username) do update set gender = excluded.gender;

-- ── Trail results ─────────────────────────────────────────────────────────────
-- Tied positions: Dani & Abel = 12.5 → both stored as 12 (mid-rank computed by app)
--                RémiL & Marjolaine = 14.5 → both stored as 14
insert into results_trail (participant_username, position) values
  ('Matou',       1),
  ('Théotime',    2),
  ('Bonickel',    3),
  ('Charlélie',   4),
  ('Guillaume',   5),
  ('David',       6),
  ('Drovich',     7),
  ('Julien',      8),
  ('Hugo',        9),
  ('Clémence',    10),
  ('Karim',       11),
  ('Dani',        12),
  ('Abel',        12),
  ('RémiL',       14),
  ('Marjolaine',  14)
on conflict (participant_username) do update set position = excluded.position;

-- ── Mario Kart results ────────────────────────────────────────────────────────
-- Tied positions stored as the lower of the two:
-- Abel & Emma = 3.5 → 3
-- Drovich & Max = 5.5 → 5
-- Alix…Flo…Jade = 11 → 11
-- Camille…Théotime = 17 → 17
-- Clémence…Lou = 25.5 → 25
insert into results_mario_kart (participant_username, position) values
  ('Banouch',    1),
  ('Harry',      2),
  ('Abel',       3),
  ('Emma',       3),
  ('Drovich',    5),
  ('Max',        5),
  ('Alix',       11),
  ('Charlélie',  11),
  ('Clément',    11),
  ('Eliott',     11),
  ('Flo',        11),
  ('Jade',       11),
  ('Camille',    17),
  ('Constance',  17),
  ('Dylan',      17),
  ('Geogeo',     17),
  ('Gu',         17),
  ('Karim',      17),
  ('Marjolaine', 17),
  ('Pierre',     17),
  ('Théotime',   17),
  ('Clémence',   25),
  ('Dani',       25),
  ('David',      25),
  ('Hugo',       25),
  ('Julien',     25),
  ('Lisa',       25),
  ('Lou',        25),
  ('RémiL',      25)
on conflict (participant_username) do update set position = excluded.position;

-- ── Blocs — override ranking ──────────────────────────────────────────────────
-- Stored as fractional positions (numeric) in the override table.
-- The app uses this directly when non-empty.
-- Mid-rank positions: David & Clémence = 2.5, Julien & Théotime = 5.5,
--   Abel & Marjolaine = 8.5, Bonickel & Guillaume & Emma = 11, RémiL & Dylan = 13.5
insert into blocs_override (participant_username, position) values
  ('Drovich',     1),
  ('David',       3),   -- 2.5 displayed as 3rd (tied 2nd-3rd)
  ('Clémence',    3),
  ('Hugo',        4),
  ('Julien',      6),   -- 5.5 → tied 5th-6th
  ('Théotime',    6),
  ('Karim',       7),
  ('Abel',        9),   -- 8.5 → tied 8th-9th
  ('Marjolaine',  9),
  ('Bonickel',    12),  -- 11 → tied 10th-11th-12th
  ('Guillaume',   12),
  ('Emma',        12),
  ('RémiL',       14),  -- 13.5 → tied 13th-14th
  ('Dylan',       14)
on conflict (participant_username) do update set position = excluded.position;
