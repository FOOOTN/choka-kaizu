-- =====================================================================
-- 消えた釣果を「提供された釣果（shared_catches）」から戻す
-- diagnose_deleted.sql で見つけた「釣果の番号」を下の 'ここに番号' に入れて Run。
-- 同期（cloud_items）に、新しい変更として戻します。持ち主の端末で「↻ 更新」すると釣果一覧に戻り、新着にも載せ直されます。
-- 写真は戻りません（「写真の同期」で送っていた写真は、その記録から取り込めます）。持ち主が会員のときだけ使えます。
-- =====================================================================
do $$
declare v_id text := 'ここに番号'; s record;
begin
  select * into s from shared_catches where local_id = v_id order by updated_at desc limit 1;
  if not found then raise exception '提供された釣果に、番号 % が見つかりません', v_id; end if;
  if s.owner is null then raise exception '持ち主が分からないため戻せません'; end if;
  perform set_config('request.jwt.claim.sub', s.owner::text, true);   -- 持ち主として書き込む（この実行の間だけ）
  insert into cloud_items(owner, kind, id, data, deleted, updated_at)
  values (s.owner, 'catch', v_id,
          coalesce(s.data, '{}'::jsonb) || jsonb_build_object(
            'lat', s.lat, 'lon', s.lon, 'species', s.species, 'count', s.count,
            'datetime', to_char(s.caught_at at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI')),
          false, now())
  on conflict (owner, kind, id) do update set data = excluded.data, deleted = false, updated_at = excluded.updated_at;
  raise notice '番号 % を戻しました。持ち主の端末で「↻ 更新」を押してください', v_id;
end $$;
