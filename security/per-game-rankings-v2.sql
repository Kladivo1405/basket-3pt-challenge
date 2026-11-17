-- Per-game practice rankings. Requires room-security v1; installs transactionally.
-- Account-bound writes and validated result shapes are not proof of an honest game.
BEGIN;
SELECT pg_advisory_xact_lock(738401210);
DO $$BEGIN IF public.bu_online_security_version_v1()<>1 THEN RAISE EXCEPTION 'Install room security v1 first';END IF;END;$$;
CREATE TABLE IF NOT EXISTS bu_private.rankings_v2(
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 board text NOT NULL,variant text NOT NULL,primary_value integer NOT NULL,tie_value integer NOT NULL,
 result jsonb NOT NULL,updated_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(user_id,board,variant)
);
CREATE INDEX IF NOT EXISTS bu_rankings_order ON bu_private.rankings_v2(board,variant,primary_value DESC,tie_value ASC);
CREATE TABLE IF NOT EXISTS bu_private.ranking_events_v2(
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,event_id uuid NOT NULL,
 board text NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(user_id,event_id)
);
CREATE TABLE IF NOT EXISTS bu_private.ranking_tickets_v2(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 started_at timestamptz NOT NULL DEFAULT clock_timestamp(),used boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS bu_ranking_ticket_user ON bu_private.ranking_tickets_v2(user_id,started_at);
ALTER TABLE bu_private.rankings_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE bu_private.ranking_events_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE bu_private.ranking_tickets_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bu_private.rankings_v2,bu_private.ranking_events_v2,bu_private.ranking_tickets_v2 FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION bu_private.valid_ranking_variant_v2(b text,v text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT CASE
 WHEN b IN ('threept60','freethrow') THEN v='standard'
 WHEN b='threept' THEN v='standard' OR v ~ '^daily:[0-9]{8}$' OR v ~ '^special:(clutch|sudden|perfect|double|noboost|hot|midrange)$'
 WHEN b='draft' THEN v='standard' OR v ~ '^daily:[0-9]{8}$'
 WHEN b IN ('parket','blockout') THEN v IN ('online','cpu:easy','cpu:medium','cpu:hard')
 WHEN b='dunk' THEN v ~ '^(easy|medium|hard):(twohand|windmill|spin|eastbay|combo)$'
 ELSE false END;
$$;
REVOKE ALL ON FUNCTION bu_private.valid_ranking_variant_v2(text,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.bu_ranking_start_v2()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();ticket uuid;
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED');END IF;
 IF NOT bu_private.consume('ranking_start',20,60) THEN RETURN jsonb_build_object('error','RATE_LIMIT');END IF;
 DELETE FROM bu_private.ranking_tickets_v2 WHERE user_id=u AND started_at<now()-interval '1 day';
 INSERT INTO bu_private.ranking_tickets_v2(user_id) VALUES(u) RETURNING id INTO ticket;
 RETURN jsonb_build_object('run_id',ticket);
END;$$;

CREATE OR REPLACE FUNCTION public.bu_ranking_submit_v2(p_board text,p_variant text,p_event_id uuid,p_result jsonb,p_nickname text DEFAULT 'PLAYER')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();value integer;tie integer:=0;canonical jsonb;old bu_private.rankings_v2%ROWTYPE;
 made integer;elapsed integer;shots jsonb;points integer;attempts integer;wins integer;losses integer;
 ticket bu_private.ranking_tickets_v2%ROWTYPE;server_ms numeric;changed boolean:=false;inserted integer;
 cap integer;note_count integer;trick text;mode text;
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED');END IF;
 IF NOT coalesce(bu_private.valid_ranking_variant_v2(p_board,p_variant),false) OR p_event_id IS NULL OR jsonb_typeof(p_result) IS DISTINCT FROM 'object' OR octet_length(p_result::text)>8192
 THEN RETURN jsonb_build_object('error','INVALID_RESULT');END IF;
 IF NOT bu_private.consume('ranking_submit',60,60) THEN RETURN jsonb_build_object('error','RATE_LIMIT');END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(u::text||':ranking',7384));
 IF EXISTS(SELECT 1 FROM bu_private.ranking_events_v2 WHERE user_id=u AND event_id=p_event_id) THEN RETURN jsonb_build_object('saved',true,'duplicate',true);END IF;
 BEGIN
  IF p_board='threept60' THEN
   SELECT * INTO ticket FROM bu_private.ranking_tickets_v2 WHERE id=(p_result->>'run_id')::uuid AND user_id=u FOR UPDATE;
   IF NOT FOUND OR ticket.used OR p_event_id<>ticket.id THEN RETURN jsonb_build_object('error','INVALID_RUN');END IF;
   shots:=p_result->'results';elapsed:=(p_result->>'elapsedMs')::integer;
   IF jsonb_typeof(shots) IS DISTINCT FROM 'array' OR elapsed IS NULL OR elapsed<0 OR elapsed>60000 THEN RETURN jsonb_build_object('error','INVALID_RESULT');END IF;
   attempts:=jsonb_array_length(shots);
   IF attempts<1 OR attempts>25 OR elapsed<(attempts-1)*250 OR EXISTS(SELECT 1 FROM jsonb_array_elements(shots) x WHERE jsonb_typeof(x) IS DISTINCT FROM 'boolean')
    OR (attempts<25 AND elapsed<>60000) THEN RETURN jsonb_build_object('error','INVALID_SHOTS');END IF;
   SELECT count(*) FILTER(WHERE shot='true'::jsonb),coalesce(sum(CASE WHEN shot='true'::jsonb THEN CASE WHEN n%5=0 THEN 2 ELSE 1 END ELSE 0 END),0)
   INTO made,points FROM jsonb_array_elements(shots) WITH ORDINALITY AS s(shot,n);
   IF made IS DISTINCT FROM (p_result->>'made')::integer OR points IS DISTINCT FROM (p_result->>'score')::integer THEN RETURN jsonb_build_object('error','INVALID_TOTAL');END IF;
   -- Network tolerance only: this rejects impossible elapsed claims, not fabricated shots.
   server_ms:=extract(epoch FROM clock_timestamp()-ticket.started_at)*1000;
   IF server_ms<0 OR server_ms>120000 OR elapsed>server_ms+3000 OR elapsed<server_ms-8000 THEN RETURN jsonb_build_object('error','TIMING_MISMATCH','message','Online timing could not be checked. Your result remains on this device.');END IF;
   value:=made;tie:=elapsed;
   canonical:=jsonb_build_object('made',made,'score',points,'elapsedMs',elapsed,'attempts',attempts);
  ELSIF p_board='threept' THEN
   value:=(p_result->>'score')::integer;made:=(p_result->>'made')::integer;
   IF value IS NULL OR made IS NULL OR value<0 OR value>50 OR made<0 OR made>25 OR value<made OR (p_variant='standard' AND (value>30 OR value>made+5)) THEN RETURN jsonb_build_object('error','INVALID_RESULT');END IF;
   tie:=-made;canonical:=jsonb_build_object('score',value,'made',made);
  ELSIF p_board='freethrow' THEN
   value:=(p_result->>'streak')::integer;
   IF value IS NULL OR value<0 OR value>10000 THEN RETURN jsonb_build_object('error','INVALID_RESULT');END IF;
   canonical:=jsonb_build_object('streak',value);
  ELSIF p_board='draft' THEN
   wins:=(p_result->>'wins')::integer;losses:=(p_result->>'losses')::integer;
   IF wins IS NULL OR losses IS NULL OR wins<0 OR losses<0 OR wins+losses<>82 THEN RETURN jsonb_build_object('error','INVALID_SEASON');END IF;
   value:=wins;tie:=losses;canonical:=jsonb_build_object('wins',wins,'losses',losses);
  ELSIF p_board IN ('parket','blockout') THEN
   IF jsonb_typeof(p_result->'won') IS DISTINCT FROM 'boolean' THEN RETURN jsonb_build_object('error','INVALID_RESULT');END IF;
   SELECT * INTO old FROM bu_private.rankings_v2 WHERE user_id=u AND board=p_board AND variant=p_variant FOR UPDATE;
   wins:=coalesce(old.primary_value,0)+CASE WHEN (p_result->>'won')::boolean THEN 1 ELSE 0 END;
   losses:=coalesce(old.tie_value,0)+CASE WHEN (p_result->>'won')::boolean THEN 0 ELSE 1 END;
   value:=wins;tie:=losses;canonical:=jsonb_build_object('wins',wins,'losses',losses);
  ELSIF p_board='dunk' THEN
   mode:=split_part(p_variant,':',1);trick:=split_part(p_variant,':',2);
   cap:=CASE trick WHEN 'twohand' THEN 36 WHEN 'windmill' THEN 40 WHEN 'spin' THEN 44 WHEN 'eastbay' THEN 47 ELSE 50 END;
   note_count:=CASE trick WHEN 'twohand' THEN 6 WHEN 'windmill' THEN 9 WHEN 'spin' THEN 12 WHEN 'eastbay' THEN 15 ELSE 18 END;
   IF mode='easy' THEN note_count:=greatest(4,ceil(note_count*.65)::integer);END IF;
   value:=(p_result->>'score')::integer;tie:=-((p_result->>'perfects')::integer);
   IF p_result->'success' IS DISTINCT FROM 'true'::jsonb OR value IS NULL OR tie IS NULL OR value<0 OR value>cap OR -tie<0 OR -tie>note_count
    OR (p_result->>'hits')::integer IS DISTINCT FROM note_count OR (p_result->>'errors')::integer IS DISTINCT FROM 0
   THEN RETURN jsonb_build_object('error','INVALID_DUNK');END IF;
   canonical:=jsonb_build_object('score',value,'perfects',-tie,'cues',note_count);
  END IF;
 EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value THEN
  RETURN jsonb_build_object('error','INVALID_RESULT');
 END;
 INSERT INTO bu_private.ranking_events_v2(user_id,event_id,board) VALUES(u,p_event_id,p_board) ON CONFLICT DO NOTHING;
 GET DIAGNOSTICS inserted=ROW_COUNT;
 IF inserted=0 THEN RETURN jsonb_build_object('saved',true,'duplicate',true);END IF;
 IF p_board='threept60' THEN UPDATE bu_private.ranking_tickets_v2 SET used=true WHERE id=ticket.id;END IF;
 INSERT INTO bu_private.rankings_v2 AS best(user_id,board,variant,primary_value,tie_value,result)
 VALUES(u,p_board,p_variant,value,tie,canonical)
 ON CONFLICT(user_id,board,variant) DO UPDATE SET primary_value=EXCLUDED.primary_value,tie_value=EXCLUDED.tie_value,result=EXCLUDED.result,updated_at=clock_timestamp()
 WHERE p_board IN ('parket','blockout') OR EXCLUDED.primary_value>best.primary_value OR (EXCLUDED.primary_value=best.primary_value AND EXCLUDED.tie_value<best.tie_value);
 GET DIAGNOSTICS inserted=ROW_COUNT;changed:=inserted>0;
 SELECT result INTO canonical FROM bu_private.rankings_v2 WHERE user_id=u AND board=p_board AND variant=p_variant;
 RETURN jsonb_build_object('saved',true,'personalBest',changed,'best',canonical,'practice',true);
END;$$;

CREATE OR REPLACE FUNCTION public.bu_ranking_list_v2(p_board text,p_variant text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE rows jsonb;
BEGIN
 IF NOT coalesce(bu_private.valid_ranking_variant_v2(p_board,p_variant),false) THEN RETURN jsonb_build_object('error','INVALID_BOARD');END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('rank',r.position,'nickname',coalesce(nullif(p.nickname,''),'PLAYER'),'result',r.result,'mine',r.user_id=auth.uid()) ORDER BY r.primary_value DESC,r.tie_value ASC,r.updated_at,r.user_id),'[]'::jsonb)
 INTO rows FROM (
  SELECT user_id,primary_value,tie_value,result,updated_at,dense_rank() OVER(ORDER BY primary_value DESC,tie_value ASC) AS position
  FROM bu_private.rankings_v2 WHERE board=p_board AND variant=p_variant
  ORDER BY primary_value DESC,tie_value ASC,updated_at,user_id LIMIT 50
 ) r LEFT JOIN public.bu_profiles p ON p.user_id=r.user_id;
 RETURN jsonb_build_object('rows',rows,'practice',true);
END;$$;
REVOKE ALL ON FUNCTION public.bu_ranking_start_v2(),public.bu_ranking_submit_v2(text,text,uuid,jsonb,text),public.bu_ranking_list_v2(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.bu_ranking_start_v2(),public.bu_ranking_submit_v2(text,text,uuid,jsonb,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bu_ranking_list_v2(text,text) TO anon,authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
SELECT 'Per-game rankings v2 installed. Refresh the game.' AS result;
