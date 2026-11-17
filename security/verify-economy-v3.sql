-- READ ONLY: checks installed permissions and lists unreviewed exposed RPCs.
WITH known(name) AS (VALUES
 ('bu_room_member_v1'),('bu_room_join_v1'),('bu_quick_match_v1'),('bu_quick_status_v1'),('bu_quick_cancel_v1'),
 ('bu_ranking_start_v2'),('bu_ranking_submit_v2'),('bu_ranking_list_v2'),('bu_wardrobe_get'),('bu_wardrobe_buy'),
 ('bu_wardrobe_daily'),('bu_wardrobe_set_outfit'),('bu_friends_list'),('bu_friend_add_v3'),('bu_log_event'),('bu_progress_claim_v3')
)
SELECT jsonb_pretty(jsonb_build_object(
 'direct_xp_update',has_column_privilege('authenticated','public.bu_profiles','xp','UPDATE'),
 'nickname_edit',has_column_privilege('authenticated','public.bu_profiles','nickname','UPDATE'),
 'direct_coin_update',has_column_privilege('authenticated','public.bu_wardrobe','coins','UPDATE'),
 'direct_stats_insert',has_table_privilege('authenticated','public.bu_game_stats','INSERT'),
 'old_coin_api',has_function_privilege('authenticated','public.bu_wardrobe_award(integer,text)','EXECUTE'),
 'new_progress_api',has_function_privilege('authenticated','public.bu_progress_claim_v3(uuid,text,text,boolean,integer)','EXECUTE'),
 'anonymous_progress_api',has_function_privilege('anon','public.bu_progress_claim_v3(uuid,text,text,boolean,integer)','EXECUTE'),
 'private_schema_access',has_schema_privilege('authenticated','bu_private','USAGE'),
 'unrestricted_room_policies',(SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename IN ('basket_matches','parket_multiplayer_rooms','draft_multiplayer_rooms') AND (qual='true' OR with_check='true')),
 'unreviewed_exposed_definers',(
  SELECT coalesce(jsonb_agg(jsonb_build_object('name',p.proname,'arguments',pg_get_function_identity_arguments(p.oid),'anonymous',has_function_privilege('anon',p.oid,'EXECUTE'),'account',has_function_privilege('authenticated',p.oid,'EXECUTE'))),'[]'::jsonb)
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.prosecdef AND p.prokind='f'
  AND (has_function_privilege('anon',p.oid,'EXECUTE') OR has_function_privilege('authenticated',p.oid,'EXECUTE'))
  AND NOT EXISTS(SELECT 1 FROM known WHERE name=p.proname)
 )
)) AS security_report;
