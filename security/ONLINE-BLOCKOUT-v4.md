# Online Blockout v0.94.0

Online Blockout now accepts player inputs, then computes turns, shot timing, scores, outcomes, rankings and rewards on the server. The defender cannot read the attacker's hoop until defence is committed. CPU Blockout and all other games remain practice modes.

## Install

1. Merge this PR. Keep both new JavaScript files beside index.html; keep existing assets and sounds.
2. In Supabase SQL Editor run the complete security/online-blockout-v4.sql. Requires the already-installed room v1, rankings v2 and economy v3 migrations. Installation is transactional and repeatable.
3. Run security/verify-blockout-v4.sql and security/verify-economy-v3.sql. The Blockout report's private/anonymous access fields should be false; account actions, board read and server clock true; restrictive policies 3. The economy report's unreviewed list should be empty.
4. Reload both clients and create a NEW online Blockout room. Old online Blockout sessions are retired. If SQL is missing, online Blockout reports an error; it does not silently use the old protocol.

## Behaviour

First to 5; players alternate attacks. Choose hoop, opponent commits defence, arm the meter, then release. Server receipt time decides the shot; the browser sends no hit, score or winning flag. Meter prediction uses measured network latency, which still needs real phone/web testing. Polling is every 900 ms; private rooms are not broadcast through Realtime.

Both participants receive canonical score-completion rewards once (winner 50 XP/25 coins, loser 20 XP/8 coins), subject to existing shared reward caps. Forfeit and inactivity grant no XP/coins. A fifth basket is settled before playback completes, so closing mid-animation does not erase it. Expiry is processed on the next authenticated read/action, not a background scheduled task. Rematches require both votes and receive a new game ID. Resume restores the authenticated player's last room.

Online rankings use private immutable outcomes; historical practice rankings remain separately labelled and are not imported. Public rankings reveal nicknames and results, not account IDs. Profiles/outfits come from canonical account data.

## Validation and limits

PGlite integration tests install twice, exercise actor/phase/input guards, hidden selection, server clock, request retries, scoring, one-time rewards, reserved receipts, rematches, matchmaking, expiry and retirement of old online APIs. Two jsdom clients exercise actual DOM controls and database RPCs, animation preservation, outfits and reconnect. Existing XSS/CSP/SRI, boot and Dunk regression checks also run.

These are local PostgreSQL-compatible and simulated browser checks, not live Supabase, multi-connection concurrency, Android or real-device latency certification. After installing, test phone versus browser: join, hidden choice, release, both personal outfits, uninterrupted flight, five-point result, rewards once, leave/timeout, resume and two-party rematch.

This phase prevents client-authoritative Blockout results. Legal-input automation, collusion, service abuse and other practice reward/result APIs remain outside its guarantee. Do not describe the whole game or its currency economy as cheatproof. Remaining gameplay families need their own authoritative migration before competitive publication.
