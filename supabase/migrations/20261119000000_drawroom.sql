-- =====================================================================
-- DRAW ROOM (Linear おえかきルーム) : Supabase setup
-- Run this whole file once in Supabase Dashboard -> SQL Editor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

-- People allowed in (written by the Edge Function verify-discord)
create table if not exists public.members (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  discord_id   text not null unique,
  display_name text not null default '',
  avatar_url   text,
  iriam_id     text check (iriam_id is null or char_length(iriam_id) between 1 and 64),
  role         text not null default 'liver' check (role in ('liver', 'staff')),
  active       boolean not null default true,      -- false = lost the Discord role / left the server
  verified_at  timestamptz not null default now(), -- last Discord role check
  created_at   timestamptz not null default now()
);

-- Name the member chose for the room (display_name keeps the Discord name)
alter table public.members add column if not exists nickname text
  check (nickname is null or char_length(nickname) between 1 and 20);

-- One row per line on the canvas
create table if not exists public.strokes (
  id         text primary key check (char_length(id) between 1 and 40),
  user_id    uuid not null default auth.uid() references public.members(user_id) on delete cascade,
  c          text not null check (c ~ '^#[0-9a-fA-F]{6}$'),
  w          real not null check (w between 0.5 and 200),
  p          jsonb not null check (jsonb_typeof(p) = 'array' and jsonb_array_length(p) between 2 and 20000),
  t          bigint not null,
  created_at timestamptz not null default now()
);
create index if not exists strokes_t_idx    on public.strokes (t, id);
create index if not exists strokes_user_idx on public.strokes (user_id);

-- Lines removed by the eraser or by staff (kept so they can be undone and checked later)
create table if not exists public.stroke_trash (
  id         text primary key,
  user_id    uuid not null,
  c          text not null,
  w          real not null,
  p          jsonb not null,
  t          bigint not null,
  deleted_by uuid not null,
  deleted_at timestamptz not null default now()
);

