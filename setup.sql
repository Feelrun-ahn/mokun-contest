-- ============================================================
--  목운중학교 교복 디자인 공모전 · Supabase 설치 스크립트
--  Supabase 대시보드 > SQL Editor 에 붙여넣고 [Run] 한 번만 실행하세요.
-- ============================================================

-- 1. 관리자 명단 --------------------------------------------------
create table if not exists admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email   text,
  created_at timestamptz default now()
);

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

-- 2. 공모전 -------------------------------------------------------
create table if not exists contests (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  subtitle    text default '',
  summary     text default '',
  target      text default '목운중학교 재학생',
  status      text not null default 'open'
              check (status in ('open','judging','announced','closed')),
  start_at    timestamptz default now(),
  end_at      timestamptz,
  judge_until timestamptz,
  result_at   timestamptz,
  prizes      jsonb default '[]'::jsonb,
  notice      jsonb default '{"sections":[]}'::jsonb,
  created_at  timestamptz default now()
);

-- 3. 제출 작품 ----------------------------------------------------
create sequence if not exists receipt_seq start 1;

create table if not exists submissions (
  id         uuid primary key default gen_random_uuid(),
  contest_id uuid references contests(id) on delete cascade,
  receipt_no text unique not null,
  name       text not null,
  student_id text not null,
  phone      text not null,
  email      text default '',
  title      text not null,
  concept    text default '',
  files      jsonb default '[]'::jsonb,   -- [{path,name,size,mime}]
  status     text default 'received'
             check (status in ('received','reviewing','awarded','rejected')),
  award      jsonb,                        -- {rank, order, image}
  memo       text default '',
  created_at timestamptz default now()
);
create index if not exists idx_sub_contest on submissions(contest_id);

-- 4. FAQ / 문의 ---------------------------------------------------
create table if not exists faqs (
  id   uuid primary key default gen_random_uuid(),
  q    text not null,
  a    text not null,
  sort int default 0
);

create table if not exists inquiries (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  email       text default '',
  question    text not null,
  answer      text default '',
  created_at  timestamptz default now(),
  answered_at timestamptz
);

-- ============================================================
--  보안 규칙 (RLS)
--  - 학생(익명)은 공모전/FAQ/수상작만 볼 수 있습니다.
--  - 다른 학생의 제출 작품·개인정보는 절대 볼 수 없습니다.
--  - 제출은 아래 submit_entry() 함수를 통해서만 가능합니다.
-- ============================================================
alter table contests    enable row level security;
alter table submissions enable row level security;
alter table faqs        enable row level security;
alter table inquiries   enable row level security;
alter table admins      enable row level security;

drop policy if exists p_contests_read  on contests;
drop policy if exists p_contests_admin on contests;
create policy p_contests_read  on contests for select using (true);
create policy p_contests_admin on contests for all    using (is_admin()) with check (is_admin());

drop policy if exists p_faqs_read  on faqs;
drop policy if exists p_faqs_admin on faqs;
create policy p_faqs_read  on faqs for select using (true);
create policy p_faqs_admin on faqs for all    using (is_admin()) with check (is_admin());

-- 제출 작품: 관리자만 조회/수정/삭제 가능 (익명은 select 정책 자체가 없음 = 차단)
drop policy if exists p_sub_admin on submissions;
create policy p_sub_admin on submissions for all using (is_admin()) with check (is_admin());

-- 문의: 누구나 등록만 가능, 열람은 관리자만
drop policy if exists p_inq_insert on inquiries;
drop policy if exists p_inq_admin  on inquiries;
create policy p_inq_insert on inquiries for insert with check (true);
create policy p_inq_admin  on inquiries for all    using (is_admin()) with check (is_admin());

drop policy if exists p_admins_self on admins;
create policy p_admins_self on admins for select using (user_id = auth.uid());

-- 테이블 접근 권한 (RLS 정책과 함께 이중으로 보호됩니다)
grant usage on schema public to anon, authenticated;
grant select on contests, faqs to anon, authenticated;          -- 공모전·FAQ는 누구나 열람
grant insert on inquiries    to anon, authenticated;            -- 문의는 누구나 등록
grant select, insert, update, delete on contests, faqs, submissions, inquiries to authenticated;
grant select on admins to authenticated;
-- ⚠ anon 에게는 submissions 권한을 절대 주지 않습니다 (다른 학생 작품·개인정보 보호)

