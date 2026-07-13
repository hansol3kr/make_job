-- 카테고리 시드: 플랫폼은 전방위(전 버티컬), GTM 씨드는 'store'(F&B·편의점·리테일)
set search_path = public, extensions;

-- 최상위 버티컬
insert into categories (slug, name, sort) values
  ('store',     '매장 (F&B·편의점·리테일)', 10),
  ('logistics', '물류·창고',               20),
  ('errand',    '생활 심부름·용역',         30),
  ('pro',       '전문 프리랜서',            40),
  ('field',     '블루칼라 현장',            50)
on conflict (slug) do nothing;

-- 씨드 버티컬(store) 하위 카테고리
insert into categories (slug, name, parent_id, sort)
select v.slug, v.name, (select id from categories where slug = 'store'), v.sort
from (values
  ('store-fnb',    '음식점 홀·주방 보조', 11),
  ('store-cafe',   '카페',               12),
  ('store-cvs',    '편의점',             13),
  ('store-retail', '리테일 매장',         14),
  ('store-cover',  '긴급 대타',           15)
) as v(slug, name, sort)
on conflict (slug) do nothing;
