-- Supabase schema for Slick Lough — Competition
-- Run this in the Supabase SQL Editor. Idempotent: safe to re-run.

-- ── Migration from the previous schema ─────────────────────────────────────
-- The four classement_* tables are merged into combined_rankings, and
-- classement_blocs_override is renamed blocs_override. Old data is dropped
-- (rankings are recomputed on demand from the admin buttons).
drop table if exists classement_vitesse;
drop table if exists classement_sportif;
drop table if exists classement_technique;
drop table if exists classement_super_combine;
drop table if exists classement_blocs_override;

-- ── Tables ─────────────────────────────────────────────────────────────────

create table if not exists participants (
  username    text primary key,
  gender      text check (gender in ('F', 'M')),
  atelier     boolean default false not null, -- workshop attended → ×2 lottery points
  blacklisted boolean default false not null, -- excluded from lottery draws
  created_at  timestamptz default now() not null
);

-- Anti-flood: the 200-participant cap is enforced server-side
-- (the client-side check is UX only and can be bypassed)
create or replace function enforce_participant_limit() returns trigger
language plpgsql as $$
begin
  if (select count(*) from participants) >= 200 then
    raise exception 'Limite de 200 participants atteinte';
  end if;
  return new;
end $$;

drop trigger if exists participants_limit on participants;
create trigger participants_limit before insert on participants
  for each row execute function enforce_participant_limit();

-- Bouldering problems. Scoring: points are split among everyone who topped
-- (1000pt problem topped by 4 people → 250pts each)
create table if not exists blocs (
  id        serial primary key,
  name      text not null,
  color     text not null default '',
  points    integer not null default 1000,
  photo_url text -- public Supabase Storage URL
);

create table if not exists results_trail (
  participant_username text primary key references participants(username) on delete cascade,
  position             integer check (position > 0),
  updated_at           timestamptz default now() not null
);

create table if not exists results_mario_kart (
  participant_username text primary key references participants(username) on delete cascade,
  position             integer check (position > 0),
  updated_at           timestamptz default now() not null
);

-- One row per participant × problem
create table if not exists results_blocs (
  participant_username text    references participants(username) on delete cascade,
  bloc_id              integer references blocs(id) on delete cascade,
  topped               boolean not null default false,
  primary key (participant_username, bloc_id)
);

-- Combined rankings, computed on demand by the admin.
-- Categories: vitesse (trail+mk), sportif (trail+blocs),
--             technique (mk+blocs), super_combine (all three)
create table if not exists combined_rankings (
  category             text not null check (category in ('vitesse', 'sportif', 'technique', 'super_combine')),
  participant_username text not null references participants(username) on delete cascade,
  rank_value           numeric not null,
  position             integer not null,
  computed_at          timestamptz default now() not null,
  primary key (category, participant_username)
);

-- Manual override of the blocs ranking; when non-empty it replaces the
-- automatic score calculation
create table if not exists blocs_override (
  participant_username text primary key references participants(username) on delete cascade,
  position             integer not null check (position > 0)
);

create table if not exists mk_registrations (
  participant_username text primary key references participants(username) on delete cascade,
  registered_at timestamptz default now() not null
);

-- MK bracket. id format: "W-{round}-{match_num}" | "L-{round}-{match_num}" | "F"
create table if not exists mk_matches (
  id         text primary key,
  bracket    text not null,          -- 'winners' | 'losers' | 'final'
  round      integer not null,
  match_num  integer not null,
  players    jsonb default '[]',     -- ["J1","J2",null,...] — null = TBD slot
  results    jsonb default '{}',     -- {"J1":1,"J2":2,...}
  status     text default 'pending', -- 'pending' | 'completed'
  advance_to text,                   -- match id for the qualifiers (null after final)
  drop_to    text                    -- match id for the eliminated (null = out)
);

-- Atomic player placement: fills the first null slot walking match_ids in
-- order. "for update" locks the row so two referees validating pools at the
-- same time cannot clobber each other. Returns the filled match id, or null.
create or replace function mk_fill_player(match_ids text[], player text)
returns text language plpgsql as $$
declare mid text; arr jsonb; idx integer;
begin
  foreach mid in array match_ids loop
    select players into arr from mk_matches where id = mid for update;
    if arr is null then continue; end if;
    select (ord - 1)::int into idx
      from jsonb_array_elements(arr) with ordinality as t(elem, ord)
      where elem = 'null'::jsonb
      order by ord limit 1;
    if idx is not null then
      update mk_matches set players = jsonb_set(arr, array[idx::text], to_jsonb(player))
        where id = mid;
      return mid;
    end if;
  end loop;
  return null;
end $$;

-- Lottery results (written by the admin, visible to all in realtime)
create table if not exists lottery_winners (
  category        text primary key, -- 'trail','mk','blocs','vitesse','sportif','technique','super_combine'
  winner_username text
);

-- Misc config flags: admin_lock, mk_phase, mk_format, gender_correction
create table if not exists competition_config (
  key   text primary key,
  value text not null
);

-- ── Realtime ───────────────────────────────────────────────────────────────
do $$ declare t text; begin
  foreach t in array array[
    'participants', 'results_trail', 'results_mario_kart', 'results_blocs',
    'blocs_override', 'combined_rankings', 'lottery_winners', 'competition_config',
    'mk_registrations', 'mk_matches'
  ] loop
    begin
      execute format('alter publication supabase_realtime add table %I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- ── RLS: public read and write ─────────────────────────────────────────────
-- Access control happens app-side (shared passwords); RLS is open by design.
do $$ declare t text; begin
  foreach t in array array[
    'participants', 'blocs', 'results_trail', 'results_mario_kart', 'results_blocs',
    'blocs_override', 'combined_rankings', 'lottery_winners', 'competition_config',
    'mk_registrations', 'mk_matches'
  ] loop
    execute format('alter table %I enable row level security', t);
    begin
      execute format('create policy "public read %s"  on %I for select using (true)', t, t);
    exception when duplicate_object then null;
    end;
    begin
      execute format('create policy "public write %s" on %I for all using (true) with check (true)', t, t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- ── Storage: bucket for problem photos ─────────────────────────────────────
-- (create manually in Dashboard > Storage if this fails)
insert into storage.buckets (id, name, public) values ('blocs-photos', 'blocs-photos', true)
  on conflict (id) do nothing;

-- Storage policies — manage via Dashboard > Storage > Policies if needed:
-- create policy "public read blocs-photos" on storage.objects for select using (bucket_id = 'blocs-photos');
-- create policy "upload blocs-photos" on storage.objects for insert with check (bucket_id = 'blocs-photos');
-- create policy "delete blocs-photos" on storage.objects for delete using (bucket_id = 'blocs-photos');

-- ── Sample problems (only when the table is empty) ─────────────────────────
do $$ begin
  if not exists (select 1 from blocs limit 1) then
    insert into blocs (name, color, points) values
      ('Problem 1', 'Yellow',      1000),
      ('Problem 2', 'Orange',      1000),
      ('Problem 3', 'Light green', 1000),
      ('Problem 4', 'Red',         1000),
      ('Problem 5', 'Dark green',  1000),
      ('Problem 6', 'Purple',      1000),
      ('Problem 7', 'Black',       1000);
  end if;
end $$;
