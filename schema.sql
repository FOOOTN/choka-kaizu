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
-- 釣果の記録を管理者と共有するか（本人が選ぶ。初期値はオフ）
alter table public.profiles add column if not exists share_catches boolean not null default false;
-- 会員（有償）の期限。決済を入れるまでは管理者が設定する
alter table public.profiles add column if not exists member_until date;
-- アイコン（avatars バケットの「利用者ID/ファイル名」）。誰でも見られる
alter table public.profiles add column if not exists avatar text check (char_length(avatar) <= 200);
-- 電話番号（SMS）の認証。番号そのものは Supabase の認証（auth.users）にだけあり、ここには元に戻せない形（ハッシュ）だけ残す
alter table public.profiles add column if not exists phone_verified_at timestamptz;
alter table public.profiles add column if not exists phone_hash text;
alter table public.profiles add column if not exists phone_tail text check (char_length(phone_tail) <= 4);
create unique index if not exists profiles_phone_hash_uq on public.profiles(phone_hash) where phone_hash is not null;
-- 利用停止した人の電話番号（ハッシュ）。アカウントを作り直しても認証できない
create table if not exists public.banned_phones (
  phone_hash text primary key,
  note       text,
  created_at timestamptz not null default now()
);
-- アプリの設定（誰でも読める・管理者だけが変える）。require_phone：おすそわけに電話番号の認証を求めるか
create table if not exists public.app_settings (k text primary key, v text not null, updated_at timestamptz not null default now());
insert into public.app_settings values ('require_phone', 'off', now()) on conflict (k) do nothing;
-- ハッシュ用の秘密の値（画面からは読めない）
create table if not exists public.app_secrets (k text primary key, v text not null);
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
insert into public.app_secrets values ('phone_salt', encode(extensions.gen_random_bytes(16), 'hex')) on conflict (k) do nothing;

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

-- 提供された釣果（アプリの初回に同意した端末から届く。ログインしていない人の分も含む。写真は送らない）
-- 端末ごとの番号（device_id）と端末内の記録番号（local_id）で1件を表す。前の版の表は作り直す
do $$ begin
  if to_regclass('public.shared_catches') is not null and not exists(
       select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'shared_catches' and column_name = 'device_id') then
    drop table public.shared_catches cascade;
  end if;
end $$;
create table if not exists public.shared_catches (
  device_id   text not null check (char_length(device_id) between 8 and 64),
  local_id    text not null check (char_length(local_id) between 1 and 40),
  owner       uuid references auth.users(id) on delete set null,      -- 最後に送ったログイン（匿名を含む）
  caught_at   timestamptz not null,
  species     text not null check (char_length(species) between 1 and 40),
  count       int check (count between 0 and 100000),
  lat         double precision not null check (lat between -90 and 90),
  lon         double precision not null check (lon between -180 and 180),
  data        jsonb not null default '{}'::jsonb check (pg_column_size(data) < 16000),
  updated_at  timestamptz not null default now(),
  primary key (device_id, local_id)
);
create index if not exists shared_catches_time_idx on public.shared_catches(caught_at desc);
create index if not exists shared_catches_owner_idx on public.shared_catches(owner);

-- やり取りの自動のお知らせ（取り消し・受けた・連絡先カードなど）と、取り消しの理由
alter table public.messages add column if not exists kind text not null default 'user';
do $$ begin
  if not exists(select 1 from pg_constraint where conname = 'messages_kind_check') then
    alter table public.messages add constraint messages_kind_check check (kind in ('user','system'));
  end if;
end $$;
alter table public.requests add column if not exists cancel_reason text check (char_length(cancel_reason) <= 100);
-- ほかの人に決まったために自動で見送りになった申し込み（不成立になったら申し込み直せる）
alter table public.requests add column if not exists auto_declined boolean not null default false;
alter table public.listings add column if not exists cancel_reason text check (char_length(cancel_reason) <= 100);

-- 連絡先カード（本人だけが編集。送ったときだけ相手に見える）
create table if not exists public.contact_cards (
  owner       uuid primary key default auth.uid() references public.profiles(id) on delete cascade,
  phone       text check (char_length(phone) <= 20),
  line_id     text check (char_length(line_id) <= 40),
  address     text check (char_length(address) <= 100),
  hours       text check (char_length(hours) <= 60),
  note        text check (char_length(note) <= 200),
  updated_at  timestamptz not null default now()
);

-- やり取りの中で送られた連絡先カード（送った時点の内容。受け渡し済みから3日たつと相手から見えなくなる）
create table if not exists public.deal_cards (
  request_id  uuid not null references public.requests(id) on delete cascade,
  sender      uuid not null references public.profiles(id) on delete cascade,
  data        jsonb not null,
  created_at  timestamptz not null default now(),
  primary key (request_id, sender)
);

-- お店の買い取り希望
create table if not exists public.wants (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops(id) on delete cascade,
  owner       uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  species     text not null check (char_length(species) between 1 and 40),
  min_len     numeric(5,1) check (min_len > 0 and min_len < 400),
  max_len     numeric(5,1) check (max_len > 0 and max_len < 400),
  shime       text[] not null default '{}' check (shime <@ array['活魚','脳締め','氷締め','野締め']::text[]),
  treat       text[] not null default '{}' check (treat <@ array['血抜き','神経締め','内臓除去']::text[]),
  price_yen   int check (price_yen between 0 and 1000000),
  price_unit  text not null default '1匹' check (price_unit in ('1匹','1kg')),
  area        text check (char_length(area) <= 40),
  until       date not null,
  memo        text check (char_length(memo) <= 400),
  status      text not null default 'open' check (status in ('open','closed')),
  created_at  timestamptz not null default now()
);
create index if not exists wants_open_idx on public.wants(status, until);

-- 受け渡し済みの取引の評価（お互いに1回ずつ。3項目×1〜5）
create table if not exists public.ratings (
  id          bigint generated always as identity primary key,
  request_id  uuid not null references public.requests(id) on delete cascade,
  rater       uuid not null references public.profiles(id) on delete cascade,
  ratee       uuid not null references public.profiles(id) on delete cascade,
  s1          smallint not null check (s1 between 1 and 5),
  s2          smallint not null check (s2 between 1 and 5),
  s3          smallint not null check (s3 between 1 and 5),
  comment     text check (char_length(comment) <= 200),
  created_at  timestamptz not null default now(),
  unique (request_id, rater)
);
create index if not exists ratings_ratee_idx on public.ratings(ratee);

