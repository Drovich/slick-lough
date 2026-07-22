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

-- ── RLS: public read, role-checked write ────────────────────────────────────
-- Reads stay open to everyone (anyone can watch the live standings).
-- Writes require a real Supabase Auth session in one of the 3 shared roles
-- (see the "role_locks" section below for how the admin/arbitre/participant
-- accounts are set up), and are blocked in real time if that role is locked.
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
  end loop;
end $$;

-- ── Real role-based access control (Supabase Auth) ──────────────────────────
-- Three shared Auth accounts (admin/arbitre/participant@slicklough.internal,
-- created once via the Dashboard) each carry a "role" in their user_metadata.
-- current_app_role() reads that role straight from the request's JWT.
create or replace function current_app_role() returns text
language sql stable as $$
  select coalesce(auth.jwt() -> 'user_metadata' ->> 'role', 'anon')
$$;

-- role_locks is the real, database-enforced version of the admin's "lock"
-- buttons. Unlike competition_config (read by the client to show a banner,
-- but never itself checked by RLS), this table is read INSIDE the write
-- policies below — so flipping it blocks every holder of that role's shared
-- password immediately, including browsers already logged in.
create table if not exists role_locks (
  role   text primary key check (role in ('participant', 'arbitre')),
  locked boolean not null default false
);
insert into role_locks (role, locked) values ('participant', false), ('arbitre', false)
  on conflict (role) do nothing;

alter table role_locks enable row level security;
do $$ begin
  create policy "public read role_locks" on role_locks for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "admin write role_locks" on role_locks for all
    using (current_app_role() = 'admin')
    with check (current_app_role() = 'admin');
exception when duplicate_object then null; end $$;

create or replace function role_is_locked(r text) returns boolean
language sql stable as $$
  select coalesce((select locked from role_locks where role = r), false)
$$;

-- Replace the old blanket "public write" policies with per-table rules.
-- Three tiers, matching who is actually meant to trigger each write:
--
--   ALL3    admin, or arbitre/participant while not locked
--           → results entry, blocs topping, MK self-registration: things a
--             participant is meant to do for themselves.
--   STAFF   admin, or arbitre while not locked (never participant)
--           → bracket management, blocs problem definitions, the manual
--             override, combined-ranking calculations: arbitre/admin tools,
--             never exposed to participants in the UI and now blocked for
--             them at the database too, even via devtools.
--   ADMIN   admin only
--           → the lottery draw results themselves.
--
-- participants also gets a DELETE-only ADMIN policy (removing someone is
-- admin-only) and a trigger that silently ignores any attempt to change
-- `blacklisted` from a non-admin session, since RLS is row-level and can't
-- otherwise single out one column from an update that touches several.
do $$
declare
  t text;
  all3  text := $c$
    current_app_role() = 'admin'
    or (current_app_role() = 'arbitre' and not role_is_locked('arbitre'))
    or (current_app_role() = 'participant' and not role_is_locked('participant'))
  $c$;
  staff text := $c$
    current_app_role() = 'admin'
    or (current_app_role() = 'arbitre' and not role_is_locked('arbitre'))
  $c$;
begin
  foreach t in array array['results_trail', 'results_mario_kart', 'results_blocs', 'mk_registrations'] loop
    execute format('drop policy if exists %I on %I', 'public write ' || t, t);
    execute format('drop policy if exists %I on %I', 'role write ' || t, t);
    execute format('create policy %I on %I for all using (%s) with check (%s)', 'role write ' || t, t, all3, all3);
  end loop;

  foreach t in array array['blocs', 'blocs_override', 'mk_matches', 'combined_rankings', 'competition_config'] loop
    execute format('drop policy if exists %I on %I', 'public write ' || t, t);
    execute format('drop policy if exists %I on %I', 'role write ' || t, t);
    execute format('create policy %I on %I for all using (%s) with check (%s)', 'role write ' || t, t, staff, staff);
  end loop;

  execute format('drop policy if exists %I on lottery_winners', 'public write lottery_winners');
  execute format('drop policy if exists %I on lottery_winners', 'role write lottery_winners');
  execute
    'create policy "role write lottery_winners" on lottery_winners for all '
    || 'using (current_app_role() = ''admin'') with check (current_app_role() = ''admin'')';

  -- participants: insert/update open to all 3 (self-registration + editing);
  -- delete is admin-only (kept separate from insert/update on purpose).
  drop policy if exists "public write participants" on participants;
  drop policy if exists "role write participants" on participants;
  execute format(
    'create policy "role insert participants" on participants for insert with check (%s)', all3
  );
  execute format(
    'create policy "role update participants" on participants for update using (%s) with check (%s)', all3, all3
  );
end $$;

do $$ begin
  create policy "admin delete participants" on participants for delete
    using (current_app_role() = 'admin');
exception when duplicate_object then null; end $$;

-- Column-level guard: only an admin session may flip `blacklisted`. RLS alone
-- can't restrict a single column within a row-level UPDATE, so a trigger
-- silently reverts that one field if a non-admin session touches it — the
-- rest of the update (gender, atelier…) still goes through normally.
create or replace function protect_blacklisted() returns trigger
language plpgsql as $$
begin
  if current_app_role() <> 'admin' and new.blacklisted is distinct from old.blacklisted then
    new.blacklisted := old.blacklisted;
  end if;
  return new;
end $$;

drop trigger if exists participants_protect_blacklisted on participants;
create trigger participants_protect_blacklisted before update on participants
  for each row execute function protect_blacklisted();

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
