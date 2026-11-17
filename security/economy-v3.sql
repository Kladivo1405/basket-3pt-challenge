-- Basketball Universe: bounded practice progression and account-owned cosmetics.
-- Requires room security v1. Client-reported game outcomes remain unverified.
BEGIN;
SELECT pg_advisory_xact_lock(738401211);
DO $$BEGIN IF public.bu_online_security_version_v1()<>1 THEN RAISE EXCEPTION 'Install room security v1 first';END IF;END;$$;

CREATE TABLE IF NOT EXISTS bu_private.progress_events_v3(
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,event_id uuid NOT NULL,
 kind text NOT NULL,mode text NOT NULL,xp integer NOT NULL,coins integer NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(user_id,event_id)
);
CREATE INDEX IF NOT EXISTS bu_progress_quota_v3 ON bu_private.progress_events_v3(user_id,created_at);
ALTER TABLE bu_private.progress_events_v3 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bu_private.progress_events_v3 FROM PUBLIC,anon,authenticated;
REVOKE ALL ON SCHEMA bu_private FROM PUBLIC,anon,authenticated;
-- Keep the original cosmetics privately recoverable before normalizing old data.
CREATE TABLE IF NOT EXISTS bu_private.wardrobe_legacy_v3(
 user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 outfit jsonb,owned jsonb,snapshot_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE bu_private.wardrobe_legacy_v3 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bu_private.wardrobe_legacy_v3 FROM PUBLIC,anon,authenticated;
INSERT INTO bu_private.wardrobe_legacy_v3(user_id,outfit,owned)
SELECT user_id,outfit,owned FROM public.bu_wardrobe ON CONFLICT(user_id) DO NOTHING;

CREATE OR REPLACE FUNCTION bu_private.outfit_v3(o jsonb,owned jsonb,strict boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result jsonb:='{"skin":"#c98d62","hair":"short","hairColor":"#15110e","jersey":"c:#f28c28","number":"23","shoes":"white","acc":"none"}';
 field text;value text;item text;valid boolean;
BEGIN
 IF jsonb_typeof(o) IS DISTINCT FROM 'object' OR octet_length(o::text)>1024
  OR o-ARRAY['skin','hair','hairColor','jersey','number','shoes','acc']<>'{}'::jsonb
 THEN IF strict THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid outfit';ELSE RETURN result;END IF;END IF;
 FOREACH field IN ARRAY ARRAY['skin','hair','hairColor','jersey','number','shoes','acc'] LOOP
  IF NOT o?field THEN CONTINUE;END IF;
  value:=o->>field;valid:=jsonb_typeof(o->field)='string';
  IF field='skin' THEN valid:=valid AND value IN ('#f5d0b0','#e8b98d','#c98d62','#a3683f','#7a4a32','#5a3524');
  ELSIF field='hairColor' THEN valid:=valid AND value IN ('#15110e','#3b2416','#8b5a2b','#d9b45b','#c2301f','#e8e8ee','#2f6fe0');
  ELSIF field='number' THEN valid:=valid AND value ~ '^[0-9]{1,2}$';
  ELSE
   item:=CASE field WHEN 'jersey' THEN 'j:' WHEN 'hair' THEN 'h:' WHEN 'shoes' THEN 's:' ELSE 'a:' END||value;
   valid:=valid AND (
    (field='jersey' AND value IN ('c:#f28c28','c:#e03a3e','c:#2f6fe0','c:#2a9d5c','c:#7b3fc4','c:#f2f2f2','c:#111111')) OR
    (field='hair' AND value IN ('short','buzz','bald')) OR
    (field='shoes' AND value IN ('white','black')) OR
    (field='acc' AND value='none') OR
    (coalesce(owned,'[]'::jsonb)?item AND (item='j:c:#f2c230' OR EXISTS(SELECT 1 FROM public.bu_shop_items s WHERE s.id=item AND s.price>=0)))
   );
  END IF;
  IF coalesce(valid,false) THEN result:=result||jsonb_build_object(field,value);
  ELSIF strict THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Select a valid item you own';END IF;
 END LOOP;
 RETURN result;
END;$$;
REVOKE ALL ON FUNCTION bu_private.outfit_v3(jsonb,jsonb,boolean) FROM PUBLIC,anon,authenticated;

-- Preserve already-worn legacy Champion Gold; future grants are server-managed.
UPDATE public.bu_wardrobe SET owned=coalesce(owned,'[]'::jsonb)||'"j:c:#f2c230"'::jsonb
WHERE outfit->>'jersey'='c:#f2c230' AND NOT coalesce(owned,'[]'::jsonb)?'j:c:#f2c230';
-- Invalid/unowned legacy cosmetics become defaults; purchased ownership is retained.
UPDATE public.bu_wardrobe SET outfit=bu_private.outfit_v3(outfit,owned,false)
WHERE outfit IS DISTINCT FROM bu_private.outfit_v3(outfit,owned,false);

CREATE OR REPLACE FUNCTION public.bu_wardrobe_get()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.bu_wardrobe;
BEGIN
 IF auth.uid() IS NULL THEN RETURN NULL;END IF;
 INSERT INTO public.bu_wardrobe(user_id) VALUES(auth.uid()) ON CONFLICT(user_id) DO NOTHING;
 UPDATE public.bu_wardrobe SET friend_code=coalesce(friend_code,upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))) WHERE user_id=auth.uid() AND friend_code IS NULL;
 SELECT * INTO r FROM public.bu_wardrobe WHERE user_id=auth.uid();
 RETURN jsonb_build_object('coins',r.coins,'owned',r.owned,'outfit',bu_private.outfit_v3(r.outfit,r.owned,false),'daily_last',r.daily_last,'daily_streak',r.daily_streak,'friend_code',r.friend_code);
