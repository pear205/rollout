-- =====================================================================
--  오늘도 출동 (Roll Out) — Supabase 초기 스키마
--  Supabase 대시보드 → SQL Editor에 통째로 붙여넣고 Run 하세요.
--  한 번만 실행하면 됩니다. (여러 번 실행해도 안전하도록 작성)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. profiles : 닉네임 + 개인 설정
--    auth.users는 Supabase가 관리하는 테이블이라 직접 건드리지 않고,
--    여기에 우리 앱이 필요한 정보만 붙입니다.
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  nickname   text not null default '이름 없는 부모',
  -- 아이 정보, 상비 목록 등 개인 설정 전체를 통째로 보관
  -- (초기엔 스키마를 자주 바꾸게 되므로 jsonb가 편합니다)
  settings   jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- 2. kits : 공유 가능한 준비물 킷
-- ---------------------------------------------------------------------
create table if not exists public.kits (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete cascade,
  title        text not null check (char_length(title) between 1 and 60),
  description  text check (char_length(description) <= 200),

  -- 조건: {ageM, hours, startT, temp, sky, places[], transport, feeding}
  conditions   jsonb not null default '{}'::jsonb,
  -- 아이템: [{id, name, qty, note}] — 규칙 엔진 결과를 사용자가 손본 최종본
  items        jsonb not null default '[]'::jsonb,

  is_public    boolean not null default false,

  -- ratings 테이블에서 트리거로 자동 갱신됩니다. 직접 쓰지 마세요.
  rating_avg   numeric(3,2) not null default 0,
  rating_count integer      not null default 0,

  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists kits_public_idx
  on public.kits (rating_avg desc, rating_count desc)
  where is_public;

create index if not exists kits_owner_idx on public.kits (owner_id);

-- 조건으로 킷을 검색하려면 (예: 야외 + 여름) jsonb 인덱스가 필요합니다
create index if not exists kits_conditions_idx on public.kits using gin (conditions);


-- ---------------------------------------------------------------------
-- 3. ratings : 별점 + 한 줄 평 (사용자당 킷 1표)
-- ---------------------------------------------------------------------
create table if not exists public.ratings (
  kit_id     uuid not null references public.kits(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  score      smallint not null check (score between 1 and 5),
  comment    text check (char_length(comment) <= 300),
  created_at timestamptz not null default now(),
  primary key (kit_id, user_id)          -- 중복 투표 원천 차단
);

create index if not exists ratings_kit_idx on public.ratings (kit_id);


-- ---------------------------------------------------------------------
-- 4. 트리거
-- ---------------------------------------------------------------------

-- 4-1. 가입하면 profiles 행을 자동 생성
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, nickname)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'name',
      split_part(new.email, '@', 1),
      '이름 없는 부모'
    )
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- 4-2. 별점이 바뀌면 kits의 집계값을 다시 계산
--      (조회할 때마다 avg()를 돌리면 목록 정렬이 느려집니다)
create or replace function public.refresh_kit_rating()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  target uuid := coalesce(new.kit_id, old.kit_id);
begin
  update public.kits k
  set rating_avg   = coalesce(r.avg_score, 0),
      rating_count = coalesce(r.cnt, 0)
  from (
    select avg(score)::numeric(3,2) as avg_score, count(*) as cnt
    from public.ratings where kit_id = target
  ) r
  where k.id = target;
  return null;
end;
$$;

drop trigger if exists on_rating_changed on public.ratings;
create trigger on_rating_changed
  after insert or update or delete on public.ratings
  for each row execute function public.refresh_kit_rating();


-- 4-3. updated_at 자동 갱신
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_kit_updated on public.kits;
create trigger on_kit_updated
  before update on public.kits
  for each row execute function public.touch_updated_at();


-- =====================================================================
-- 5. RLS — 이 부분이 보안의 전부입니다. anon key를 HTML에 노출해도
--    안전한 이유가 여기 있습니다. 절대 끄지 마세요.
-- =====================================================================
alter table public.profiles enable row level security;
alter table public.kits     enable row level security;
alter table public.ratings  enable row level security;


-- ---- profiles ----
-- 닉네임은 공개 킷 목록에 표시돼야 하므로 읽기는 전체 허용
drop policy if exists "프로필 읽기" on public.profiles;
create policy "프로필 읽기" on public.profiles
  for select using (true);

drop policy if exists "내 프로필만 수정" on public.profiles;
create policy "내 프로필만 수정" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);


