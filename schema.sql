-- =====================================================================
-- 釣果海図ログ：おすそわけ（無償）・お店（魚介類販売業の許可あり）マッチング
-- Supabase の SQL Editor に全文を貼り付けて「Run」で実行してください。
-- 何度実行しても同じ状態になるように書いてあります（作り直し可）。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. テーブル
-- ---------------------------------------------------------------------

-- 利用者（ログインした人ごとに1件。ニックネームと利用規約への同意）
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  nickname    text not null check (char_length(nickname) between 1 and 20),
  role        text not null default 'user' check (role in ('user','admin')),
  banned      boolean not null default false,
  agreed_at   timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

-- お店（魚介類販売業の許可を持つ店。管理者が許可証を確認して承認）
create table if not exists public.shops (
  id             uuid primary key default gen_random_uuid(),
  owner          uuid not null references public.profiles(id) on delete cascade,
  name           text not null check (char_length(name) between 1 and 60),
  license_no     text not null check (char_length(license_no) between 1 and 40),
  health_center  text not null check (char_length(health_center) between 1 and 40),
  area           text not null check (char_length(area) between 1 and 40),
  license_photo  text,
  status         text not null default 'pending' check (status in ('pending','approved','rejected','suspended')),
  admin_note     text check (char_length(admin_note) <= 400),
  created_at     timestamptz not null default now(),
  reviewed_at    timestamptz
);
create unique index if not exists shops_one_per_owner on public.shops(owner);

-- 出品できない種類（管理者が画面から追加・削除できる）
create table if not exists public.blocked_terms (
  term    text primary key,
  reason  text not null
);

-- 出品
create table if not exists public.listings (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind          text not null check (kind in ('gift','shop')),          -- gift=おすそわけ / shop=お店向け
  species       text not null check (char_length(species) between 1 and 40),
  count         int  not null check (count between 1 and 200),
  length_cm     numeric(5,1) check (length_cm > 0 and length_cm < 400),
  weight_g      int  check (weight_g > 0 and weight_g < 200000),
  caught_at     timestamptz not null,
  catch_lat     double precision not null,                               -- 釣った位置（本人と管理者だけが見られる）
  catch_lon     double precision not null,
  pickup_lat    double precision not null,                               -- 受け渡し場所の目安（約1km単位に丸めて公開）
  pickup_lon    double precision not null,
  pickup_area   text not null check (char_length(pickup_area) between 1 and 40),
  shime         text not null check (shime in ('活魚','脳締め','氷締め','野締め')),
  treat         text[] not null default '{}' check (treat <@ array['血抜き','神経締め','内臓除去']::text[]),
  shime_at      timestamptz,
  cooling       text check (cooling in ('氷','潮氷','クーラーのみ')),
  handoff       text not null check (handoff in ('取りに来てもらう','店に持ち込む','どちらでも')),
  price_yen     int  check (price_yen between 0 and 1000000),
  memo          text check (char_length(memo) <= 400),
  photos        text[] not null,
  photo_checked boolean not null default false,                           -- 写真の撮影日時が釣った日時と合っていた（端末側の判定）
  status        text not null default 'open' check (status in ('open','reserved','done','cancelled','removed')),
  expires_at    timestamptz not null,
  created_at    timestamptz not null default now()
);
create index if not exists listings_open_idx  on public.listings(status, expires_at);
create index if not exists listings_owner_idx on public.listings(owner, created_at);

-- 申し込み（欲しい／買いたい）
create table if not exists public.requests (
  id          uuid primary key default gen_random_uuid(),
  listing_id  uuid not null references public.listings(id) on delete cascade,
  requester   uuid not null references public.profiles(id) on delete cascade,
  shop_id     uuid references public.shops(id) on delete set null,
  message     text not null check (char_length(message) between 1 and 400),
  offer_yen   int  check (offer_yen between 0 and 1000000),
  status      text not null default 'pending' check (status in ('pending','accepted','declined','cancelled','done')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (listing_id, requester)
);
create index if not exists requests_requester_idx on public.requests(requester);

-- やり取りのメッセージ（受け渡し場所・時間はここで決める）
create table if not exists public.messages (
  id          bigint generated always as identity primary key,
  request_id  uuid not null references public.requests(id) on delete cascade,
  sender      uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 1000),
  created_at  timestamptz not null default now()
);
create index if not exists messages_request_idx on public.messages(request_id, id);

