
-- =====================================================================
-- 15. パーティ（仲間の位置）・SOS（2026-11-17）
--     ・パーティ：会員がパーティを作り、招待コードで仲間が入る（20人まで・1人1パーティ）。
--       「位置を仲間に共有」をオンにした人の現在地と、直近の航跡（2時間・60点まで）を、同じパーティの人だけが見られる
--     ・ポイント：パーティの人だけが見られる地点（「ここで釣れた」など）を置ける（パーティごとに100件まで）
--     ・SOS：ログインした人（無料を含む）が出せる。同じパーティの人には距離に関係なく、
--       「近くのSOSを受け取る」をオンにしている人には、最後の現在地から半径30km以内なら届く
--     ・届くのはアプリを開いている間だけ（画面に出す・音・振動・ブラウザの通知）。118番の代わりにはならない
--     ・現在地（live_pos）は、だれも直接読めない。パーティの仲間とSOSの受け手を決めるのに関数の中だけで使う
-- =====================================================================
create table if not exists public.parties (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 30),
  code        text not null unique,
  owner       uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now()
);
create table if not exists public.party_members (
  party_id    uuid not null references public.parties(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  joined_at   timestamptz not null default now(),
  primary key (party_id, user_id)
);
create unique index if not exists party_members_one on public.party_members(user_id);   -- 1人1パーティ

-- 最後の現在地（1人1件）。share_party：仲間に見せる／sos_rx：近くのSOSを受け取る
create table if not exists public.live_pos (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  lat         double precision not null check (lat between -90 and 90),
  lon         double precision not null check (lon between -180 and 180),
  acc         real,
  heading     real,
  speed       real,
  at          timestamptz not null default now(),
  share_party boolean not null default false,
  sos_rx      boolean not null default false,
  trail       jsonb not null default '[]'::jsonb        -- [[lat,lon,ミリ秒], …] 古い順。2時間・60点まで
);
create index if not exists live_pos_rx_idx on public.live_pos(at) where sos_rx;

create table if not exists public.party_points (
  id          bigint generated always as identity primary key,
  party_id    uuid not null references public.parties(id) on delete cascade,
  owner       uuid not null references public.profiles(id) on delete cascade,
  lat         double precision not null check (lat between -90 and 90),
  lon         double precision not null check (lon between -180 and 180),
  label       text not null check (char_length(label) between 1 and 30),
  memo        text check (char_length(memo) <= 200),
  created_at  timestamptz not null default now()
);
create index if not exists party_points_party_idx on public.party_points(party_id, created_at desc);

create table if not exists public.sos_alerts (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  lat         double precision not null check (lat between -90 and 90),
  lon         double precision not null check (lon between -180 and 180),
  acc         real,
  reason      text not null check (char_length(reason) between 1 and 30),
  msg         text check (char_length(msg) <= 200),
  people      int check (people between 1 and 99),
  status      text not null default 'open' check (status in ('open','safe','cancelled')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  closed_at   timestamptz
);
create index if not exists sos_open_idx on public.sos_alerts(status, created_at desc);
create unique index if not exists sos_one_open on public.sos_alerts(user_id) where status = 'open';

create table if not exists public.sos_replies (
  sos_id      bigint not null references public.sos_alerts(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  kind        text not null check (kind in ('seen','going')),
  at          timestamptz not null default now(),
  primary key (sos_id, user_id)
);

-- だれも直接読み書きしない（関数を通してだけ）
alter table public.parties       enable row level security;
alter table public.party_members enable row level security;
alter table public.live_pos      enable row level security;
alter table public.party_points  enable row level security;
alter table public.sos_alerts    enable row level security;
alter table public.sos_replies   enable row level security;
drop policy if exists sos_admin on public.sos_alerts;
create policy sos_admin on public.sos_alerts for select to authenticated using (is_admin());
revoke all on public.parties, public.party_members, public.live_pos, public.party_points, public.sos_alerts, public.sos_replies from anon;
revoke insert, update, delete on public.parties, public.party_members, public.live_pos, public.party_points, public.sos_alerts, public.sos_replies from authenticated;
revoke select on public.parties, public.party_members, public.live_pos, public.party_points, public.sos_replies from authenticated;

-- 2点間の距離（km）
create or replace function public.geo_km(a_lat float8, a_lon float8, b_lat float8, b_lon float8) returns float8
language sql immutable set search_path = public as $$
  select 6371.0 * 2 * asin(least(1, sqrt(power(sin(radians(b_lat - a_lat) / 2), 2)
       + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lon - a_lon) / 2), 2))))
