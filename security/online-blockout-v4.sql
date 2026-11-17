-- Authoritative ONLINE Blockout. CPU and other games remain practice modes.
-- Requires economy v3 and rankings v2. All match state is server-private.
BEGIN;
SELECT pg_advisory_xact_lock(738401212);
DO $$BEGIN IF to_regprocedure('public.bu_progress_claim_v3(uuid,text,text,boolean,integer)') IS NULL THEN RAISE EXCEPTION 'Install economy v3 first';END IF;END;$$;
CREATE TABLE IF NOT EXISTS bu_private.blockout_v4(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),code text UNIQUE NOT NULL,
 game_id uuid NOT NULL DEFAULT gen_random_uuid(),host_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 guest_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
 host_name text NOT NULL,guest_name text,host_look jsonb,guest_look jsonb,
 phase text NOT NULL DEFAULT 'lobby' CHECK(phase IN ('lobby','choose','block','ready','shoot','playback','finished','cancelled')),
 revision integer NOT NULL DEFAULT 0,starter integer NOT NULL DEFAULT 0,attacker integer NOT NULL DEFAULT 0,
 chosen integer,guarded integer,score0 integer NOT NULL DEFAULT 0,score1 integer NOT NULL DEFAULT 0,
 possession integer NOT NULL DEFAULT 1,shots integer NOT NULL DEFAULT 0,blocked integer NOT NULL DEFAULT 0,missed integer NOT NULL DEFAULT 0,
 origin_ms bigint,deadline_ms bigint,last_result jsonb,winner integer,finish_reason text,
 rematch_mask integer NOT NULL DEFAULT 0,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(score0 BETWEEN 0 AND 5 AND score1 BETWEEN 0 AND 5),CHECK(attacker IN (0,1)),CHECK(starter IN (0,1)),
 CHECK(chosen IS NULL OR chosen BETWEEN 1 AND 3),CHECK(guarded IS NULL OR guarded BETWEEN 1 AND 3),CHECK(winner IS NULL OR winner IN (0,1)),CHECK(guest_id IS NULL OR guest_id<>host_id)
);
CREATE INDEX IF NOT EXISTS bu_bo4_host ON bu_private.blockout_v4(host_id,created_at);
CREATE INDEX IF NOT EXISTS bu_bo4_guest ON bu_private.blockout_v4(guest_id,created_at);
CREATE TABLE IF NOT EXISTS bu_private.blockout_outcomes_v4(
 game_id uuid PRIMARY KEY,match_id uuid NOT NULL REFERENCES bu_private.blockout_v4(id) ON DELETE CASCADE,
 host_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,guest_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 winner integer NOT NULL CHECK(winner IN (0,1)),score0 integer NOT NULL,score1 integer NOT NULL,reason text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS bu_private.blockout_requests_v4(
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,request_id uuid NOT NULL,
 fingerprint text NOT NULL,response jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(user_id,request_id)
);
CREATE TABLE IF NOT EXISTS bu_private.blockout_rewards_v4(
 game_id uuid NOT NULL REFERENCES bu_private.blockout_outcomes_v4(game_id) ON DELETE CASCADE,
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,xp integer NOT NULL,coins integer NOT NULL,seen boolean NOT NULL DEFAULT false,
 PRIMARY KEY(game_id,user_id)
);
CREATE TABLE IF NOT EXISTS bu_private.blockout_queue_v4(
 user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 match_id uuid REFERENCES bu_private.blockout_v4(id) ON DELETE CASCADE,created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
DO $$DECLARE t text;BEGIN FOREACH t IN ARRAY ARRAY['blockout_v4','blockout_outcomes_v4','blockout_requests_v4','blockout_rewards_v4','blockout_queue_v4'] LOOP
 EXECUTE format('ALTER TABLE bu_private.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('REVOKE ALL ON TABLE bu_private.%I FROM PUBLIC,anon,authenticated',t);
END LOOP;END;$$;
REVOKE ALL ON SCHEMA bu_private FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION bu_private.bo4_now() RETURNS bigint LANGUAGE sql VOLATILE SET search_path=pg_catalog AS $$SELECT floor(extract(epoch FROM clock_timestamp())*1000)::bigint;$$;
CREATE OR REPLACE FUNCTION bu_private.bo4_marker(t bigint) RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$SELECT CASE WHEN mod(greatest(0,t),2200)<=1100 THEN mod(greatest(0,t),2200)/11.0 ELSE (2200-mod(greatest(0,t),2200))/11.0 END;$$;

CREATE OR REPLACE FUNCTION bu_private.bo4_reward(g uuid,u uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE o bu_private.blockout_outcomes_v4;r bu_private.blockout_rewards_v4;p public.bu_profiles;w public.bu_wardrobe;
 won boolean;give_xp integer;give_coins integer;used_xp bigint;used_coins bigint;h text;event_id uuid;
BEGIN
 SELECT * INTO o FROM bu_private.blockout_outcomes_v4 WHERE game_id=g;
 IF NOT FOUND OR u IS NULL OR u NOT IN (o.host_id,o.guest_id) THEN RETURN jsonb_build_object('error','NO_OUTCOME');END IF;
 won:=CASE WHEN u=o.host_id THEN o.winner=0 ELSE o.winner=1 END;
 PERFORM pg_advisory_xact_lock(hashtextextended(u::text||':progress-v3',7385));
 SELECT * INTO r FROM bu_private.blockout_rewards_v4 WHERE game_id=g AND user_id=u;
 IF NOT FOUND THEN
  IF NOT EXISTS(SELECT 1 FROM public.bu_profiles WHERE user_id=u) THEN INSERT INTO public.bu_profiles(user_id,nickname,avatar,xp) VALUES(u,'Rookie','🏀',0) ON CONFLICT DO NOTHING;END IF;
  INSERT INTO public.bu_wardrobe(user_id) VALUES(u) ON CONFLICT DO NOTHING;
  SELECT * INTO p FROM public.bu_profiles WHERE user_id=u FOR UPDATE;
  SELECT * INTO w FROM public.bu_wardrobe WHERE user_id=u FOR UPDATE;
  SELECT coalesce(sum(xp),0) INTO used_xp FROM bu_private.progress_events_v3 WHERE user_id=u AND created_at>clock_timestamp()-interval '1 hour';
  SELECT coalesce(sum(amount),0) INTO used_coins FROM public.bu_coin_log WHERE user_id=u AND amount>0 AND reason IS DISTINCT FROM 'daily:v3' AND created_at>clock_timestamp()-interval '1 hour';
  give_xp:=CASE WHEN o.reason='score' THEN least(CASE WHEN won THEN 50 ELSE 20 END,greatest(0,1000-used_xp),greatest(0,2147483647::bigint-coalesce(p.xp,0)))::integer ELSE 0 END;
  give_coins:=CASE WHEN o.reason='score' THEN least(CASE WHEN won THEN 25 ELSE 8 END,greatest(0,500-used_coins),greatest(0,2147483647::bigint-coalesce(w.coins,0)))::integer ELSE 0 END;
  -- A reserved UUIDv8 namespace cannot be pre-claimed via the practice UUIDv4 API.
  h:=md5('blockout-v4:'||g::text||':'||u::text);event_id:=(substr(h,1,12)||'8'||substr(h,14))::uuid;
  INSERT INTO bu_private.progress_events_v3(user_id,event_id,kind,mode,xp,coins) VALUES(u,event_id,'verified_v4','blockout',give_xp,give_coins);
  UPDATE public.bu_profiles SET xp=xp+give_xp,updated_at=clock_timestamp() WHERE user_id=u;
  UPDATE public.bu_wardrobe SET coins=coins+give_coins,updated_at=clock_timestamp() WHERE user_id=u;
  INSERT INTO public.bu_coin_log(user_id,amount,reason) VALUES(u,give_coins,'verified:blockout');
  INSERT INTO public.bu_game_stats AS s(user_id,game_mode,played,wins,losses) VALUES(u,'blockout',1,CASE WHEN won THEN 1 ELSE 0 END,CASE WHEN won THEN 0 ELSE 1 END)
  ON CONFLICT(user_id,game_mode) DO UPDATE SET played=least(2147483647::bigint,greatest(0,s.played)::bigint+1)::integer,wins=least(2147483647::bigint,greatest(0,s.wins)::bigint+CASE WHEN won THEN 1 ELSE 0 END)::integer,losses=least(2147483647::bigint,greatest(0,s.losses)::bigint+CASE WHEN won THEN 0 ELSE 1 END)::integer,updated_at=clock_timestamp();
  INSERT INTO public.bu_match_history(user_id,game_mode,result,xp_earned,details) VALUES(u,'blockout',CASE WHEN won THEN 'win' ELSE 'loss' END,give_xp,jsonb_build_object('verified_rules',true,'game_id',g,'reason',o.reason));
  INSERT INTO bu_private.blockout_rewards_v4(game_id,user_id,xp,coins) VALUES(g,u,give_xp,give_coins) RETURNING * INTO r;
 END IF;
 SELECT * INTO p FROM public.bu_profiles WHERE user_id=u;SELECT * INTO w FROM public.bu_wardrobe WHERE user_id=u;
 RETURN jsonb_build_object('saved',true,'verified',true,'won',won,'xp',p.xp,'coins',w.coins,'owned',w.owned,'xpAwarded',r.xp,'coinsAwarded',r.coins,'reason',o.reason,'capped',o.reason='score' AND (r.xp<CASE WHEN won THEN 50 ELSE 20 END OR r.coins<CASE WHEN won THEN 25 ELSE 8 END));
END;$$;

CREATE OR REPLACE FUNCTION bu_private.bo4_finish(m uuid,winning integer,why text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r bu_private.blockout_v4;u uuid;
BEGIN
 SELECT * INTO r FROM bu_private.blockout_v4 WHERE id=m FOR UPDATE;
 IF r.phase IN ('finished','cancelled') THEN RETURN;END IF;
 IF r.guest_id IS NULL THEN UPDATE bu_private.blockout_v4 SET phase='cancelled',revision=revision+1,deadline_ms=NULL WHERE id=m;RETURN;END IF;
 UPDATE bu_private.blockout_v4 SET phase='finished',winner=winning,finish_reason=why,revision=revision+1,deadline_ms=NULL WHERE id=m;
 INSERT INTO bu_private.blockout_outcomes_v4(game_id,match_id,host_id,guest_id,winner,score0,score1,reason) VALUES(r.game_id,r.id,r.host_id,r.guest_id,winning,r.score0,r.score1,why) ON CONFLICT DO NOTHING;
 -- Acquire both participants' reward locks in stable order across simultaneous rooms.
 FOR u IN SELECT x FROM unnest(ARRAY[r.host_id,r.guest_id]) x ORDER BY x LOOP PERFORM pg_advisory_xact_lock(hashtextextended(u::text||':progress-v3',7385));END LOOP;
 PERFORM bu_private.bo4_reward(r.game_id,r.host_id);PERFORM bu_private.bo4_reward(r.game_id,r.guest_id);
END;$$;

CREATE OR REPLACE FUNCTION bu_private.bo4_resolve(m uuid,release numeric,timed_out boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r bu_private.blockout_v4;hit boolean;was_blocked boolean;now_ms bigint:=bu_private.bo4_now();
BEGIN
 SELECT * INTO r FROM bu_private.blockout_v4 WHERE id=m FOR UPDATE;
 IF r.phase<>'shoot' THEN RETURN;END IF;
 hit:=NOT timed_out AND release BETWEEN 40 AND 60;was_blocked:=r.chosen=r.guarded;
 UPDATE bu_private.blockout_v4 SET
 score0=score0+CASE WHEN r.attacker=0 AND hit AND NOT was_blocked THEN 1 ELSE 0 END,
 score1=score1+CASE WHEN r.attacker=1 AND hit AND NOT was_blocked THEN 1 ELSE 0 END,
 shots=shots+1,blocked=blockout_v4.blocked+CASE WHEN was_blocked THEN 1 ELSE 0 END,
 missed=missed+CASE WHEN NOT was_blocked AND NOT hit THEN 1 ELSE 0 END,
 last_result=jsonb_build_object('id',gen_random_uuid(),'possession',r.possession,'shooter',r.attacker,'chosen',r.chosen,'blockedHoop',r.guarded,'hit',hit,'blocked',was_blocked,'release',release,'timeout',timed_out,'before_scores',jsonb_build_array(r.score0,r.score1)),
 phase='playback',deadline_ms=now_ms+2400,revision=revision+1 WHERE id=m;
 SELECT * INTO r FROM bu_private.blockout_v4 WHERE id=m;
 IF r.score0>=5 OR r.score1>=5 THEN
  -- Persist the immutable outcome/rewards now, even if both browsers close mid-flight.
  PERFORM bu_private.bo4_finish(m,CASE WHEN r.score0>=5 THEN 0 ELSE 1 END,'score');
  UPDATE bu_private.blockout_v4 SET phase='playback',deadline_ms=now_ms+2400 WHERE id=m;
 END IF;
END;$$;

CREATE OR REPLACE FUNCTION bu_private.bo4_tick(m uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r bu_private.blockout_v4;n bigint:=bu_private.bo4_now();loser integer;
BEGIN
 SELECT * INTO r FROM bu_private.blockout_v4 WHERE id=m FOR UPDATE;
 IF r.deadline_ms IS NULL OR n<r.deadline_ms THEN RETURN;END IF;
 IF r.phase='lobby' THEN UPDATE bu_private.blockout_v4 SET phase='cancelled',deadline_ms=NULL,revision=revision+1 WHERE id=m;
 ELSIF r.phase='playback' THEN
  IF r.score0>=5 OR r.score1>=5 THEN PERFORM bu_private.bo4_finish(m,CASE WHEN r.score0>=5 THEN 0 ELSE 1 END,'score');
  ELSE UPDATE bu_private.blockout_v4 SET phase='choose',attacker=1-attacker,chosen=NULL,guarded=NULL,origin_ms=NULL,deadline_ms=n+45000,possession=possession+1,revision=revision+1 WHERE id=m;END IF;
 ELSIF r.phase='shoot' THEN PERFORM bu_private.bo4_resolve(m,0,true);
 ELSIF r.phase IN ('choose','block','ready') THEN loser:=CASE WHEN r.phase='block' THEN 1-r.attacker ELSE r.attacker END;PERFORM bu_private.bo4_finish(m,1-loser,'timeout');END IF;
END;$$;

CREATE OR REPLACE FUNCTION bu_private.bo4_view(m uuid,u uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r bu_private.blockout_v4;slot integer;
BEGIN
 SELECT * INTO r FROM bu_private.blockout_v4 WHERE id=m;
 IF NOT FOUND OR u IS NULL OR (u<>r.host_id AND u IS DISTINCT FROM r.guest_id) THEN RETURN jsonb_build_object('error','FORBIDDEN');END IF;
 slot:=CASE WHEN u=r.host_id THEN 0 ELSE 1 END;
 RETURN jsonb_build_object('match_id',r.id,'game_id',r.game_id,'code',r.code,'rules_version',4,'revision',r.revision,'you',slot,'server_ms',bu_private.bo4_now(),'phase',r.phase,
 'players',jsonb_build_array(jsonb_build_object('name',r.host_name,'look',r.host_look),CASE WHEN r.guest_id IS NULL THEN NULL ELSE jsonb_build_object('name',r.guest_name,'look',r.guest_look) END),
 'scores',jsonb_build_array(r.score0,r.score1),'attacker',r.attacker,'defender',1-r.attacker,'possession',r.possession,
 'chosen',CASE WHEN slot=r.attacker OR r.phase IN ('ready','shoot','playback','finished') THEN r.chosen ELSE NULL END,
 'blockedHoop',CASE WHEN slot=1-r.attacker OR r.phase IN ('playback','finished') THEN r.guarded ELSE NULL END,
 'stats',jsonb_build_object('shots',r.shots,'blocked',r.blocked,'missed',r.missed,'scored',r.score0+r.score1),
 'last_result',r.last_result,'origin_ms',r.origin_ms,'deadline_ms',r.deadline_ms,'winner',r.winner,'finish_reason',r.finish_reason,'rematch_mask',r.rematch_mask);
END;$$;

CREATE OR REPLACE FUNCTION bu_private.bo4_new(h uuid,g uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE m uuid;c text;bytes bytea;alphabet text:='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';hn text;gn text;hl jsonb;gl jsonb;i integer;
BEGIN
 IF (SELECT count(*) FROM bu_private.blockout_v4 WHERE (host_id=h OR guest_id=h) AND created_at>clock_timestamp()-interval '10 minutes')>=20 THEN RAISE EXCEPTION 'Please wait before creating another match';END IF;
 LOOP c:='';bytes:=uuid_send(gen_random_uuid());FOR i IN 0..5 LOOP c:=c||substr(alphabet,1+get_byte(bytes,i)%36,1);END LOOP;EXIT WHEN NOT EXISTS(SELECT 1 FROM bu_private.blockout_v4 WHERE code=c);END LOOP;
 SELECT left(coalesce(nickname,'PLAYER'),16) INTO hn FROM public.bu_profiles WHERE user_id=h;
 SELECT bu_private.outfit_v3(outfit,owned,false) INTO hl FROM public.bu_wardrobe WHERE user_id=h;
 IF g IS NOT NULL THEN SELECT left(coalesce(nickname,'PLAYER'),16) INTO gn FROM public.bu_profiles WHERE user_id=g;SELECT bu_private.outfit_v3(outfit,owned,false) INTO gl FROM public.bu_wardrobe WHERE user_id=g;END IF;
 INSERT INTO bu_private.blockout_v4(code,host_id,guest_id,host_name,guest_name,host_look,guest_look,phase,deadline_ms)
 VALUES(c,h,g,coalesce(hn,'PLAYER'),gn,coalesce(hl,'{}'),coalesce(gl,'{}'),CASE WHEN g IS NULL THEN 'lobby' ELSE 'choose' END,bu_private.bo4_now()+CASE WHEN g IS NULL THEN 600000 ELSE 45000 END) RETURNING id INTO m;
 RETURN m;
END;$$;

CREATE OR REPLACE FUNCTION public.bu_blockout_create_v4() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE m uuid;BEGIN IF auth.uid() IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED');END IF;
 IF NOT bu_private.consume('bo4_create',10,600) THEN RETURN jsonb_build_object('error','RATE_LIMIT');END IF;
 m:=bu_private.bo4_new(auth.uid());RETURN bu_private.bo4_view(m,auth.uid());END;$$;

CREATE OR REPLACE FUNCTION public.bu_blockout_join_v4(p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r bu_private.blockout_v4;u uuid:=auth.uid();n text;l jsonb;
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED');END IF;
 IF NOT bu_private.consume('bo4_join',20,60) THEN RETURN jsonb_build_object('error','RATE_LIMIT');END IF;
 IF p_code IS NULL OR upper(trim(p_code)) !~ '^[A-Z0-9]{6}$' THEN RETURN jsonb_build_object('error','INVALID_CODE');END IF;
 SELECT * INTO r FROM bu_private.blockout_v4 WHERE code=upper(trim(p_code)) FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('error','ROOM_UNAVAILABLE');END IF;
 PERFORM bu_private.bo4_tick(r.id);SELECT * INTO r FROM bu_private.blockout_v4 WHERE id=r.id;
 IF u=r.host_id OR u=r.guest_id THEN RETURN bu_private.bo4_view(r.id,u);END IF;
 IF r.phase<>'lobby' OR r.guest_id IS NOT NULL THEN RETURN jsonb_build_object('error','ROOM_UNAVAILABLE');END IF;
 SELECT left(coalesce(nickname,'PLAYER'),16) INTO n FROM public.bu_profiles WHERE user_id=u;SELECT bu_private.outfit_v3(outfit,owned,false) INTO l FROM public.bu_wardrobe WHERE user_id=u;
 UPDATE bu_private.blockout_v4 SET guest_id=u,guest_name=coalesce(n,'PLAYER'),guest_look=coalesce(l,'{}'),revision=revision+1 WHERE id=r.id;
 RETURN bu_private.bo4_view(r.id,u);
END;$$;

CREATE OR REPLACE FUNCTION public.bu_blockout_get_v4(p_match_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM bu_private.blockout_v4 WHERE id=p_match_id AND (host_id=auth.uid() OR guest_id=auth.uid())) THEN RETURN jsonb_build_object('error','FORBIDDEN');END IF;
 IF NOT bu_private.consume('bo4_read',180,60) THEN RETURN jsonb_build_object('error','RATE_LIMIT');END IF;
 PERFORM bu_private.bo4_tick(p_match_id);RETURN bu_private.bo4_view(p_match_id,auth.uid());
END;$$;

CREATE OR REPLACE FUNCTION public.bu_blockout_action_v4(p_match_id uuid,p_game_id uuid,p_revision integer,p_request_id uuid,p_action text,p_value integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r bu_private.blockout_v4;q bu_private.blockout_requests_v4;u uuid:=auth.uid();slot integer;fp text;response jsonb;n bigint:=bu_private.bo4_now();release numeric;mask integer;
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED');END IF;
 IF p_request_id IS NULL OR p_revision IS NULL OR p_game_id IS NULL OR p_action IS NULL OR p_action NOT IN ('start','choose','guard','arm','release','advance','leave','rematch') OR (p_action NOT IN ('choose','guard') AND p_value IS NOT NULL) THEN RETURN jsonb_build_object('error','INVALID_ACTION');END IF;
 fp:=md5(jsonb_build_array(p_match_id,p_game_id,p_revision,p_action,p_value)::text);
 SELECT * INTO q FROM bu_private.blockout_requests_v4 WHERE user_id=u AND request_id=p_request_id;
 IF FOUND THEN IF q.fingerprint<>fp THEN RETURN jsonb_build_object('error','REQUEST_REUSED');END IF;RETURN q.response;END IF;
 IF NOT bu_private.consume('bo4_action',120,60) THEN RETURN jsonb_build_object('error','RATE_LIMIT');END IF;
 SELECT * INTO r FROM bu_private.blockout_v4 WHERE id=p_match_id FOR UPDATE;
 IF NOT FOUND OR (u<>r.host_id AND u IS DISTINCT FROM r.guest_id) THEN RETURN jsonb_build_object('error','FORBIDDEN');END IF;
 -- Recheck after the row lock: an identical retry may have committed while waiting.
 SELECT * INTO q FROM bu_private.blockout_requests_v4 WHERE user_id=u AND request_id=p_request_id;
 IF FOUND THEN IF q.fingerprint<>fp THEN RETURN jsonb_build_object('error','REQUEST_REUSED');END IF;RETURN q.response;END IF;
 IF NOT (p_action='release' AND r.phase='shoot' AND n>=r.origin_ms AND n<r.deadline_ms) THEN PERFORM bu_private.bo4_tick(r.id);END IF;
 SELECT * INTO r FROM bu_private.blockout_v4 WHERE id=p_match_id;
 IF r.game_id<>p_game_id OR r.revision<>p_revision THEN RETURN jsonb_build_object('error','STALE','state',bu_private.bo4_view(r.id,u));END IF;
 slot:=CASE WHEN u=r.host_id THEN 0 ELSE 1 END;
 IF p_action='start' AND r.phase='lobby' AND slot=0 AND r.guest_id IS NOT NULL THEN
  UPDATE bu_private.blockout_v4 SET phase='choose',deadline_ms=n+45000,revision=revision+1 WHERE id=r.id;
 ELSIF p_action='choose' AND r.phase='choose' AND slot=r.attacker AND p_value BETWEEN 1 AND 3 THEN
  UPDATE bu_private.blockout_v4 SET chosen=p_value,phase='block',deadline_ms=n+45000,revision=revision+1 WHERE id=r.id;
 ELSIF p_action='guard' AND r.phase='block' AND slot<>r.attacker AND p_value BETWEEN 1 AND 3 THEN
  UPDATE bu_private.blockout_v4 SET guarded=p_value,phase='ready',deadline_ms=n+45000,revision=revision+1 WHERE id=r.id;
 ELSIF p_action='arm' AND r.phase='ready' AND slot=r.attacker THEN
  UPDATE bu_private.blockout_v4 SET phase='shoot',origin_ms=n+1500,deadline_ms=n+16500,revision=revision+1 WHERE id=r.id;
 ELSIF p_action='release' AND r.phase='shoot' AND slot=r.attacker THEN
  IF n<r.origin_ms THEN RETURN jsonb_build_object('error','EARLY');END IF;
  release:=bu_private.bo4_marker(n-r.origin_ms);PERFORM bu_private.bo4_resolve(r.id,release,false);
 ELSIF p_action='advance' AND r.phase='playback' THEN RETURN jsonb_build_object('error','NOT_READY');
 ELSIF p_action='leave' AND r.phase NOT IN ('finished','cancelled') THEN
  IF r.score0>=5 OR r.score1>=5 THEN PERFORM bu_private.bo4_finish(r.id,CASE WHEN r.score0>=5 THEN 0 ELSE 1 END,'score');ELSE PERFORM bu_private.bo4_finish(r.id,1-slot,'forfeit');END IF;
 ELSIF p_action='rematch' AND r.phase='finished' THEN
  mask:=r.rematch_mask|(1<<slot);
  IF mask=r.rematch_mask THEN NULL;
  ELSIF mask=3 THEN UPDATE bu_private.blockout_v4 SET game_id=gen_random_uuid(),phase='choose',revision=revision+1,starter=1-starter,attacker=1-starter,chosen=NULL,guarded=NULL,score0=0,score1=0,possession=1,shots=0,blocked=0,missed=0,origin_ms=NULL,last_result=NULL,winner=NULL,finish_reason=NULL,rematch_mask=0,deadline_ms=n+45000 WHERE id=r.id;
  ELSE UPDATE bu_private.blockout_v4 SET rematch_mask=mask,revision=revision+1 WHERE id=r.id;END IF;
 ELSE RETURN jsonb_build_object('error','ILLEGAL_MOVE','state',bu_private.bo4_view(r.id,u));END IF;
 response:=bu_private.bo4_view(r.id,u);
 INSERT INTO bu_private.blockout_requests_v4(user_id,request_id,fingerprint,response) VALUES(u,p_request_id,fp,response);
 RETURN response;
END;$$;

CREATE OR REPLACE FUNCTION public.bu_blockout_claim_v4(p_game_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE response jsonb;n integer;BEGIN
 response:=bu_private.bo4_reward(p_game_id,auth.uid());IF response?'error' THEN RETURN response;END IF;
 UPDATE bu_private.blockout_rewards_v4 SET seen=true WHERE game_id=p_game_id AND user_id=auth.uid() AND NOT seen;GET DIAGNOSTICS n=ROW_COUNT;
 RETURN response||jsonb_build_object('notify',n>0);
END;$$;

CREATE OR REPLACE FUNCTION public.bu_blockout_board_v4() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 WITH results AS (
 SELECT host_id AS user_id,(winner=0)::integer AS won,(winner=1)::integer AS lost FROM bu_private.blockout_outcomes_v4
 UNION ALL SELECT guest_id,(winner=1)::integer,(winner=0)::integer FROM bu_private.blockout_outcomes_v4
 ),totals AS (SELECT user_id,sum(won)::integer AS wins,sum(lost)::integer AS losses FROM results GROUP BY user_id),ranked AS (
 SELECT *,dense_rank() OVER(ORDER BY wins DESC,losses ASC) AS place FROM totals
 ) SELECT jsonb_build_object('verified',true,'rows',coalesce((SELECT jsonb_agg(jsonb_build_object('rank',place,'nickname',name,'result',jsonb_build_object('wins',wins,'losses',losses),'mine',user_id=auth.uid()) ORDER BY wins DESC,losses ASC,user_id) FROM (SELECT r.*,coalesce(p.nickname,'PLAYER') AS name FROM ranked r LEFT JOIN public.bu_profiles p USING(user_id) ORDER BY wins DESC,losses ASC,user_id LIMIT 50) x),'[]'::jsonb));
$$;

CREATE OR REPLACE FUNCTION public.bu_blockout_queue_v4(p_action text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();q bu_private.blockout_queue_v4;other bu_private.blockout_queue_v4;m uuid;
BEGIN
 IF u IS NULL OR p_action IS NULL OR p_action NOT IN ('join','status','cancel') THEN RETURN jsonb_build_object('error','INVALID_REQUEST');END IF;
 PERFORM pg_advisory_xact_lock(738401214);
 SELECT * INTO q FROM bu_private.blockout_queue_v4 WHERE user_id=u FOR UPDATE;
 IF q.match_id IS NOT NULL THEN
  PERFORM bu_private.bo4_tick(q.match_id);
  IF p_action='join' AND EXISTS(SELECT 1 FROM bu_private.blockout_v4 WHERE id=q.match_id AND phase IN ('finished','cancelled')) THEN DELETE FROM bu_private.blockout_queue_v4 WHERE user_id=u;
  ELSE RETURN jsonb_build_object('status','matched','state',bu_private.bo4_view(q.match_id,u));END IF;
 END IF;
 IF p_action='cancel' THEN DELETE FROM bu_private.blockout_queue_v4 WHERE user_id=u;RETURN jsonb_build_object('status','cancelled');END IF;
 IF p_action='status' THEN RETURN jsonb_build_object('status',CASE WHEN q.user_id IS NOT NULL AND q.created_at>clock_timestamp()-interval '30 seconds' THEN 'waiting' ELSE 'expired' END);END IF;
 IF NOT bu_private.consume('bo4_queue',20,60) THEN RETURN jsonb_build_object('error','RATE_LIMIT');END IF;
 DELETE FROM bu_private.blockout_queue_v4 WHERE match_id IS NULL AND created_at<clock_timestamp()-interval '30 seconds';
 INSERT INTO bu_private.blockout_queue_v4(user_id) VALUES(u) ON CONFLICT(user_id) DO NOTHING;
 SELECT * INTO other FROM bu_private.blockout_queue_v4 WHERE user_id<>u AND match_id IS NULL AND created_at>clock_timestamp()-interval '30 seconds' ORDER BY created_at LIMIT 1 FOR UPDATE;
 IF other.user_id IS NULL THEN RETURN jsonb_build_object('status','waiting');END IF;
 m:=bu_private.bo4_new(other.user_id,u);UPDATE bu_private.blockout_queue_v4 SET match_id=m WHERE user_id IN (other.user_id,u);
 RETURN jsonb_build_object('status','matched','state',bu_private.bo4_view(m,u));
END;$$;

-- Pin and deny direct execution of every new private helper.
DO $$DECLARE f record;BEGIN FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='bu_private' AND p.proname LIKE 'bo4_%' LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f.signature);END LOOP;END;$$;
REVOKE ALL ON FUNCTION public.bu_blockout_create_v4(),public.bu_blockout_join_v4(text),public.bu_blockout_get_v4(uuid),public.bu_blockout_action_v4(uuid,uuid,integer,uuid,text,integer),public.bu_blockout_claim_v4(uuid),public.bu_blockout_board_v4(),public.bu_blockout_queue_v4(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.bu_blockout_create_v4(),public.bu_blockout_join_v4(text),public.bu_blockout_get_v4(uuid),public.bu_blockout_action_v4(uuid,uuid,integer,uuid,text,integer),public.bu_blockout_claim_v4(uuid),public.bu_blockout_queue_v4(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bu_blockout_board_v4() TO anon,authenticated;
-- Compatibility/retirement definitions are appended by build.mjs before COMMIT.

-- Preserve other practice modes; reserve canonical receipts and retire old online Blockout.
CREATE OR REPLACE FUNCTION public.bu_progress_claim_v3(p_event_id uuid,p_kind text,p_mode text,p_won boolean DEFAULT false,p_xp integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();p public.bu_profiles;w public.bu_wardrobe;give_xp integer;give_coins integer;used_xp bigint;used_coins bigint;requested_xp integer;requested_coins integer;
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED');END IF;
 IF substr(p_event_id::text,15,1) IS DISTINCT FROM '4' THEN RETURN jsonb_build_object('error','RESERVED_RECEIPT');END IF;
 IF p_event_id IS NULL OR p_kind IS NULL OR p_kind NOT IN ('match','solo') OR p_mode IS NULL OR
  (p_kind='match' AND p_mode NOT IN ('threept','draft','parket','blockout')) OR (p_kind='solo' AND p_mode<>'solo')
 THEN RETURN jsonb_build_object('error','INVALID_EVENT');END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(u::text||':progress-v3',7385));
 IF EXISTS(SELECT 1 FROM bu_private.progress_events_v3 WHERE user_id=u AND event_id=p_event_id) THEN
  SELECT * INTO p FROM public.bu_profiles WHERE user_id=u;SELECT * INTO w FROM public.bu_wardrobe WHERE user_id=u;
  RETURN jsonb_build_object('saved',true,'duplicate',true,'xp',p.xp,'coins',w.coins,'owned',w.owned);
 END IF;
 IF NOT bu_private.consume('progress',60,60) THEN RETURN jsonb_build_object('error','RATE_LIMIT');END IF;
 IF NOT EXISTS(SELECT 1 FROM public.bu_profiles WHERE user_id=u) THEN INSERT INTO public.bu_profiles(user_id,nickname,avatar,xp) VALUES(u,'Rookie','🏀',0) ON CONFLICT(user_id) DO NOTHING;END IF;
 INSERT INTO public.bu_wardrobe(user_id) VALUES(u) ON CONFLICT(user_id) DO NOTHING;
 SELECT * INTO p FROM public.bu_profiles WHERE user_id=u FOR UPDATE;
 SELECT * INTO w FROM public.bu_wardrobe WHERE user_id=u FOR UPDATE;
 requested_xp:=CASE WHEN p_kind='match' THEN CASE WHEN coalesce(p_won,false) THEN 50 ELSE 20 END ELSE greatest(0,least(coalesce(p_xp,0),90)) END;
 requested_coins:=CASE WHEN p_kind='match' THEN CASE WHEN coalesce(p_won,false) THEN 25 ELSE 8 END ELSE round(requested_xp/4.0)::integer END;
 SELECT coalesce(sum(e.xp),0) INTO used_xp FROM bu_private.progress_events_v3 e WHERE e.user_id=u AND e.created_at>clock_timestamp()-interval '1 hour';
 SELECT coalesce(sum(amount),0) INTO used_coins FROM public.bu_coin_log WHERE user_id=u AND amount>0 AND reason IS DISTINCT FROM 'daily:v3' AND created_at>clock_timestamp()-interval '1 hour';
 give_xp:=least(requested_xp,greatest(0,1000-used_xp),greatest(0,2147483647::bigint-coalesce(p.xp,0)))::integer;
 give_coins:=least(requested_coins,greatest(0,500-used_coins),greatest(0,2147483647::bigint-coalesce(w.coins,0)))::integer;
 UPDATE public.bu_profiles SET xp=coalesce(xp,0)+give_xp,updated_at=clock_timestamp() WHERE user_id=u RETURNING * INTO p;
 IF p_kind='match' THEN
  INSERT INTO public.bu_game_stats AS stats(user_id,game_mode,played,wins,losses) VALUES(u,p_mode,1,CASE WHEN coalesce(p_won,false) THEN 1 ELSE 0 END,CASE WHEN coalesce(p_won,false) THEN 0 ELSE 1 END)
  ON CONFLICT(user_id,game_mode) DO UPDATE SET played=least(2147483647::bigint,greatest(0,stats.played)::bigint+1)::integer,wins=least(2147483647::bigint,greatest(0,stats.wins)::bigint+CASE WHEN coalesce(p_won,false) THEN 1 ELSE 0 END)::integer,losses=least(2147483647::bigint,greatest(0,stats.losses)::bigint+CASE WHEN coalesce(p_won,false) THEN 0 ELSE 1 END)::integer,updated_at=clock_timestamp();
  INSERT INTO public.bu_match_history(user_id,game_mode,result,xp_earned,details) VALUES(u,p_mode,CASE WHEN coalesce(p_won,false) THEN 'win' ELSE 'loss' END,give_xp,jsonb_build_object('practice',true,'event_id',p_event_id));
 END IF;
 UPDATE public.bu_wardrobe SET coins=coins+give_coins,
  owned=CASE WHEN p_kind='match' AND p_mode='draft' AND coalesce(p_won,false) AND NOT coalesce(owned,'[]'::jsonb)?'j:c:#f2c230' THEN coalesce(owned,'[]'::jsonb)||'"j:c:#f2c230"'::jsonb ELSE owned END,
  updated_at=clock_timestamp() WHERE user_id=u RETURNING * INTO w;
 INSERT INTO bu_private.progress_events_v3(user_id,event_id,kind,mode,xp,coins) VALUES(u,p_event_id,p_kind,p_mode,give_xp,give_coins);
 INSERT INTO public.bu_coin_log(user_id,amount,reason) VALUES(u,give_coins,'practice:'||p_mode);
 RETURN jsonb_build_object('saved',true,'xp',p.xp,'xpAwarded',give_xp,'coins',w.coins,'coinsAwarded',give_coins,'owned',w.owned,'capped',give_xp<requested_xp OR give_coins<requested_coins,'practice',true);
END;$$;
CREATE OR REPLACE FUNCTION public.bu_room_join_v1(p_kind text,p_code text,p_nickname text,p_look jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();t text;r jsonb;st jsonb;m bu_private.room_members%ROWTYPE;
 n integer;capacity integer;name text:=coalesce(nullif(left(trim(p_nickname),16),''),'PLAYER');roster jsonb;
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED','message','Sign in before joining.');END IF;
 IF p_kind='blockout' THEN RETURN jsonb_build_object('error','RETIRED_MODE','message','Refresh the game to play server-controlled Blockout.');END IF;
 IF NOT bu_private.consume('room_join',40,60) THEN RETURN jsonb_build_object('error','RATE_LIMIT','message','Too many attempts. Please wait one minute.');END IF;
 t:=CASE WHEN p_kind IN ('threept','threeptcontest') THEN 'basket_matches' WHEN p_kind='draft' THEN 'draft_multiplayer_rooms' WHEN p_kind IN ('parket','blockout') THEN 'parket_multiplayer_rooms' ELSE NULL END;
 IF t IS NULL OR p_code !~ '^[A-Z0-9]{6}$' OR octet_length(coalesce(p_look,'{}'::jsonb)::text)>2048 THEN RETURN jsonb_build_object('error','INVALID_REQUEST');END IF;
 EXECUTE format('SELECT to_jsonb(room) FROM public.%I room WHERE room_code=$1 FOR UPDATE',t) INTO r USING p_code;
 IF r IS NULL THEN
  IF EXISTS(SELECT 1 FROM bu_private.room_members WHERE room_table=t AND room_code=p_code AND user_id=u AND created_at>now()-interval '1 minute')
  THEN RETURN jsonb_build_object('error','ROOM_NOT_READY');END IF;
  RETURN jsonb_build_object('error','ROOM_UNAVAILABLE');
 END IF;
 -- Never adopt legacy rooms by nicknames. Existing rows stay archived.
 IF NOT EXISTS(SELECT 1 FROM bu_private.room_members WHERE room_table=t AND room_code=p_code AND slot=0)
 THEN RETURN jsonb_build_object('error','ROOM_UNAVAILABLE','message','Create a new room with the updated game.');END IF;
 st:=r->'game_state';
 IF (p_kind='threeptcontest' AND st->>'mode' IS DISTINCT FROM '3ptcontest') OR
    (p_kind='threept' AND st->>'mode'='3ptcontest') OR
    (p_kind='blockout' AND st->>'mode' IS DISTINCT FROM 'three_hoops_blockout') OR
    (p_kind='parket' AND st->>'mode'='three_hoops_blockout')
 THEN RETURN jsonb_build_object('error','WRONG_MODE','message','This code belongs to a different game mode.');END IF;
 SELECT * INTO m FROM bu_private.room_members WHERE room_table=t AND room_code=p_code AND user_id=u;
 IF FOUND AND m.joined THEN RETURN jsonb_build_object('row',r,'slot',m.slot);END IF;
 IF (p_kind IN ('parket','blockout') AND st->>'phase' IS DISTINCT FROM 'lobby') OR
    (p_kind IN ('threept','threeptcontest','draft') AND r->>'status' IS DISTINCT FROM 'waiting')
 THEN RETURN jsonb_build_object('error','ROOM_UNAVAILABLE','message','The room is full or the game has started.');END IF;
 SELECT count(*) INTO n FROM bu_private.room_members WHERE room_table=t AND room_code=p_code AND joined;
 capacity:=CASE WHEN p_kind='parket' THEN 6 ELSE 2 END;
 IF n>=capacity THEN RETURN jsonb_build_object('error','ROOM_FULL');END IF;
 IF m.user_id IS NOT NULL AND m.slot<>n THEN RETURN jsonb_build_object('error','ROOM_NOT_READY');END IF;
 -- An exact-code invitation claims one slot atomically under the room row lock.
 IF m.user_id IS NULL THEN
  IF EXISTS(SELECT 1 FROM bu_private.room_members WHERE room_table=t AND room_code=p_code AND slot=n)
  THEN RETURN jsonb_build_object('error','ROOM_RESERVED');END IF;
  INSERT INTO bu_private.room_members(room_table,room_code,user_id,slot,joined) VALUES(t,p_code,u,n,true);
 ELSE
  UPDATE bu_private.room_members SET joined=true WHERE room_table=t AND room_code=p_code AND user_id=u;
 END IF;
 IF p_kind IN ('threept','threeptcontest') THEN
  st:=st||jsonb_build_object('names',jsonb_build_array(r->>'player1_name',name),'phase',CASE WHEN p_kind='threeptcontest' THEN 'playing' ELSE 'draft' END);
  IF p_kind='threeptcontest' THEN st:=st||'{"turn":0}'::jsonb;END IF;
  UPDATE public.basket_matches SET player2_name=name,status='playing',game_state=st WHERE room_code=p_code;
 ELSIF p_kind='draft' THEN
  st:=st||jsonb_build_object('players',jsonb_build_array(r->>'host_name',name));
  UPDATE public.draft_multiplayer_rooms SET guest_name=name,status='playing',game_state=st,updated_at=now() WHERE room_code=p_code;
 ELSE
  roster:=coalesce(st->'players','[]'::jsonb);
  IF jsonb_typeof(roster)<>'array' OR jsonb_array_length(roster)<>n THEN RAISE EXCEPTION 'Invalid room roster';END IF;
  st:=st||jsonb_build_object('players',roster||jsonb_build_array(jsonb_build_object('name',name,'look',coalesce(p_look,'{}'::jsonb),'ready',p_kind='blockout')));
  UPDATE public.parket_multiplayer_rooms SET game_state=st,updated_at=now() WHERE room_code=p_code;
 END IF;
 EXECUTE format('SELECT to_jsonb(room) FROM public.%I room WHERE room_code=$1',t) INTO r USING p_code;
 RETURN jsonb_build_object('row',r,'slot',n);
END;$$;
CREATE OR REPLACE FUNCTION public.bu_quick_match_v1(p_mode text,p_nickname text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();me bu_private.quick_queue%ROWTYPE;other bu_private.quick_queue%ROWTYPE;
 code text;t text;initial jsonb;host_name text;
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED');END IF;
 IF p_mode='blockout' THEN RETURN jsonb_build_object('error','RETIRED_MODE');END IF;
 IF p_mode NOT IN ('threept','threeptcontest','parket','draft','blockout') THEN RETURN jsonb_build_object('error','INVALID_MODE');END IF;
 IF NOT bu_private.consume('quick_match',15,60) THEN RETURN jsonb_build_object('error','RATE_LIMIT');END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('bu-quick-'||p_mode,8192));
 -- Repeated taps reuse a pending entry rather than matching a user with themself.
 SELECT * INTO me FROM bu_private.quick_queue WHERE user_id=u AND mode=p_mode AND status IN ('waiting','matched') AND created_at>now()-interval '20 seconds' ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
 IF FOUND THEN RETURN jsonb_build_object('status',me.status,'queue_id',me.id,'room_code',me.room_code,'slot',me.slot,'opponent',me.opponent);END IF;
 UPDATE bu_private.quick_queue SET status='expired' WHERE mode=p_mode AND status='waiting' AND created_at<now()-interval '20 seconds';
 SELECT * INTO other FROM bu_private.quick_queue WHERE mode=p_mode AND status='waiting' AND user_id<>u AND created_at>now()-interval '20 seconds' ORDER BY created_at LIMIT 1 FOR UPDATE;
 INSERT INTO bu_private.quick_queue(user_id,mode,nickname) VALUES(u,p_mode,coalesce(nullif(left(trim(p_nickname),16),''),'PLAYER')) RETURNING * INTO me;
 IF other.id IS NULL THEN RETURN jsonb_build_object('status','waiting','queue_id',me.id);END IF;
 t:=CASE WHEN p_mode IN ('threept','threeptcontest') THEN 'basket_matches' WHEN p_mode='draft' THEN 'draft_multiplayer_rooms' ELSE 'parket_multiplayer_rooms' END;
 -- UUID-backed 6-character codes; reserve both slots before returning the match.
 LOOP
  code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
  EXIT WHEN NOT EXISTS(SELECT 1 FROM bu_private.room_members WHERE room_table=t AND room_code=code)
   AND NOT EXISTS(SELECT 1 FROM public.basket_matches WHERE room_code=code)
   AND NOT EXISTS(SELECT 1 FROM public.parket_multiplayer_rooms WHERE room_code=code)
   AND NOT EXISTS(SELECT 1 FROM public.draft_multiplayer_rooms WHERE room_code=code);
 END LOOP;
 -- The creator is the first waiting player, except contest mode which starts here.
 IF p_mode='threeptcontest' THEN
  INSERT INTO bu_private.room_members(room_table,room_code,user_id,slot,joined) VALUES(t,code,u,0,true),(t,code,other.user_id,1,true);
  initial:=jsonb_build_object('mode','3ptcontest','phase','playing','names',jsonb_build_array(me.nickname,other.nickname),'results',jsonb_build_array(NULL,NULL),'turn',0);
  INSERT INTO public.basket_matches(room_code,player1_name,player2_name,status,game_state) VALUES(code,me.nickname,other.nickname,'playing',initial);
  UPDATE bu_private.quick_queue SET status='matched',room_code=code,slot=1,opponent=me.nickname WHERE id=other.id;
  UPDATE bu_private.quick_queue SET status='matched',room_code=code,slot=0,opponent=other.nickname WHERE id=me.id;
  RETURN jsonb_build_object('status','matched','queue_id',me.id,'room_code',code,'slot',0,'opponent',other.nickname);
 END IF;
 INSERT INTO bu_private.room_members(room_table,room_code,user_id,slot,joined) VALUES(t,code,other.user_id,0,false),(t,code,u,1,false);
 UPDATE bu_private.quick_queue SET status='matched',room_code=code,slot=0,opponent=me.nickname WHERE id=other.id;
 UPDATE bu_private.quick_queue SET status='matched',room_code=code,slot=1,opponent=other.nickname WHERE id=me.id;
 RETURN jsonb_build_object('status','matched','queue_id',me.id,'room_code',code,'slot',1,'opponent',other.nickname);
END;$$;

DROP POLICY IF EXISTS bu_no_legacy_bo_read_v4 ON public.parket_multiplayer_rooms;
DROP POLICY IF EXISTS bu_no_legacy_bo_insert_v4 ON public.parket_multiplayer_rooms;
DROP POLICY IF EXISTS bu_no_legacy_bo_update_v4 ON public.parket_multiplayer_rooms;
CREATE POLICY bu_no_legacy_bo_read_v4 ON public.parket_multiplayer_rooms AS RESTRICTIVE FOR SELECT TO authenticated USING(game_state->>'mode' IS DISTINCT FROM 'three_hoops_blockout');
CREATE POLICY bu_no_legacy_bo_insert_v4 ON public.parket_multiplayer_rooms AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK(game_state->>'mode' IS DISTINCT FROM 'three_hoops_blockout');
CREATE POLICY bu_no_legacy_bo_update_v4 ON public.parket_multiplayer_rooms AS RESTRICTIVE FOR UPDATE TO authenticated USING(game_state->>'mode' IS DISTINCT FROM 'three_hoops_blockout') WITH CHECK(game_state->>'mode' IS DISTINCT FROM 'three_hoops_blockout');
NOTIFY pgrst,'reload schema';
COMMIT;
SELECT 'Online Blockout v4 installed. Refresh both clients and create a new room.' AS result;
