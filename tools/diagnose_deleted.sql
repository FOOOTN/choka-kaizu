-- =====================================================================
-- 消えた釣果を調べる（読むだけ。データは変えません）
-- Supabase の SQL Editor に貼り付けて Run。魚種（'アマダイ'）を調べたい魚に変えて使えます
-- SQL Editor は最後の問い合わせの結果だけを表示するので、最近の削除の一覧を先に、魚種で探す結果を最後に置いています
-- 釣果の番号の頭8文字は登録した日時です（JavaScript で new Date(parseInt('mvx64l1u',36)) ）
-- =====================================================================
-- A) 最近付いた削除の印（どの持ち主の釣果が、いつ消されたか）
select c.id as 釣果の番号, p.nickname as 持ち主,
       coalesce(c.trash->>'species', '（中身は残っていません）') as 魚種,
       to_char(c.updated_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI:SS') as 端末で削除した日時,
       to_char(c.synced_at  at time zone 'Asia/Tokyo', 'MM/DD HH24:MI:SS') as サーバーに届いた日時
  from cloud_items c join profiles p on p.id = c.owner
 where c.kind = 'catch' and c.deleted
 order by c.synced_at desc limit 30;

-- B) 魚種で探す
with q as (select 'アマダイ'::text as sp)

--   その魚の記録が、サーバーのどこに残っているか
select '同期（cloud_items）' as 場所, c.id as 釣果の番号, p.nickname as 持ち主,
       case when c.deleted then '削除の印あり' else '残っている' end as 状態,
       coalesce(c.data->>'datetime', c.trash->>'datetime') as 釣った日時,
       to_char(c.updated_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI:SS') as 端末で変えた日時,
       to_char(c.synced_at  at time zone 'Asia/Tokyo', 'MM/DD HH24:MI:SS') as サーバーに届いた日時
  from cloud_items c join profiles p on p.id = c.owner, q
 where c.kind = 'catch' and (c.data->>'species' like '%' || q.sp || '%' or c.trash->>'species' like '%' || q.sp || '%')
union all
select '提供された釣果（shared_catches）', s.local_id, coalesce(p.nickname, '匿名'), '残っている（中身あり）',
       to_char(s.caught_at at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI'),
       to_char(s.updated_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI:SS'), null
  from shared_catches s left join profiles p on p.id = s.owner, q
 where s.species like '%' || q.sp || '%'
union all
select '新着（posts）', x.catch_id, u.nickname, x.status,
       to_char(x.caught_at at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI'),
       to_char(x.updated_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI:SS'), null
  from posts x join profiles u on u.id = x.owner, q
 where x.kind = 'catch' and x.species like '%' || q.sp || '%'

--   上で見つかった釣果の番号に、削除の印が付いているか（付いていれば、その日時に「削除」が押された）
union all
select '↑の番号の削除の印', c.id, p.nickname,
       case when c.deleted then '削除の印あり' else '削除の印なし' end, null,
       to_char(c.updated_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI:SS'),
       to_char(c.synced_at  at time zone 'Asia/Tokyo', 'MM/DD HH24:MI:SS')
  from cloud_items c join profiles p on p.id = c.owner, q
 where c.kind = 'catch' and c.data is null
   and c.id in (select s.local_id from shared_catches s where s.species like '%' || q.sp || '%')
order by 1, 6;
