/* Presentation-only observer for legacy/practice rooms. Never submits scores or rewards. */
(() => {
    "use strict";
    const esc = x => BUSecurity.esc(x);
    let root = null, key = "", seen = new Set, pending = [], playing = false, closing = null, hidden = "", generation = 0, lastSnapshot = null, maxSeq = 0, runToken = "", resumeBtn = null, hiddenData = null;
    const draftSeen = new Set;
    function safeLook(value) {
        const o = value && typeof value === "object" ? value : {};
        const outfit = BUSecurity.outfit({
            skin: o.skin,
            hair: o.hair,
            hairColor: o.hairColor,
            jersey: "c:" + String(o.jersey || "#f28c28"),
            number: o.number,
            shoes: "white",
            acc: o.acc
        });
        return window.buLookOf ? buLookOf(outfit) : {
            jersey: "#f28c28",
            number: "23"
        };
    }
    function close() {
        generation++;
        if (resumeBtn) resumeBtn.remove();
        resumeBtn = null;
        hiddenData = null;
        if (root) {
            window.FTAnim?.destroy();
            root.remove();
        }
        root = null;
        key = "";
        seen.clear();
        pending = [];
        playing = false;
        closing = null;
        lastSnapshot = null;
        maxSeq = 0;
        runToken = "";
    }
    function mount(id, data) {
        if (key !== id) close();
        if (hidden === id) return false;
        key = id;
        if (!root) {
            root = document.createElement("div");
            root.id = "buSpectator";
            root.className = "overlay";
            root.style.zIndex = "152";
            root.innerHTML = BUSecurity.html('<section class="modal" style="width:min(900px,96vw);max-height:94vh;overflow:auto"><div class="eyebrow" id="buWatchLabel"></div><h2 id="buWatchName"></h2><div style="display:flex;justify-content:space-between;gap:12px"><b id="buWatchScore"></b><span id="buWatchClock"></span></div><div class="ftStage" id="buWatchCourt" style="margin:14px 0"><div class="ftCall"></div></div><p id="buWatchStatus" role="status"></p><button class="secondary" id="buWatchHide" style="width:100%">HIDE COURT</button></section>');
            document.body.append(root);
            document.getElementById("buWatchHide").onclick = () => {
                const callback = closing, snapshot = lastSnapshot;
                hidden = id;
                close();
                if (callback) {
                    callback();
                    return;
                }
                hiddenData = snapshot;
                resumeBtn = document.createElement("button");
                resumeBtn.textContent = "RESUME OPPONENT VIEW";
                resumeBtn.style.cssText = "position:fixed;right:16px;bottom:16px;z-index:154;padding:14px;background:#ffb665;color:#142032;border-radius:12px";
                resumeBtn.onclick = () => {
                    const data = hiddenData || snapshot;
                    hidden = "";
                    if (resumeBtn) resumeBtn.remove();
                    resumeBtn = null;
                    watch(id, data);
                };
                document.body.append(resumeBtn);
            };
            if (window.FTAnim && (data.look || data.shots?.length)) {
                FTAnim.mount(document.getElementById("buWatchCourt"), {
                    dist: 6.7,
                    look: safeLook(data.look)
                });
                FTAnim.setSpeed(1.8);
            } else {
                const placeholder = document.createElement("div");
                placeholder.className = "buWatchPlaceholder";
                placeholder.style.cssText = "min-height:180px;display:grid;place-items:center;color:#b7c8db";
                placeholder.textContent = "Waiting for the opponent to choose a player…";
                document.getElementById("buWatchCourt").append(placeholder);
            }
        }
        return true;
    }
    function draw() {
        if (!root || !lastSnapshot) return;
        const d = lastSnapshot;
        document.getElementById("buWatchLabel").textContent = d.simulated ? "SIMULATED QUARTER HIGHLIGHT" : "WATCHING OPPONENT";
        document.getElementById("buWatchName").textContent = String(d.name || "Opponent").slice(0, 80);
        document.getElementById("buWatchScore").textContent = d.simulated ? String(d.score || 0) + " POINTS THIS QUARTER" : String(d.score || 0) + " PTS · " + String(d.made || 0) + " MADE";
        document.getElementById("buWatchClock").textContent = Number.isFinite(d.remaining) ? Math.ceil(Math.max(0, d.remaining)) + " SEC" : "";
        document.getElementById("buWatchStatus").textContent = d.simulated ? "Simulated team highlight · quarter score reported by the draft engine." : pending.length || playing ? "Watch the shot. Your controls are locked while your opponent plays." : d.simulated ? "Quarter score reported by the draft simulation." : "Waiting for the next release…";
    }
    function next() {
        if (playing || !root) return;
        if (!pending.length) {
            draw();
            if (closing) {
                const cb = closing;
                close();
                cb();
            }
            return;
        }
        const event = pending.shift(), token = generation;
        playing = true;
        draw();
        if (window.FTAnim) {
            FTAnim.reset();
            FTAnim.setLook(safeLook(event.look || lastSnapshot.look));
            FTAnim.setSpot(Math.max(3, Math.min(8.5, Number(event.dist) || 7.24)));
        }
        let complete = false;
        const done = () => {
            if (complete || token !== generation) return;
            complete = true;
            clearTimeout(timer);
            playing = false;
            next();
        };
        const timer = setTimeout(done, 6e3);
        if (window.FTAnim) FTAnim.shoot({
            hit: !!event.hit,
            err: event.hit ? 0 : 2.5,
            streak: 0
        }, done); else done();
    }
    function watch(id, data) {
        if (!id || !data) return;
        if (hidden === id) {
            hiddenData = data;
            return;
        }
        if (!mount(id, data)) return;
        if (data.run && runToken && data.run !== runToken) {
            generation++;
            pending = [];
            seen.clear();
            maxSeq = 0;
            playing = false;
            window.FTAnim?.reset();
        }
        if (data.run) runToken = data.run;
        const host = document.getElementById("buWatchCourt");
        if (window.FTAnim && !host.querySelector("canvas") && (data.look || data.shots?.length)) {
            host.querySelector(".buWatchPlaceholder")?.remove();
            FTAnim.mount(host, {
                dist: 6.7,
                look: safeLook(data.look)
            });
            FTAnim.setSpeed(1.8);
        } else if (window.FTAnim && !playing && data.look) FTAnim.setLook(safeLook(data.look));
        lastSnapshot = data;
        const events = Array.isArray(data.shots) ? data.shots.slice(-25) : [];
        let fresh = events.filter(e => e && typeof e.hit === "boolean" && !seen.has(String(e.id)));
        if (!seen.size && fresh.length > 3) fresh = fresh.slice(-1);
        for (const e of events) if (e) seen.add(String(e.id));
        for (const e of fresh) {
            if (Number.isInteger(e.n) && e.n <= maxSeq) continue;
            if (Number.isInteger(e.n)) maxSeq = e.n;
            pending.push({
                ...e,
                look: data.look
            });
        }
        if (pending.length > 25) pending = pending.slice(-25);
        draw();
        next();
    }
    function finish(id, callback) {
        if (key !== id || hidden === id) {
            if (key === id || hidden === id) close();
            callback();
            return;
        }
        closing = callback;
        next();
    }
    function draft(room, state, slot) {
        const e = state?.lastQuarter;
        if (!e || e.slot === slot || !room) return;
        const id = "draft:" + room + ":" + e.id;
        if (hidden === id || draftSeen.has(id)) return;
        draftSeen.add(id);
        if (draftSeen.size > 200) draftSeen.delete(draftSeen.values().next().value);
        watch(id, {
            name: state.players?.[e.slot] || "Opponent",
            score: e.points,
            made: 1,
            simulated: true,
            look: e.look,
            shots: [ {
                id: e.id,
                hit: true,
                dist: 6.7
            } ]
        });
        finish(id, () => {});
    }
    Object.defineProperty(window, "BUSpectator", {
        value: Object.freeze({
            watch: watch,
            finish: finish,
            close: close,
            draft: draft
        })
    });
})();