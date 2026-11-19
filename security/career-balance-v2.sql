-- Career balance v2. Existing in-flight/old-client runs keep their original timing.
BEGIN;
SELECT pg_advisory_xact_lock(738401217);
ALTER TABLE bu_private.career_runs_v5 ADD COLUMN IF NOT EXISTS difficulty text NOT NULL DEFAULT 'medium';
ALTER TABLE bu_private.career_runs_v5 ADD COLUMN IF NOT EXISTS rules_version integer NOT NULL DEFAULT 1;
CREATE OR REPLACE FUNCTION bu_private.cv5_bot(r bu_private.career_runs_v5,n bigint) RETURNS integer LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
DECLARE score integer:=0;i integer;rating integer;attempts integer;chance numeric;gap numeric;
BEGIN
 IF r.kind<>'match' THEN RETURN 0;END IF;
 IF r.rules_version=1 THEN rating:=18+r.rival*10+(r.season_no-1)*4;FOR i IN 0..7 LOOP IF n-r.started_ms>=3000+i*3300 AND mod(r.seed+i*37,100)<least(88,37+rating*.6) THEN score:=score+3;END IF;END LOOP;RETURN score;END IF;
 attempts:=8+r.rival+CASE r.difficulty WHEN 'easy' THEN -1 WHEN 'hard' THEN 2 ELSE 0 END;
 chance:=least(94,greatest(15,38+r.rival*12+(r.season_no-1)*4+CASE r.difficulty WHEN 'easy' THEN -14 WHEN 'hard' THEN 12 ELSE 0 END));
 gap:=27000.0/(attempts-1);
 FOR i IN 0..attempts-1 LOOP IF n-r.started_ms>=2000+i*gap AND mod(r.seed+i*37,100)<chance THEN score:=score+3;END IF;END LOOP;RETURN score;
END;$$;
CREATE OR REPLACE FUNCTION bu_private.cv5_view(u uuid,n bigint) RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog AS $$DECLARE r bu_private.career_runs_v5;s jsonb;rev integer;v jsonb;BEGIN
 SELECT * INTO r FROM bu_private.career_runs_v5 WHERE user_id=u ORDER BY sequence DESC LIMIT 1;
 IF FOUND AND NOT r.done THEN
  IF r.kind='match' AND n>=r.started_ms+30000 THEN PERFORM bu_private.cv5_finish(r.id,n);SELECT * INTO r FROM bu_private.career_runs_v5 WHERE id=r.id;
  ELSIF r.kind IN ('dunk','windmill') AND n>=r.origin_ms+2200+(CASE WHEN r.kind='windmill' THEN 7*620 ELSE 5*850 END)+500 THEN
   UPDATE bu_private.career_runs_v5 SET errors=errors+(CASE WHEN kind='windmill' THEN 8 ELSE 6 END)-cue_index,cue_index=CASE WHEN kind='windmill' THEN 8 ELSE 6 END WHERE id=r.id;PERFORM bu_private.cv5_finish(r.id,n);SELECT * INTO r FROM bu_private.career_runs_v5 WHERE id=r.id;
  ELSIF n-r.started_ms>120000 THEN UPDATE bu_private.career_runs_v5 SET done=true,abandoned=true WHERE id=r.id;SELECT * INTO r FROM bu_private.career_runs_v5 WHERE id=r.id;END IF;
 END IF;
 SELECT state,revision INTO s,rev FROM bu_private.career_v5 WHERE user_id=u;
 IF r.id IS NOT NULL THEN v:=jsonb_build_object('rules_version',r.rules_version,'difficulty',r.difficulty,'half_ms',CASE WHEN r.rules_version=2 THEN 1200 ELSE 1400 END,'target_width',least(70,CASE WHEN r.rules_version=2 THEN CASE WHEN r.kind='ft' THEN 18 ELSE 10 END ELSE CASE WHEN r.kind='ft' THEN 23 ELSE 13 END END+(r.stats->>CASE WHEN r.kind='ft' THEN 1 ELSE 0 END)::integer*CASE WHEN r.rules_version=2 THEN .32 ELSE .4 END),'dunk_window',CASE WHEN r.rules_version=2 THEN least(260,145+(r.stats->>2)::integer*1.05) ELSE least(300,165+(r.stats->>2)::integer*1.3) END,'id',r.id,'kind',r.kind,'player',r.player,'stats',r.stats,'start',r.started_ms,'origin',r.origin_ms,'next',r.next_ms,'shots',r.shots,'made',r.made,'perfect',r.perfect,'points',r.points,'errors',r.errors,'index',r.cue_index,'done',r.done,'abandoned',r.abandoned,'result',r.result,'bot',bu_private.cv5_bot(r,least(n,r.started_ms+30000)));END IF;
 RETURN jsonb_build_object('balance_version',2,'state',s,'revision',rev,'run',v,'server_ms',n);END;$$;