-- 通報
create table if not exists public.reports (
  id          bigint generated always as identity primary key,
  listing_id  uuid not null references public.listings(id) on delete cascade,
  reporter    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  reason      text not null check (reason in ('禁止されている種類','サイズ・数量が不自然','他人の写真・うその内容','おすそわけなのにお金を求められた','受け渡しのトラブル','その他')),
  detail      text check (char_length(detail) <= 400),
  status      text not null default 'open' check (status in ('open','closed')),
  created_at  timestamptz not null default now(),
  unique (listing_id, reporter)
);

-- ---------------------------------------------------------------------
-- 2. 出品できない種類の初期値
--    ひらがな・カタカナどちらで入力されても止まるように、照合はカタカナに直して行う
-- ---------------------------------------------------------------------
insert into public.blocked_terms(term, reason) values
  ('アワビ','特定水産動植物（許可なく採ると罰則）'), ('鮑','特定水産動植物（許可なく採ると罰則）'),
  ('ナマコ','特定水産動植物（許可なく採ると罰則）'), ('海鼠','特定水産動植物（許可なく採ると罰則）'),
  ('シラスウナギ','特定水産動植物（許可なく採ると罰則）'),
  ('サザエ','漁業権の対象'), ('栄螺','漁業権の対象'), ('トコブシ','漁業権の対象'),
  ('イセエビ','漁業権の対象'), ('伊勢海老','漁業権の対象'), ('ウニ','漁業権の対象'), ('雲丹','漁業権の対象'),
  ('カキ','漁業権の対象（貝類）'), ('ハマグリ','漁業権の対象（貝類）'), ('アサリ','漁業権の対象（貝類）'),
  ('ホタテ','漁業権の対象（貝類）'), ('バイガイ','漁業権の対象（貝類）'), ('ツブ','漁業権の対象（貝類）'),
  ('シッタカ','漁業権の対象（貝類）'), ('貝','漁業権の対象（貝類）'),
  ('モズク','漁業権の対象（海藻）'), ('ワカメ','漁業権の対象（海藻）'), ('コンブ','漁業権の対象（海藻）'),
  ('テングサ','漁業権の対象（海藻）'), ('アカモク','漁業権の対象（海藻）'), ('海藻','漁業権の対象（海藻）'),
  ('エビ','エビ類は漁業の対象のため出品不可'), ('海老','エビ類は漁業の対象のため出品不可'),
  ('カニ','カニ類は漁業の対象のため出品不可'), ('ガニ','カニ類は漁業の対象のため出品不可'), ('蟹','カニ類は漁業の対象のため出品不可'),
  ('ホタルイカ','富山湾の漁業の対象のため出品不可'),
  ('タコ','地域によって漁業権の対象（富山県の扱いを確認するまで出品不可）'),
  ('ダコ','地域によって漁業権の対象（富山県の扱いを確認するまで出品不可）'),
  ('蛸','地域によって漁業権の対象（富山県の扱いを確認するまで出品不可）'),
  ('フグ','毒のおそれ（処理に資格が必要）'), ('河豚','毒のおそれ（処理に資格が必要）'),
  ('ソウシハギ','毒のおそれ'), ('アオブダイ','毒のおそれ'), ('バラハタ','毒のおそれ（シガテラ）'),
  ('バラフエダイ','毒のおそれ（シガテラ）'), ('オニカマス','毒のおそれ（シガテラ）')
on conflict (term) do nothing;

-- ---------------------------------------------------------------------
-- 3. 補助関数
-- ---------------------------------------------------------------------
create or replace function public.kana_norm(s text) returns text
language sql immutable as $$
  select translate(normalize(coalesce(s,''), NFKC),
    'ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろゎわゐゑをんゔゕゖ',
    'ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾタダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポマミムメモャヤュユョヨラリルレロヮワヰヱヲンヴヵヶ')
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'admin' and not banned)
$$;

create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and not banned)
$$;

-- 承認済みのお店を持っていればその店のID
create or replace function public.my_shop() returns uuid
language sql stable security definer set search_path = public as $$
  select id from shops where owner = auth.uid() and status = 'approved'
$$;

-- 出品できない種類なら理由を返す
create or replace function public.blocked_reason(p_species text) returns text
language sql stable security definer set search_path = public as $$
  select reason from blocked_terms
   where position(kana_norm(term) in kana_norm(p_species)) > 0
   order by char_length(term) desc limit 1
$$;