$$;

create or replace function public.my_party() returns uuid
language sql stable security definer set search_path = public as $$
  select party_id from party_members where user_id = auth.uid()
$$;

-- 招待コード（読み間違えやすい 0/O・1/I/L を使わない6文字）
create or replace function public.party_new_code() returns text
language plpgsql volatile set search_path = public as $$
declare a text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; c text;
begin
  loop
    c := '';
    for i in 1..6 loop c := c || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
    exit when not exists(select 1 from parties where code = c);
  end loop;
  return c;
end $$;

-- パーティを抜ける（作った人が抜けたら、残っている人のうち一番早く入った人が引き継ぐ。だれもいなければ消す）
create or replace function public.party_leave() returns void
language plpgsql security definer set search_path = public as $$
declare v_party uuid; v_next uuid;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  delete from party_members where user_id = auth.uid() returning party_id into v_party;
  if v_party is null then return; end if;
  select user_id into v_next from party_members where party_id = v_party order by joined_at limit 1;
  if v_next is null then delete from parties where id = v_party;
  else update parties set owner = v_next where id = v_party and owner = auth.uid(); end if;
end $$;

-- パーティを作る（会員）。入っていたパーティからは抜ける
create or replace function public.party_create(p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_code text;
begin
  if auth.uid() is null or not is_active_user() then raise exception 'ログインして表示名を登録してください'; end if;
  if not is_member() then raise exception 'パーティは会員の機能です'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'パーティの名前を入れてください'; end if;
  perform party_leave();
  v_code := party_new_code();
  insert into parties(name, code, owner) values (left(btrim(p_name), 30), v_code, auth.uid()) returning id into v_id;
  insert into party_members(party_id, user_id) values (v_id, auth.uid());
  return jsonb_build_object('id', v_id, 'code', v_code);
end $$;

-- 招待コードで入る（会員・20人まで）
create or replace function public.party_join(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare v parties; n int;
begin
  if auth.uid() is null or not is_active_user() then raise exception 'ログインして表示名を登録してください'; end if;
  if not is_member() then raise exception 'パーティは会員の機能です'; end if;
  select * into v from parties where code = upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  if not found then raise exception 'その招待コードのパーティは見つかりません'; end if;
  if exists(select 1 from party_members where party_id = v.id and user_id = auth.uid()) then return v.name; end if;
  select count(*) into n from party_members where party_id = v.id;
  if n >= 20 then raise exception 'このパーティは満員です（20人まで）'; end if;
  perform party_leave();
  insert into party_members(party_id, user_id) values (v.id, auth.uid());
  return v.name;
end $$;

-- 作った人が、パーティを解散する／ほかの人を外す／招待コードを作り直す
create or replace function public.party_admin(p_action text, p_member int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v parties; v_uid uuid;
begin
  select * into v from parties where id = my_party();
  if not found then raise exception 'パーティに入っていません'; end if;
  if v.owner <> auth.uid() then raise exception 'パーティを作った人だけができます'; end if;
  if p_action = 'close' then
    delete from parties where id = v.id;
    return '{}'::jsonb;
  elsif p_action = 'recode' then
    update parties set code = party_new_code() where id = v.id returning code into v.code;
    return jsonb_build_object('code', v.code);
  elsif p_action = 'kick' then
    -- p_member は party_state の members の no（入った順の番号）。利用者の番号は画面に出さない
    select user_id into v_uid from (select user_id, row_number() over (order by joined_at, user_id) no
                                      from party_members where party_id = v.id) t where t.no = p_member;
    if v_uid is null or v_uid = auth.uid() then raise exception 'その人は外せません'; end if;
    delete from party_members where party_id = v.id and user_id = v_uid;
    return '{}'::jsonb;
  end if;
  raise exception '操作が正しくありません';
end $$;

-- 現在地を送る（1人1件を上書き）。仲間への共有も、近くのSOSを受け取るのもオフなら、位置を消す
create or replace function public.pos_update(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_share boolean := coalesce((p->>'share')::boolean, false);
        v_rx boolean := coalesce((p->>'rx')::boolean, false);
        v_lat float8 := (p->>'lat')::float8; v_lon float8 := (p->>'lon')::float8;
        v_now bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  if auth.uid() is null or not is_active_user() then raise exception 'ログインして表示名を登録してください'; end if;
  if not v_share and not v_rx then delete from live_pos where user_id = auth.uid(); return; end if;
  if v_lat is null or v_lon is null or v_lat not between -90 and 90 or v_lon not between -180 and 180 then
    raise exception '位置が正しくありません';
  end if;
  insert into live_pos as l (user_id, lat, lon, acc, heading, speed, at, share_party, sos_rx, trail)
  values (auth.uid(), v_lat, v_lon, nullif(p->>'acc', '')::real, nullif(p->>'heading', '')::real,
          nullif(p->>'speed', '')::real, now(), v_share, v_rx,
          case when v_share then jsonb_build_array(jsonb_build_array(round(v_lat::numeric, 5), round(v_lon::numeric, 5), v_now)) else '[]'::jsonb end)
  on conflict (user_id) do update set
    lat = excluded.lat, lon = excluded.lon, acc = excluded.acc, heading = excluded.heading, speed = excluded.speed,
    at = now(), share_party = excluded.share_party, sos_rx = excluded.sos_rx,
    trail = case when not v_share then '[]'::jsonb else (
      select coalesce(jsonb_agg(e order by n), '[]'::jsonb) from (
        select e, n from jsonb_array_elements(l.trail || excluded.trail) with ordinality t(e, n)
         where (e->>2)::bigint > v_now - 7200000
         order by n desc limit 60) x) end;
end $$;

-- パーティの様子：仲間（入った順の番号・表示名・アイコン・位置・航跡・SOS）とポイント
create or replace function public.party_state() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v parties;
begin
  if auth.uid() is null then return null; end if;
  select * into v from parties where id = my_party();
  if not found then return null; end if;
  return jsonb_build_object(
    'id', v.id, 'name', v.name, 'code', v.code, 'owner', v.owner = auth.uid(),
    'members', (select coalesce(jsonb_agg(m order by (m->>'no')::int), '[]'::jsonb) from (
       select jsonb_build_object(
         'no', t.no, 'name', p.nickname, 'avatar', p.avatar, 'tsunuke', p.tsunuke, 'me', t.user_id = auth.uid(),
         'owner', t.user_id = v.owner, 'joined_at', t.joined_at,
         'lat', case when l.share_party and l.at > now() - interval '12 hours' then l.lat end,
         'lon', case when l.share_party and l.at > now() - interval '12 hours' then l.lon end,
         'acc', case when l.share_party then l.acc end, 'heading', case when l.share_party then l.heading end,
         'speed', case when l.share_party then l.speed end,
         'at', case when l.share_party then l.at end,
         'trail', case when l.share_party then l.trail else '[]'::jsonb end,
         'sos', (select jsonb_build_object('id', s.id, 'reason', s.reason, 'msg', s.msg, 'people', s.people,
                    'lat', s.lat, 'lon', s.lon, 'at', s.created_at, 'updated_at', s.updated_at)
                   from sos_alerts s where s.user_id = t.user_id and s.status = 'open')) m
         from (select user_id, joined_at, row_number() over (order by joined_at, user_id) no
                 from party_members where party_id = v.id) t
         join profiles p on p.id = t.user_id
         left join live_pos l on l.user_id = t.user_id) x),
    'points', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'lat', q.lat, 'lon', q.lon, 'label', q.label, 'memo', q.memo,
                 'at', q.created_at, 'by', p.nickname, 'mine', q.owner = auth.uid()) order by q.created_at desc), '[]'::jsonb)
                 from party_points q join profiles p on p.id = q.owner where q.party_id = v.id));
