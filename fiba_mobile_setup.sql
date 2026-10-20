create table if not exists public.fm_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  abbr text,
  ovr integer default 0,
  lvl integer default 1,
  wins integer default 0,
  losses integer default 0,
  deck text default '',
  r_chance double precision default 0,
  r_full double precision default 0,
  r_auto double precision default 0,
  updated_at timestamptz default now()
);
create unique index if not exists fm_profiles_name_key on public.fm_profiles (lower(name));

create table if not exists public.fm_saves (
  id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz default now()
);

create table if not exists public.fm_banned (
  id uuid primary key references auth.users(id) on delete cascade,
  reason text,
  at timestamptz default now()
);

create table if not exists public.fm_cheat_log (
  id bigserial primary key,
  uid uuid,
  name text,
  what text,
  old_bp numeric,
  new_bp numeric,
  old_gp numeric,
  new_gp numeric,
  at timestamptz default now()
);

create table if not exists public.fm_save_claims (
  fid text primary key,
  owner uuid not null references auth.users(id) on delete cascade default auth.uid()
);

create or replace function public.fm_is_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from auth.users
    where id = auth.uid() and email = 'p3eb4ba99e38dacc41a7e3290af6598e8ce009ce7@pixelhoops.app'
  );
$$;

create or replace function public.fm_is_banned() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.fm_banned where id = auth.uid());
$$;

alter table public.fm_profiles enable row level security;
alter table public.fm_saves enable row level security;
alter table public.fm_banned enable row level security;
alter table public.fm_cheat_log enable row level security;
alter table public.fm_save_claims enable row level security;

drop policy if exists fm_profiles_read on public.fm_profiles;
drop policy if exists fm_profiles_ins on public.fm_profiles;
drop policy if exists fm_profiles_upd on public.fm_profiles;
create policy fm_profiles_read on public.fm_profiles for select using (true);
create policy fm_profiles_ins on public.fm_profiles for insert
  with check (id = auth.uid() and not public.fm_is_banned() and (lower(name) <> 'woonn' or public.fm_is_admin()));
create policy fm_profiles_upd on public.fm_profiles for update
  using (id = auth.uid())
  with check (id = auth.uid() and not public.fm_is_banned() and (lower(name) <> 'woonn' or public.fm_is_admin()));

drop policy if exists fm_saves_read on public.fm_saves;
drop policy if exists fm_saves_ins on public.fm_saves;
drop policy if exists fm_saves_upd on public.fm_saves;
create policy fm_saves_read on public.fm_saves for select using (id = auth.uid() or public.fm_is_admin());
create policy fm_saves_ins on public.fm_saves for insert with check (id = auth.uid() and not public.fm_is_banned());
create policy fm_saves_upd on public.fm_saves for update
  using (id = auth.uid())
  with check (id = auth.uid() and not public.fm_is_banned());

drop policy if exists fm_banned_read on public.fm_banned;
drop policy if exists fm_banned_admin on public.fm_banned;
create policy fm_banned_read on public.fm_banned for select using (id = auth.uid() or public.fm_is_admin());
create policy fm_banned_admin on public.fm_banned for all using (public.fm_is_admin()) with check (public.fm_is_admin());

drop policy if exists fm_cheat_read on public.fm_cheat_log;
create policy fm_cheat_read on public.fm_cheat_log for select using (public.fm_is_admin());

drop policy if exists fm_claims_read on public.fm_save_claims;
drop policy if exists fm_claims_ins on public.fm_save_claims;
create policy fm_claims_read on public.fm_save_claims for select using (true);
create policy fm_claims_ins on public.fm_save_claims for insert with check (owner = auth.uid());

create or replace function public.fm_cheat_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare ob numeric; nb numeric; og numeric; ng numeric;
begin
  if coalesce(new.data->>'_adm', '0') <> coalesce(old.data->>'_adm', '0') then
    return new;
  end if;
  ob := coalesce(nullif(old.data->>'bp', '')::numeric, 0);
  nb := coalesce(nullif(new.data->>'bp', '')::numeric, 0);
  og := coalesce(nullif(old.data->>'gp', '')::numeric, 0);
  ng := coalesce(nullif(new.data->>'gp', '')::numeric, 0);
  if nb - ob > 100000 then
    insert into public.fm_cheat_log (uid, name, what, old_bp, new_bp, old_gp, new_gp)
    values (new.id, (select name from public.fm_profiles where id = new.id), 'BP 급증', ob, nb, og, ng);
  end if;
  return new;
exception when others then
  return new;
end;
$$;

drop trigger if exists fm_cheat on public.fm_saves;
create trigger fm_cheat after update on public.fm_saves
  for each row execute function public.fm_cheat_trg();

create or replace function public.fm_admin_give_bp(target text, amount bigint) returns numeric
language plpgsql security definer set search_path = public as $$
declare uid uuid; d jsonb; nb numeric;
begin
  if not public.fm_is_admin() then raise exception 'not admin'; end if;
  select id into uid from public.fm_profiles where lower(name) = lower(target) limit 1;
  if uid is null then raise exception 'no user'; end if;
  select data into d from public.fm_saves where id = uid for update;
  if d is null then raise exception 'no save'; end if;
  nb := greatest(0, coalesce(nullif(d->>'bp', '')::numeric, 0) + amount);
  if nb > 10000000 then raise exception 'too much'; end if;
  d := jsonb_set(jsonb_set(d, '{bp}', to_jsonb(nb)), '{_adm}', to_jsonb((extract(epoch from now()) * 1000)::bigint));
  update public.fm_saves set data = d, updated_at = now() where id = uid;
  return nb;
end;
$$;

revoke all on function public.fm_admin_give_bp(text, bigint) from public;
grant execute on function public.fm_admin_give_bp(text, bigint) to authenticated;
grant execute on function public.fm_is_admin() to anon, authenticated;
grant execute on function public.fm_is_banned() to anon, authenticated;
grant select on public.fm_profiles, public.fm_save_claims to anon, authenticated;
grant select, insert, update on public.fm_profiles, public.fm_saves to authenticated;
grant select, insert, update, delete on public.fm_banned to authenticated;
grant select on public.fm_cheat_log to authenticated;
grant insert on public.fm_save_claims to authenticated;
