-- Read only. Expected: false for exposed private data/helpers and anonymous actions;
-- true for account actions, public board reads, real clock; restrictive policies = 3.
SELECT jsonb_pretty(jsonb_build_object(
 'private_schema_access',has_schema_privilege('authenticated','bu_private','USAGE'),
 'private_table_access',EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='bu_private' AND c.relname LIKE 'blockout_%v4' AND (has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE') OR has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE'))),
 'private_helper_access',EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='bu_private' AND p.proname LIKE 'bo4_%' AND (has_function_privilege('authenticated',p.oid,'EXECUTE') OR has_function_privilege('anon',p.oid,'EXECUTE'))),
 'anonymous_actions',EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'bu_blockout_%_v4' AND p.proname<>'bu_blockout_board_v4' AND has_function_privilege('anon',p.oid,'EXECUTE')),
 'account_actions',(SELECT count(*)=6 AND bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE')) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'bu_blockout_%_v4' AND p.proname<>'bu_blockout_board_v4'),
 'public_board_read',has_function_privilege('anon','public.bu_blockout_board_v4()','EXECUTE'),
 'real_server_clock',position('clock_timestamp' in pg_get_functiondef('bu_private.bo4_now()'::regprocedure))>0,
 'legacy_restrictive_policies',(SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='parket_multiplayer_rooms' AND policyname LIKE 'bu_no_legacy_bo_%_v4' AND permissive='RESTRICTIVE')
)) AS blockout_security_report;
