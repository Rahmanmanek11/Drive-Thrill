-- =====================================================================
-- BACKEND OJOL (Supabase / PostgreSQL) — dipakai bersama oleh:
--   1. Aplikasi Driver   2. Aplikasi Customer   3. Panel Admin
-- Jalankan SELURUH file ini di Supabase > SQL Editor > New query > Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- TABEL ----------
create table if not exists profiles (
  id uuid primary key references auth.users on delete cascade,
  role text not null default 'customer' check (role in ('customer','driver','admin')),
  full_name text,
  phone text,
  created_at timestamptz default now()
);

create table if not exists drivers (
  id uuid primary key references profiles(id) on delete cascade,
  vehicle_type text not null default 'motor' check (vehicle_type in ('motor','mobil')),
  vehicle_model text,
  plate text,
  approved boolean not null default false,   -- admin harus menyetujui dulu
  banned boolean not null default false,
  status text not null default 'offline' check (status in ('offline','online','busy')),
  lat double precision,
  lng double precision,
  last_seen timestamptz,
  rating numeric(3,2) not null default 5.00,
  total_trips int not null default 0,
  balance bigint not null default 0,          -- saldo deposit (komisi dipotong dari sini)
  created_at timestamptz default now()
);

create table if not exists settings (
  key text primary key,
  value numeric not null
);
insert into settings(key,value) values
  ('commission_pct',10),
  ('base_fare_motor',5000), ('per_km_motor',2500),
  ('base_fare_mobil',8000), ('per_km_mobil',4000),
  ('dispatch_radius_km',5),
  ('offer_seconds',30),
  ('min_balance',-50000)
on conflict (key) do nothing;

create table if not exists orders (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references profiles(id),
  driver_id uuid references profiles(id),
  service text not null default 'motor' check (service in ('motor','mobil')),
  pickup_address text, pickup_lat double precision not null, pickup_lng double precision not null,
  dest_address text,   dest_lat double precision not null,   dest_lng double precision not null,
  distance_km numeric(7,2),
  fare bigint,
  payment text not null default 'cash',
  status text not null default 'searching'
    check (status in ('searching','accepted','arrived','ongoing','completed','cancelled')),
  cancel_reason text,
  cancelled_by text,
  search_started_at timestamptz default now(),
  created_at timestamptz default now(),
  accepted_at timestamptz, arrived_at timestamptz, started_at timestamptz, completed_at timestamptz
);
create index if not exists orders_driver_idx on orders(driver_id, status);
create index if not exists orders_customer_idx on orders(customer_id, status);

