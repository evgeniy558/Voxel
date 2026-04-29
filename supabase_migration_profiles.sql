-- Sphere: таблица профилей пользователей (Supabase)
-- Выполните в SQL Editor в Supabase Dashboard.

create table if not exists public.profiles (
  id uuid primary key default gen_random_uuid(),
  user_id text not null unique,
  email text,
  nickname text not null default '',
  username text not null default '',
  avatar_url text,
  bio text,
  auth_provider text not null default 'email',
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- RLS: разрешить анонимному ключу вставку/обновление по user_id (для мобильного клиента)
alter table public.profiles enable row level security;

-- Политика для анонимных запросов (до входа)
create policy "Allow anon to manage own profile by user_id"
  on public.profiles
  for all
  to anon
  using (true)
  with check (true);

-- Политика для авторизованных пользователей: только свой профиль (user_id = auth.uid())
-- После signInWithIdToken запросы идут с ролью authenticated — без этой политики будет "violates row-level security"
create policy "Allow authenticated to manage own profile"
  on public.profiles
  for all
  to authenticated
  using (user_id = (auth.uid())::text)
  with check (user_id = (auth.uid())::text);

-- Бакет для аватарок (в Storage создайте bucket "avatars", public)
-- В Dashboard: Storage -> New bucket -> avatars, Public bucket = on
