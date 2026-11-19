/* Basketball Universe · 3PT Contest Multiplayer: sequential individual 60-second runs */
(function() {
    const $ = id => document.getElementById(id);
    let room = null, slot = null, channel = null, queueId = null, active = false, lastState = null;
    const botNames = [ "ClutchKing14", "SplashMode", "Hammer23", "IceInMyVeins", "Buckets99", "DowntownAce", "RimReaper7" ];
    function nick() {
        return ($("nick1")?.value || "").trim().slice(0, 16) || "PLAYER";
    }
    function code() {
        return BUSecurity.roomCode();
    }
    let liveWrites = Promise.resolve(), watchPoll = null, watchGeneration = 0;
    function watchKey(st) {
        return "contest:" + room + ":" + st.turn;
    }
    function cleanupChannel() {
        watchGeneration++;
        clearInterval(watchPoll);
        watchPoll = null;
        if (channel && typeof sb !== "undefined" && sb) {
            try {
                sb.removeChannel(channel);
            } catch (_) {}
        }
        channel = null;
    }
    async function ensureAuth() {
        if (typeof sb === "undefined" || !sb) throw Error("Online services are unavailable.");
        const {data: data} = await sb.auth.getSession();
        if (!data?.session) {
            const {error: error} = await sb.auth.signInAnonymously();
            if (error) throw error;
        }
    }
    function modal() {
        let old = $("bu3ptMpLobby");
        if (old) old.remove();
        let e = document.createElement("div");
        e.id = "bu3ptMpLobby";
        e.className = "overlay";
        e.style.zIndex = "149";
        e.innerHTML = BUSecurity.html('<div class="modal" style="width:min(520px,96vw)"><div class="eyebrow">BASKETBALL UNIVERSE · ONLINE</div><h2>🏆 3PT MULTIPLAYER</h2><p>Each player takes 25 shots in 60 seconds. Player one goes first, then player two.</p><label class="field">YOUR NICKNAME</label><input id="bu3ptMpNick" maxlength="16" value="' + BUSecurity.esc(nick()) + '" placeholder="Your nickname"><button class="primary" id="bu3ptMpCreate" style="width:100%;margin-top:10px">CREATE ROOM</button><button class="primary" id="bu3ptMpQuick" style="width:100%;margin-top:8px">⚡ QUICK MATCH</button><div style="height:1px;background:#ffffff22;margin:16px 0"></div><label class="field">ROOM CODE</label><input id="bu3ptMpCode" maxlength="6" placeholder="ABC123" style="text-transform:uppercase"><button class="secondary" id="bu3ptMpJoin" style="width:100%;margin-top:8px">JOIN ROOM</button><p id="bu3ptMpMsg" style="min-height:20px;margin-bottom:0"></p><button class="secondary" id="bu3ptMpBack" style="width:100%;margin-top:8px">BACK</button></div>');
        document.body.append(e);
        $("bu3ptMpBack").onclick = () => {
            e.remove();
            $("threePtMenu").classList.remove("hidden");
        };
        $("bu3ptMpCreate").onclick = createRoom;
        $("bu3ptMpJoin").onclick = joinRoom;
        $("bu3ptMpQuick").onclick = quickMatch;
        const cpu = document.createElement("button");
        cpu.className = "secondary";
        cpu.textContent = "CPU PRACTICE";
        cpu.style.width = "100%";
        cpu.onclick = () => {
            room = null;
            slot = 0;
            startBot();
        };
        $("bu3ptMpQuick").after(cpu);
    }
    function msg(t) {
        if ($("bu3ptMpMsg")) $("bu3ptMpMsg").textContent = t;
    }
    async function createRoom() {
        try {
            await BUOnline.ensure(sb);
            await ensureAuth();
            msg("Creating room…");
            room = code();
            slot = 0;
            const st = {
                mode: "3ptcontest",
                phase: "waiting",
                names: [ $("bu3ptMpNick").value.trim() || nick(), "WAITING…" ],
                results: [ null, null ],
                turn: 0
            };
            const {error: error} = await sb.from("basket_matches").insert({
                room_code: room,
                player1_name: st.names[0],
                player2_name: null,
                status: "waiting",
                game_state: st
            });
            if (error) throw error;
            showWaiting(st);
        } catch (e) {
            msg("Error: " + e.message);
        }
    }
    async function joinRoom() {
        try {
            msg("Joining room…");
            const joined = await BUOnline.join(sb, "threeptcontest", $("bu3ptMpCode").value, $("bu3ptMpNick").value || nick());
            room = joined.row.room_code;
            slot = joined.slot;
            showWaiting(joined.row.game_state);
        } catch (e) {
            msg("Error: " + e.message);
        }
    }
    async function quickMatch() {
        const searchStarted = Date.now();
        try {
            await ensureAuth();
            msg("🔎 Searching for an opponent · up to 10 seconds…");
            const {data: data, error: error} = await BUOnline.quick(sb, "match", {
                p_mode: "threeptcontest",
                p_nickname: $("bu3ptMpNick").value.trim() || nick()
            });
            if (error) throw error;
            queueId = data.queue_id;
            if (data.status === "matched") {
                room = data.room_code;
                slot = data.slot;
                await attachRoom();
                return;
            }
            while (Date.now() - searchStarted < 1e4) {
                await new Promise(r => setTimeout(r, 500));
                const {data: s, error: se} = await BUOnline.quick(sb, "status", {
                    p_queue_id: queueId
                });
                if (se) throw se;
                if (s.status === "matched") {
                    room = s.room_code;
                    slot = s.slot;
                    await attachRoom();
                    return;
                }
            }
            try {
                await BUOnline.quick(sb, "cancel", {
                    p_queue_id: queueId
                });
            } catch (_) {}
            queueId = null;
            msg("No online opponent found. You can try again or choose CPU practice.");
            room = null;
            slot = 0;
        } catch (e) {
            console.warn("3PT Quick Match -> bot:", e.message);
            try {
                if (queueId) await BUOnline.quick(sb, "cancel", {
                    p_queue_id: queueId
                });
            } catch (_) {}
            queueId = null;
            await new Promise(r => setTimeout(r, Math.max(0, 1e4 - (Date.now() - searchStarted))));
            msg("No online opponent found. You can try again or choose CPU practice.");
            room = null;
            slot = 0;
        }
    }
    async function attachRoom() {
        const {data: data, error: error} = await sb.from("basket_matches").select("*").eq("room_code", room).maybeSingle();
        if (error) throw error;
        if (!data) throw Error("Room is no longer available.");
        let st = data.game_state || {};
        if (slot === 0 && !st.names?.[1]) st.names[1] = data.player2_name || "PLAYER 2";
        showWaiting(st);
    }
    function showWaiting(st) {
        lastState = st;
        $("bu3ptMpLobby")?.remove();
        const old = $("bu3ptMpWait");
        if (old) old.remove();
        const e = document.createElement("div");
        e.id = "bu3ptMpWait";
        e.className = "overlay";
        e.style.zIndex = "149";
        e.innerHTML = BUSecurity.html('<div class="modal" style="width:min(500px,96vw);text-align:center"><div class="eyebrow">3PT MULTIPLAYER</div><h2>ROOM ' + (room || "QUICK MATCH") + '</h2><p id="bu3ptMpWaitText">' + (st.phase === "waiting" ? "Waiting for the other player…" : "Connected! Preparing the match…") + '</p><div style="font-size:22px;font-weight:900;margin:14px">' + (st.names || []).map(BUSecurity.esc).join("  VS  ") + '</div><p>Each player gets 60 seconds and 25 shots. You play one after the other.</p><button class="secondary" id="bu3ptMpCancel">CANCEL</button></div>');
        document.body.append(e);
        $("bu3ptMpCancel").onclick = () => {
            cleanupChannel();
            BUSpectator.close();
            room = null;
            e.remove();
            active = false;
            $("threePtMenu").classList.remove("hidden");
        };
        if (room) {
            cleanupChannel();
            channel = sb.channel("bu3pt-contest-" + room).on("postgres_changes", {
                event: "UPDATE",
                schema: "public",
                table: "basket_matches",
                filter: "room_code=eq." + room
            }, p => onUpdate(p.new?.game_state)).subscribe();
            const token = watchGeneration, code = room;
            watchPoll = setInterval(async () => {
                try {
                    const {data: data, error: error} = await sb.from("basket_matches").select("game_state").eq("room_code", code).single();
                    if (!error && token === watchGeneration && code === room) onUpdate(data.game_state);
                } catch (_) {}
            }, 1200);
            if (st.phase === "playing" && st.names?.[1]) onUpdate(st);
        }
    }
    function onUpdate(st) {
        if (!st || st.mode !== "3ptcontest") return;
        lastState = st;
        const wait = $("bu3ptMpWait");
        if (st.phase === "waiting") return;
        if (st.phase === "playing") {
            if (wait) $("bu3ptMpWaitText").textContent = st.turn === slot ? "Your turn! Choose a player." : "Opponent is taking their turn…";
            if (st.turn !== slot) {
                const live = st.live?.slot === st.turn ? st.live : null;
                BUSpectator.watch(watchKey(st), {
                    name: st.names?.[st.turn] || "Opponent",
                    ...live || {},
                    name: st.names?.[st.turn] || "Opponent"
                });
            } else if (!active && !st.results[slot]) {
                BUSpectator.finish("contest:" + room + ":" + (1 - slot), () => startOwnRun());
            }
            return;
        }
        if (st.phase === "complete") BUSpectator.finish("contest:" + room + ":" + (1 - slot), () => showFinal(st));
    }
    function publishProgress(live) {
        const code = room, mine = slot, token = watchGeneration;
        if (!code) return;
        liveWrites = liveWrites.then(async () => {
            if (token !== watchGeneration || code !== room) return;
            const {data: data, error: error} = await sb.from("basket_matches").select("game_state").eq("room_code", code).single();
            if (error) throw error;
            if (token !== watchGeneration || code !== room) return;
            const st = data.game_state;
            if (st.phase !== "playing" || st.turn !== mine || st.results?.[mine]) return;
            const next = {
                ...st,
                live: {
                    ...live,
                    slot: mine
                }
            };
            const result = await sb.from("basket_matches").update({
                game_state: next
            }).eq("room_code", code);
            if (result.error) throw result.error;
        }).catch(() => {
            const el = $("bu3ptCall");
            if (el) el.textContent = "Shot sharing interrupted · reconnecting…";
        });
    }
    function startOwnRun() {
        if (active || !window.BU3PTContest) return;
        BUSpectator.close();
        active = true;
        $("bu3ptMpWait")?.remove();
        window.BU3PTContest.start(p => window.BU3PTContest.begin(p, r => submitResult(r), publishProgress));
    }
    async function submitResult(r) {
        await liveWrites;
        const {data: data, error: error} = await sb.from("basket_matches").select("game_state").eq("room_code", room).single();
        if (error) {
            active = false;
            alert("Error reading result: " + error.message);
            return;
        }
        const st = data.game_state;
        if (st.results[slot]) {
            active = false;
            return;
        }
        st.results[slot] = r;
        if (slot === 0) {
            st.turn = 1;
            st.phase = "playing";
        } else {
            st.phase = "complete";
        }
        const {error: up} = await sb.from("basket_matches").update({
            game_state: st,
            status: st.phase === "complete" ? "finished" : "playing",
            player1_score: st.results[0]?.score || 0,
            player2_score: st.results[1]?.score || 0
        }).eq("room_code", room);
        active = false;
        if (up) {
            alert("Could not save the result: " + up.message);
            return;
        }
        if (st.phase === "complete") showFinal(st); else showWaiting(st);
    }
    function showFinal(st) {
        BUSpectator.close();
        cleanupChannel();
        $("bu3ptMpWait")?.remove();
        const a = st.results[0], b = st.results[1];
        if (!a || !b) return;
        const cmp = BURankings.compareTimed(a, b);
        try {
            if (window.BU && cmp !== 0) {
                const mine = slot == null ? 0 : slot;
                BU.report("threept", mine === 0 ? cmp < 0 : cmp > 0, "c3-" + (room || "bot") + "-" + a.made + "-" + b.made + "-" + BURankings.time(a) + "-" + BURankings.time(b));
            }
        } catch (_) {}
        const win = cmp === 0 ? "TIE GAME" : st.names[cmp < 0 ? 0 : 1] + " WINS!";
        $("bu3ptMpFinal")?.remove();
        const e = document.createElement("div");
        e.id = "bu3ptMpFinal";
        e.className = "overlay";
        e.style.zIndex = "153";
        e.innerHTML = BUSecurity.html('<div class="modal" style="width:min(540px,96vw);text-align:center"><div class="eyebrow">FINAL RESULTS</div><h2>' + BUSecurity.esc(win) + '</h2><div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:16px 0">' + [ a, b ].map((r, i) => '<div class="stat"><small>' + BUSecurity.esc(st.names[i]) + '</small><b style="font-size:32px">' + Number(r.made) + "/25</b><span>" + BURankings.seconds(BURankings.time(r)) + "</span><small>" + Number(r.score) + " PTS · " + BUSecurity.esc(r.player) + "</small></div>").join("") + '</div><p>Most makes wins. Equal makes: fastest time.</p><button class="secondary" id="bu3ptMpBoard" style="width:100%">LEADERBOARD</button><button class="primary" id="bu3ptMpAgain" style="width:100%;margin-top:12px">PLAY AGAIN</button><button class="secondary" id="bu3ptMpDone" style="width:100%;margin-top:8px">BACK TO 3PT MENU</button></div>');
        document.body.append(e);
        $("bu3ptMpBoard").onclick = () => BURankings.open("threept60");
        $("bu3ptMpDone").onclick = () => {
            e.remove();
            $("threePtMenu").classList.remove("hidden");
        };
        $("bu3ptMpAgain").onclick = () => {
            e.remove();
            room = null;
            slot = null;
            modal();
        };
    }
    function startBot() {
        BUSpectator.close();
        const st = {
            mode: "3ptcontest",
            phase: "playing",
            names: [ nick(), "CPU · " + botNames[Math.floor(Math.random() * botNames.length)] ],
            results: [ null, null ],
            turn: 0
        };
        showWaiting(st);
        setTimeout(() => {
            if (!active) {
                active = true;
                window.BU3PTContest.start(p => window.BU3PTContest.begin(p, r => {
                    const bm = Math.floor(11 + Math.random() * 10), bot = {
                        player: st.names[1],
                        score: bm + Math.floor(Math.random() * 4),
                        made: bm,
                        elapsedMs: Math.round(38e3 + Math.random() * 18e3),
                        remaining: 0,
                        results: [],
                        stations: []
                    };
                    st.results[0] = r;
                    st.results[1] = bot;
                    st.phase = "complete";
                    active = false;
                    showWaiting({
                        ...st,
                        phase: "playing",
                        turn: 1
                    });
                    setTimeout(() => showFinal(st), 2200 + Math.random() * 2200);
                }));
            }
        }, 500);
    }
    document.addEventListener("DOMContentLoaded", () => {
        const b = $("threePtContestMpBtn");
        if (b) b.onclick = () => {
            $("threePtMenu").classList.add("hidden");
            modal();
        };
    });
})();