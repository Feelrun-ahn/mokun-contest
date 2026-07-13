-- 이미 setup-1 을 실행한 프로젝트에 적용하는 변경사항
-- SQL Editor 에 붙여넣고 Run 하세요.

-- ① 접수번호 앞글자 MK → MG
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

  v_no := 'MG' || to_char(now(),'YYYY') || '-' || lpad(nextval('receipt_seq')::text, 4, '0');

  insert into submissions(contest_id, receipt_no, name, student_id, phone, email, title, concept, files)
  values (c.id, v_no, btrim(p_name), btrim(p_student_id), btrim(p_phone),
          coalesce(btrim(p_email),''), btrim(p_title), coalesce(btrim(p_concept),''), p_files);

  return v_no;
end $$;

grant execute on function submit_entry(text,text,text,text,text,text,jsonb) to anon, authenticated;

-- ② 문의(QnA)에 연락처 칸 추가
alter table inquiries add column if not exists phone text default '';

-- ③ 공지의 로고 다운로드 링크를 실제 학교 로고로 교체
update contests
   set notice = jsonb_set(notice, '{sections,2,downloads,0}',
     '{"name":"목운중학교 로고 (PNG)","file":"mogun-logo.png","size":"PNG"}'::jsonb)
 where notice->'sections'->2->'downloads'->0->>'file' = 'mokun-logo.svg';

-- ④ API 캐시 갱신 (새 칸을 바로 인식하도록)
notify pgrst, 'reload schema';

select '완료' as 결과;