-- ============================================================
--  함수 (익명 학생이 사용할 수 있는 유일한 통로)
-- ============================================================

-- 작품 제출: 접수번호 자동 발급 + 접수기간/학번/1인 2작품 제한 검사
create or replace function submit_entry(
  p_name text, p_student_id text, p_phone text, p_email text,
  p_title text, p_concept text, p_files jsonb
) returns text
language plpgsql security definer set search_path = public as $$
declare
  c        contests%rowtype;
  v_no     text;
  v_count  int;
begin
  select * into c from contests
   where status <> 'closed' order by created_at desc limit 1;
  if c.id is null then raise exception '진행 중인 공모전이 없습니다.'; end if;
  if c.status <> 'open' then raise exception '현재는 접수 기간이 아닙니다.'; end if;
  if c.end_at is not null and c.end_at < now() then raise exception '접수가 마감되었습니다.'; end if;

  if p_name is null or btrim(p_name) = '' then raise exception '이름을 입력해 주세요.'; end if;
  if p_student_id !~ '^[0-9]{4,6}$' then raise exception '학번은 숫자 4~6자리로 입력해 주세요.'; end if;
  if replace(p_phone,' ','') !~ '^0[0-9]{1,2}-?[0-9]{3,4}-?[0-9]{4}$' then
    raise exception '연락처 형식을 확인해 주세요. (예: 010-1234-5678)'; end if;
  if p_title is null or btrim(p_title) = '' then raise exception '작품명을 입력해 주세요.'; end if;
  if p_files is null or jsonb_array_length(p_files) = 0 then
    raise exception '디자인 파일을 1개 이상 올려주세요.'; end if;
  if jsonb_array_length(p_files) > 5 then raise exception '파일은 최대 5개까지 올릴 수 있습니다.'; end if;

  select count(*) into v_count from submissions
   where contest_id = c.id and student_id = btrim(p_student_id);
  if v_count >= 2 then raise exception '1인당 최대 2개 작품까지 제출할 수 있습니다.'; end if;

  v_no := 'MK' || to_char(now(),'YYYY') || '-' || lpad(nextval('receipt_seq')::text, 4, '0');

  insert into submissions(contest_id, receipt_no, name, student_id, phone, email, title, concept, files)
  values (c.id, v_no, btrim(p_name), btrim(p_student_id), btrim(p_phone),
          coalesce(btrim(p_email),''), btrim(p_title), coalesce(btrim(p_concept),''), p_files);

  return v_no;
end $$;

-- 접수 조회: 접수번호 + 이름이 정확히 일치할 때만 본인 것 1건 반환
create or replace function lookup_submission(p_receipt text, p_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  select jsonb_build_object(
    'receipt_no', s.receipt_no, 'name', s.name, 'title', s.title,
    'status', s.status, 'award', s.award, 'created_at', s.created_at,
    'files', (select jsonb_agg(jsonb_build_object('name', f->>'name', 'size', f->>'size'))
                from jsonb_array_elements(s.files) f),
    'contest_title', c.title, 'contest_status', c.status
  ) into r
  from submissions s join contests c on c.id = s.contest_id
  where upper(s.receipt_no) = upper(btrim(p_receipt)) and s.name = btrim(p_name);

  if r is null then raise exception '일치하는 접수 내역이 없습니다. 접수번호와 이름을 확인해 주세요.'; end if;
  return r;
end $$;

-- 수상작 공개: 수상 지정된 작품만 (연락처·학번 등 개인정보 제외)
create or replace function get_winners()
returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'result_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'contest_title', c.title, 'result_at', c.result_at, 'contest_status', c.status,
      'winners', (
        select jsonb_agg(jsonb_build_object(
          'title', s.title, 'concept', s.concept, 'name', s.name, 'award', s.award
        ) order by (s.award->>'order')::int nulls last)
        from submissions s where s.contest_id = c.id and s.award is not null)
    ) as x
    from contests c
    where c.status in ('announced','closed')
      and exists (select 1 from submissions s where s.contest_id = c.id and s.award is not null)
  ) t;
$$;