-- ---- kits ----
-- 공개된 킷 또는 내 킷만 보인다
drop policy if exists "공개 킷과 내 킷 읽기" on public.kits;
create policy "공개 킷과 내 킷 읽기" on public.kits
  for select using (is_public or auth.uid() = owner_id);

-- owner_id를 남의 것으로 위조해서 저장하는 것을 막는다
drop policy if exists "내 킷만 생성" on public.kits;
create policy "내 킷만 생성" on public.kits
  for insert with check (auth.uid() = owner_id);

drop policy if exists "내 킷만 수정" on public.kits;
create policy "내 킷만 수정" on public.kits
  for update using (auth.uid() = owner_id) with check (auth.uid() = owner_id);

drop policy if exists "내 킷만 삭제" on public.kits;
create policy "내 킷만 삭제" on public.kits
  for delete using (auth.uid() = owner_id);


-- ---- ratings ----
drop policy if exists "평가 읽기" on public.ratings;
create policy "평가 읽기" on public.ratings
  for select using (
    exists (select 1 from public.kits k
            where k.id = kit_id and (k.is_public or k.owner_id = auth.uid()))
  );

-- 공개 킷에만, 본인 이름으로, 내 킷이 아닌 것에만 평가 가능
drop policy if exists "남의 공개 킷에만 평가" on public.ratings;
create policy "남의 공개 킷에만 평가" on public.ratings
  for insert with check (
    auth.uid() = user_id
    and exists (
      select 1 from public.kits k
      where k.id = kit_id and k.is_public and k.owner_id <> auth.uid()
    )
  );

drop policy if exists "내 평가만 수정" on public.ratings;
create policy "내 평가만 수정" on public.ratings
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "내 평가만 삭제" on public.ratings;
create policy "내 평가만 삭제" on public.ratings
  for delete using (auth.uid() = user_id);


-- =====================================================================
-- 5-B. Data API 노출 권한 (GRANT)
--
--   프로젝트 생성 시 "Automatically expose new tables"를 껐다면 이 블록이
--   필요합니다. 켜뒀다면 실행해도 무해합니다(이미 있는 권한을 다시 줄 뿐).
--
--   GRANT와 RLS는 층이 다릅니다:
--     GRANT = "이 테이블을 API로 만질 수 있는가" (테이블 단위)
--     RLS   = "그중 어떤 행을 만질 수 있는가"    (행 단위)
--   둘 다 통과해야 데이터가 나옵니다. 그래서 GRANT를 줘도 안전합니다.
--
--   anon          = 로그인하지 않은 방문자
--   authenticated = 로그인한 사용자
-- =====================================================================
grant usage on schema public to anon, authenticated;

-- profiles : 닉네임은 누구나 읽고, 수정은 로그인 사용자만 (RLS가 본인 행으로 제한)
grant select on public.profiles to anon, authenticated;
grant update on public.profiles to authenticated;

-- kits : 공개 킷은 비로그인도 구경 가능 (RLS가 is_public으로 걸러줌)
grant select on public.kits to anon, authenticated;
grant insert, update, delete on public.kits to authenticated;

-- ratings : 별점은 로그인해야 남길 수 있음
grant select on public.ratings to anon, authenticated;
grant insert, update, delete on public.ratings to authenticated;


-- =====================================================================
-- 6. 목록 조회용 뷰 — 킷 + 작성자 닉네임을 한 번에
--    security_invoker: 뷰를 조회한 사람의 권한으로 실행 → RLS가 그대로 적용됨
-- =====================================================================
create or replace view public.kits_with_author
with (security_invoker = on) as
select
  k.id, k.title, k.description, k.conditions, k.items,
  k.rating_avg, k.rating_count, k.created_at,
  k.owner_id, p.nickname as author
from public.kits k
join public.profiles p on p.id = k.owner_id
where k.is_public;

grant select on public.kits_with_author to anon, authenticated;


-- =====================================================================
-- 7. 확인용 쿼리
--    아래 두 줄의 주석을 풀고 실행해서 결과를 확인하세요.
-- =====================================================================

-- (1) RLS가 세 테이블 모두 true여야 합니다
-- select tablename, rowsecurity from pg_tables
--  where schemaname = 'public' and tablename in ('profiles','kits','ratings');

-- (2) 정책이 10개 잡혀야 합니다
--     profiles 2 (읽기/수정) + kits 4 + ratings 4
--     profiles에 INSERT 정책이 없는 이유: 가입 시 handle_new_user 트리거가
--     security definer로 행을 만들기 때문에 RLS를 거치지 않습니다.
-- select tablename, policyname, cmd from pg_policies
--  where schemaname = 'public' order by tablename;