END;$$;

CREATE OR REPLACE FUNCTION public.bu_wardrobe_set_outfit(p_outfit jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.bu_wardrobe;safe jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first';END IF;
 IF NOT bu_private.consume('outfit',120,60) THEN RAISE EXCEPTION 'Please wait before changing your outfit again';END IF;
 INSERT INTO public.bu_wardrobe(user_id) VALUES(auth.uid()) ON CONFLICT(user_id) DO NOTHING;
 SELECT * INTO r FROM public.bu_wardrobe WHERE user_id=auth.uid() FOR UPDATE;
 safe:=bu_private.outfit_v3(p_outfit,r.owned,true);
 UPDATE public.bu_wardrobe SET outfit=safe,updated_at=clock_timestamp() WHERE user_id=auth.uid();
END;$$;

CREATE OR REPLACE FUNCTION public.bu_wardrobe_buy(p_item text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.bu_wardrobe;price integer;
BEGIN
 IF auth.uid() IS NULL THEN RETURN NULL;END IF;
 IF NOT bu_private.consume('shop_buy',30,60) THEN RETURN jsonb_build_object('ok',false,'reason','Please wait before trying again');END IF;
 IF p_item IS NULL OR length(p_item)>100 THEN RETURN jsonb_build_object('ok',false,'reason','Unknown item');END IF;
 INSERT INTO public.bu_wardrobe(user_id) VALUES(auth.uid()) ON CONFLICT(user_id) DO NOTHING;
 SELECT * INTO r FROM public.bu_wardrobe WHERE user_id=auth.uid() FOR UPDATE;
 SELECT s.price INTO price FROM public.bu_shop_items s WHERE s.id=p_item;
 IF price IS NULL OR price<0 OR price>1000000 THEN RETURN jsonb_build_object('ok',false,'reason','Unknown item');END IF;
 IF r.owned?p_item THEN RETURN jsonb_build_object('ok',true,'coins',r.coins,'owned',r.owned);END IF;
 IF r.coins<price THEN RETURN jsonb_build_object('ok',false,'reason','Not enough coins','coins',r.coins);END IF;
 UPDATE public.bu_wardrobe SET coins=coins-price,owned=coalesce(owned,'[]'::jsonb)||to_jsonb(p_item),updated_at=clock_timestamp() WHERE user_id=auth.uid() RETURNING * INTO r;
 RETURN jsonb_build_object('ok',true,'coins',r.coins,'owned',r.owned);
END;$$;

CREATE OR REPLACE FUNCTION public.bu_wardrobe_daily()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.bu_wardrobe;s integer;rw integer;today date:=(clock_timestamp() AT TIME ZONE 'UTC')::date;
BEGIN
 IF auth.uid() IS NULL THEN RETURN NULL;END IF;
 INSERT INTO public.bu_wardrobe(user_id) VALUES(auth.uid()) ON CONFLICT(user_id) DO NOTHING;
 SELECT * INTO r FROM public.bu_wardrobe WHERE user_id=auth.uid() FOR UPDATE;
 IF r.daily_last=today THEN RETURN jsonb_build_object('claimed',true,'coins',r.coins,'streak',r.daily_streak);END IF;
 s:=CASE WHEN r.daily_last=today-1 THEN least(9998,greatest(0,coalesce(r.daily_streak,0)))+1 ELSE 1 END;
 rw:=least(20+least(s,7)*10+CASE WHEN s%7=0 THEN 60 ELSE 0 END,greatest(0,2147483647::bigint-r.coins))::integer;
 UPDATE public.bu_wardrobe SET coins=coins+rw,daily_last=today,daily_streak=s,updated_at=clock_timestamp() WHERE user_id=auth.uid() RETURNING * INTO r;
 INSERT INTO public.bu_coin_log(user_id,amount,reason) VALUES(auth.uid(),rw,'daily:v3');
 RETURN jsonb_build_object('claimed',false,'reward',rw,'coins',r.coins,'streak',s);
END;$$;

-- Own profiles may be created with zero XP and edited only in cosmetic columns.
DO $$DECLARE t text;p record;c record;
BEGIN
 FOREACH t IN ARRAY ARRAY['bu_profiles','bu_game_stats','bu_match_history','bu_wardrobe','bu_coin_log','bu_friends'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=t LOOP EXECUTE format('DROP POLICY %I ON public.%I',p.policyname,t);END LOOP;
  EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated',t);
  -- Also remove any column-level grants left by older migrations.
  FOR c IN SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name=t LOOP
   EXECUTE format('REVOKE ALL (%I) ON TABLE public.%I FROM PUBLIC,anon,authenticated',c.column_name,t);
  END LOOP;
  IF t<>'bu_coin_log' THEN
   EXECUTE format('GRANT SELECT ON public.%I TO authenticated',t);
   EXECUTE format('CREATE POLICY bu_own_read_v3 ON public.%I FOR SELECT TO authenticated USING(user_id=auth.uid())',t);
  END IF;
 END LOOP;
END;$$;
GRANT INSERT ON public.bu_profiles TO authenticated;
GRANT UPDATE(nickname,avatar) ON public.bu_profiles TO authenticated;
CREATE POLICY bu_profile_create_v3 ON public.bu_profiles FOR INSERT TO authenticated WITH CHECK(user_id=auth.uid() AND xp=0);
CREATE POLICY bu_profile_edit_v3 ON public.bu_profiles FOR UPDATE TO authenticated USING(user_id=auth.uid()) WITH CHECK(user_id=auth.uid());
CREATE OR REPLACE FUNCTION bu_private.profile_cosmetics_v3()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF auth.uid() IS NOT NULL AND NOT bu_private.consume('profile_edit',30,60) THEN RAISE EXCEPTION 'Please wait before editing your profile again';END IF;
 NEW.nickname:=coalesce(nullif(left(trim(regexp_replace(coalesce(NEW.nickname,''),'[[:cntrl:]]','','g')),16),''),'Rookie');
 IF NEW.avatar IS NULL OR NEW.avatar NOT IN ('🏀','🐐','🔥','⚡','🦁','🐺','🦅','👑','🤖','🐍','🦈','💎') THEN NEW.avatar:='🏀';END IF;
 NEW.updated_at:=clock_timestamp();RETURN NEW;
END;$$;
REVOKE ALL ON FUNCTION bu_private.profile_cosmetics_v3() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS bu_profile_cosmetics_v3 ON public.bu_profiles;
CREATE TRIGGER bu_profile_cosmetics_v3 BEFORE INSERT OR UPDATE OF nickname,avatar ON public.bu_profiles FOR EACH ROW EXECUTE FUNCTION bu_private.profile_cosmetics_v3();
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.bu_shop_items FROM PUBLIC,anon,authenticated;
-- Retire the redundant unrestricted visit writer; protected activity logging stays.
REVOKE ALL ON public.basketball_universe_visits FROM PUBLIC,anon,authenticated;
DO $$DECLARE p record;BEGIN
 FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='basketball_universe_visits' LOOP
  EXECUTE format('DROP POLICY %I ON public.basketball_universe_visits',p.policyname);
 END LOOP;
END;$$;

CREATE OR REPLACE FUNCTION public.bu_progress_claim_v3(p_event_id uuid,p_kind text,p_mode text,p_won boolean DEFAULT false,p_xp integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();p public.bu_profiles;w public.bu_wardrobe;give_xp integer;give_coins integer;used_xp bigint;used_coins bigint;requested_xp integer;requested_coins integer;
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED');END IF;
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

CREATE OR REPLACE FUNCTION public.bu_friend_add_v3(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();friend uuid;name text;matches integer;query text:=trim(p_code);
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','Sign in first');END IF;
 IF query IS NULL OR length(query)<1 OR length(query)>24 THEN RETURN jsonb_build_object('ok',false,'reason','Invalid code');END IF;
 IF NOT bu_private.consume('add_friend',20,60) THEN RETURN jsonb_build_object('ok',false,'reason','Please wait before trying again');END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(u::text||':friends',7386));
 SELECT count(*) INTO matches FROM public.bu_wardrobe WHERE upper(friend_code)=upper(query);
 IF matches=1 THEN SELECT w.user_id INTO friend FROM public.bu_wardrobe w WHERE upper(w.friend_code)=upper(query);
 ELSIF matches>1 THEN RETURN jsonb_build_object('ok',false,'reason','Use the unique friend code');
 ELSE
  SELECT count(*) INTO matches FROM public.bu_profiles WHERE lower(nickname)=lower(query);
  IF matches=1 THEN SELECT p.user_id INTO friend FROM public.bu_profiles p WHERE lower(p.nickname)=lower(query);END IF;
 END IF;
 IF friend IS NULL THEN RETURN jsonb_build_object('ok',false,'reason',CASE WHEN matches>1 THEN 'Use the unique friend code' ELSE 'Code not found' END);END IF;
 IF friend=u THEN RETURN jsonb_build_object('ok',false,'reason','You cannot add yourself');END IF;
 IF (SELECT count(*) FROM public.bu_friends WHERE user_id=u)>=200 THEN RETURN jsonb_build_object('ok',false,'reason','Friend limit reached');END IF;
 INSERT INTO public.bu_friends(user_id,friend_id) VALUES(u,friend) ON CONFLICT DO NOTHING;
 SELECT nickname INTO name FROM public.bu_profiles WHERE user_id=friend;
 RETURN jsonb_build_object('ok',true,'nickname',coalesce(name,'PLAYER'));
END;$$;

-- Existing friend reads already bind to auth.uid(); pin their namespace too.
ALTER FUNCTION public.bu_friends_list() SET search_path=pg_catalog;
CREATE OR REPLACE FUNCTION public.bu_log_event(p_event text,p_mode text DEFAULT NULL,p_owner boolean DEFAULT false,p_guest boolean DEFAULT NULL,p_provider text DEFAULT NULL,p_device text DEFAULT NULL,p_referrer text DEFAULT NULL,p_meta jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE recent integer;
BEGIN
 IF auth.uid() IS NULL OR p_event IS NULL OR p_event NOT IN ('visit','guest_start','login','register','open_mode','match','solo_run') THEN RETURN;END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':activity',7387));
 SELECT count(*) INTO recent FROM public.bu_activity WHERE user_id=auth.uid() AND created_at>clock_timestamp()-interval '1 hour';
 IF recent>=120 THEN RETURN;END IF;
 INSERT INTO public.bu_activity(user_id,event,mode,is_guest,provider,is_owner,device,referrer,meta)
 VALUES(auth.uid(),p_event,left(p_mode,30),p_guest,left(p_provider,20),coalesce(p_owner,false),left(p_device,10),left(p_referrer,120),CASE WHEN octet_length(coalesce(p_meta,'{}'::jsonb)::text)<=400 AND jsonb_typeof(p_meta)='object' THEN p_meta ELSE '{}'::jsonb END);
END;$$;

DO $$DECLARE f record;
BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature,p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND (p.proname LIKE 'bu_wardrobe_%' OR p.proname IN ('bu_add_friend','bu_friend_add_v3','bu_friends_list','bu_log_event','bu_progress_claim_v3')) LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f.signature);
 END LOOP;
END;$$;
GRANT EXECUTE ON FUNCTION public.bu_wardrobe_get(),public.bu_wardrobe_buy(text),public.bu_wardrobe_daily(),public.bu_wardrobe_set_outfit(jsonb),public.bu_friends_list(),public.bu_friend_add_v3(text),public.bu_progress_claim_v3(uuid,text,text,boolean,integer),public.bu_log_event(text,text,boolean,boolean,text,text,text,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
SELECT 'Economy security v3 installed. Refresh the game.' AS result;