-- 현재 접수 건수 (메인 화면 표시용)
create or replace function submission_count(p_contest uuid)
returns int language sql security definer set search_path = public as $$
  select count(*)::int from submissions where contest_id = p_contest;
$$;

-- 익명 학생에게 위 함수 실행 권한만 부여
grant execute on function submit_entry(text,text,text,text,text,text,jsonb) to anon, authenticated;
grant execute on function lookup_submission(text,text) to anon, authenticated;
grant execute on function get_winners() to anon, authenticated;
grant execute on function submission_count(uuid) to anon, authenticated;
grant usage on sequence receipt_seq to anon, authenticated;

-- ============================================================
--  파일 저장소 (Storage)
--  submissions : 비공개. 학생은 업로드만, 열람·다운로드는 관리자만.
--  winners     : 공개. 수상작 이미지만 관리자가 올립니다.
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit)
values ('submissions','submissions', false, 20971520)
on conflict (id) do update set public=false, file_size_limit=20971520;

insert into storage.buckets (id, name, public, file_size_limit)
values ('winners','winners', true, 20971520)
on conflict (id) do update set public=true;

drop policy if exists p_sub_upload   on storage.objects;
drop policy if exists p_sub_admin_rw on storage.objects;
drop policy if exists p_win_read     on storage.objects;
drop policy if exists p_win_admin_rw on storage.objects;

create policy p_sub_upload   on storage.objects for insert
  with check (bucket_id = 'submissions');
create policy p_sub_admin_rw on storage.objects for all
  using (bucket_id = 'submissions' and is_admin())
  with check (bucket_id = 'submissions' and is_admin());
create policy p_win_read     on storage.objects for select
  using (bucket_id = 'winners');
create policy p_win_admin_rw on storage.objects for all
  using (bucket_id = 'winners' and is_admin())
  with check (bucket_id = 'winners' and is_admin());

