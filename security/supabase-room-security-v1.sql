-- Basketball Universe: bind rooms to authenticated user IDs, including guest IDs.
-- This changes permissions. Old rooms remain stored but cannot be claimed by name.
-- Run once in Supabase SQL Editor after the compatible web client is published.
-- No player profiles, passwords, outfits, coins or saved scores are deleted.
BEGIN;
SELECT pg_advisory_xact_lock(738401209);
CREATE SCHEMA IF NOT EXISTS bu_private;
REVOKE ALL ON SCHEMA bu_private FROM PUBLIC,anon,authenticated;

CREATE TABLE IF NOT EXISTS bu_private.room_members (
 room_table text NOT NULL CHECK(room_table IN ('basket_matches','parket_multiplayer_rooms','draft_multiplayer_rooms')),
 room_code text NOT NULL CHECK(room_code ~ '^[A-Z0-9]{6}$'),
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 slot integer NOT NULL CHECK(slot BETWEEN 0 AND 5),
 joined boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(room_table,room_code,user_id),UNIQUE(room_table,room_code,slot)
);
CREATE INDEX IF NOT EXISTS bu_room_member_user ON bu_private.room_members(user_id,created_at);
CREATE TABLE IF NOT EXISTS bu_private.request_limits (
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 action text NOT NULL,window_start timestamptz NOT NULL,attempts integer NOT NULL,
 PRIMARY KEY(user_id,action)
);
CREATE TABLE IF NOT EXISTS bu_private.quick_queue (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 mode text NOT NULL CHECK(mode IN ('threept','threeptcontest','parket','draft','blockout')),
 nickname text NOT NULL,status text NOT NULL DEFAULT 'waiting',
 room_code text,slot integer,opponent text,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bu_quick_waiting ON bu_private.quick_queue(mode,status,created_at);
ALTER TABLE bu_private.room_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE bu_private.request_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE bu_private.quick_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA bu_private FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION bu_private.consume(p_action text,p_limit integer,p_seconds integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE n integer;u uuid:=auth.uid();
BEGIN
 IF u IS NULL THEN RETURN false;END IF;
 INSERT INTO bu_private.request_limits AS limits(user_id,action,window_start,attempts)
 VALUES(u,p_action,clock_timestamp(),1)
 ON CONFLICT(user_id,action) DO UPDATE SET
 attempts=CASE WHEN limits.window_start<clock_timestamp()-make_interval(secs=>p_seconds) THEN 1 ELSE limits.attempts+1 END,
 window_start=CASE WHEN limits.window_start<clock_timestamp()-make_interval(secs=>p_seconds) THEN clock_timestamp() ELSE limits.window_start END
 RETURNING attempts INTO n;
 RETURN n<=p_limit;
END;$$;
REVOKE ALL ON FUNCTION bu_private.consume(text,integer,integer) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.bu_room_member_v1(p_table text,p_code text)
RETURNS boolean LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM bu_private.room_members
 WHERE room_table=p_table AND room_code=p_code AND user_id=auth.uid() AND joined);
$$;
REVOKE ALL ON FUNCTION public.bu_room_member_v1(text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bu_room_member_v1(text,text) TO authenticated;

CREATE OR REPLACE FUNCTION bu_private.register_room()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();reserved uuid;active integer;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Sign in before creating a room';END IF;
 IF NEW.room_code !~ '^[A-Z0-9]{6}$' THEN RAISE EXCEPTION 'Invalid room code';END IF;
 IF NEW.game_state IS NULL OR jsonb_typeof(NEW.game_state)<>'object' OR octet_length(NEW.game_state::text)>262144
 THEN RAISE EXCEPTION 'Invalid room state';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(u::text,7183));
 SELECT user_id INTO reserved FROM bu_private.room_members
 WHERE room_table=TG_TABLE_NAME AND room_code=NEW.room_code AND slot=0 FOR UPDATE;
 IF reserved IS NOT NULL AND reserved<>u THEN RAISE EXCEPTION 'Room code is reserved';END IF;
 IF reserved IS NULL THEN
  SELECT count(*) INTO active FROM bu_private.room_members WHERE user_id=u AND slot=0 AND created_at>now()-interval '10 minutes';
  IF active>=20 THEN RAISE EXCEPTION 'Too many rooms. Please wait.';END IF;
  INSERT INTO bu_private.room_members(room_table,room_code,user_id,slot,joined) VALUES(TG_TABLE_NAME,NEW.room_code,u,0,true);
 ELSE
  UPDATE bu_private.room_members SET joined=true WHERE room_table=TG_TABLE_NAME AND room_code=NEW.room_code AND user_id=u;
 END IF;
 RETURN NEW;
END;$$;
REVOKE ALL ON FUNCTION bu_private.register_room() FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION bu_private.guard_room_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.room_code IS DISTINCT FROM OLD.room_code OR (to_jsonb(NEW)->'id') IS DISTINCT FROM (to_jsonb(OLD)->'id')
 THEN RAISE EXCEPTION 'Room identity cannot change';END IF;
 IF NEW.game_state IS NULL OR jsonb_typeof(NEW.game_state)<>'object' OR octet_length(NEW.game_state::text)>262144
 THEN RAISE EXCEPTION 'Invalid room state';END IF;
 RETURN NEW;
END;$$;
REVOKE ALL ON FUNCTION bu_private.guard_room_update() FROM PUBLIC,anon,authenticated;

DO $$DECLARE t text;p record;
BEGIN
 FOREACH t IN ARRAY ARRAY['basket_matches','parket_multiplayer_rooms','draft_multiplayer_rooms'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=t LOOP
   EXECUTE format('DROP POLICY %I ON public.%I',p.policyname,t);
  END LOOP;
  EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated',t);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE ON TABLE public.%I TO authenticated',t);
  EXECUTE format('CREATE POLICY bu_members_read ON public.%I FOR SELECT TO authenticated USING (public.bu_room_member_v1(%L,room_code))',t,t);
  EXECUTE format('CREATE POLICY bu_host_create ON public.%I FOR INSERT TO authenticated WITH CHECK (public.bu_room_member_v1(%L,room_code))',t,t);
  EXECUTE format('CREATE POLICY bu_members_update ON public.%I FOR UPDATE TO authenticated USING (public.bu_room_member_v1(%L,room_code)) WITH CHECK (public.bu_room_member_v1(%L,room_code))',t,t,t);
  EXECUTE format('DROP TRIGGER IF EXISTS bu_secure_create ON public.%I',t);
  EXECUTE format('CREATE TRIGGER bu_secure_create BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION bu_private.register_room()',t);
  EXECUTE format('DROP TRIGGER IF EXISTS bu_secure_identity ON public.%I',t);
  EXECUTE format('CREATE TRIGGER bu_secure_identity BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION bu_private.guard_room_update()',t);
 END LOOP;
END;$$;

CREATE OR REPLACE FUNCTION public.bu_room_join_v1(p_kind text,p_code text,p_nickname text,p_look jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();t text;r jsonb;st jsonb;m bu_private.room_members%ROWTYPE;
 n integer;capacity integer;name text:=coalesce(nullif(left(trim(p_nickname),16),''),'PLAYER');roster jsonb;
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED','message','Sign in before joining.');END IF;
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
REVOKE ALL ON FUNCTION public.bu_room_join_v1(text,text,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bu_room_join_v1(text,text,text,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.bu_quick_match_v1(p_mode text,p_nickname text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();me bu_private.quick_queue%ROWTYPE;other bu_private.quick_queue%ROWTYPE;
 code text;t text;initial jsonb;host_name text;
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED');END IF;
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

CREATE OR REPLACE FUNCTION public.bu_quick_status_v1(p_queue_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE q bu_private.quick_queue%ROWTYPE;
BEGIN
 SELECT * INTO q FROM bu_private.quick_queue WHERE id=p_queue_id AND user_id=auth.uid();
 IF NOT FOUND THEN RETURN jsonb_build_object('error','QUEUE_UNAVAILABLE');END IF;
 RETURN jsonb_build_object('status',q.status,'queue_id',q.id,'room_code',q.room_code,'slot',q.slot,'opponent',q.opponent);
END;$$;
CREATE OR REPLACE FUNCTION public.bu_quick_cancel_v1(p_queue_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 UPDATE bu_private.quick_queue SET status='cancelled' WHERE id=p_queue_id AND user_id=auth.uid() AND status='waiting';
 RETURN jsonb_build_object('ok',true);
END;$$;
REVOKE ALL ON FUNCTION public.bu_quick_match_v1(text,text),public.bu_quick_status_v1(uuid),public.bu_quick_cancel_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bu_quick_match_v1(text,text),public.bu_quick_status_v1(uuid),public.bu_quick_cancel_v1(uuid) TO authenticated;

-- Disable the old entry points: their SECURITY DEFINER bodies could bypass RLS.
DO $$DECLARE f record;
BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('basket_quick_match','basket_quick_status','basket_quick_cancel') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f.signature);
 END LOOP;
END;$$;

-- The old nickname-keyed leaderboard cannot prove ownership. Keep historical
-- scores readable; pause new writes instead of allowing changes to other players.
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON TABLE public.basket_leaderboard FROM PUBLIC,anon,authenticated;
DO $$DECLARE p record;t text;
BEGIN
 FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='basket_leaderboard' AND cmd IN ('INSERT','UPDATE','DELETE','ALL') LOOP
  EXECUTE format('DROP POLICY %I ON public.basket_leaderboard',p.policyname);
 END LOOP;
 FOREACH t IN ARRAY ARRAY['bu_players_overview','bu_activity_recent','bu_activity_daily'] LOOP
  IF to_regclass('public.'||t) IS NOT NULL THEN EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated',t);END IF;
 END LOOP;
END;$$;

CREATE OR REPLACE FUNCTION public.bu_online_security_version_v1()
RETURNS integer LANGUAGE sql STABLE SET search_path=pg_catalog AS $$SELECT 1;$$;
REVOKE ALL ON FUNCTION public.bu_online_security_version_v1() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bu_online_security_version_v1() TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
SELECT 'Room security v1 installed. Reload the game and create a NEW room.' AS result;