-- 申し込みの当事者か（出品者・申込者）
create or replace function public.is_request_party(p_request uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from requests r join listings l on l.id = r.listing_id
     where r.id = p_request and (r.requester = auth.uid() or l.owner = auth.uid()))
$$;

-- ---------------------------------------------------------------------
-- 4. 書き込み時のチェック（トリガー）
--    auth.uid() が空＝SQL Editor など管理画面からの操作は素通しにする
-- ---------------------------------------------------------------------

-- 利用者：自分で role（管理者）や banned（停止）を変えられないようにする
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or is_admin() then return new; end if;
  if tg_op = 'INSERT' then
    new.id := auth.uid(); new.role := 'user'; new.banned := false;
    new.agreed_at := now(); new.created_at := now();
  else
    if new.role is distinct from old.role or new.banned is distinct from old.banned or new.id <> old.id then
      raise exception '権限がありません';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before insert or update on public.profiles
  for each row execute function public.profiles_guard();

-- お店：登録・修正すると必ず「審査待ち」に戻る。承認は管理者だけ
create or replace function public.shops_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if is_admin() then
    if tg_op = 'UPDATE' and new.status is distinct from old.status then new.reviewed_at := now(); end if;
    return new;
  end if;
  if not is_active_user() then raise exception '利用が停止されているか、登録が済んでいません'; end if;
  if tg_op = 'INSERT' then
    new.owner := auth.uid(); new.created_at := now();
  elsif old.status not in ('pending','rejected') then
    raise exception '承認後の内容は管理者に連絡して変更してください';
  elsif new.owner <> old.owner then
    raise exception '権限がありません';
  end if;
  if new.license_photo is not null and split_part(new.license_photo, '/', 1) <> auth.uid()::text then
    raise exception '許可証の写真の保存先が正しくありません';
  end if;
  new.status := 'pending'; new.admin_note := null; new.reviewed_at := null;
  return new;
end $$;
drop trigger if exists shops_guard on public.shops;
create trigger shops_guard before insert or update on public.shops
  for each row execute function public.shops_guard();

-- 出品：密漁・事故防止のチェックと、期限・件数の上限
create or replace function public.listings_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_reason text;
  v_n int;
