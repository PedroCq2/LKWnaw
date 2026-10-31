-- Síť parkovišť LKWnav: místa od řidičů (+ opravy míst z OpenStreetMap) a hlášení obsazenosti.
--
-- Spuštění: Supabase → SQL Editor → vložit a spustit (nebo `psql -f schema.sql` na vlastním
-- PostgreSQL s PostgRESTem). Skript jde spustit opakovaně.
--
-- Aplikace pak při sestavení dostane adresu REST API a veřejný klíč:
--   flutter build apk --dart-define=NET_URL=https://<projekt>.supabase.co/rest/v1 \
--                     --dart-define=NET_KEY=<publishable / anon key>
--
-- Čtení: tabulka net_places (všichni) a funkce net_status (obsazenost za poslední 3 h).
-- Zápis: jen funkce net_save_place / net_report – kontrolují údaje, mají limity proti spamu
-- a ukládají historii. Id zařízení (náhodné, z instalace aplikace) se ven nevydává.

-- Role PostgRESTu (Supabase je má; na vlastním serveru se vytvoří).
do $$ begin
  if not exists (select from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;
grant usage on schema public to anon, authenticated;

create table if not exists public.net_places (
  id         text primary key check (id ~ '^(u:[0-9a-z]{6,24}|osm:[nwr][0-9]{1,12})$'),
  name       text not null check (char_length(name) between 1 and 80),
  lat        double precision not null check (lat between 34 and 72),
  lon        double precision not null check (lon between -25 and 45),
  type       text not null check (type in ('truckpark', 'rest_area', 'services', 'parking', 'industrial', 'other')),
  capacity   int check (capacity between 0 and 2000),
  fee        text check (fee in ('free', 'paid')),
  amenities  text[] not null default '{}' check (
    amenities <@ array['wc', 'shower', 'food', 'shop', 'fuel', 'adblue', 'guarded', 'fenced', 'lit', 'wifi', 'hotel', 'nonstop']
  ),
  note       text check (char_length(note) <= 300),
  hidden     boolean not null default false, -- tři řidiči nahlásili „neexistuje“
  edits      int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists net_places_lat_lon on public.net_places (lat, lon);

-- Každá změna místa (kdo a co) – pro opravu vandalismu. Jen pro správce.
create table if not exists public.net_place_edits (
  id       bigint generated always as identity primary key,
  place_id text not null,
  device   text not null,
  at       timestamptz not null default now(),
  data     jsonb not null
);
create index if not exists net_place_edits_device on public.net_place_edits (device, at desc);

-- Hlášení obsazenosti (free / limited / full) a zrušení místa (gone). Jen pro správce.
create table if not exists public.net_reports (
  id         bigint generated always as identity primary key,
  place_id   text not null check (char_length(place_id) <= 40),
  lat        double precision not null check (lat between 34 and 72),
  lon        double precision not null check (lon between -25 and 45),
  kind       text not null check (kind in ('free', 'limited', 'full', 'gone')),
  device     text not null check (char_length(device) between 8 and 64),
  created_at timestamptz not null default now()
);
create index if not exists net_reports_recent on public.net_reports (created_at desc);
create index if not exists net_reports_place on public.net_reports (place_id, created_at desc);
create index if not exists net_reports_device on public.net_reports (device, created_at desc);

alter table public.net_places enable row level security;
alter table public.net_place_edits enable row level security;
alter table public.net_reports enable row level security;

drop policy if exists net_places_read on public.net_places;
create policy net_places_read on public.net_places for select to anon, authenticated using (true);

revoke insert, update, delete, truncate on public.net_places from anon, authenticated;
revoke all on public.net_place_edits, public.net_reports from anon, authenticated;
grant select on public.net_places to anon, authenticated;

-- Přidání / úprava místa. p = {id, name, lat, lon, type, capacity, fee, amenities[], note, device}.
create or replace function public.net_save_place(p jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_id     text := p ->> 'id';
  v_device text := p ->> 'device';
  v_lat    double precision := (p ->> 'lat')::double precision;
  v_lon    double precision := (p ->> 'lon')::double precision;
  v_old    public.net_places;
begin
  if v_device is null or char_length(v_device) not between 8 and 64 then
    raise exception 'chybí zařízení' using errcode = '22023';
  end if;
  if (select count(*) from public.net_place_edits e where e.device = v_device and e.at > now() - interval '1 day') >= 60 then
    raise exception 'příliš mnoho změn' using errcode = 'PT429';
  end if;
  select * into v_old from public.net_places where id = v_id;
  -- Existující místo jde posunout nejvýš o 300 m (oprava polohy, ne přesun jinam).
  if v_old.id is not null and sqrt(power((v_lat - v_old.lat) * 111320, 2)
       + power((v_lon - v_old.lon) * 111320 * cos(radians(v_old.lat)), 2)) > 300 then
    v_lat := v_old.lat;
    v_lon := v_old.lon;
  end if;
  insert into public.net_places as t (id, name, lat, lon, type, capacity, fee, amenities, note)
  values (
    v_id,
    left(coalesce(nullif(trim(p ->> 'name'), ''), 'Parkoviště'), 80),
    v_lat,
    v_lon,
    p ->> 'type',
    (p ->> 'capacity')::int,
    p ->> 'fee',
    coalesce(array(select jsonb_array_elements_text(p -> 'amenities')), '{}'),
    nullif(left(trim(p ->> 'note'), 300), '')
  )
  on conflict (id) do update set
    name = excluded.name, lat = excluded.lat, lon = excluded.lon, type = excluded.type,
    capacity = excluded.capacity, fee = excluded.fee, amenities = excluded.amenities, note = excluded.note,
    edits = t.edits + 1, updated_at = now();
  insert into public.net_place_edits (place_id, device, data) values (v_id, v_device, p - 'device');
end $$;

-- Hlášení obsazenosti / zrušení. r = {place_id, lat, lon, kind, device, created_at}.
create or replace function public.net_report(r jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_place  text := r ->> 'place_id';
  v_kind   text := r ->> 'kind';
  v_device text := r ->> 'device';
  v_at     timestamptz := coalesce((r ->> 'created_at')::timestamptz, now());
begin
  -- Hlášení odeslané později (bez signálu) si nechá svůj čas, ale ne z budoucnosti ani starší než den.
  if v_at > now() or v_at < now() - interval '1 day' then
    v_at := now();
  end if;
  if (select count(*) from public.net_reports x where x.device = v_device and x.created_at > now() - interval '1 hour') >= 30 then
    raise exception 'příliš mnoho hlášení' using errcode = 'PT429';
  end if;
  insert into public.net_reports (place_id, lat, lon, kind, device, created_at)
  values (v_place, (r ->> 'lat')::double precision, (r ->> 'lon')::double precision, v_kind, v_device, v_at);
  -- Tři různí řidiči za 60 dní: „neexistuje“ → místo se všem skryje (i místo z OSM).
  if v_kind = 'gone' and (
    select count(distinct x.device) from public.net_reports x
    where x.place_id = v_place and x.kind = 'gone' and x.created_at > now() - interval '60 days'
  ) >= 3 then
    insert into public.net_places (id, name, lat, lon, type, hidden)
    values (v_place, 'Zrušené místo', (r ->> 'lat')::double precision, (r ->> 'lon')::double precision, 'other', true)
    on conflict (id) do update set hidden = true, updated_at = now();
  end if;
end $$;

-- Obsazenost v oblasti: poslední hlášení každého místa za 3 hodiny (bez id zařízení).
create or replace function public.net_status(a double precision, b double precision, c double precision, d double precision)
returns table (place_id text, lat double precision, lon double precision, kind text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select distinct on (x.place_id) x.place_id, x.lat, x.lon, x.kind, x.created_at
  from public.net_reports x
  where x.kind in ('free', 'limited', 'full')
    and x.created_at > now() - interval '3 hours'
    and x.lat between a and b and x.lon between c and d
  order by x.place_id, x.created_at desc
  limit 1000;
$$;

revoke all on function public.net_save_place(jsonb), public.net_report(jsonb),
  public.net_status(double precision, double precision, double precision, double precision) from public;
grant execute on function public.net_save_place(jsonb), public.net_report(jsonb),
  public.net_status(double precision, double precision, double precision, double precision) to anon, authenticated;

-- ---------------------------------------------------------------- rychlosti od řidičů

-- Řidič nahlásil, co je na značce (pro kamiony), když mapa ukazuje jinou rychlost. Jen pro správce.
create table if not exists public.speed_reports (
  id         bigint generated always as identity primary key,
  way_id     bigint not null check (way_id > 0),
  lat        double precision not null check (lat between 34 and 72),
  lon        double precision not null check (lon between -25 and 45),
  shown      int check (shown between 0 and 250),
  kmh        int not null check (kmh between 5 and 150),
  device     text not null check (char_length(device) between 8 and 64),
  created_at timestamptz not null default now()
);
create index if not exists speed_reports_way on public.speed_reports (way_id, created_at desc);
create index if not exists speed_reports_device on public.speed_reports (device, created_at desc);
alter table public.speed_reports enable row level security;
revoke all on public.speed_reports from anon, authenticated;

-- r = {way_id, lat, lon, shown, kmh, device}.
create or replace function public.speed_report(r jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_device text := r ->> 'device';
begin
  if (select count(*) from public.speed_reports x where x.device = v_device and x.created_at > now() - interval '1 day') >= 60 then
    raise exception 'příliš mnoho hlášení' using errcode = 'PT429';
  end if;
  insert into public.speed_reports (way_id, lat, lon, shown, kmh, device)
  values ((r ->> 'way_id')::bigint, (r ->> 'lat')::double precision, (r ->> 'lon')::double precision,
          (r ->> 'shown')::int, (r ->> 'kmh')::int, v_device);
end $$;

-- Opravy pro cesty OSM: hodnota, kterou za rok shodně nahlásili aspoň dva různí řidiči
-- (u každého řidiče jeho poslední hlášení).
create or replace function public.speed_fixes(ids bigint[])
returns table (way_id bigint, kmh int)
language sql stable security definer set search_path = '' as $$
  with latest as (
    select distinct on (x.way_id, x.device) x.way_id, x.device, x.kmh
    from public.speed_reports x
    where x.way_id = any (ids[1:5000]) and x.created_at > now() - interval '365 days'
    order by x.way_id, x.device, x.created_at desc
  ), votes as (
    select l.way_id, l.kmh, count(*) as n from latest l group by l.way_id, l.kmh
  )
  select distinct on (v.way_id) v.way_id, v.kmh::int
  from votes v
  where v.n >= 2
  order by v.way_id, v.n desc, v.kmh;
$$;

-- ---------------------------------------------------------------- zprávy z aplikace

-- Chyba / vylepšení / nová funkce (zatřesení telefonem) se systémovými informacemi. Jen pro správce
-- (Supabase → Table Editor → app_feedback; status: new / seen / done / rejected).
create table if not exists public.app_feedback (
  id          bigint generated always as identity primary key,
  kind        text not null check (kind in ('bug', 'improvement', 'feature')),
  message     text not null check (char_length(message) between 1 and 4000),
  info        jsonb check (info is null or pg_column_size(info) <= 32768),
  app_version text check (char_length(app_version) <= 40),
  device      text not null check (char_length(device) between 8 and 64),
  status      text not null default 'new' check (status in ('new', 'seen', 'done', 'rejected')),
  created_at  timestamptz not null default now()
);
create index if not exists app_feedback_status on public.app_feedback (status, created_at desc);
alter table public.app_feedback enable row level security;
revoke all on public.app_feedback from anon, authenticated;

-- f = {kind, message, info{}, app_version, device}.
create or replace function public.send_feedback(f jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_device text := f ->> 'device';
begin
  if (select count(*) from public.app_feedback x where x.device = v_device and x.created_at > now() - interval '1 day') >= 30 then
    raise exception 'příliš mnoho zpráv' using errcode = 'PT429';
  end if;
  insert into public.app_feedback (kind, message, info, app_version, device)
  values (f ->> 'kind', left(trim(f ->> 'message'), 4000),
          case when jsonb_typeof(f -> 'info') = 'object' then f -> 'info' end,
          left(f ->> 'app_version', 40), v_device);
end $$;

revoke all on function public.speed_report(jsonb), public.speed_fixes(bigint[]), public.send_feedback(jsonb) from public;
grant execute on function public.speed_report(jsonb), public.speed_fixes(bigint[]), public.send_feedback(jsonb)
  to anon, authenticated;
