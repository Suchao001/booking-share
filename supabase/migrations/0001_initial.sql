-- Single-company MVP. Add users to team_members after creating them in Supabase Auth.

create extension if not exists btree_gist;

create table public.team_members (
  user_id uuid primary key references auth.users (id) on delete cascade,
  joined_at timestamptz not null default now()
);

create table public.rooms (
  id bigint generated always as identity primary key,
  name text not null unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.bookings (
  id bigint generated always as identity primary key,
  room_id bigint not null references public.rooms (id),
  title text not null check (length(btrim(title)) > 0),
  customer_count integer not null check (customer_count > 0),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'confirmed' check (status in ('confirmed', 'cancelled')),
  note text,
  created_at timestamptz not null default now(),
  constraint booking_time_order check (ends_at > starts_at),
  constraint no_overlapping_confirmed_bookings exclude using gist (
    room_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status = 'confirmed')
);

create index bookings_starts_at_idx on public.bookings (starts_at);

alter table public.team_members enable row level security;
alter table public.rooms enable row level security;
alter table public.bookings enable row level security;

create policy "Members can read their own membership"
on public.team_members for select to authenticated
using (user_id = (select auth.uid()));

create policy "Members can read rooms"
on public.rooms for select to authenticated
using (exists (
  select 1 from public.team_members m where m.user_id = (select auth.uid())
));

create policy "Members can read bookings"
on public.bookings for select to authenticated
using (exists (
  select 1 from public.team_members m where m.user_id = (select auth.uid())
));

create policy "Members can add bookings"
on public.bookings for insert to authenticated
with check (exists (
  select 1 from public.team_members m where m.user_id = (select auth.uid())
));

create policy "Members can edit or cancel bookings"
on public.bookings for update to authenticated
using (exists (
  select 1 from public.team_members m where m.user_id = (select auth.uid())
))
with check (exists (
  select 1 from public.team_members m where m.user_id = (select auth.uid())
));
