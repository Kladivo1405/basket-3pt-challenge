-- READ ONLY. Export the result as CSV and share it for the remaining RPC audit.
-- Reads function definitions and permissions, not player rows, passwords or tokens.
SELECT p.proname AS function_name,
       pg_get_function_identity_arguments(p.oid) AS arguments,
       p.prosecdef AS security_definer,
       p.proconfig::text AS function_settings,
       has_function_privilege('anon',p.oid,'EXECUTE') AS anonymous_access,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS account_access,
       pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.prokind='f'
  AND (p.proname LIKE 'bu_wardrobe_%' OR p.proname LIKE 'bu_friend%'
       OR p.proname IN ('bu_log_event'))
ORDER BY p.proname;
