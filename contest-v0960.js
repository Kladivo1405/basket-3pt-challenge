/* Basketball Universe · 3PT Solo Contest v1
   5 racks × 5 balls, 60-second clock, player-based timing window, FTAnim presentation. */
(function() {
    "use strict";
    const $ = id => document.getElementById(id);
    const spots = [ {
        name: "LEFT CORNER",
        dist: 6.7
    }, {
        name: "LEFT WING",
        dist: 7.05
    }, {
        name: "TOP OF THE KEY",
        dist: 7.24
    }, {
        name: "RIGHT WING",
        dist: 7.05
    }, {
        name: "RIGHT CORNER",
        dist: 6.7
    } ];
    let game = null, timer = null, raf = null, completeCallback = null, pickCallback = null, progressCallback = null;
    function emitProgress() {
        if (!game || !progressCallback) return;
        progressCallback({
            run: game.runId,
            name: game.player.name,
            look: window.buCurrentLook?.(),
            score: game.score,
            made: game.made,
            remaining: game.remaining,
            startedAt: game.deadline === null ? null : Date.now() - game.lastReleaseMs,
            shots: game.results.map((hit, i) => ({
                id: game.runId + ":" + (i + 1),
                n: i + 1,
                hit: hit,
                dist: spots[Math.min(4, Math.floor(i / 5))].dist
            }))
        });
    }
    function targetFor(p) {
        const pct = Number(p && p.pct) || 36;
        return Math.max(.05, Math.min(.12, .08 + (pct - 36) * .005));
    }
    function start(onPick) {
        pickCallback = typeof onPick === "function" ? onPick : null;
        const pool = typeof players !== "undefined" ? [ ...players ] : [];
        if (typeof jokePlayer !== "undefined") pool.push(jokePlayer);
        if (!pool.length) {
            alert("Player list is not available.");
            return;
        }
        const choices = [];
        while (choices.length < 3 && choices.length < pool.length) {
            const p = pool[Math.floor(Math.random() * pool.length)];
            if (!choices.some(x => x.name === p.name)) choices.push(p);
        }
        const old = $("bu3ptContestPick");
        if (old) old.remove();
        const el = document.createElement("div");
        el.id = "bu3ptContestPick";
        el.className = "overlay";
        el.style.zIndex = "150";
        el.innerHTML = BUSecurity.html('<div class="modal" style="width:min(560px,96vw);max-height:90vh;overflow:auto"><div class="eyebrow">BASKETBALL UNIVERSE · 3PT SOLO CONTEST</div><h2>CHOOSE YOUR SHOOTER</h2><p>Choose a player. His shooting ability sets the size of the target zone.</p><div id="bu3ptContestChoices" class="candidategrid"></div><button class="secondary" id="bu3ptContestCancel" style="width:100%;margin-top:12px">BACK</button></div>');
        document.body.append(el);
        const host = $("bu3ptContestChoices");
        choices.forEach(p => {
            const b = document.createElement("button");
            b.className = "candidate";
            b.innerHTML = BUSecurity.html("<strong>" + p.name + '</strong><span class="crestRow">' + (window.buTeamCrest ? buTeamCrest(p.team, false, "xs") : "") + p.team + " · " + p.pos + "</span><em>" + Number(p.pct).toFixed(1) + "% 3PT</em><span>Target zone: " + Math.round(targetFor(p) * 100) + "%</span>");
            b.onclick = () => {
                el.remove();
                if (pickCallback) {
                    const cb = pickCallback;
                    pickCallback = null;
                    cb(p);
                } else begin(p);
            };
            host.append(b);
        });
        $("bu3ptContestCancel").onclick = () => {
            el.remove();
            if (!pickCallback) $("threePtMenu").classList.remove("hidden");
        };
    }
    function begin(player, onComplete, onProgress) {
        cleanup();
        progressCallback = typeof onProgress === "function" ? onProgress : null;
        completeCallback = typeof onComplete === "function" ? onComplete : null;
        game = {
            runId: crypto.randomUUID(),
            player: player,
            station: 0,
            shot: 0,
            made: 0,
            score: 0,
            results: [],
            marker: 0,
            dir: 1,
            target: targetFor(player),
            busy: false,
            remaining: 60,
            deadline: null,
            lastReleaseMs: 0,
            ticket: null,
            ended: false
        };
        const old = $("bu3ptContest");
        if (old) old.remove();
        const el = document.createElement("div");
        el.id = "bu3ptContest";
        el.className = "overlay";
        el.style.zIndex = "151";
        el.innerHTML = BUSecurity.html(`<div class="modal testContest"><header class="testContestHead"><div><div class="eyebrow">BU · BASKETBALL UNIVERSE <span class="testDevice"></span></div><h2>3PT CONTEST</h2></div><div class="testClock"><small>TIME</small><b id="bu3ptClock">60</b></div></header>\n <div class="testContestGrid"><section class="testPlayArea"><div class="testPlayer"><div><b id="bu3ptPlayer"></b><div class="muted" id="bu3ptRating"></div></div><span class="livePill">● LIVE</span></div><div class="testSpot"><b id="bu3ptSpotName">LEFT CORNER</b><span id="bu3ptRackCount">BALL 1 / 5</span></div><div id="bu3ptCourt" class="ftStage"></div><div id="bu3ptRackDots" class="testRack"></div></section>\n <section class="testControlArea"><div class="testStats"><div class="stat"><small>SCORE</small><b id="bu3ptScore">0</b></div><div class="stat"><small>MADE</small><b id="bu3ptMade">0/25</b></div><div class="stat"><small>STATION</small><b id="bu3ptStation">1/5</b></div></div><div class="testRelease"><h3>FIND YOUR RHYTHM.</h3><p>Stop the marker inside the gold zone.<br>Every fifth ball scores double.</p><div class="ftMeterLabels"><span>EARLY</span><b id="bu3ptTargetLabel">TARGET 12%</b><span>LATE</span></div><div class="ftMeter"><div id="bu3ptTarget" class="ftTarget"></div><div id="bu3ptMarker" class="ftMarker"></div></div><div id="bu3ptCall" class="feedback">GET READY</div><button class="primary" id="bu3ptShoot">STOP & SHOOT</button><small class="testKeyboard">SPACE TO SHOOT · 25 BALLS · 60 SECONDS</small></div><div class="testCrowdHint">3 consecutive makes → MVP!<br>3 consecutive misses → BOOO!</div><div class="testActions"><button class="secondary" data-audio-toggle aria-pressed="true">SOUND ON</button><button class="secondary" id="testInGameAudio">AUDIO</button></div><button class="secondary" id="bu3ptExit">END RUN</button></section></div></div>`);
        document.body.append(el);
        $("bu3ptPlayer").textContent = player.name;
        $("bu3ptRating").textContent = player.team + " · " + player.pct + "% career 3PT";
        $("bu3ptTargetLabel").textContent = "TARGET " + Math.round(game.target * 100) + "%";
        const width = game.target * 100;
        $("bu3ptTarget").style.width = width + "%";
        $("bu3ptTarget").style.left = (100 - width) / 2 + "%";
        if (window.FTAnim) {
            FTAnim.setLook(window.buCurrentLook ? buCurrentLook() : null);
            FTAnim.setSpeed(1.8);
            FTAnim.mount($("bu3ptCourt"), {
                dist: spots[0].dist
            });
        }
        $("bu3ptShoot").onclick = shoot;
        $("testInGameAudio").onclick = () => window.BUTestUI.openAudio();
        window.BUTestAudioRefresh?.();
        $("bu3ptExit").onclick = () => finish(true);
        try {
            window.BUArena && BUArena.attach($("bu3ptCourt"), "3PT CONTEST");
        } catch (_) {}
        render();
        emitProgress();
        startMeter();
        $("bu3ptCall").textContent = "FIRST SHOT STARTS THE CLOCK";
        timer = setInterval(() => {
            if (!game || game.ended || game.deadline === null) return;
            game.remaining = Math.max(0, (game.deadline - performance.now()) / 1e3);
            $("bu3ptClock").textContent = Math.ceil(game.remaining);
            try {
                window.BUArena && BUArena.clock(game.remaining);
            } catch (_) {}
            if (game.remaining <= 0 && !game.busy) finish(false);
        }, 100);
    }
    function startMeter() {
        clearInterval(raf);
        if (!game || game.ended) return;
        game.marker = 0;
        game.dir = 1;
        game.busy = false;
        $("bu3ptShoot").disabled = false;
        $("bu3ptShoot").textContent = "STOP & SHOOT";
        raf = setInterval(() => {
            if (!game || game.ended || game.busy) return;
            game.marker += game.dir * 1.48;
            if (game.marker >= 100) {
                game.marker = 100;
                game.dir = -1;
            }
            if (game.marker <= 0) {
                game.marker = 0;
                game.dir = 1;
            }
            $("bu3ptMarker").style.left = game.marker + "%";
        }, 16);
    }
    function render() {
        if (!game) return;
        $("bu3ptScore").textContent = game.score;
        $("bu3ptMade").textContent = game.made + "/25";
        $("bu3ptStation").textContent = game.station + 1 + "/5";
        $("bu3ptSpotName").textContent = spots[game.station].name;
        $("bu3ptRackCount").textContent = "BALL " + (game.shot + 1) + " / 5";
        $("bu3ptRackDots").innerHTML = BUSecurity.html(Array.from({
            length: 5
        }, (_, i) => '<span style="width:16px;height:16px;border-radius:50%;display:inline-block;background:' + (game.results[game.station * 5 + i] === true ? "#42e695" : game.results[game.station * 5 + i] === false ? "#687487" : i === 4 ? "#e7b83e" : "#e77d32") + ';border:1px solid #ffffff55"></span>').join(""));
    }
    function shoot() {
        if (!game || game.ended || game.busy) return;
        const releaseAt = performance.now();
        if (game.deadline !== null && releaseAt >= game.deadline) {
            game.remaining = 0;
            finish(false);
            return;
        }
        if (game.deadline === null) {
            game.deadline = releaseAt + 6e4;
            game.ticket = BURankings.startTimed();
        }
        game.remaining = Math.max(0, (game.deadline - releaseAt) / 1e3);
        game.lastReleaseMs = Math.round(6e4 - game.remaining * 1e3);
        game.busy = true;
        clearInterval(raf);
        $("bu3ptShoot").disabled = true;
        const left = (100 - game.target * 100) / 2, right = left + game.target * 100, hit = game.marker >= left && game.marker <= right, err = (game.marker - 50) / Math.max(1, game.target * 50), money = game.shot === 4;
        game.results.push(hit);
        if (hit) {
            game.made++;
            game.score += money ? 2 : 1;
        }
        emitProgress();
        const shotNo = game.shot + 1, station = game.station;
        try {
            window.BUArena && BUArena.shot(hit, game.made, game.results.length - game.made, game.score);
        } catch (_) {}
        $("bu3ptCall").className = "feedback " + (hit ? "good" : "bad");
        $("bu3ptCall").textContent = hit ? money ? "MONEYBALL! +2" : "BUCKET! +1" : "NO GOOD";
        render();
        const next = () => {
            if (!game || game.ended) return;
            game.shot++;
            if (game.shot >= 5) {
                game.shot = 0;
                game.station++;
                if (game.station >= 5) {
                    finish(false);
                    return;
                }
                if (window.FTAnim) {
                    FTAnim.setSpot(spots[game.station].dist);
                    FTAnim.reset();
                }
                $("bu3ptCall").textContent = "NEXT STATION · " + spots[game.station].name;
            } else if (window.FTAnim) FTAnim.reset();
            if (game.remaining <= 0) {
                finish(false);
                return;
            }
            render();
            startMeter();
        };
        if (window.FTAnim) FTAnim.shoot({
            hit: hit,
            err: err,
            streak: game.made
        }, next); else setTimeout(next, 650);
    }
    function finish(quit) {
        if (!game || game.ended) return;
        game.ended = true;
        clearInterval(timer);
        clearInterval(raf);
        if (window.FTAnim) {
            FTAnim.destroy();
            FTAnim.setSpeed(1);
        }
        try {
            window.BUArena && BUArena.detach();
        } catch (_) {}
        const g = game;
        const elapsedMs = g.results.length === 25 ? g.lastReleaseMs : 6e4;
        const timedResult = {
            player: g.player.name,
            score: g.score,
            made: g.made,
            elapsedMs: elapsedMs,
            remaining: (6e4 - elapsedMs) / 1e3,
            results: g.results.slice(),
            stations: spots.map((sp, i) => g.results.slice(i * 5, i * 5 + 5).filter(Boolean).length)
        };
        if (!quit && g.deadline !== null) {
            BURankings.timed(timedResult, g.ticket).then(status => {
                const node = g.saveStatusNode;
                if (node?.isConnected) node.textContent = status.saved ? "Saved to the 3PT leaderboard." : status.message || "Saved on this device.";
            });
        }
        if (completeCallback) {
            const cb = completeCallback;
            completeCallback = null;
            const result = timedResult;
            game = null;
            {
                const ov = $("bu3ptContest");
                if (ov) ov.remove();
            }
            cb(result);
            return;
        }
        window.BU && BU.solo(Math.min(90, 10 + g.score * 2), "c3s-" + Date.now());
        const old = $("bu3ptContest");
        if (old) old.remove();
        const el = document.createElement("div");
        el.id = "bu3ptContestResult";
        el.className = "overlay";
        el.style.zIndex = "152";
        const rows = spots.map((s, i) => {
            const a = g.results.slice(i * 5, i * 5 + 5), m = a.filter(Boolean).length;
            return '<div style="display:flex;justify-content:space-between;padding:9px 12px;border-radius:9px;background:#ffffff0b;margin:5px 0"><span>' + s.name + "</span><b>" + m + "/5</b></div>";
        }).join("");
        el.innerHTML = BUSecurity.html('<div class="modal" style="width:min(520px,96vw);max-height:90vh;overflow:auto;text-align:center"><div class="eyebrow">' + (quit ? "CONTEST ENDED" : "FINAL SCORE") + "</div><h2>🏀 " + g.score + ' POINTS</h2><div style="font-size:42px;color:#ffd166;font-weight:1000">' + g.made + "/25</div><p>" + g.player.name + " · " + Math.round(g.target * 100) + "% target · " + BURankings.seconds(elapsedMs) + ' elapsed</p><p id="bu3ptSaveStatus">' + (quit ? "Unfinished run · not submitted." : "Saving result…") + '</p><button class="secondary" id="bu3ptResultBoard">LEADERBOARD</button><h3 style="text-align:left">STATION RESULTS</h3>' + rows + '<button class="primary" id="bu3ptAgain" style="width:100%;margin-top:12px">PLAY AGAIN</button><button class="secondary" id="bu3ptResultBack" style="width:100%;margin-top:8px">BACK TO 3PT MENU</button></div>');
        document.body.append(el);
        g.saveStatusNode = $("bu3ptSaveStatus");
        $("bu3ptResultBoard").onclick = () => BURankings.open("threept60");
        $("bu3ptAgain").onclick = () => {
            el.remove();
            start();
        };
        $("bu3ptResultBack").onclick = () => {
            el.remove();
            $("threePtMenu").classList.remove("hidden");
        };
        game = null;
    }
    function cleanup() {
        progressCallback = null;
        clearInterval(timer);
        clearInterval(raf);
        if (window.FTAnim) {
            FTAnim.destroy();
            FTAnim.setSpeed(1);
        }
        game = null;
        const a = $("bu3ptContest"), b = $("bu3ptContestResult"), c = $("bu3ptContestPick");
        [ a, b, c ].forEach(x => x && x.remove());
    }
    window.BU3PTContest = {
        start: start,
        begin: begin,
        cleanup: cleanup
    };
    document.addEventListener("DOMContentLoaded", () => {
        const btn = $("threePtContestBtn");
        if (btn) btn.addEventListener("click", () => {
            $("threePtMenu").classList.add("hidden");
            start();
        });
    });
})();