begin
  if auth.uid() is null then return new; end if;            -- 管理画面からの投入は素通し
  new.owner := auth.uid();
  if not is_active_user() then raise exception '利用が停止されているか、登録が済んでいません'; end if;
  new.status := 'open'; new.created_at := now();

  v_reason := blocked_reason(new.species);
  if v_reason is not null then raise exception 'この種類は出品できません（%）', v_reason; end if;

  if coalesce(array_length(new.photos, 1), 0) not between 1 and 4 then
    raise exception '写真は1〜4枚つけてください';
  end if;
  if exists(select 1 from unnest(new.photos) p where split_part(p, '/', 1) <> new.owner::text) then
    raise exception '写真の保存先が正しくありません';
  end if;

  if new.caught_at > now() + interval '10 minutes' then raise exception '釣った日時が未来になっています'; end if;
  if new.caught_at < now() - interval '24 hours'  then raise exception '出品できるのは24時間以内に釣った魚だけです'; end if;
  if new.shime_at is not null and (new.shime_at < new.caught_at - interval '10 minutes' or new.shime_at > now() + interval '10 minutes') then
    raise exception '締めた時刻が釣った時刻より前か、未来になっています';
  end if;

  -- 富山県内（受け渡し場所は陸側、釣った位置は富山湾を含む範囲）
  if not (new.pickup_lat between 36.25 and 37.05 and new.pickup_lon between 136.75 and 137.80) then
    raise exception '受け渡し場所が富山県内ではありません';
  end if;
  if not (new.catch_lat between 36.20 and 37.40 and new.catch_lon between 136.70 and 137.90) then
    raise exception '釣った位置が富山県の範囲外です';
  end if;

  if new.kind = 'gift' then
    new.price_yen := null;
    new.handoff := '取りに来てもらう';
    -- 釣った日（日本時間）の終わりまで
    new.expires_at := (((new.caught_at at time zone 'Asia/Tokyo')::date + 1)::timestamp at time zone 'Asia/Tokyo');
    select count(*) into v_n from listings
     where owner = new.owner and kind = 'gift'
       and (created_at at time zone 'Asia/Tokyo')::date = (now() at time zone 'Asia/Tokyo')::date;
    if v_n >= 5 then raise exception 'おすそわけの出品は1日5件までです'; end if;
  else
    new.expires_at := new.caught_at + interval '24 hours';
    select count(*) into v_n from listings
     where owner = new.owner and kind = 'shop' and status in ('open','reserved','done')
       and created_at >= (date_trunc('month', now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo');
    if v_n >= 4 then
      raise exception 'お店向けの出品は1か月4件までです（くり返し売ると漁業とみなされるおそれがあるため）';
    end if;
  end if;

  if new.expires_at <= now() then raise exception '受付期限を過ぎています（おすそわけは釣った日のうちだけです）'; end if;
  return new;
end $$;
drop trigger if exists listings_before_insert on public.listings;
create trigger listings_before_insert before insert on public.listings
  for each row execute function public.listings_before_insert();

-- ---------------------------------------------------------------------
-- 5. 画面から呼ぶ操作（申し込み・承諾・完了・取り消し）
-- ---------------------------------------------------------------------
create or replace function public.make_request(p_listing uuid, p_message text, p_offer int default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  l listings;
  v_shop uuid;
  v_id uuid;
  v_n int;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  if not is_active_user() then raise exception '利用が停止されているか、登録が済んでいません'; end if;
  select * into l from listings where id = p_listing for update;
  if not found or l.status <> 'open' or l.expires_at <= now() then raise exception 'この出品は受付を終了しています'; end if;
  if l.owner = auth.uid() then raise exception '自分の出品には申し込めません'; end if;
  if l.kind = 'shop' then
    v_shop := my_shop();
    if v_shop is null then raise exception 'お店向けの出品に申し込めるのは、承認済みのお店だけです'; end if;
  else
    p_offer := null;
    select count(*) into v_n from requests
     where requester = auth.uid() and status in ('pending','accepted')
       and created_at > now() - interval '24 hours';
    if v_n >= 5 then raise exception 'おすそわけの申し込みは同時に5件までです'; end if;
  end if;
  insert into requests(listing_id, requester, shop_id, message, offer_yen)
  values (p_listing, auth.uid(), v_shop, p_message, p_offer)
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'この出品にはすでに申し込んでいます';
end $$;

-- 出品者が申し込みを受ける／断る
create or replace function public.respond_request(p_request uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r requests; l listings;
begin
  select * into r from requests where id = p_request for update;
  if not found then raise exception '申し込みが見つかりません'; end if;
  select * into l from listings where id = r.listing_id for update;
  if l.owner <> auth.uid() then raise exception '権限がありません'; end if;
  if r.status <> 'pending' then raise exception 'この申し込みはすでに処理されています'; end if;
  if p_accept then
    if l.status <> 'open' or l.expires_at <= now() then raise exception 'この出品は受付を終了しています'; end if;
    update requests set status = 'accepted', updated_at = now() where id = r.id;
    update requests set status = 'declined', updated_at = now()
     where listing_id = l.id and id <> r.id and status = 'pending';
    update listings set status = 'reserved' where id = l.id;
  else
    update requests set status = 'declined', updated_at = now() where id = r.id;
  end if;
end $$;

-- 出品者が受け渡し完了にする
create or replace function public.finish_request(p_request uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r requests; l listings;
begin
  select * into r from requests where id = p_request for update;
  if not found then raise exception '申し込みが見つかりません'; end if;
  select * into l from listings where id = r.listing_id for update;
  if l.owner <> auth.uid() then raise exception '権限がありません'; end if;
  if r.status <> 'accepted' then raise exception '受けた申し込みだけ完了にできます'; end if;
  update requests set status = 'done', updated_at = now() where id = r.id;
  update listings set status = 'done' where id = l.id;
end $$;

-- 申込者が申し込みを取り消す（受けてもらった後なら出品は受付中に戻る）
create or replace function public.cancel_request(p_request uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r requests;
begin
  select * into r from requests where id = p_request for update;
  if not found or r.requester <> auth.uid() then raise exception '権限がありません'; end if;
  if r.status not in ('pending','accepted') then raise exception 'この申し込みは取り消せません'; end if;
  update requests set status = 'cancelled', updated_at = now() where id = r.id;
  if r.status = 'accepted' then
    update listings set status = 'open' where id = r.listing_id and status = 'reserved';
  end if;
end $$;

-- 出品者が出品を取り下げる（申し込みはすべて取り消しになる）
create or replace function public.cancel_listing(p_listing uuid)
returns void language plpgsql security definer set search_path = public as $$
declare l listings;
begin
  select * into l from listings where id = p_listing for update;
  if not found or l.owner <> auth.uid() then raise exception '権限がありません'; end if;
  if l.status not in ('open','reserved') then raise exception 'この出品は取り下げられません'; end if;
  update listings set status = 'cancelled' where id = l.id;
  update requests set status = 'cancelled', updated_at = now()
   where listing_id = l.id and status in ('pending','accepted');
end $$;

-- ---------------------------------------------------------------------
-- 6. 画面用のビュー（見てよい範囲だけ、位置は丸めて出す）
-- ---------------------------------------------------------------------
drop view if exists public.listing_cards;
create view public.listing_cards with (security_barrier = true) as
select
  l.id, l.kind, l.species, l.count, l.length_cm, l.weight_g, l.caught_at,
  round(l.pickup_lat::numeric, 2)::float8 as lat,          -- 約1km単位
  round(l.pickup_lon::numeric, 2)::float8 as lon,
  l.pickup_area, l.shime, l.treat, l.shime_at, l.cooling, l.handoff, l.price_yen, l.memo,
  l.photos, l.photo_checked,
  case when l.status = 'open' and l.expires_at <= now() then 'expired' else l.status end as status,
  l.expires_at, l.created_at,
  p.nickname as owner_name,
  (l.owner = auth.uid()) as mine,
  (select r.id from requests r where r.listing_id = l.id and r.requester = auth.uid()) as my_request,
  case when is_admin() then l.catch_lat end as catch_lat,  -- 釣った位置は管理者だけ
  case when is_admin() then l.catch_lon end as catch_lon,
  case when is_admin() then l.owner end as owner_id
from public.listings l
join public.profiles p on p.id = l.owner
where auth.uid() is not null
  and (l.status <> 'removed' or is_admin())
  and (
       is_admin()
    or l.owner = auth.uid()
    or exists(select 1 from requests r where r.listing_id = l.id and r.requester = auth.uid())
    or (l.status = 'open' and l.expires_at > now() and not p.banned
        and (l.kind = 'gift' or my_shop() is not null))
  );

drop view if exists public.request_cards;
create view public.request_cards with (security_barrier = true) as
select
  r.id, r.listing_id, r.status, r.message, r.offer_yen, r.created_at, r.updated_at,
  rp.nickname as requester_name,
  s.name as shop_name, s.area as shop_area,
  op.nickname as owner_name,
  l.species, l.count, l.kind, l.pickup_area, l.handoff, l.price_yen, l.expires_at,
  l.status as listing_status,
  (l.owner = auth.uid()) as i_am_owner,
  (select count(*) from messages m where m.request_id = r.id) as msg_count,
  (select max(m.created_at) from messages m where m.request_id = r.id) as last_msg_at
from public.requests r
join public.listings l  on l.id = r.listing_id
join public.profiles rp on rp.id = r.requester
join public.profiles op on op.id = l.owner
left join public.shops s on s.id = r.shop_id
where auth.uid() is not null
  and (r.requester = auth.uid() or l.owner = auth.uid() or is_admin());

-- 管理者用：通報の一覧
drop view if exists public.report_cards;
create view public.report_cards with (security_barrier = true) as
select rp.id, rp.reason, rp.detail, rp.status, rp.created_at,
       rp.listing_id, l.species, l.kind, l.status as listing_status, l.owner as owner_id,
       op.nickname as owner_name, op.banned as owner_banned,
       rr.nickname as reporter_name
from public.reports rp
join public.listings l  on l.id = rp.listing_id
join public.profiles op on op.id = l.owner
join public.profiles rr on rr.id = rp.reporter
where is_admin();

-- 管理者用：お店の一覧（申請者のニックネーム付き）
drop view if exists public.shop_cards;
create view public.shop_cards with (security_barrier = true) as
select s.*, p.nickname as owner_name
from public.shops s join public.profiles p on p.id = s.owner
where is_admin() or s.owner = auth.uid();

-- ---------------------------------------------------------------------
-- 7. アクセス権（RLS）
-- ---------------------------------------------------------------------
alter table public.profiles      enable row level security;
alter table public.shops         enable row level security;
alter table public.blocked_terms enable row level security;
alter table public.listings      enable row level security;
alter table public.requests      enable row level security;
alter table public.messages      enable row level security;
alter table public.reports       enable row level security;

drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_insert on public.profiles;
drop policy if exists profiles_update on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (id = auth.uid() or is_admin());
create policy profiles_insert on public.profiles for insert to authenticated with check (id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid() or is_admin());

drop policy if exists shops_select on public.shops;
drop policy if exists shops_insert on public.shops;
drop policy if exists shops_update on public.shops;
create policy shops_select on public.shops for select to authenticated using (owner = auth.uid() or is_admin());
create policy shops_insert on public.shops for insert to authenticated with check (owner = auth.uid());
create policy shops_update on public.shops for update to authenticated
  using (is_admin() or (owner = auth.uid() and status in ('pending','rejected')));

drop policy if exists blocked_select on public.blocked_terms;
drop policy if exists blocked_admin  on public.blocked_terms;
create policy blocked_select on public.blocked_terms for select to anon, authenticated using (true);
create policy blocked_admin  on public.blocked_terms for all to authenticated using (is_admin()) with check (is_admin());

drop policy if exists listings_select on public.listings;
drop policy if exists listings_insert on public.listings;
drop policy if exists listings_update on public.listings;
create policy listings_select on public.listings for select to authenticated using (owner = auth.uid() or is_admin());
create policy listings_insert on public.listings for insert to authenticated with check (owner = auth.uid());
create policy listings_update on public.listings for update to authenticated using (is_admin());

drop policy if exists requests_select on public.requests;
create policy requests_select on public.requests for select to authenticated
  using (requester = auth.uid() or is_admin() or is_request_party(id));

drop policy if exists messages_select on public.messages;
drop policy if exists messages_insert on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (is_request_party(request_id) or is_admin());
create policy messages_insert on public.messages for insert to authenticated
  with check (
    sender = auth.uid() and is_active_user() and is_request_party(request_id)
    and exists(select 1 from requests r where r.id = request_id and r.status in ('pending','accepted'))
  );

drop policy if exists reports_select on public.reports;
drop policy if exists reports_insert on public.reports;
drop policy if exists reports_update on public.reports;
create policy reports_select on public.reports for select to authenticated using (reporter = auth.uid() or is_admin());
create policy reports_insert on public.reports for insert to authenticated with check (reporter = auth.uid() and is_active_user());
create policy reports_update on public.reports for update to authenticated using (is_admin());

-- ログインしていない人（anon）には何も見せない。操作は関数経由
revoke all on public.profiles, public.shops, public.listings, public.requests, public.messages, public.reports from anon;
revoke all on public.listing_cards, public.request_cards, public.report_cards, public.shop_cards from anon;
grant select on public.listing_cards, public.request_cards, public.report_cards, public.shop_cards to authenticated;
grant select on public.blocked_terms to anon, authenticated;
-- 画面から直接さわれるのは必要な列・操作だけ
revoke update on public.listings from authenticated;
grant  update (status) on public.listings to authenticated;          -- 管理者の削除（removed）用。RLSで管理者に限定
revoke update on public.profiles from authenticated;
grant  update (nickname, banned) on public.profiles to authenticated; -- banned はトリガーで管理者に限定

revoke execute on function public.make_request(uuid, text, int), public.respond_request(uuid, boolean),
  public.finish_request(uuid), public.cancel_request(uuid), public.cancel_listing(uuid) from public, anon;
grant execute on function public.make_request(uuid, text, int), public.respond_request(uuid, boolean),
  public.finish_request(uuid), public.cancel_request(uuid), public.cancel_listing(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 8. 写真の保存場所（Storage）
--    photos   : 出品の写真。ログインした人なら見られる
--    licenses : お店の許可証。本人と管理者だけ
--    どちらも「利用者ID/ファイル名」の形で、自分のフォルダにだけ置ける
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('photos', 'photos', false), ('licenses', 'licenses', false)
on conflict (id) do nothing;

drop policy if exists "photos_insert_own" on storage.objects;
drop policy if exists "photos_read"       on storage.objects;
drop policy if exists "photos_delete_own" on storage.objects;
drop policy if exists "licenses_insert_own" on storage.objects;
drop policy if exists "licenses_read"       on storage.objects;
create policy "photos_insert_own" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos_read" on storage.objects for select to authenticated
  using (bucket_id = 'photos');
create policy "photos_delete_own" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "licenses_insert_own" on storage.objects for insert to authenticated
  with check (bucket_id = 'licenses' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "licenses_read" on storage.objects for select to authenticated
  using (bucket_id = 'licenses' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