-- ============================================================
--  초기 데이터 (공모전 1건 + FAQ) — 관리자 페이지에서 언제든 수정 가능
-- ============================================================
insert into contests (title, subtitle, summary, target, status, start_at, end_at, judge_until, result_at, prizes, notice)
select
  '2026 목운중학교 교복 디자인 공모전',
  '우리가 매일 입는 교복, 우리 손으로 디자인합니다',
  '목운중학교 학생회가 주관하는 교복 디자인 공모전입니다. 학생들이 직접 입고 싶은 교복을 자유롭게 제안해 주세요. 선정된 디자인은 학교 운영위원회 검토를 거쳐 실제 교복 개선안에 반영됩니다.',
  '목운중학교 재학생 누구나 (개인 또는 2인 이하 팀)',
  'open',
  now(), now() + interval '21 days', now() + interval '30 days', now() + interval '35 days',
  '[{"rank":"대상","count":1,"reward":"상장 + 문화상품권 10만원 + 실제 교복 반영 검토"},
    {"rank":"최우수상","count":2,"reward":"상장 + 문화상품권 5만원"},
    {"rank":"우수상","count":3,"reward":"상장 + 문화상품권 3만원"},
    {"rank":"입선","count":10,"reward":"상장 + 학생회 굿즈"}]'::jsonb,
  '{"author":"목운중학교 학생회","sections":[
    {"icon":"alert","title":"1. 디자인 제작 시 주의사항","items":[
      "반드시 본인이 직접 제작한 창작물이어야 합니다. 타인의 디자인·이미지·AI 생성물의 무단 도용은 실격 사유입니다.",
      "기존 브랜드 로고, 캐릭터, 저작권이 있는 이미지나 폰트를 사용할 수 없습니다.",
      "특정 인물·단체를 비하하거나 정치적·상업적 메시지가 담긴 디자인은 제출할 수 없습니다.",
      "동복(상의·하의·자켓)과 하복(상의·하의) 중 최소 1개 세트 이상을 포함해야 합니다.",
      "학생 활동성과 계절 특성을 고려해 실제로 착용 가능한 디자인이어야 합니다.",
      "작품 안에 본인의 이름·학번 등 신원을 알 수 있는 정보를 넣지 마세요. (블라인드 심사)"]},
    {"icon":"file","title":"2. 제출 규격 및 파일 형식","items":[
      "파일 형식: JPG, PNG, PDF (필요 시 원본 AI/PSD를 ZIP으로 함께 제출 가능)",
      "해상도: 최소 1,500px 이상 / 300dpi 권장",
      "파일 크기: 파일당 최대 20MB, 최대 5개까지 업로드 가능",
      "필수 포함 항목: ① 전체 착장 도식화(앞·뒤) ② 컬러 배색안 ③ 디자인 설명(200자 이내)",
      "파일명 예시: 교복디자인_동복_01.png (파일명에 이름·학번을 쓰지 마세요)",
      "손그림도 제출 가능합니다. 스캔 또는 밝은 곳에서 촬영해 선명하게 올려주세요."]},
    {"icon":"download","title":"3. 목운중학교 로고 및 공식 자료 다운로드","items":[
      "아래 자료는 공모전 참가 목적으로만 사용할 수 있습니다.",
      "로고의 색상·비율을 임의로 변형하지 마세요."],
     "downloads":[
      {"name":"목운중학교 로고 (SVG)","file":"mokun-logo.svg","size":"SVG"},
      {"name":"교복 도식화 템플릿 (SVG)","file":"uniform-template.svg","size":"SVG"},
      {"name":"학교 상징 색상 팔레트 (TXT)","file":"color-palette.txt","size":"TXT"},
      {"name":"공모전 안내문 (TXT)","file":"contest-guide.txt","size":"TXT"}]},
    {"icon":"star","title":"4. 심사 기준","items":[],
     "criteria":[
      {"name":"창의성","weight":30,"desc":"기존 교복과 차별화되는 새로운 아이디어인가"},
      {"name":"실용성·활동성","weight":25,"desc":"실제로 학교생활에서 편하게 입을 수 있는가"},
      {"name":"학교 정체성","weight":20,"desc":"목운중학교의 상징과 분위기를 잘 담고 있는가"},
      {"name":"완성도","weight":15,"desc":"도식화와 배색이 명확하고 설명이 충실한가"},
      {"name":"학생 선호도","weight":10,"desc":"전교생 온라인 투표 결과"}]},
    {"icon":"info","title":"5. 유의사항","items":[
      "제출 후에는 파일을 수정할 수 없습니다. 재제출이 필요하면 학생회로 문의해 주세요.",
      "1인당 최대 2개 작품까지 제출할 수 있습니다.",
      "수상작의 저작권은 창작자에게 있으며, 학교는 교복 개선 및 홍보 목적으로 활용할 수 있습니다.",
      "표절·대리 제작이 확인되면 수상 후에도 취소됩니다.",
      "제출한 개인정보는 공모전 진행·시상 목적으로만 사용되며 종료 후 파기됩니다.",
      "문의: 학생회실 (점심시간) 또는 FAQ 페이지의 문의하기"]}
  ]}'::jsonb
where not exists (select 1 from contests);

insert into faqs (q, a, sort)
select * from (values
  ('디자인 전공자가 아니어도 참가할 수 있나요?','네. 목운중 재학생이면 누구나 참가할 수 있습니다. 그림 실력보다 아이디어와 설명의 완성도를 더 중요하게 봅니다.',1),
  ('손그림으로 그려도 되나요?','가능합니다. 스캔하거나 밝은 곳에서 선명하게 촬영해 JPG/PNG로 올려주세요.',2),
  ('팀으로 참가해도 되나요?','2인 이하 팀까지 가능합니다. 제출 시 대표자 1명의 정보를 입력하고, 작품 설명에 팀원 이름을 함께 적어주세요.',3),
  ('몇 개까지 낼 수 있나요?','1인당 최대 2개 작품까지 제출할 수 있습니다.',4),
  ('제출한 작품을 수정하고 싶어요.','제출 후 파일 수정은 불가능합니다. 접수번호와 함께 문의하기로 연락 주시면 학생회에서 확인 후 도와드립니다.',5),
  ('접수가 잘 됐는지 확인하고 싶어요.','제출 완료 시 발급되는 접수번호로 [접수 조회] 메뉴에서 언제든 확인할 수 있습니다.',6),
  ('수상하면 실제 교복이 바뀌나요?','대상 수상작은 학교 운영위원회와 교복 업체 검토를 거쳐 실제 교복 개선안에 반영을 추진합니다. 다만 최종 도입 여부는 학교 결정에 따릅니다.',7)
) v where not exists (select 1 from faqs);