create table if not exists public.bans (
  user_id    uuid primary key references public.members(user_id) on delete cascade,
  until      timestamptz,                 -- null = no end date
  reason     text not null default '',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.warnings (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.members(user_id) on delete cascade,
  message    text not null check (char_length(message) between 1 and 500),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists warnings_user_idx on public.warnings (user_id);

create table if not exists public.mod_log (
  id         bigint generated always as identity primary key,
  actor      uuid,
  action     text not null,
  target     uuid,
  detail     text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. Checks used by the access rules
-- ---------------------------------------------------------------------

create or replace function public.is_banned(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.bans b
    where b.user_id = uid and (b.until is null or b.until > now())
  );
$$;

-- In the room = active member, Discord role checked within 30 days, not banned
create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.members m
    where m.user_id = auth.uid()
      and m.active
      and m.verified_at > now() - interval '30 days'
  ) and not public.is_banned(auth.uid());
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_member() and exists (
    select 1 from public.members m where m.user_id = auth.uid() and m.role = 'staff'
  );
$$;

-- ---------------------------------------------------------------------
-- 3. Row Level Security
-- ---------------------------------------------------------------------

alter table public.members      enable row level security;
alter table public.strokes      enable row level security;
alter table public.stroke_trash enable row level security;
alter table public.bans         enable row level security;
alter table public.warnings     enable row level security;
alter table public.mod_log      enable row level security;

drop policy if exists members_select on public.members;
create policy members_select on public.members
  for select to authenticated using (user_id = auth.uid() or public.is_staff());

drop policy if exists strokes_select on public.strokes;
create policy strokes_select on public.strokes
  for select to authenticated using (public.is_member());

drop policy if exists strokes_insert on public.strokes;
create policy strokes_insert on public.strokes
  for insert to authenticated with check (public.is_member() and user_id = auth.uid());

-- Undo of your own line. Staff deletes go through erase_strokes() so they are logged.
drop policy if exists strokes_delete on public.strokes;
create policy strokes_delete on public.strokes
  for delete to authenticated using (public.is_member() and user_id = auth.uid());

drop policy if exists bans_select on public.bans;
create policy bans_select on public.bans
  for select to authenticated using (user_id = auth.uid() or public.is_staff());

drop policy if exists warnings_select on public.warnings;
create policy warnings_select on public.warnings
  for select to authenticated using (user_id = auth.uid() or public.is_staff());

drop policy if exists mod_log_select on public.mod_log;
create policy mod_log_select on public.mod_log
  for select to authenticated using (public.is_staff());

-- stroke_trash has no policies: only the functions below touch it.

-- Table privileges (newer projects do not grant these automatically).
-- Row Level Security above still decides which rows each person can touch.
grant usage on schema public to authenticated, service_role;
grant all on public.members, public.strokes, public.stroke_trash, public.bans, public.warnings, public.mod_log to service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;
grant select on public.members, public.strokes, public.bans, public.warnings, public.mod_log to authenticated;
grant insert, delete on public.strokes to authenticated;

-- Names everyone in the room may see (no IRIAM ID, no Discord ID)
create or replace view public.profiles as
  select user_id, coalesce(nickname, display_name) as display_name, avatar_url, role
  from public.members
  where public.is_member();
revoke all on public.profiles from anon;
grant select on public.profiles to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. Functions called from the page (everyone)
-- ---------------------------------------------------------------------

create or replace function public.my_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  m public.members;
  b public.bans;
begin
  select * into m from public.members where user_id = auth.uid();
  if not found then
    return jsonb_build_object('known', false);
  end if;
  select * into b from public.bans
   where user_id = auth.uid() and (until is null or until > now());
  return jsonb_build_object(
    'known', true,
    'active', m.active,
    'verified', m.verified_at > now() - interval '30 days',
    'role', m.role,
    'display_name', coalesce(m.nickname, m.display_name),
    'discord_name', m.display_name,
    'nickname', m.nickname,
    'iriam_id', m.iriam_id,
    'banned', b.user_id is not null,
    'ban_until', b.until,
    'ban_reason', b.reason,
    'warnings', coalesce((
      select jsonb_agg(jsonb_build_object('id', w.id, 'message', w.message, 'created_at', w.created_at) order by w.id)
      from public.warnings w
      where w.user_id = auth.uid() and w.read_at is null
    ), '[]'::jsonb)
  );
end $$;

-- First time only: the member sets their own IRIAM ID. Staff can correct it later.
create or replace function public.set_my_iriam(iriam text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.members where user_id = auth.uid() and active) then
    raise exception 'not_member';
  end if;
  if iriam is null or char_length(btrim(iriam)) not between 1 and 64 then
    raise exception 'invalid_iriam';
  end if;
  update public.members set iriam_id = btrim(iriam)
   where user_id = auth.uid() and iriam_id is null;
end $$;

-- The member's own display name in the room (any time)
create or replace function public.set_my_nickname(nick text) returns void
language plpgsql security definer set search_path = public as $$
declare v text := btrim(regexp_replace(coalesce(nick, ''), '[[:cntrl:]]', '', 'g'));
begin
  if not exists (select 1 from public.members where user_id = auth.uid() and active) then
    raise exception 'not_member';
  end if;
  if char_length(v) not between 1 and 20 then raise exception 'invalid_nickname'; end if;
  update public.members set nickname = v where user_id = auth.uid();
end $$;

create or replace function public.ack_warning(wid bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.warnings set read_at = now()
   where id = wid and user_id = auth.uid() and read_at is null;
end $$;

-- Eraser: replace lines with the pieces left after rubbing.
-- removed = ids of the lines that were touched; pieces = [{id, p, src}] where src is one of removed.
-- Pieces keep the author, colour, width and time of their source line.
-- Only your own lines, unless you are staff.
create or replace function public.erase_strokes(removed text[], pieces jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  others int;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  if removed is null or coalesce(array_length(removed, 1), 0) = 0 then return; end if;
  if array_length(removed, 1) > 500 then raise exception 'too_many'; end if;

  select count(*) into others from public.strokes
   where id = any(removed) and user_id <> auth.uid();
  if others > 0 and not public.is_staff() then raise exception 'not_allowed'; end if;

  insert into public.strokes (id, user_id, c, w, p, t)
    select e->>'id', o.user_id, o.c, o.w, e->'p', o.t
    from jsonb_array_elements(coalesce(pieces, '[]'::jsonb)) e
    join public.strokes o on o.id = e->>'src'
    where o.id = any(removed);

  insert into public.stroke_trash (id, user_id, c, w, p, t, deleted_by)
    select id, user_id, c, w, p, t, auth.uid() from public.strokes where id = any(removed)
    on conflict (id) do nothing;

  if others > 0 then
    insert into public.mod_log (actor, action, target, detail)
      select auth.uid(), 'erase', s.user_id, count(*) || '本の線を消した'
      from public.strokes s
      where s.id = any(removed) and s.user_id <> auth.uid()
      group by s.user_id;
  end if;

  delete from public.strokes where id = any(removed);
end $$;

-- Undo of an eraser rub: put back lines you removed, take away the pieces it left.
create or replace function public.restore_strokes(trash_ids text[], remove_ids text[])
returns setof public.strokes
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  if exists (select 1 from public.strokes where id = any(coalesce(remove_ids, '{}')) and user_id <> auth.uid())
     and not public.is_staff() then
    raise exception 'not_allowed';
  end if;
  delete from public.strokes where id = any(coalesce(remove_ids, '{}'));
  return query
    with moved as (
      delete from public.stroke_trash
       where id = any(coalesce(trash_ids, '{}')) and deleted_by = auth.uid()
      returning id, user_id, c, w, p, t
    )
    insert into public.strokes (id, user_id, c, w, p, t)
      select id, user_id, c, w, p, t from moved
    returning *;
end $$;

-- ---------------------------------------------------------------------
-- 5. Functions for staff
-- ---------------------------------------------------------------------

drop function if exists public.staff_members();
create or replace function public.staff_members()
returns table (
  user_id uuid, display_name text, discord_name text, discord_id text, iriam_id text, role text,
  active boolean, verified_at timestamptz, stroke_count bigint, warning_count bigint,
  banned boolean, ban_until timestamptz, ban_reason text
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  return query
    select m.user_id, coalesce(m.nickname, m.display_name), m.display_name, m.discord_id, m.iriam_id, m.role, m.active, m.verified_at,
           (select count(*) from public.strokes s where s.user_id = m.user_id),
           (select count(*) from public.warnings w where w.user_id = m.user_id),
           (b.user_id is not null), b.until, b.reason
    from public.members m
    left join public.bans b
      on b.user_id = m.user_id and (b.until is null or b.until > now())
    order by coalesce(m.nickname, m.display_name);
end $$;

create or replace function public.staff_warn(target uuid, msg text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  insert into public.warnings (user_id, message, created_by) values (target, btrim(msg), auth.uid());
  insert into public.mod_log (actor, action, target, detail) values (auth.uid(), 'warn', target, btrim(msg));
end $$;

-- days = null -> no end date
create or replace function public.staff_ban(target uuid, days int, reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  if target = auth.uid() then raise exception 'cannot_ban_self'; end if;
  insert into public.bans (user_id, until, reason, created_by)
  values (target,
          case when days is null then null else now() + make_interval(days => days) end,
          coalesce(btrim(reason), ''), auth.uid())
  on conflict (user_id) do update
    set until = excluded.until, reason = excluded.reason,
        created_by = excluded.created_by, created_at = now();
  insert into public.mod_log (actor, action, target, detail)
  values (auth.uid(), 'ban', target,
          coalesce(days::text || '日', '無期限') || ' / ' || coalesce(btrim(reason), ''));
end $$;

create or replace function public.staff_unban(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  delete from public.bans where user_id = target;
  insert into public.mod_log (actor, action, target, detail) values (auth.uid(), 'unban', target, null);
end $$;

create or replace function public.staff_delete_user_strokes(target uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  insert into public.stroke_trash (id, user_id, c, w, p, t, deleted_by)
    select id, user_id, c, w, p, t, auth.uid() from public.strokes where user_id = target
    on conflict (id) do nothing;
  delete from public.strokes where user_id = target;
  get diagnostics n = row_count;
  insert into public.mod_log (actor, action, target, detail) values (auth.uid(), 'delete_all_of_user', target, n || '本');
  return n;
end $$;

create or replace function public.staff_clear_all() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  insert into public.stroke_trash (id, user_id, c, w, p, t, deleted_by)
    select id, user_id, c, w, p, t, auth.uid() from public.strokes
    on conflict (id) do nothing;
  delete from public.strokes where true;
  get diagnostics n = row_count;
  insert into public.mod_log (actor, action, target, detail) values (auth.uid(), 'clear_all', null, n || '本');
  return n;
end $$;

create or replace function public.staff_set_iriam(target uuid, iriam text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  update public.members set iriam_id = nullif(btrim(iriam), '') where user_id = target;
  insert into public.mod_log (actor, action, target, detail) values (auth.uid(), 'set_iriam', target, btrim(iriam));
end $$;

-- Only signed-in people may call the functions
revoke execute on function
  public.my_status(), public.set_my_iriam(text), public.set_my_nickname(text), public.ack_warning(bigint),
  public.erase_strokes(text[], jsonb), public.restore_strokes(text[], text[]),
  public.staff_members(), public.staff_warn(uuid, text), public.staff_ban(uuid, int, text),
  public.staff_unban(uuid), public.staff_delete_user_strokes(uuid), public.staff_clear_all(),
  public.staff_set_iriam(uuid, text)
from public, anon;
grant execute on function
  public.my_status(), public.set_my_iriam(text), public.set_my_nickname(text), public.ack_warning(bigint),
  public.erase_strokes(text[], jsonb), public.restore_strokes(text[], text[]),
  public.staff_members(), public.staff_warn(uuid, text), public.staff_ban(uuid, int, text),
  public.staff_unban(uuid), public.staff_delete_user_strokes(uuid), public.staff_clear_all(),
  public.staff_set_iriam(uuid, text)
to authenticated;

-- ---------------------------------------------------------------------
-- 6. Realtime
-- ---------------------------------------------------------------------

-- Change notifications for saved lines, warnings and bans
do $$
declare t text;
begin
  foreach t in array array['strokes', 'warnings', 'bans'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Private channel "room:main" (lines being drawn + who is here): members only
drop policy if exists "drawroom members receive" on realtime.messages;
create policy "drawroom members receive" on realtime.messages
  for select to authenticated using (public.is_member());

drop policy if exists "drawroom members send" on realtime.messages;
create policy "drawroom members send" on realtime.messages
  for insert to authenticated with check (public.is_member());

-- ---------------------------------------------------------------------
-- 7. Daily reset: clear the whole canvas every day at 10:30 JST
-- ---------------------------------------------------------------------

-- Moves every line to stroke_trash (deleted_by = all zeros = "automatic")
-- and drops trash older than 14 days.
create or replace function public.daily_clear() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into public.stroke_trash (id, user_id, c, w, p, t, deleted_by)
    select id, user_id, c, w, p, t, '00000000-0000-0000-0000-000000000000'::uuid from public.strokes
    on conflict (id) do nothing;
  delete from public.strokes where true;
  get diagnostics n = row_count;
  delete from public.stroke_trash where deleted_at < now() - interval '14 days';
  insert into public.mod_log (actor, action, target, detail) values (null, 'auto_clear', null, n || '本');
  return n;
end $$;
revoke execute on function public.daily_clear() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. Schedule (pg_cron runs in UTC: 01:30 UTC = 10:30 JST)
-- ---------------------------------------------------------------------
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;
select cron.schedule('drawroom-daily-clear', '30 1 * * *', 'select public.daily_clear()');