-- みんなの投稿（写真・ブログ）
create table if not exists public.posts (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind          text not null check (kind in ('photo','blog')),
  title         text check (char_length(title) <= 80),
  body          text check (char_length(body) <= 5000),
  photos        text[] not null default '{}',
  species       text check (char_length(species) <= 40),
  size_cm       numeric(5,1) check (size_cm > 0 and size_cm < 400),
  count         int check (count between 1 and 10000),
  method        text check (char_length(method) <= 40),
  shime         text check (char_length(shime) <= 40),
  caught_at     timestamptz,
  place         text check (char_length(place) <= 40),           -- 本人が書く大まかな場所（誰でも見える）
  lat           double precision check (lat between -90 and 90),  -- 釣った位置（ログインした人だけに見える）
  lon           double precision check (lon between -180 and 180),
  allow_comments boolean not null default true,
  status        text not null default 'public' check (status in ('public','removed')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists posts_time_idx on public.posts(status, created_at desc);
create index if not exists posts_owner_idx on public.posts(owner);

create table if not exists public.post_likes (
  post_id     uuid not null references public.posts(id) on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.post_comments (
  id          bigint generated always as identity primary key,
  post_id     uuid not null references public.posts(id) on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 500),
  created_at  timestamptz not null default now()
);
create index if not exists post_comments_post_idx on public.post_comments(post_id, id);

-- 投稿・コメントの通報
create table if not exists public.post_reports (
  id          bigint generated always as identity primary key,
  post_id     uuid not null references public.posts(id) on delete cascade,
  comment_id  bigint references public.post_comments(id) on delete cascade,
  reporter    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  reason      text not null check (reason in ('釣り場や個人の情報が書かれている','不適切な写真・言葉','他人の写真・うその内容','宣伝・迷惑行為','その他')),
  detail      text check (char_length(detail) <= 400),
  status      text not null default 'open' check (status in ('open','closed')),
  created_at  timestamptz not null default now()
);

-- ダイレクトメッセージ（1対1）とブロック
create table if not exists public.dm_threads (
  id          uuid primary key default gen_random_uuid(),
  a           uuid not null references public.profiles(id) on delete cascade,
  b           uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  last_at     timestamptz not null default now(),
  check (a < b),
  unique (a, b)
);
create table if not exists public.dm_messages (
  id          bigint generated always as identity primary key,
  thread_id   uuid not null references public.dm_threads(id) on delete cascade,
  sender      uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 1000),
  created_at  timestamptz not null default now()
);
create index if not exists dm_messages_thread_idx on public.dm_messages(thread_id, id);
create table if not exists public.blocks (
  blocker     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  blocked     uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker, blocked)
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

-- 電話番号の認証が済んでいるか（管理者は不要）
create or replace function public.phone_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select is_admin()
      or coalesce((select v from app_settings where k = 'require_phone'), 'off') <> 'on'   -- 認証を求めない設定のあいだは全員OK
      or exists(select 1 from profiles where id = auth.uid() and phone_verified_at is not null and not banned)
$$;
create or replace function public.phone_hash_of(p text) returns text
language sql stable security definer set search_path = public as $$
  select encode(extensions.digest(regexp_replace(p, '\D', '', 'g') || (select v from app_secrets where k = 'phone_salt'), 'sha256'), 'hex')
$$;
revoke execute on function public.phone_hash_of(text) from public, anon, authenticated;

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

-- 会員か（管理者は常に会員）
create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and not banned
                  and (role = 'admin' or member_until >= (now() at time zone 'Asia/Tokyo')::date))
$$;

-- 公開中の投稿か／自分の投稿か（RLS の中から投稿を調べるため）
create or replace function public.post_is_public(p_post uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from posts where id = p_post and status = 'public')
$$;
create or replace function public.is_my_post(p_post uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from posts where id = p_post and owner = auth.uid())
$$;

-- どちらかがブロックしているか
create or replace function public.is_blocked(p_a uuid, p_b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from blocks where (blocker = p_a and blocked = p_b) or (blocker = p_b and blocked = p_a))
$$;

-- やり取りに自動のお知らせを書く
create or replace function public.sysmsg(p_request uuid, p_body text) returns void
language sql security definer set search_path = public as $$
  insert into messages(request_id, sender, body, kind) values (p_request, auth.uid(), left(p_body, 1000), 'system')
$$;