create table if not exists order_offers (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  driver_id uuid not null references drivers(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','rejected','expired')),
  expires_at timestamptz not null,
  created_at timestamptz default now(),
  unique(order_id, driver_id)
);
create index if not exists offers_driver_idx on order_offers(driver_id, status);

create table if not exists wallet_tx (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references drivers(id) on delete cascade,
  order_id uuid references orders(id),
  amount bigint not null,                      -- negatif = potongan, positif = top up
  type text not null check (type in ('commission','topup','adjustment')),
  note text,
  created_at timestamptz default now()
);

-- ---------- FUNGSI BANTU ----------
create or replace function haversine_km(a1 double precision, o1 double precision, a2 double precision, o2 double precision)
returns double precision language sql immutable as $$
  select 6371 * acos(least(1, greatest(-1,
    cos(radians(a1))*cos(radians(a2))*cos(radians(o2)-radians(o1)) + sin(radians(a1))*sin(radians(a2)))));
$$;

create or replace function is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

-- ---------- REGISTRASI OTOMATIS ----------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare r text := coalesce(new.raw_user_meta_data->>'role','customer'); vt text;
begin
  if r not in ('customer','driver') then r := 'customer'; end if;   -- admin hanya lewat SQL manual
  insert into profiles(id, role, full_name, phone)
  values (new.id, r, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'phone');
  if r = 'driver' then
    vt := new.raw_user_meta_data->>'vehicle_type';
    if vt not in ('motor','mobil') or vt is null then vt := 'motor'; end if;
    insert into drivers(id, vehicle_type, vehicle_model, plate)
    values (new.id, vt, new.raw_user_meta_data->>'vehicle_model', upper(new.raw_user_meta_data->>'plate'));
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- ORDER: tarif dihitung SERVER (anti curang) ----------
create or replace function orders_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare base numeric; perkm numeric; dist numeric;
begin
  dist := haversine_km(new.pickup_lat,new.pickup_lng,new.dest_lat,new.dest_lng) * 1.3; -- faktor jalan
  select value into base  from settings where key = 'base_fare_' || new.service;
  select value into perkm from settings where key = 'per_km_'   || new.service;
  new.distance_km := round(dist, 2);
  new.fare := greatest(base, round((base + perkm * dist) / 500) * 500);
  new.status := 'searching';
  new.driver_id := null;
  new.search_started_at := now();
  return new;
end $$;
drop trigger if exists orders_bi on orders;
create trigger orders_bi before insert on orders for each row execute function orders_before_insert();

-- ---------- DISPATCH: cari driver terdekat & kirim tawaran ----------
create or replace function dispatch_order(p_order uuid) returns int
language plpgsql security definer set search_path = public as $$
declare o orders; rad numeric; secs numeric; n int;
begin
  select * into o from orders where id = p_order and status = 'searching';
  if not found then return 0; end if;
  select value into rad  from settings where key = 'dispatch_radius_km';
  select value into secs from settings where key = 'offer_seconds';

  with c as (
    select d.id,
           haversine_km(d.lat,d.lng,o.pickup_lat,o.pickup_lng) as dist
    from drivers d
    where d.status = 'online' and d.approved and not d.banned
      and d.vehicle_type = o.service
      and d.lat is not null and d.last_seen > now() - interval '2 minutes'
      and not exists (select 1 from order_offers f where f.order_id = o.id and f.driver_id = d.id)
      and haversine_km(d.lat,d.lng,o.pickup_lat,o.pickup_lng) <= rad
    order by dist limit 5
  )
  insert into order_offers(order_id, driver_id, expires_at)
  select o.id, c.id, now() + make_interval(secs => secs::double precision) from c;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function dispatch_order(uuid) from public, anon, authenticated;

create or replace function orders_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform dispatch_order(new.id); return new; end $$;
drop trigger if exists orders_ai on orders;
create trigger orders_ai after insert on orders for each row execute function orders_after_insert();

-- Bila order dibatalkan: bebaskan driver & tutup tawaran
create or replace function orders_after_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    if old.driver_id is not null then
      update drivers set status = 'online' where id = old.driver_id and status = 'busy';
    end if;
    update order_offers set status = 'expired' where order_id = new.id and status = 'pending';
  end if;
  return new;
end $$;
drop trigger if exists orders_au on orders;
create trigger orders_au after update on orders for each row execute function orders_after_update();

-- ---------- RPC UNTUK APLIKASI DRIVER ----------
create or replace function driver_update_location(p_lat double precision, p_lng double precision)
returns void language sql security definer set search_path = public as $$
  update drivers set lat = p_lat, lng = p_lng, last_seen = now() where id = auth.uid();
$$;

create or replace function driver_set_status(p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d drivers; minb numeric;
begin
  select * into d from drivers where id = auth.uid();
  if not found then return jsonb_build_object('ok',false,'msg','Bukan akun driver'); end if;
  if d.banned or not d.approved then return jsonb_build_object('ok',false,'msg','Akun belum aktif'); end if;
  if p_status not in ('online','offline') then return jsonb_build_object('ok',false,'msg','Status tidak valid'); end if;
  if d.status = 'busy' then return jsonb_build_object('ok',false,'msg','Selesaikan order yang sedang berjalan'); end if;
  if p_status = 'online' then
    select value into minb from settings where key = 'min_balance';
    if d.balance < minb then
      return jsonb_build_object('ok',false,'msg','Saldo deposit kurang. Hubungi admin untuk top up.');
    end if;
  end if;
  update drivers set status = p_status, last_seen = now() where id = d.id;
  return jsonb_build_object('ok',true);
end $$;

create or replace function accept_offer(p_offer uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f order_offers; cnt int;
begin
  select * into f from order_offers
   where id = p_offer and driver_id = auth.uid() and status = 'pending' and expires_at > now()
   for update;
  if not found then return jsonb_build_object('ok',false,'msg','Tawaran sudah kedaluwarsa'); end if;

  update orders set driver_id = auth.uid(), status = 'accepted', accepted_at = now()
   where id = f.order_id and status = 'searching' and driver_id is null;
  get diagnostics cnt = row_count;
  if cnt = 0 then
    update order_offers set status = 'expired' where id = p_offer;
    return jsonb_build_object('ok',false,'msg','Order sudah diambil driver lain');
  end if;

  update order_offers set status = 'accepted' where id = p_offer;
  update order_offers set status = 'expired' where order_id = f.order_id and id <> p_offer and status = 'pending';
  update drivers set status = 'busy' where id = auth.uid();
  return jsonb_build_object('ok',true,'order_id',f.order_id);
end $$;

create or replace function reject_offer(p_offer uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f order_offers;
begin
  update order_offers set status = 'rejected'
   where id = p_offer and driver_id = auth.uid() and status = 'pending'
   returning * into f;
  if found then perform dispatch_order(f.order_id); end if;   -- langsung cari driver berikutnya
  return jsonb_build_object('ok',true);
end $$;

create or replace function driver_update_order(p_order uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o orders; pct numeric; com bigint;
begin
  select * into o from orders where id = p_order and driver_id = auth.uid() for update;
  if not found then return jsonb_build_object('ok',false,'msg','Order tidak ditemukan'); end if;

  if o.status = 'accepted' and p_status = 'arrived' then
    update orders set status = 'arrived', arrived_at = now() where id = o.id;
  elsif o.status = 'arrived' and p_status = 'ongoing' then
    update orders set status = 'ongoing', started_at = now() where id = o.id;
  elsif o.status = 'ongoing' and p_status = 'completed' then
    select value into pct from settings where key = 'commission_pct';
    com := round(o.fare * pct / 100);
    update orders set status = 'completed', completed_at = now() where id = o.id;
    insert into wallet_tx(driver_id, order_id, amount, type, note)
      values (auth.uid(), o.id, -com, 'commission', 'Komisi ' || pct || '%');
    update drivers set balance = balance - com, total_trips = total_trips + 1, status = 'online'
      where id = auth.uid();
    return jsonb_build_object('ok',true,'fare',o.fare,'commission',com);
  else
    return jsonb_build_object('ok',false,'msg','Perubahan status tidak valid');
  end if;
  return jsonb_build_object('ok',true);
end $$;

create or replace function driver_cancel_order(p_order uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders
   where id = p_order and driver_id = auth.uid() and status in ('accepted','arrived') for update;
  if not found then return jsonb_build_object('ok',false,'msg','Order tidak bisa dibatalkan'); end if;
  -- order dikembalikan ke pencarian driver lain (driver ini tidak ditawari lagi)
  update orders set status = 'searching', driver_id = null, accepted_at = null, arrived_at = null,
         cancel_reason = 'Driver batal: ' || coalesce(p_reason,'-'), search_started_at = now()
   where id = o.id;
  update drivers set status = 'online' where id = auth.uid();
  perform dispatch_order(o.id);
  return jsonb_build_object('ok',true);
end $$;

-- Dipanggil berkala oleh aplikasi (atau pg_cron): tutup tawaran kadaluwarsa,
-- cari driver lain, batalkan order yang tidak dapat driver > 3 menit
create or replace function expire_offers() returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  update order_offers set status = 'expired' where status = 'pending' and expires_at < now();
  update orders set status = 'cancelled', cancelled_by = 'system', cancel_reason = 'Driver tidak ditemukan'
   where status = 'searching' and search_started_at < now() - interval '3 minutes';
  for r in
    select id from orders o where o.status = 'searching'
      and not exists (select 1 from order_offers f where f.order_id = o.id and f.status = 'pending')
  loop
    perform dispatch_order(r.id);
  end loop;
end $$;

grant execute on function driver_update_location(double precision,double precision) to authenticated;
grant execute on function driver_set_status(text) to authenticated;
grant execute on function accept_offer(uuid) to authenticated;
grant execute on function reject_offer(uuid) to authenticated;
grant execute on function driver_update_order(uuid,text) to authenticated;
grant execute on function driver_cancel_order(uuid,text) to authenticated;
grant execute on function expire_offers() to authenticated;

-- ---------- KEAMANAN (Row Level Security) ----------
alter table profiles enable row level security;
alter table drivers enable row level security;
alter table settings enable row level security;
alter table orders enable row level security;
alter table order_offers enable row level security;
alter table wallet_tx enable row level security;

-- profiles
create policy "profil sendiri/admin" on profiles for select
  using (id = auth.uid() or is_admin()
         or exists (select 1 from orders o where o.customer_id = profiles.id and o.driver_id = auth.uid())
         or exists (select 1 from orders o where o.driver_id = profiles.id and o.customer_id = auth.uid()));
create policy "admin ubah profil" on profiles for update using (is_admin());

-- drivers (ubah hanya lewat RPC / admin)
create policy "driver sendiri/admin/customer aktif" on drivers for select
  using (id = auth.uid() or is_admin()
         or exists (select 1 from orders o where o.driver_id = drivers.id and o.customer_id = auth.uid()
                    and o.status in ('accepted','arrived','ongoing')));
create policy "admin ubah driver" on drivers for update using (is_admin());

-- settings
create policy "baca pengaturan" on settings for select using (auth.uid() is not null);
create policy "admin ubah pengaturan" on settings for all using (is_admin()) with check (is_admin());

-- orders
create policy "customer lihat order" on orders for select using (customer_id = auth.uid());
create policy "customer buat order" on orders for insert with check (customer_id = auth.uid());
create policy "customer batalkan" on orders for update
  using (customer_id = auth.uid() and status in ('searching','accepted','arrived'))
  with check (status = 'cancelled');
create policy "driver lihat order" on orders for select
  using (driver_id = auth.uid()
         or exists (select 1 from order_offers f where f.order_id = orders.id and f.driver_id = auth.uid()));
create policy "admin kelola order" on orders for all using (is_admin()) with check (is_admin());

-- offers
create policy "driver lihat tawaran" on order_offers for select using (driver_id = auth.uid() or is_admin());

-- wallet
create policy "driver lihat dompet" on wallet_tx for select using (driver_id = auth.uid() or is_admin());
create policy "admin kelola dompet" on wallet_tx for insert with check (is_admin());

-- ---------- REALTIME ----------
alter publication supabase_realtime add table orders, order_offers, drivers;

-- ---------- JADIKAN AKUN ANDA ADMIN (jalankan setelah daftar lewat aplikasi) ----------
-- update profiles set role = 'admin' where id = (select id from auth.users where email = 'EMAIL_ANDA');
-- Setujui driver:  update drivers set approved = true where id = '<uuid driver>';
-- Top up driver:   insert into wallet_tx(driver_id,amount,type,note) values('<uuid>',100000,'topup','Top up');
--                  update drivers set balance = balance + 100000 where id = '<uuid>';