end $$;

-- ポイントを置く・消す（パーティの人だけ。消せるのは置いた人と作った人）
create or replace function public.point_add(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_party uuid := my_party(); v_id bigint; n int;
begin
  if v_party is null then raise exception 'パーティに入っていません'; end if;
  if not is_active_user() then raise exception '利用が停止されています'; end if;
  if coalesce(btrim(p->>'label'), '') = '' then raise exception 'ポイントの名前を入れてください'; end if;
  select count(*) into n from party_points where party_id = v_party;
  if n >= 100 then raise exception 'ポイントはパーティごとに100件までです。古いポイントを消してください'; end if;
  insert into party_points(party_id, owner, lat, lon, label, memo)
  values (v_party, auth.uid(), (p->>'lat')::float8, (p->>'lon')::float8, left(btrim(p->>'label'), 30), nullif(left(btrim(p->>'memo'), 200), ''))
  returning id into v_id;
  return v_id;
end $$;
create or replace function public.point_del(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from party_points q using parties v
   where q.id = p_id and q.party_id = my_party() and v.id = q.party_id and (q.owner = auth.uid() or v.owner = auth.uid());
  if not found then raise exception '消せるのは、置いた人とパーティを作った人だけです'; end if;
end $$;

-- SOS を出す（ログインした人。無料を含む）。出し直すと位置・内容を新しくする（1人同時に1件）
create or replace function public.sos_send(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_lat float8 := (p->>'lat')::float8; v_lon float8 := (p->>'lon')::float8;
begin
  if auth.uid() is null or not is_active_user() then raise exception 'ログインして表示名を登録してください'; end if;
  if v_lat is null or v_lon is null then raise exception '現在地が分からないため送れません。118番に電話してください'; end if;
  update sos_alerts set lat = v_lat, lon = v_lon, acc = nullif(p->>'acc', '')::real,
         reason = coalesce(nullif(left(btrim(p->>'reason'), 30), ''), reason),
         msg = coalesce(nullif(left(btrim(p->>'msg'), 200), ''), msg),
         people = coalesce(nullif(p->>'people', '')::int, people), updated_at = now()
   where user_id = auth.uid() and status = 'open' returning id into v_id;
  if v_id is null then
    insert into sos_alerts(user_id, lat, lon, acc, reason, msg, people)
    values (auth.uid(), v_lat, v_lon, nullif(p->>'acc', '')::real, coalesce(nullif(left(btrim(p->>'reason'), 30), ''), 'その他'),
            nullif(left(btrim(p->>'msg'), 200), ''), nullif(p->>'people', '')::int)
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- SOS を終える（safe：無事・解決した／cancelled：まちがえて出した）
create or replace function public.sos_close(p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('safe','cancelled') then raise exception '操作が正しくありません'; end if;
  update sos_alerts set status = p_status, closed_at = now(), updated_at = now() where user_id = auth.uid() and status = 'open';
end $$;

-- 自分の SOS（出している間）と、だれが応答したか
create or replace function public.sos_mine() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', s.id, 'reason', s.reason, 'msg', s.msg, 'people', s.people, 'lat', s.lat, 'lon', s.lon,
           'at', s.created_at, 'updated_at', s.updated_at,
           'replies', (select coalesce(jsonb_agg(jsonb_build_object('name', p.nickname, 'kind', r.kind, 'at', r.at) order by r.at), '[]'::jsonb)
                         from sos_replies r join profiles p on p.id = r.user_id where r.sos_id = s.id))
    from sos_alerts s where s.user_id = auth.uid() and s.status = 'open'
$$;

-- 届いている SOS：同じパーティの人の SOS（距離に関係なく）と、
-- 「近くのSOSを受け取る」をオンにしていて、最後の現在地（1時間以内）から半径30km以内の SOS（12時間以内に出たもの）
create or replace function public.sos_inbox() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me live_pos; v_party uuid := my_party(); v_near boolean;
begin
  if auth.uid() is null or not is_active_user() then return '[]'::jsonb; end if;
  select * into me from live_pos where user_id = auth.uid();
  v_near := found and me.sos_rx and me.at > now() - interval '1 hour';
  return (select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
    select jsonb_build_object('id', s.id, 'name', p.nickname, 'avatar', p.avatar, 'reason', s.reason, 'msg', s.msg, 'people', s.people,
             'lat', s.lat, 'lon', s.lon, 'acc', s.acc, 'at', s.created_at, 'updated_at', s.updated_at,
             'party', v_party is not null and exists(select 1 from party_members m where m.party_id = v_party and m.user_id = s.user_id),
             'km', case when me.user_id is not null then round(geo_km(me.lat, me.lon, s.lat, s.lon)::numeric, 1) end,
             'going', (select count(*) from sos_replies r where r.sos_id = s.id and r.kind = 'going'),
             'seen',  (select count(*) from sos_replies r where r.sos_id = s.id),
             'my_reply', (select r.kind from sos_replies r where r.sos_id = s.id and r.user_id = auth.uid())) x
      from sos_alerts s join profiles p on p.id = s.user_id
     where s.status = 'open' and s.user_id <> auth.uid() and s.created_at > now() - interval '12 hours' and not p.banned
       and ((v_party is not null and exists(select 1 from party_members m where m.party_id = v_party and m.user_id = s.user_id))
            or (v_near and s.lat between me.lat - 0.3 and me.lat + 0.3
                and s.lon between me.lon - 0.4 and me.lon + 0.4
                and geo_km(me.lat, me.lon, s.lat, s.lon) <= 30))
     limit 50) t);
end $$;

-- 届いた SOS に応答する（seen：確認した／going：向かう）。届いている SOS にだけ
create or replace function public.sos_reply(p_id bigint, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_kind not in ('seen','going') then raise exception '操作が正しくありません'; end if;
  if not exists(select 1 from jsonb_array_elements(sos_inbox()) e where (e->>'id')::bigint = p_id) then
    raise exception 'このSOSは終わったか、届いていません';
  end if;
  insert into sos_replies(sos_id, user_id, kind) values (p_id, auth.uid(), p_kind)
  on conflict (sos_id, user_id) do update set kind = case when sos_replies.kind = 'going' then 'going' else excluded.kind end, at = now();
end $$;

revoke execute on function public.my_party(), public.party_new_code() from public, anon, authenticated;
revoke execute on function public.party_create(text), public.party_join(text), public.party_leave(), public.party_admin(text, int),
  public.pos_update(jsonb), public.party_state(), public.point_add(jsonb), public.point_del(bigint),
  public.sos_send(jsonb), public.sos_close(text), public.sos_mine(), public.sos_inbox(), public.sos_reply(bigint, text) from public, anon;
grant execute on function public.party_create(text), public.party_join(text), public.party_leave(), public.party_admin(text, int),
  public.pos_update(jsonb), public.party_state(), public.point_add(jsonb), public.point_del(bigint),
  public.sos_send(jsonb), public.sos_close(text), public.sos_mine(), public.sos_inbox(), public.sos_reply(bigint, text) to authenticated;

notify pgrst, 'reload schema';