-- 評価のまとめ（3件未満は平均を出さない）
create or replace function public.rating_of(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('n', count(*),
           'avg', case when count(*) >= 3 then round(avg((s1 + s2 + s3) / 3.0), 1) end)
    from ratings where ratee = p_user
$$;

-- 買い取り希望と出品が合うか
create or replace function public.want_matches(w public.wants, l public.listings) returns boolean
language sql stable as $$
  select (position(kana_norm(w.species) in kana_norm(l.species)) > 0 or position(kana_norm(l.species) in kana_norm(w.species)) > 0)
     and (w.min_len is null or l.length_cm >= w.min_len)
     and (w.max_len is null or l.length_cm <= w.max_len)
     and (cardinality(w.shime) = 0 or l.shime = any(w.shime))
     and (w.treat <@ l.treat)
$$;

-- ---------------------------------------------------------------------
-- 4. 書き込み時のチェック（トリガー）
--    auth.uid() が空＝SQL Editor など管理画面からの操作は素通しにする
-- ---------------------------------------------------------------------

-- 利用者：自分で role（管理者）や banned（停止）を変えられないようにする
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.banned and not old.banned and new.phone_hash is not null then
    -- 利用停止した人の電話番号は、作り直しても認証できないように残す
    insert into banned_phones(phone_hash, note) values (new.phone_hash, '利用停止：' || new.nickname) on conflict do nothing;
  end if;
  if auth.uid() is null or is_admin() then return new; end if;
  if tg_op = 'INSERT' then
    new.id := auth.uid(); new.role := 'user'; new.banned := false; new.member_until := null;
    new.phone_verified_at := null; new.phone_hash := null; new.phone_tail := null;
    new.agreed_at := now(); new.created_at := now();
  else
    if new.role is distinct from old.role or new.banned is distinct from old.banned
       or new.member_until is distinct from old.member_until or new.id <> old.id
       or ((new.phone_verified_at is distinct from old.phone_verified_at or new.phone_hash is distinct from old.phone_hash)
           and coalesce(current_setting('app.phone_verify', true), '') <> '1')
       or (new.phone_tail is distinct from old.phone_tail and coalesce(current_setting('app.phone_verify', true), '') <> '1') then
      raise exception '権限がありません';
    end if;
  end if;
  if new.avatar is not null and new.avatar not like new.id::text || '/%' then
    raise exception 'アイコンは自分のフォルダの画像だけ設定できます';
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
  if not is_member() then raise exception 'お店の登録は会員の機能です'; end if;
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
  if not is_member() then raise exception 'おすそわけ・お店向けの出品は会員の機能です'; end if;
  if not phone_ok() then raise exception '出品の前に、電話番号の認証をしてください'; end if;
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

-- 買い取り希望：承認済みのお店だけ。期限は60日以内、同時に10件まで
create or replace function public.wants_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_reason text; v_n int;
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' then
    if new.owner <> old.owner or new.shop_id <> old.shop_id then raise exception '権限がありません'; end if;
    return new;
  end if;
  new.owner := auth.uid(); new.status := 'open'; new.created_at := now();
  if not is_member() then raise exception '買い取り希望は会員の機能です'; end if;
  new.shop_id := my_shop();
  if new.shop_id is null then raise exception '買い取り希望を出せるのは、承認済みのお店だけです'; end if;
  v_reason := blocked_reason(new.species);
  if v_reason is not null then raise exception 'この種類は扱えません（%）', v_reason; end if;
  if new.min_len is not null and new.max_len is not null and new.min_len > new.max_len then
    raise exception 'サイズの範囲が逆になっています';
  end if;
  if new.until < (now() at time zone 'Asia/Tokyo')::date or new.until > (now() at time zone 'Asia/Tokyo')::date + 60 then
    raise exception '期限は今日から60日以内にしてください';
  end if;
  select count(*) into v_n from wants where shop_id = new.shop_id and status = 'open'
     and until >= (now() at time zone 'Asia/Tokyo')::date;
  if v_n >= 10 then raise exception '受付中の買い取り希望は10件までです'; end if;
  return new;
end $$;
drop trigger if exists wants_guard on public.wants;
create trigger wants_guard before insert or update on public.wants
  for each row execute function public.wants_guard();

-- 連絡先カード：本人のものだけ
create or replace function public.contact_cards_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  new.owner := auth.uid(); new.updated_at := now();
  return new;
end $$;
drop trigger if exists contact_cards_guard on public.contact_cards;
create trigger contact_cards_guard before insert or update on public.contact_cards
  for each row execute function public.contact_cards_guard();

-- 投稿：会員だけ。写真は自分のフォルダ、6枚まで。1日20件まで
create or replace function public.posts_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' then
    if is_admin() and new.owner <> auth.uid() then
      new.owner := old.owner; return new;                  -- 管理者は削除（status）だけ
    end if;
    if old.owner <> auth.uid() then raise exception '権限がありません'; end if;
    new.owner := old.owner; new.created_at := old.created_at; new.updated_at := now();
    if new.status <> old.status and new.status <> 'removed' then raise exception '権限がありません'; end if;
  else
    if not is_member() then raise exception '投稿は会員の機能です'; end if;
    new.owner := auth.uid(); new.created_at := now(); new.updated_at := now(); new.status := 'public';
    select count(*) into v_n from posts where owner = auth.uid() and created_at > now() - interval '24 hours';
    if v_n >= 20 then raise exception '投稿は1日20件までです'; end if;
  end if;
  if coalesce(array_length(new.photos, 1), 0) > 6 then raise exception '写真は6枚までです'; end if;
  if exists(select 1 from unnest(new.photos) p where split_part(p, '/', 1) <> new.owner::text) then
    raise exception '写真の保存先が正しくありません';
  end if;
  if new.kind = 'blog' and coalesce(btrim(new.title), '') = '' then raise exception 'ブログにはタイトルを付けてください'; end if;
  if new.kind = 'photo' and coalesce(array_length(new.photos, 1), 0) = 0 then raise exception '写真を1枚以上つけてください'; end if;
  if (new.lat is null) <> (new.lon is null) then raise exception '位置が正しくありません'; end if;
  return new;
end $$;
drop trigger if exists posts_guard on public.posts;
create trigger posts_guard before insert or update on public.posts
  for each row execute function public.posts_guard();

-- コメント：コメントを受け付けている公開中の投稿だけ。ブロックされていたら書けない
create or replace function public.post_comments_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare p posts; v_n int;
begin
  if auth.uid() is null then return new; end if;
  if not is_active_user() then raise exception 'コメントするには表示名の登録が必要です'; end if;
  new.user_id := auth.uid(); new.created_at := now();
  select * into p from posts where id = new.post_id;
  if not found or p.status <> 'public' then raise exception 'この投稿は見られなくなりました'; end if;
  if not p.allow_comments then raise exception 'この投稿はコメントを受け付けていません'; end if;
  if is_blocked(p.owner, auth.uid()) then raise exception 'この投稿にはコメントできません'; end if;
  select count(*) into v_n from post_comments where user_id = auth.uid() and created_at > now() - interval '1 hour';
  if v_n >= 30 then raise exception 'コメントは1時間に30件までです'; end if;
  return new;
end $$;
drop trigger if exists post_comments_guard on public.post_comments;
create trigger post_comments_guard before insert on public.post_comments
  for each row execute function public.post_comments_guard();

-- メッセージの相手とのやり取りを開く（なければ作る）
create or replace function public.dm_open(p_user uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_a uuid; v_b uuid; v_id uuid;
begin
  if not is_active_user() then raise exception 'メッセージを送るには表示名の登録が必要です'; end if;
  if p_user = auth.uid() then raise exception '自分にはメッセージを送れません'; end if;
  if not exists(select 1 from profiles where id = p_user and not banned) then raise exception '相手が見つかりません'; end if;
  if is_blocked(auth.uid(), p_user) then raise exception 'この相手とはメッセージをやり取りできません'; end if;
  v_a := least(auth.uid(), p_user); v_b := greatest(auth.uid(), p_user);
  insert into dm_threads(a, b) values (v_a, v_b) on conflict (a, b) do nothing;
  select id into v_id from dm_threads where a = v_a and b = v_b;
  return v_id;
end $$;

-- 投稿者の id から相手を開く（投稿者の id は画面に出さないため、投稿から開く）
create or replace function public.dm_open_post(p_post uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_owner uuid;
begin
  select owner into v_owner from posts where id = p_post and status = 'public';
  if not found then raise exception 'この投稿は見られなくなりました'; end if;
  return dm_open(v_owner);
end $$;

create or replace function public.dm_messages_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare t dm_threads; v_n int;
begin
  if auth.uid() is null then return new; end if;
  new.sender := auth.uid(); new.created_at := now();
  select * into t from dm_threads where id = new.thread_id;
  if not found or auth.uid() not in (t.a, t.b) then raise exception '権限がありません'; end if;
  if not is_active_user() then raise exception '利用が停止されています'; end if;
  if is_blocked(t.a, t.b) then raise exception 'この相手とはメッセージをやり取りできません'; end if;
  select count(*) into v_n from dm_messages where sender = auth.uid() and created_at > now() - interval '1 hour';
  if v_n >= 60 then raise exception 'メッセージは1時間に60件までです'; end if;
  update dm_threads set last_at = now() where id = t.id;
  return new;
end $$;
drop trigger if exists dm_messages_guard on public.dm_messages;
create trigger dm_messages_guard before insert on public.dm_messages
  for each row execute function public.dm_messages_guard();

-- メッセージの相手をブロック／解除する
create or replace function public.dm_block(p_thread uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare t dm_threads; v_other uuid;
begin
  select * into t from dm_threads where id = p_thread;
  if not found or auth.uid() not in (t.a, t.b) then raise exception '権限がありません'; end if;
  v_other := case when t.a = auth.uid() then t.b else t.a end;
  if p_on then insert into blocks(blocker, blocked) values (auth.uid(), v_other) on conflict do nothing;
  else delete from blocks where blocker = auth.uid() and blocked = v_other; end if;
end $$;

-- 前の版の仕組み（本人ごとの共有オン・オフ）は使わないので外す
drop trigger if exists profiles_share_off on public.profiles;
drop function if exists public.profiles_share_off();
drop function if exists public.shared_catches_guard();

-- 釣果を受け取る（端末から最大500件ずつ。同じ端末・同じ記録は上書き）
create or replace function public.push_catches(p_device text, p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int; total int;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  if not is_member() then raise exception '釣果の記録は会員の機能です'; end if;
  if char_length(coalesce(p_device, '')) not between 8 and 64 then raise exception '端末の番号が正しくありません'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 500 then
    raise exception '一度に送れるのは500件までです';
  end if;
  insert into shared_catches(device_id, local_id, owner, caught_at, species, count, lat, lon, data, updated_at)
  select p_device, left(r->>'local_id', 40), auth.uid(), (r->>'caught_at')::timestamptz,
         left(coalesce(nullif(r->>'species', ''), '不明'), 40),
         round(nullif(r->>'count', '')::numeric)::int,
         (r->>'lat')::float8, (r->>'lon')::float8,
         case when jsonb_typeof(r->'data') = 'object' then r->'data' else '{}'::jsonb end, now()
    from jsonb_array_elements(p_rows) r
   where coalesce(r->>'local_id', '') <> '' and r->>'lat' is not null and r->>'lon' is not null and r->>'caught_at' is not null
  on conflict (device_id, local_id) do update
     set owner = excluded.owner, caught_at = excluded.caught_at, species = excluded.species, count = excluded.count,
         lat = excluded.lat, lon = excluded.lon, data = excluded.data, updated_at = now();
  get diagnostics n = row_count;
  select count(*) into total from shared_catches where device_id = p_device;
  if total > 20000 then raise exception '1台あたりの上限（20000件）を超えました'; end if;
  return n;
end $$;

-- 端末で記録を消したとき
create or replace function public.forget_catch(p_device text, p_local text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  delete from shared_catches where device_id = p_device and local_id = p_local;
end $$;

-- 提供をやめたとき（その端末から届いた記録をすべて消す）
create or replace function public.forget_device(p_device text)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  if char_length(coalesce(p_device, '')) < 8 then raise exception '端末の番号が正しくありません'; end if;
  delete from shared_catches where device_id = p_device;
  get diagnostics n = row_count;
  return n;
end $$;

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
  if not is_member() then raise exception 'おすそわけへの申し込みは会員の機能です'; end if;
  if not phone_ok() then raise exception '申し込みの前に、電話番号の認証をしてください'; end if;
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
  -- 自分で取り消した申し込みと、ほかの人に決まったため見送りになった申し込みは、申し込み直せる
  select id into v_id from requests where listing_id = p_listing and requester = auth.uid();
  if found then
    update requests set status = 'pending', message = p_message, offer_yen = p_offer, shop_id = v_shop,
                        cancel_reason = null, auto_declined = false, updated_at = now()
     where id = v_id and (status = 'cancelled' or (status = 'declined' and auto_declined));
    if not found then raise exception 'この出品にはすでに申し込んでいます'; end if;
    perform sysmsg(v_id, 'もう一度申し込みました：' || left(p_message, 300));
    return v_id;
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
declare r requests; l listings; o record;
begin
  select * into r from requests where id = p_request for update;
  if not found then raise exception '申し込みが見つかりません'; end if;
  select * into l from listings where id = r.listing_id for update;
  if l.owner <> auth.uid() then raise exception '権限がありません'; end if;
  if r.status <> 'pending' then raise exception 'この申し込みはすでに処理されています'; end if;
  if p_accept then
    if l.status <> 'open' or l.expires_at <= now() then raise exception 'この出品は受付を終了しています'; end if;
    update requests set status = 'accepted', updated_at = now() where id = r.id;
    perform sysmsg(r.id, '出品者が申し込みを受けました。受け渡しの場所と時間を決めてください。');
    for o in select id from requests where listing_id = l.id and id <> r.id and status = 'pending' loop
      update requests set status = 'declined', auto_declined = true, updated_at = now() where id = o.id;
      perform sysmsg(o.id, 'ほかの方に決まったため、今回は見送りになりました。取引が成立しなかった場合は、お知らせします。');
    end loop;
    update listings set status = 'reserved' where id = l.id;
  else
    update requests set status = 'declined', updated_at = now() where id = r.id;
    perform sysmsg(r.id, '出品者が今回は見送りました。');
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
  perform sysmsg(r.id, '受け渡しが完了しました。よければお互いに評価してください。');
end $$;

-- 申込者が申し込みを取り消す（受けてもらった後なら出品は受付中に戻る）。理由は相手に伝わる
drop function if exists public.cancel_request(uuid);
create or replace function public.cancel_request(p_request uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r requests; o record;
begin
  select * into r from requests where id = p_request for update;
  if not found or r.requester <> auth.uid() then raise exception '権限がありません'; end if;
  if r.status not in ('pending','accepted') then raise exception 'この申し込みは取り消せません'; end if;
  update requests set status = 'cancelled', cancel_reason = left(p_reason, 100), updated_at = now() where id = r.id;
  perform sysmsg(r.id, '申込者が取り消しました' || coalesce('（理由：' || left(p_reason, 100) || '）', '') || '。');
  if r.status = 'accepted' then
    update listings set status = 'open' where id = r.listing_id and status = 'reserved' and expires_at > now();
    if found then                                    -- 見送りになっていた人に、また申し込めることを知らせる
      for o in select id from requests where listing_id = r.listing_id and status = 'declined' and auto_declined loop
        perform sysmsg(o.id, '決まっていた方の取引が成立しなかったため、出品が受付中に戻りました。「もう一度申し込む」から申し込めます。');
      end loop;
    end if;
  end if;
end $$;

-- 出品者が出品を取り下げる（申し込みはすべて取り消しになり、相手にお知らせが届く）
drop function if exists public.cancel_listing(uuid);
create or replace function public.cancel_listing(p_listing uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare l listings; o record;
begin
  select * into l from listings where id = p_listing for update;
  if not found or l.owner <> auth.uid() then raise exception '権限がありません'; end if;
  if l.status not in ('open','reserved') then raise exception 'この出品は取り下げられません'; end if;
  update listings set status = 'cancelled', cancel_reason = left(p_reason, 100) where id = l.id;
  for o in select id from requests where listing_id = l.id and status in ('pending','accepted') loop
    update requests set status = 'cancelled', cancel_reason = left(p_reason, 100), updated_at = now() where id = o.id;
    perform sysmsg(o.id, '出品者が出品を取り下げました' || coalesce('（理由：' || left(p_reason, 100) || '）', '') || '。');
  end loop;
end $$;

-- 出品者が出品の内容を直す（魚種・釣った日時・写真・位置は変えられない。申し込んでいる人にはお知らせが届く）
create or replace function public.update_listing(p_listing uuid, p_patch jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare l listings; o record; v_shime_at timestamptz; v_treat text[];
begin
  select * into l from listings where id = p_listing for update;
  if not found or l.owner <> auth.uid() then raise exception '権限がありません'; end if;
  if not is_active_user() then raise exception '利用が停止されています'; end if;
  if l.status not in ('open','reserved') or l.expires_at <= now() then raise exception '受付中の出品だけ編集できます'; end if;
  v_shime_at := nullif(p_patch->>'shime_at', '')::timestamptz;
  if v_shime_at is not null and (v_shime_at < l.caught_at - interval '10 minutes' or v_shime_at > now() + interval '10 minutes') then
    raise exception '締めた日時は、釣った日時（%）より後で、今より前にしてください', to_char(l.caught_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI');
  end if;
  v_treat := coalesce(array(select jsonb_array_elements_text(p_patch->'treat')), '{}');
  update listings set
    count       = (p_patch->>'count')::int,
    length_cm   = nullif(p_patch->>'length_cm', '')::numeric,
    shime       = p_patch->>'shime',
    treat       = v_treat,
    shime_at    = v_shime_at,
    cooling     = nullif(p_patch->>'cooling', ''),
    pickup_area = p_patch->>'pickup_area',
    handoff     = case when l.kind = 'gift' then '取りに来てもらう' else coalesce(nullif(p_patch->>'handoff', ''), l.handoff) end,
    price_yen   = case when l.kind = 'gift' then null else nullif(p_patch->>'price_yen', '')::int end,
    memo        = nullif(left(p_patch->>'memo', 400), '')
  where id = l.id;
  for o in select id from requests where listing_id = l.id and status in ('pending','accepted') loop
    perform sysmsg(o.id, '出品者が出品の内容を変更しました。「探す」や出品の詳細で確認してください。');
  end loop;
end $$;

-- 連絡先カードを相手に送る（申し込みを受けたあとだけ）
create or replace function public.send_card(p_request uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r requests; c contact_cards; d jsonb; nick text;
begin
  select * into r from requests where id = p_request;
  if not found or not is_request_party(p_request) then raise exception '権限がありません'; end if;
  if r.status <> 'accepted' then raise exception '連絡先カードを送れるのは、申し込みを受けたあとだけです'; end if;
  select * into c from contact_cards where owner = auth.uid();
  d := jsonb_strip_nulls(jsonb_build_object('phone', nullif(c.phone, ''), 'line_id', nullif(c.line_id, ''),
         'address', nullif(c.address, ''), 'hours', nullif(c.hours, ''), 'note', nullif(c.note, '')));
  if not found or d = '{}'::jsonb then raise exception '先に「連絡先カード」を作ってください'; end if;
  insert into deal_cards(request_id, sender, data) values (p_request, auth.uid(), d)
  on conflict (request_id, sender) do update set data = excluded.data, created_at = now();
  select nickname into nick from profiles where id = auth.uid();
  perform sysmsg(p_request, nick || 'さんが連絡先カードを送りました。');
end $$;

-- 受け渡し済みの取引を評価する（30日以内・1回だけ）
create or replace function public.rate_deal(p_request uuid, p_s1 int, p_s2 int, p_s3 int, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r requests; l listings; v_ratee uuid;
begin
  select * into r from requests where id = p_request;
  if not found or not is_request_party(p_request) then raise exception '権限がありません'; end if;
  if r.status <> 'done' then raise exception '評価できるのは受け渡し済みの取引だけです'; end if;
  if r.updated_at < now() - interval '30 days' then raise exception '評価できるのは受け渡しから30日以内です'; end if;
  select * into l from listings where id = r.listing_id;
  v_ratee := case when l.owner = auth.uid() then r.requester else l.owner end;
  insert into ratings(request_id, rater, ratee, s1, s2, s3, comment)
  values (p_request, auth.uid(), v_ratee, p_s1, p_s2, p_s3, nullif(left(p_comment, 200), ''));
exception when unique_violation then
  raise exception 'この取引はすでに評価しました';
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
  rating_of(l.owner) as owner_rating,
  (p.phone_verified_at is not null) as owner_verified,
  (my_shop() is not null and exists(select 1 from wants w where w.shop_id = my_shop() and w.status = 'open'
      and w.until >= (now() at time zone 'Asia/Tokyo')::date and want_matches(w, l))) as matches_my_want,
  l.cancel_reason,
  (l.owner = auth.uid()) as mine,
  (select r.id from requests r where r.listing_id = l.id and r.requester = auth.uid()
      and (r.status in ('pending','accepted','done') or (r.status = 'declined' and not r.auto_declined))) as my_request,
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
  (r.requester = auth.uid()) as i_am_requester,
  (l.owner = auth.uid() or r.requester = auth.uid()) as i_am_party,
  (select count(*) from messages m where m.request_id = r.id) as msg_count,
  (select max(m.created_at) from messages m where m.request_id = r.id and m.sender <> auth.uid()) as last_msg_at,
  r.cancel_reason, r.auto_declined,
  (r.requester = auth.uid() and (r.status = 'cancelled' or (r.status = 'declined' and r.auto_declined))
     and l.status = 'open' and l.expires_at > now()) as can_reapply,
  rating_of(case when l.owner = auth.uid() then r.requester else l.owner end) as other_rating,
  (case when l.owner = auth.uid() then rp.phone_verified_at else op.phone_verified_at end) is not null as other_verified,
  exists(select 1 from ratings g where g.request_id = r.id and g.rater = auth.uid()) as my_rated,
  (r.status = 'done' and r.updated_at > now() - interval '30 days') as can_rate
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

-- 買い取り希望の一覧（ログインした人が見られる。受付中のもの＋自分のお店のもの）
drop view if exists public.want_cards;
create view public.want_cards with (security_barrier = true) as
select w.*, s.name as shop_name, s.area as shop_area, (w.owner = auth.uid()) as mine,
       (w.status = 'open' and w.until >= (now() at time zone 'Asia/Tokyo')::date) as active
from public.wants w join public.shops s on s.id = w.shop_id
where auth.uid() is not null
  and (w.owner = auth.uid() or is_admin()
       or (w.status = 'open' and w.until >= (now() at time zone 'Asia/Tokyo')::date and s.status = 'approved' and is_active_user()));

-- 管理者用：評価の一覧
drop view if exists public.rating_cards;
create view public.rating_cards with (security_barrier = true) as
select g.id, g.request_id, g.s1, g.s2, g.s3, g.comment, g.created_at,
       a.nickname as rater_name, b.nickname as ratee_name, l.species, l.kind, (l.owner = g.ratee) as ratee_is_owner
from public.ratings g
join public.profiles a on a.id = g.rater
join public.profiles b on b.id = g.ratee
join public.requests r on r.id = g.request_id
join public.listings l on l.id = r.listing_id
where is_admin();

-- みんなの投稿（ログインしなくても見られる。釣った位置はログインした人だけ）
drop view if exists public.post_cards;
create view public.post_cards with (security_barrier = true) as
select p.id, p.kind, p.title, p.body, p.photos, p.species, p.size_cm, p.count, p.method, p.shime, p.caught_at, p.place,
       case when is_member() or p.owner = auth.uid() then p.lat end as lat,   -- 釣った位置は会員だけ
       case when is_member() or p.owner = auth.uid() then p.lon end as lon,
       (p.lat is not null) as has_pos,
       p.allow_comments, p.status, p.created_at, p.updated_at,
       u.nickname as owner_name, u.avatar as owner_avatar,
       (p.owner = auth.uid()) as mine,
       (select count(*) from post_likes k where k.post_id = p.id) as like_count,
       (select count(*) from post_comments c where c.post_id = p.id) as comment_count,
       exists(select 1 from post_likes k where k.post_id = p.id and k.user_id = auth.uid()) as liked
from public.posts p join public.profiles u on u.id = p.owner
where (p.status = 'public' and not u.banned) or p.owner = auth.uid() or is_admin();

drop view if exists public.comment_cards;
create view public.comment_cards with (security_barrier = true) as
select c.id, c.post_id, c.body, c.created_at, u.nickname as user_name, u.avatar as user_avatar,
       (c.user_id = auth.uid()) as mine,
       exists(select 1 from posts p where p.id = c.post_id and p.owner = auth.uid()) as on_my_post
from public.post_comments c
join public.profiles u on u.id = c.user_id
join public.posts p on p.id = c.post_id
where (p.status = 'public' and not u.banned) or p.owner = auth.uid() or is_admin();

-- メッセージの一覧（自分の分だけ）
drop view if exists public.dm_cards;
create view public.dm_cards with (security_barrier = true) as
select t.id, t.last_at, o.nickname as other_name, o.avatar as other_avatar,
       exists(select 1 from blocks k where k.blocker = auth.uid() and k.blocked = o.id) as i_blocked,
       is_blocked(t.a, t.b) as blocked,
       (select m.body from dm_messages m where m.thread_id = t.id order by m.id desc limit 1) as last_body,
       (select max(m.created_at) from dm_messages m where m.thread_id = t.id and m.sender <> auth.uid()) as last_in_at
from public.dm_threads t
join public.profiles o on o.id = case when t.a = auth.uid() then t.b else t.a end
where auth.uid() in (t.a, t.b);

-- 管理者用：投稿の通報
drop view if exists public.post_report_cards;
create view public.post_report_cards with (security_barrier = true) as
select r.id, r.reason, r.detail, r.status, r.created_at, r.post_id, r.comment_id,
       coalesce(p.title, left(p.body, 40)) as post_title, pu.nickname as owner_name,
       c.body as comment_body, cu.nickname as comment_user, ru.nickname as reporter_name
from public.post_reports r
join public.posts p on p.id = r.post_id
join public.profiles pu on pu.id = p.owner
join public.profiles ru on ru.id = r.reporter
left join public.post_comments c on c.id = r.comment_id
left join public.profiles cu on cu.id = c.user_id
where is_admin();

-- 管理者用：利用者の一覧（会員の期限を管理する）
drop view if exists public.user_cards;
create view public.user_cards with (security_barrier = true) as
select p.id, p.nickname, p.role, p.banned, p.member_until, p.created_at, u.email, u.last_sign_in_at,
       p.phone_verified_at, p.phone_tail,
       (select count(*) from posts x where x.owner = p.id) as posts,
       (select count(*) from listings x where x.owner = p.id) as listings
from public.profiles p join auth.users u on u.id = p.id
where is_admin();

-- 管理者用：提供された釣果（ログインしていない端末は「匿名-端末番号の頭4文字」）
drop view if exists public.shared_catch_cards;
create view public.shared_catch_cards with (security_barrier = true) as
select c.*, coalesce(n.nickname, '匿名-' || left(c.device_id, 4)) as nickname, (n.nickname is not null) as registered
from public.shared_catches c
left join lateral (                                 -- 同じ端末でログインしたことがあれば、その表示名
  select p.nickname from public.shared_catches c2 join public.profiles p on p.id = c2.owner
   where c2.device_id = c.device_id order by (c2.owner = c.owner) desc, c2.updated_at desc limit 1) n on true
where is_admin();

-- 管理者用：利用状況のまとめ
create or replace function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare j jsonb;
begin
  if not is_admin() then raise exception '権限がありません'; end if;
  select jsonb_build_object(
    'users',          (select count(*) from profiles),
    'users_7d',       (select count(*) from profiles where created_at > now() - interval '7 days'),
    'users_30d',      (select count(*) from profiles where created_at > now() - interval '30 days'),
    'signins_7d',     (select count(*) from auth.users where last_sign_in_at > now() - interval '7 days' and not coalesce(is_anonymous, false)),
    'active_30d',     (select count(distinct u) from (
                         select owner u from listings where created_at > now() - interval '30 days'
                         union select requester from requests where created_at > now() - interval '30 days'
                         union select sender from messages where created_at > now() - interval '30 days') t),
    'banned',         (select count(*) from profiles where banned),
    'sharing_devices',(select count(distinct device_id) from shared_catches),
    'shared_7d',      (select count(*) from shared_catches where caught_at > now() - interval '7 days'),
    'listings',       (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select kind || '_' || status k, count(*) n from listings group by 1) t),
    'listings_30d',   (select count(*) from listings where created_at > now() - interval '30 days'),
    'requests',       (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) from (select status, count(*) n from requests group by 1) t),
    'messages',       (select count(*) from messages),
    'shops',          (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) from (select status, count(*) n from shops group by 1) t),
    'reports_open',   (select count(*) from reports where status = 'open'),
    'members',        (select count(*) from profiles where role = 'admin' or member_until >= (now() at time zone 'Asia/Tokyo')::date),
    'posts',          (select count(*) from posts where status = 'public'),
    'posts_7d',       (select count(*) from posts where status = 'public' and created_at > now() - interval '7 days'),
    'comments',       (select count(*) from post_comments),
    'likes',          (select count(*) from post_likes),
    'dms',            (select count(*) from dm_messages),
    'post_reports_open', (select count(*) from post_reports where status = 'open'),
    'wants_open',     (select count(*) from wants where status = 'open' and until >= (now() at time zone 'Asia/Tokyo')::date),
    'ratings',        (select count(*) from ratings),
    'cancels',        (select coalesce(jsonb_object_agg(cancel_reason, n), '{}'::jsonb) from (
                         select cancel_reason, count(*) n from requests where cancel_reason is not null group by 1) t),
    'top_species',    (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
                         select species, count(*) n, sum(count) fish from listings where status <> 'removed'
                         group by species order by 2 desc, 1 limit 10) t),
    'daily',          (select coalesce(jsonb_agg(t order by d), '[]'::jsonb) from (
                         select (created_at at time zone 'Asia/Tokyo')::date d,
                                count(*) filter (where kind = 'gift') gift, count(*) filter (where kind = 'shop') shop
                           from listings where created_at > now() - interval '30 days' group by 1) t),
    'shared_catches', (select count(*) from shared_catches),
    'shared_species', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
                         select species, count(*) n, sum(coalesce(count, 1)) fish from shared_catches
                         group by species order by 2 desc, 1 limit 10) t)
  ) into j;
  return j;
end $$;

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
alter table public.shared_catches enable row level security;
alter table public.contact_cards enable row level security;
alter table public.deal_cards    enable row level security;
alter table public.wants         enable row level security;
alter table public.ratings       enable row level security;
alter table public.posts         enable row level security;
alter table public.post_likes    enable row level security;
alter table public.post_comments enable row level security;
alter table public.post_reports  enable row level security;
alter table public.dm_threads    enable row level security;
alter table public.dm_messages   enable row level security;
alter table public.blocks        enable row level security;

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
    sender = auth.uid() and kind = 'user' and is_active_user() and is_request_party(request_id)
    and exists(select 1 from requests r where r.id = request_id and r.status in ('pending','accepted'))
  );

drop policy if exists reports_select on public.reports;
drop policy if exists reports_insert on public.reports;
drop policy if exists reports_update on public.reports;
create policy reports_select on public.reports for select to authenticated using (reporter = auth.uid() or is_admin());
create policy reports_insert on public.reports for insert to authenticated with check (reporter = auth.uid() and is_active_user());
create policy reports_update on public.reports for update to authenticated using (is_admin());

-- 提供された釣果：読めるのは管理者だけ。書き込みは push_catches などの関数を通してだけ
drop policy if exists shared_select on public.shared_catches;
drop policy if exists shared_insert on public.shared_catches;
drop policy if exists shared_update on public.shared_catches;
drop policy if exists shared_delete on public.shared_catches;
create policy shared_select on public.shared_catches for select to authenticated using (is_admin());
revoke insert, update, delete on public.shared_catches from authenticated;

drop policy if exists cards_own on public.contact_cards;
create policy cards_own on public.contact_cards for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid() and is_active_user());

-- 送られたカード：当事者が見られるのは、取引中か、受け渡し済みから3日以内。管理者はいつでも
drop policy if exists deal_cards_select on public.deal_cards;
create policy deal_cards_select on public.deal_cards for select to authenticated
  using (is_admin() or (is_request_party(request_id) and exists(
    select 1 from requests r where r.id = request_id
       and (r.status in ('pending','accepted') or (r.status = 'done' and r.updated_at > now() - interval '3 days')))));
revoke insert, update, delete on public.deal_cards from authenticated;

drop policy if exists wants_select on public.wants;
drop policy if exists wants_insert on public.wants;
drop policy if exists wants_update on public.wants;
create policy wants_select on public.wants for select to authenticated using (owner = auth.uid() or is_admin());
create policy wants_insert on public.wants for insert to authenticated with check (owner = auth.uid());
create policy wants_update on public.wants for update to authenticated using (owner = auth.uid() or is_admin());

drop policy if exists ratings_select on public.ratings;
drop policy if exists ratings_delete on public.ratings;
create policy ratings_select on public.ratings for select to authenticated using (rater = auth.uid() or is_admin());
create policy ratings_delete on public.ratings for delete to authenticated using (is_admin());
revoke insert, update on public.ratings from authenticated;

drop policy if exists posts_select on public.posts;
drop policy if exists posts_insert on public.posts;
drop policy if exists posts_update on public.posts;
drop policy if exists posts_delete on public.posts;
create policy posts_select on public.posts for select to authenticated using (owner = auth.uid() or is_admin());
create policy posts_insert on public.posts for insert to authenticated with check (owner = auth.uid());
create policy posts_update on public.posts for update to authenticated using (owner = auth.uid() or is_admin());
create policy posts_delete on public.posts for delete to authenticated using (owner = auth.uid() or is_admin());

drop policy if exists likes_select on public.post_likes;
drop policy if exists likes_insert on public.post_likes;
drop policy if exists likes_delete on public.post_likes;
create policy likes_select on public.post_likes for select to authenticated using (user_id = auth.uid() or is_admin());
create policy likes_insert on public.post_likes for insert to authenticated
  with check (user_id = auth.uid() and is_active_user() and post_is_public(post_id));
create policy likes_delete on public.post_likes for delete to authenticated using (user_id = auth.uid());

drop policy if exists comments_select on public.post_comments;
drop policy if exists comments_insert on public.post_comments;
drop policy if exists comments_delete on public.post_comments;
create policy comments_select on public.post_comments for select to authenticated using (user_id = auth.uid() or is_admin() or is_my_post(post_id));
create policy comments_insert on public.post_comments for insert to authenticated with check (user_id = auth.uid());
create policy comments_delete on public.post_comments for delete to authenticated   -- 自分のコメント・自分の投稿へのコメント・管理者
  using (user_id = auth.uid() or is_admin() or is_my_post(post_id));

drop policy if exists preports_select on public.post_reports;
drop policy if exists preports_insert on public.post_reports;
drop policy if exists preports_update on public.post_reports;
create policy preports_select on public.post_reports for select to authenticated using (reporter = auth.uid() or is_admin());
create policy preports_insert on public.post_reports for insert to authenticated with check (reporter = auth.uid() and is_active_user());
create policy preports_update on public.post_reports for update to authenticated using (is_admin());

drop policy if exists dmt_select on public.dm_threads;
create policy dmt_select on public.dm_threads for select to authenticated using (auth.uid() in (a, b) or is_admin());
revoke insert, update, delete on public.dm_threads from authenticated;
drop policy if exists dmm_select on public.dm_messages;
drop policy if exists dmm_insert on public.dm_messages;
create policy dmm_select on public.dm_messages for select to authenticated
  using (is_admin() or exists(select 1 from dm_threads t where t.id = thread_id and auth.uid() in (t.a, t.b)));
create policy dmm_insert on public.dm_messages for insert to authenticated with check (sender = auth.uid());
drop policy if exists blocks_select on public.blocks;
create policy blocks_select on public.blocks for select to authenticated using (blocker = auth.uid() or is_admin());
revoke insert, update, delete on public.blocks from authenticated;

-- ログインしていない人（anon）には何も見せない。操作は関数経由
revoke all on public.profiles, public.shops, public.listings, public.requests, public.messages, public.reports, public.shared_catches,
  public.contact_cards, public.deal_cards, public.wants, public.ratings,
  public.posts, public.post_likes, public.post_comments, public.post_reports, public.dm_threads, public.dm_messages, public.blocks from anon;
revoke all on public.listing_cards, public.request_cards, public.report_cards, public.shop_cards, public.shared_catch_cards,
  public.want_cards, public.rating_cards, public.dm_cards, public.post_report_cards, public.user_cards from anon;
grant select on public.listing_cards, public.request_cards, public.report_cards, public.shop_cards, public.shared_catch_cards,
  public.want_cards, public.rating_cards, public.post_cards, public.comment_cards, public.dm_cards, public.post_report_cards, public.user_cards to authenticated;
grant select on public.post_cards, public.comment_cards to anon;        -- みんなの投稿はログインしなくても見られる（位置は出ない）
revoke update on public.wants from authenticated;
grant  update (status) on public.wants to authenticated;
grant select on public.blocked_terms to anon, authenticated;
-- 画面から直接さわれるのは必要な列・操作だけ
revoke update on public.listings from authenticated;
grant  update (status) on public.listings to authenticated;          -- 管理者の削除（removed）用。RLSで管理者に限定
revoke update on public.profiles from authenticated;
grant  update (nickname, banned, share_catches, member_until, avatar) on public.profiles to authenticated; -- banned・member_until はトリガーで管理者に限定
revoke update on public.posts from authenticated;
grant  update (title, body, place, allow_comments, status) on public.posts to authenticated;

revoke execute on function public.make_request(uuid, text, int), public.respond_request(uuid, boolean),
  public.finish_request(uuid), public.cancel_request(uuid, text), public.cancel_listing(uuid, text),
  public.send_card(uuid), public.rate_deal(uuid, int, int, int, text), public.update_listing(uuid, jsonb) from public, anon;
grant execute on function public.make_request(uuid, text, int), public.respond_request(uuid, boolean),
  public.finish_request(uuid), public.cancel_request(uuid, text), public.cancel_listing(uuid, text),
  public.send_card(uuid), public.rate_deal(uuid, int, int, int, text), public.update_listing(uuid, jsonb) to authenticated;
revoke execute on function public.sysmsg(uuid, text) from public, anon, authenticated;   -- 関数の中からだけ使う
revoke execute on function public.dm_open(uuid), public.dm_open_post(uuid), public.dm_block(uuid, boolean) from public, anon;
grant  execute on function public.dm_open(uuid), public.dm_open_post(uuid), public.dm_block(uuid, boolean) to authenticated;
revoke execute on function public.push_catches(text, jsonb), public.forget_catch(text, text), public.forget_device(text) from public, anon;
grant  execute on function public.push_catches(text, jsonb), public.forget_catch(text, text), public.forget_device(text) to authenticated;
revoke execute on function public.admin_stats() from public, anon;
grant  execute on function public.admin_stats() to authenticated;   -- 中で管理者かどうかを確かめる

-- ---------------------------------------------------------------------
-- 8. 写真の保存場所（Storage）
--    photos   : 出品の写真。ログインした人なら見られる
--    licenses : お店の許可証。本人と管理者だけ
--    どちらも「利用者ID/ファイル名」の形で、自分のフォルダにだけ置ける
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('photos', 'photos', false), ('licenses', 'licenses', false), ('posts', 'posts', true), ('avatars', 'avatars', true)
on conflict (id) do nothing;
-- avatars : アイコン。誰でも見られる。ログインして表示名を登録した人が、自分のフォルダにだけ置ける
-- posts : みんなの投稿の写真。誰でも見られる（位置情報は縮小のときに消してある）。置けるのは会員の自分のフォルダだけ

drop policy if exists "photos_insert_own" on storage.objects;
drop policy if exists "photos_read"       on storage.objects;
drop policy if exists "photos_delete_own" on storage.objects;
drop policy if exists "licenses_insert_own" on storage.objects;
drop policy if exists "licenses_read"       on storage.objects;
drop policy if exists "posts_insert_own"    on storage.objects;
drop policy if exists "posts_delete_own"    on storage.objects;
drop policy if exists "avatars_insert_own"  on storage.objects;
drop policy if exists "avatars_delete_own"  on storage.objects;
create policy "avatars_insert_own" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text and public.is_active_user());
create policy "avatars_delete_own" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
create policy "posts_insert_own" on storage.objects for insert to authenticated
  with check (bucket_id = 'posts' and (storage.foldername(name))[1] = auth.uid()::text and public.is_member());
create policy "posts_delete_own" on storage.objects for delete to authenticated
  using (bucket_id = 'posts' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
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

-- ---------------------------------------------------------------------
-- 10. PCとスマホの同期（会員）：釣果（写真は除く）と航跡を、本人だけが読み書きする
--     写真は「写真を同期」を押したときだけ cloud バケットに置く
-- ---------------------------------------------------------------------
create table if not exists public.cloud_items (
  owner      uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind       text not null check (kind in ('catch','track')),
  id         text not null check (char_length(id) between 1 and 60),
  data       jsonb,
  deleted    boolean not null default false,
  updated_at timestamptz not null,                 -- 端末で最後に変えた時刻（新しい方を残す）
  synced_at  timestamptz not null default now(),   -- サーバーに入った時刻（差分の取り出し用）
  primary key (owner, kind, id)
);
create index if not exists cloud_items_pull_idx on public.cloud_items(owner, synced_at);

create or replace function public.cloud_items_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_member() then raise exception '同期は会員の機能です'; end if;
  new.owner := auth.uid();
  if new.deleted then new.data := null; end if;
  if new.data is not null and pg_column_size(new.data) > 3000000 then
    raise exception '1件のデータが大きすぎます'; end if;
  if new.updated_at > now() + interval '1 day' then new.updated_at := now(); end if;
  if tg_op = 'UPDATE' then
    if new.updated_at < old.updated_at then return null; end if;   -- 古い変更は無視
    if new.owner <> old.owner then raise exception '権限がありません'; end if;
  elsif (select count(*) from cloud_items where owner = auth.uid()) >= 20000 then
    raise exception '同期できる件数の上限です';
  end if;
  new.synced_at := clock_timestamp();
  return new;
end $$;
drop trigger if exists cloud_items_guard on public.cloud_items;
create trigger cloud_items_guard before insert or update on public.cloud_items
  for each row execute function public.cloud_items_guard();

alter table public.cloud_items enable row level security;
alter table public.app_secrets   enable row level security;   -- ポリシーなし＝画面からは読めない
alter table public.app_settings  enable row level security;
drop policy if exists settings_read on public.app_settings;
drop policy if exists settings_admin on public.app_settings;
create policy settings_read on public.app_settings for select to anon, authenticated using (true);
create policy settings_admin on public.app_settings for update to authenticated using (is_admin()) with check (is_admin());
revoke insert, delete on public.app_settings from anon, authenticated;
alter table public.banned_phones enable row level security;
drop policy if exists banned_phones_admin on public.banned_phones;
create policy banned_phones_admin on public.banned_phones for select to authenticated using (is_admin());
revoke all on public.app_secrets from anon, authenticated;
revoke all on public.banned_phones from anon;
drop policy if exists cloud_select on public.cloud_items;
drop policy if exists cloud_insert on public.cloud_items;
drop policy if exists cloud_update on public.cloud_items;
create policy cloud_select on public.cloud_items for select to authenticated using (owner = auth.uid());
create policy cloud_insert on public.cloud_items for insert to authenticated with check (owner = auth.uid());
create policy cloud_update on public.cloud_items for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
revoke all on public.cloud_items from anon;
revoke delete on public.cloud_items from authenticated;

-- 電話番号の認証を確定する（SMSのコードで Supabase の認証が電話番号を確認したあとに呼ぶ）
create or replace function public.phone_verify() returns json
language plpgsql security definer set search_path = public, auth as $$
declare v_phone text; v_conf timestamptz; v_hash text; v_other uuid;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  if not exists(select 1 from profiles where id = auth.uid() and not banned) then raise exception '表示名の登録が必要です'; end if;
  select phone, phone_confirmed_at into v_phone, v_conf from auth.users where id = auth.uid();
  v_phone := regexp_replace(coalesce(v_phone, ''), '\D', '', 'g');
  if v_phone = '' or v_conf is null then raise exception 'SMSのコードでの確認が済んでいません'; end if;
  if v_phone !~ '^81[789]0[0-9]{8}$' then raise exception '日本の携帯電話番号（070・080・090）だけ認証できます'; end if;
  v_hash := phone_hash_of(v_phone);
  if exists(select 1 from banned_phones where phone_hash = v_hash) then raise exception 'この電話番号では認証できません'; end if;
  select id into v_other from profiles where phone_hash = v_hash and id <> auth.uid();
  if v_other is not null then raise exception 'この電話番号はほかのアカウントで使われています'; end if;
  perform set_config('app.phone_verify', '1', true);       -- この操作の中だけ、認証の欄を書き換えてよい
  update profiles set phone_verified_at = now(), phone_hash = v_hash, phone_tail = right(v_phone, 4) where id = auth.uid();
  perform set_config('app.phone_verify', '', true);
  return json_build_object('tail', right(v_phone, 4));
end $$;
-- 管理者：認証を外す（番号の使い回し・機種変更で困った人のため）。Supabase 側の電話番号も外す
create or replace function public.admin_phone_reset(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception '権限がありません'; end if;
  update profiles set phone_verified_at = null, phone_hash = null, phone_tail = null where id = p_user;
  begin
    update auth.users set phone = null, phone_confirmed_at = null where id = p_user;
  exception when others then null;      -- 外せない環境でも、アプリ側の認証は外す
  end;
end $$;
-- 管理者：停止した番号の一覧の件数と、全部の解除（誤って停止したとき用。個別にはSQLで）
revoke execute on function public.phone_verify(), public.admin_phone_reset(uuid) from public, anon;
grant execute on function public.phone_verify(), public.admin_phone_reset(uuid) to authenticated;

-- 同期の使用量（本人）
create or replace function public.cloud_usage() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'catches', count(*) filter (where kind = 'catch' and not deleted),
    'tracks',  count(*) filter (where kind = 'track' and not deleted),
    'bytes',   coalesce(sum(pg_column_size(data)), 0),
    'photo_bytes', (select coalesce(sum((o.metadata->>'size')::bigint), 0) from storage.objects o
                     where o.bucket_id = 'cloud' and (storage.foldername(o.name))[1] = auth.uid()::text))
  from cloud_items where owner = auth.uid()
$$;
revoke execute on function public.cloud_usage() from anon;

insert into storage.buckets (id, name, public) values ('cloud', 'cloud', false) on conflict (id) do nothing;
drop policy if exists "cloud_insert_own" on storage.objects;
drop policy if exists "cloud_read_own"   on storage.objects;
drop policy if exists "cloud_delete_own" on storage.objects;
create policy "cloud_insert_own" on storage.objects for insert to authenticated
  with check (bucket_id = 'cloud' and (storage.foldername(name))[1] = auth.uid()::text and public.is_member());
create policy "cloud_read_own" on storage.objects for select to authenticated
  using (bucket_id = 'cloud' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "cloud_delete_own" on storage.objects for delete to authenticated
  using (bucket_id = 'cloud' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- 9. 変更をすぐ画面から使えるように、Supabase に読み込み直してもらう
-- ---------------------------------------------------------------------
notify pgrst, 'reload schema';
