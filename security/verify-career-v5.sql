-- READ ONLY. Expected all true except anonymous/private access false.
SELECT jsonb_pretty(jsonb_build_object(
 'account_api',has_function_privilege('authenticated','public.bu_career_v5(uuid,text,jsonb)','EXECUTE'),
 'anonymous_api',has_function_privilege('anon','public.bu_career_v5(uuid,text,jsonb)','EXECUTE'),
 'private_schema_access',has_schema_privilege('authenticated','bu_private','USAGE'),
 'private_table_access',EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='bu_private' AND c.relname IN ('career_v5','career_runs_v5','career_requests_v5') AND (has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE') OR has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE'))),
 'all_tables_rls',(SELECT count(*)=3 AND bool_and(c.relrowsecurity) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='bu_private' AND c.relname IN ('career_v5','career_runs_v5','career_requests_v5')),
 'private_helper_access',EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='bu_private' AND p.proname LIKE 'cv5_%' AND (has_function_privilege('anon',p.oid,'EXECUTE') OR has_function_privilege('authenticated',p.oid,'EXECUTE'))),
 'real_server_clock',position('clock_timestamp' IN pg_get_functiondef('bu_private.cv5_now()'::regprocedure))>0,
 'api_search_path',EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='bu_career_v5' AND p.prosecdef AND p.proconfig@>ARRAY['search_path=pg_catalog'])
)) AS career_security_report;