CREATE OR REPLACE FUNCTION public.bu_career_v5(p_request uuid,p_action text,p_payload jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u uuid:=auth.uid();n bigint:=bu_private.cv5_now();s jsonb;r bu_private.career_runs_v5;fp text;cached bu_private.career_requests_v5;resp jsonb;id text;pl jsonb;meta jsonb;i integer;val integer;cost integer;cap integer;lv integer;kind text;oldrev integer;v numeric;hit boolean;is_perfect boolean;window_ms integer;cues integer;gap integer;target bigint;mode text;task integer;stat text;goal integer;rx integer;rc integer;
BEGIN
 IF u IS NULL THEN RETURN jsonb_build_object('error','AUTH_REQUIRED');END IF;
 IF p_request IS NULL OR p_action IS NULL OR p_action NOT IN ('get','season_difficulty','specialize','upgrade','recruit','select','jersey','number','claim','new_season','start','release','dunk_hit','abandon') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR octet_length(p_payload::text)>1024 THEN RETURN jsonb_build_object('error','INVALID_REQUEST');END IF;
 IF NOT bu_private.consume('career_v5',180,60) THEN RETURN jsonb_build_object('error','RATE_LIMIT');END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(u::text||':career_v5',7384));
 fp:=md5(jsonb_build_array(p_action,p_payload)::text);SELECT * INTO cached FROM bu_private.career_requests_v5 WHERE user_id=u AND career_requests_v5.id=p_request;
 IF FOUND THEN IF cached.fingerprint<>fp THEN RETURN jsonb_build_object('error','REQUEST_REUSED');END IF;RETURN cached.response;END IF;
 INSERT INTO bu_private.career_v5(user_id,state) VALUES(u,'{"xp":0,"coins":180,"active":"rp","players":{"rp":{"stats":[12,12,12],"color":null,"num":12,"focus":null}},"totals":{"makes":0,"perfect":0,"drills":0,"dunks":0,"wins":0,"games":0},"daily":{},"weekly":{},"badges":{},"season":{"number":1,"games":[],"history":[]}}') ON CONFLICT DO NOTHING;
 SELECT state,revision INTO s,oldrev FROM bu_private.career_v5 WHERE user_id=u FOR UPDATE;s:=bu_private.cv5_periods(s);UPDATE bu_private.career_v5 SET state=s WHERE user_id=u;
 PERFORM bu_private.cv5_view(u,n);SELECT state INTO s FROM bu_private.career_v5 WHERE user_id=u;SELECT * INTO r FROM bu_private.career_runs_v5 WHERE user_id=u AND NOT done ORDER BY started_ms DESC LIMIT 1 FOR UPDATE;
 IF p_action NOT IN ('get','release','dunk_hit','abandon') AND r.id IS NOT NULL THEN RETURN jsonb_build_object('error','RUN_ACTIVE','message','Finish or leave your current Career session.');END IF;
 id:=s->>'active';pl:=s#>ARRAY['players',id];meta:=bu_private.cv5_roster(id);lv:=bu_private.cv5_level((s->>'xp')::integer);
 BEGIN
 IF p_action='season_difficulty' THEN
  mode:=p_payload->>'difficulty';IF mode IS NULL OR mode NOT IN ('easy','medium','hard') OR jsonb_array_length(s#>'{season,games}')<>0 THEN RETURN jsonb_build_object('error','DIFFICULTY_LOCKED','message','Choose Easy, Medium or Hard before the first season match.');END IF;
  s:=jsonb_set(s,'{season,difficulty}',to_jsonb(mode));
 ELSIF p_action IN ('specialize','upgrade') THEN
  i:=(p_payload->>'attribute')::integer;IF i IS NULL OR i NOT BETWEEN 0 AND 2 THEN RETURN jsonb_build_object('error','INVALID_ATTRIBUTE');END IF;
  IF p_action='specialize' THEN IF pl->>'focus' IS NOT NULL THEN RETURN jsonb_build_object('error','FOCUS_ALREADY_CHOSEN');END IF;pl:=jsonb_set(pl,'{focus}',to_jsonb(i));
  ELSE
   IF pl->>'focus' IS NULL THEN RETURN jsonb_build_object('error','CHOOSE_FOCUS_FIRST');END IF;
   val:=(pl#>>ARRAY['stats',i::text])::integer;cap:=least(99,(meta->>'cap')::integer+CASE WHEN (pl->>'focus')::integer=i THEN 10 ELSE 0 END);
   IF val>=cap THEN RETURN jsonb_build_object('error','AT_POTENTIAL');END IF;
   cost:=round((12+power(val-(meta->>'base')::integer,1.5)*3+(meta->>'base')::integer*.2)*CASE WHEN (pl->>'focus')::integer=i THEN .75 ELSE 1 END);
   IF (s->>'coins')::integer<cost THEN RETURN jsonb_build_object('error','NOT_ENOUGH_COINS');END IF;
   s:=jsonb_set(s,'{coins}',to_jsonb((s->>'coins')::integer-cost));pl:=jsonb_set(pl,ARRAY['stats',i::text],to_jsonb(val+1));
  END IF;s:=jsonb_set(s,ARRAY['players',id],pl);
 ELSIF p_action IN ('recruit','select') THEN
  id:=p_payload->>'player';meta:=bu_private.cv5_roster(id);IF meta IS NULL THEN RETURN jsonb_build_object('error','INVALID_PLAYER');END IF;
  IF NOT (s->'players')?id THEN
   IF p_action='select' OR lv<(meta->>'level')::integer THEN RETURN jsonb_build_object('error','PLAYER_LOCKED');END IF;
   cost:=(meta->>'price')::integer;IF (s->>'coins')::integer<cost THEN RETURN jsonb_build_object('error','NOT_ENOUGH_COINS');END IF;
   s:=jsonb_set(s,'{coins}',to_jsonb((s->>'coins')::integer-cost));s:=jsonb_set(s,ARRAY['players',id],jsonb_build_object('stats',jsonb_build_array((meta->>'base')::integer,(meta->>'base')::integer,(meta->>'base')::integer),'num',CASE id WHEN 'ld' THEN 77 WHEN 'sc' THEN 30 ELSE 34 END,'color',NULL,'focus',NULL));
  END IF;s:=jsonb_set(s,'{active}',to_jsonb(id));
 ELSIF p_action='number' THEN val:=(p_payload->>'number')::integer;IF val IS NULL OR val NOT BETWEEN 0 AND 99 THEN RETURN jsonb_build_object('error','INVALID_NUMBER');END IF;s:=jsonb_set(s,ARRAY['players',id,'num'],to_jsonb(val));
 ELSIF p_action='jersey' THEN
  i:=(p_payload->>'jersey')::integer;IF i IS NULL OR i NOT BETWEEN 0 AND 3 OR (i=1 AND (s#>>'{totals,makes}')::integer<1) OR (i=2 AND (s#>>'{totals,drills}')::integer<5) OR (i=3 AND coalesce(s#>>'{badges,champ}','false')<>'true') THEN RETURN jsonb_build_object('error','JERSEY_LOCKED');END IF;
  s:=jsonb_set(s,ARRAY['players',id,'color'],CASE i WHEN 0 THEN 'null'::jsonb WHEN 1 THEN '"#df6854"'::jsonb WHEN 2 THEN '"#70c6d1"'::jsonb ELSE '"#ad84cf"'::jsonb END);
 ELSIF p_action='claim' THEN
  mode:=p_payload->>'period';task:=(p_payload->>'task')::integer;IF mode IS NULL OR mode NOT IN ('daily','weekly') OR task IS NULL OR task NOT BETWEEN 0 AND 2 THEN RETURN jsonb_build_object('error','INVALID_CHALLENGE');END IF;
  IF (s#>ARRAY[mode,'claimed'])@>jsonb_build_array(task) THEN RETURN jsonb_build_object('error','ALREADY_CLAIMED');END IF;
  stat:=CASE WHEN mode='daily' THEN CASE task WHEN 0 THEN 'makes' WHEN 1 THEN 'drills' ELSE 'games' END ELSE CASE task WHEN 0 THEN 'makes' WHEN 1 THEN 'dunks' ELSE 'wins' END END;
  goal:=CASE WHEN mode='daily' THEN CASE task WHEN 0 THEN 5 WHEN 1 THEN 2 ELSE 1 END ELSE CASE task WHEN 0 THEN 35 WHEN 1 THEN 3 ELSE 3 END END;
  IF (s#>>ARRAY['totals',stat])::integer-(s#>>ARRAY[mode,'base',stat])::integer<goal THEN RETURN jsonb_build_object('error','CHALLENGE_INCOMPLETE');END IF;
  rx:=CASE WHEN mode='daily' THEN CASE task WHEN 0 THEN 35 WHEN 1 THEN 45 ELSE 50 END ELSE CASE task WHEN 0 THEN 120 WHEN 1 THEN 100 ELSE 150 END END;rc:=CASE WHEN mode='daily' THEN CASE task WHEN 0 THEN 45 WHEN 1 THEN 55 ELSE 60 END ELSE CASE task WHEN 0 THEN 180 WHEN 1 THEN 150 ELSE 220 END END;
  s:=jsonb_set(s,ARRAY[mode,'claimed'],(s#>ARRAY[mode,'claimed'])||jsonb_build_array(task));s:=jsonb_set(s,'{xp}',to_jsonb((s->>'xp')::integer+rx));s:=jsonb_set(s,'{coins}',to_jsonb((s->>'coins')::integer+rc));
 ELSIF p_action='new_season' THEN
  IF jsonb_array_length(s#>'{season,games}')<>4 THEN RETURN jsonb_build_object('error','SEASON_INCOMPLETE');END IF;
  SELECT count(*) INTO val FROM jsonb_array_elements(s#>'{season,games}') g WHERE g->>'won'='true';
  s:=jsonb_set(s,'{season,history}',(s#>'{season,history}')||jsonb_build_array(jsonb_build_object('number',(s#>>'{season,number}')::integer,'wins',val,'difficulty',coalesce(s#>>'{season,difficulty}','medium'))));s:=jsonb_set(s,'{season,number}',to_jsonb((s#>>'{season,number}')::integer+1));s:=jsonb_set(s,'{season,games}','[]');
 ELSIF p_action='start' THEN
  kind:=p_payload->>'kind';IF kind IS NULL OR kind NOT IN ('3pt','ft','dunk','windmill','match') THEN RETURN jsonb_build_object('error','INVALID_MODE');END IF;
  IF pl->>'focus' IS NULL THEN RETURN jsonb_build_object('error','CHOOSE_FOCUS_FIRST','message','Choose a development path in My Player first.');END IF;
  IF kind='windmill' AND (s#>>'{totals,dunks}')::integer<3 THEN RETURN jsonb_build_object('error','SIGNATURE_LOCKED');END IF;
  IF kind='match' AND jsonb_array_length(s#>'{season,games}')>=4 THEN RETURN jsonb_build_object('error','SEASON_COMPLETE');END IF;
  IF NOT bu_private.consume('career_start_v5',90,600) THEN RETURN jsonb_build_object('error','RATE_LIMIT');END IF;
  INSERT INTO bu_private.career_runs_v5(user_id,kind,player,stats,season_no,rival,seed,started_ms,origin_ms,next_ms,difficulty,rules_version) VALUES(u,kind,id,pl->'stats',(s#>>'{season,number}')::integer,jsonb_array_length(s#>'{season,games}'),floor(random()*100)::integer,n,n+1500,n+1500,coalesce(s#>>'{season,difficulty}','medium'),CASE WHEN p_payload->>'rules_version'='2' THEN 2 ELSE 1 END);
 ELSIF p_action IN ('release','dunk_hit','abandon') THEN
  IF r.id IS NULL OR r.id::text IS DISTINCT FROM p_payload->>'run' THEN RETURN jsonb_build_object('error','INVALID_RUN');END IF;
  IF p_action='abandon' THEN UPDATE bu_private.career_runs_v5 SET done=true,abandoned=true WHERE career_runs_v5.id=r.id;
  ELSIF p_action='release' THEN
   IF r.kind NOT IN ('3pt','ft','match') OR n<r.origin_ms OR n<r.next_ms THEN RETURN jsonb_build_object('error','NOT_READY');END IF;
   IF r.kind='match' AND n>=r.started_ms+30000 THEN RETURN jsonb_build_object('error','RUN_FINISHED');END IF;
   v:=mod(n-r.origin_ms,CASE WHEN r.rules_version=2 THEN 2400 ELSE 2800 END)::numeric/CASE WHEN r.rules_version=2 THEN 1200 ELSE 1400 END*100;IF v>100 THEN v:=200-v;END IF;
   window_ms:=CASE WHEN r.rules_version=2 THEN CASE WHEN r.kind='ft' THEN 18 ELSE 10 END ELSE CASE WHEN r.kind='ft' THEN 23 ELSE 13 END END;
   hit:=abs(v-50)<=(least(70,window_ms+(r.stats->>CASE WHEN r.kind='ft' THEN 1 ELSE 0 END)::integer*CASE WHEN r.rules_version=2 THEN .32 ELSE .4 END))/2;is_perfect:=hit AND abs(v-50)<=3;
   UPDATE bu_private.career_runs_v5 SET shots=shots+1,made=made+CASE WHEN hit THEN 1 ELSE 0 END,perfect=perfect+CASE WHEN is_perfect THEN 1 ELSE 0 END,points=points+CASE WHEN hit THEN CASE WHEN r.kind='ft' THEN 1 ELSE 3 END ELSE 0 END,next_ms=n+760,origin_ms=n+760 WHERE career_runs_v5.id=r.id;
   IF r.kind<>'match' AND r.shots+1=5 THEN PERFORM bu_private.cv5_finish(r.id,n);END IF;
  ELSE
   IF r.kind NOT IN ('dunk','windmill') OR n<r.origin_ms THEN RETURN jsonb_build_object('error','NOT_READY');END IF;
   cues:=CASE WHEN r.kind='windmill' THEN 8 ELSE 6 END;gap:=CASE WHEN r.kind='windmill' THEN 620 ELSE 850 END;window_ms:=CASE WHEN r.rules_version=2 THEN least(260,145+(r.stats->>2)::integer*1.05) ELSE least(300,165+(r.stats->>2)::integer*1.3) END;
   WHILE r.cue_index<cues AND n>r.origin_ms+2200+r.cue_index*gap+window_ms LOOP r.cue_index:=r.cue_index+1;r.errors:=r.errors+1;END LOOP;
   IF r.cue_index>=cues THEN UPDATE bu_private.career_runs_v5 SET errors=r.errors,cue_index=r.cue_index WHERE career_runs_v5.id=r.id;PERFORM bu_private.cv5_finish(r.id,n);
   ELSE target:=r.origin_ms+2200+r.cue_index*gap;hit:=abs(n-target)<=window_ms;is_perfect:=hit AND abs(n-target)<=65;
    UPDATE bu_private.career_runs_v5 SET errors=r.errors+CASE WHEN hit THEN 0 ELSE 1 END,cue_index=r.cue_index+CASE WHEN hit THEN 1 ELSE 0 END,made=made+CASE WHEN hit THEN 1 ELSE 0 END,shots=shots+1,perfect=perfect+CASE WHEN is_perfect THEN 1 ELSE 0 END WHERE career_runs_v5.id=r.id;
    IF hit AND r.cue_index+1=cues THEN PERFORM bu_private.cv5_finish(r.id,n);END IF;
   END IF;
  END IF;
 END IF;
 EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value THEN RETURN jsonb_build_object('error','INVALID_VALUE');END;
 IF p_action NOT IN ('release','dunk_hit','abandon','get') THEN UPDATE bu_private.career_v5 SET state=s,revision=revision+1,updated_at=clock_timestamp() WHERE user_id=u;END IF;
 resp:=bu_private.cv5_view(u,n);
 IF p_action<>'get' THEN INSERT INTO bu_private.career_requests_v5(user_id,id,fingerprint,response) VALUES(u,p_request,fp,resp);END IF;
 -- Keep retry receipts bounded; expired requests cannot replay an active session ID.
 DELETE FROM bu_private.career_runs_v5 WHERE user_id=u AND done AND started_ms<n-2592000000;
 DELETE FROM bu_private.career_requests_v5 WHERE user_id=u AND created_at<clock_timestamp()-interval '7 days';
 RETURN resp;
END;$$;
REVOKE ALL ON FUNCTION bu_private.cv5_bot(bu_private.career_runs_v5,bigint),bu_private.cv5_view(uuid,bigint) FROM PUBLIC,anon,authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
SELECT 'Career balance v2 installed. Refresh Career.' AS result;
