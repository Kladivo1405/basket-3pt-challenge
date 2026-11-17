-- READ ONLY. Run after supabase-room-security-v1.sql.
SELECT jsonb_pretty(jsonb_build_object(
 'installed_version',public.bu_online_security_version_v1(),
 'unrestricted_room_policies',(
  SELECT count(*) FROM pg_policies WHERE schemaname='public'
  AND tablename IN ('basket_matches','parket_multiplayer_rooms','draft_multiplayer_rooms')
  AND (qual='true' OR with_check='true')
 ),
 'anonymous_room_read',has_table_privilege('anon','public.basket_matches','SELECT'),
 'legacy_ranking_write',has_table_privilege('authenticated','public.basket_leaderboard','UPDATE'),
 'old_queue_rpc_access',(
  SELECT coalesce(bool_or(has_function_privilege('anon',p.oid,'EXECUTE') OR has_function_privilege('authenticated',p.oid,'EXECUTE')),false)
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN ('basket_quick_match','basket_quick_status','basket_quick_cancel')
 ),
 'admin_view_api_grants',(
  SELECT count(*) FROM information_schema.table_privileges WHERE table_schema='public'
  AND table_name IN ('bu_players_overview','bu_activity_recent','bu_activity_daily')
  AND grantee IN ('anon','authenticated','PUBLIC')
 )
)) AS security_report;
