# v0.96.0 — Watch opponents and tune Career

## Player-facing changes

Classic online 3PT now plays the opponent's actual shared shot events with the existing FTAnim court instead of a CSS ball dot. Timed 3PT multiplayer shares player selection, outfit and cumulative per-shot events during the 60-second run. Both players watch one another; ordered/deduplicated playback finishes before the next turn or final results. A placeholder appears until the opponent chooses a player; personal look is set before the first frame. Realtime has a 1.2-second room-read fallback. Fast releases are queued, so the court can trail the latest scoreboard; hiding the court skips its remaining playback when your turn is ready. The court can be hidden and resumed. This needs both clients refreshed; old timed clients only submit a final result and cannot provide live shot events.

Parket and authoritative online Blockout already render both participants' shot playback and retain that behaviour. Draft has no manual shooting mechanic: it now shows a clearly labelled SIMULATED QUARTER HIGHLIGHT when the opponent reports a quarter score, without inventing individual player inputs. A duplicate room update cannot replay the same quarter highlight. Career Online remains unavailable; this does not add its multiplayer backend.

Timed 3PT Quick Match no longer calls a bot a found online opponent. CPU practice is an explicit separate choice. It remains a practice run with its existing simulated CPU result.

Career uses the same shot renderer, now in a court/control layout closer to the main contest, with the same gradient release meter. RELEASE stays in the DOM with fixed size and label throughout connection, countdown, shot flight and readiness. Only its enabled state changes. 3PT/free-throw windows are tighter, the new meter is faster and Dunk cue timing is less forgiving. Early XP level costs and rewards are unchanged.

Solo seasons offer Easy / Medium / Hard before the first match; the choice locks for that season. Four rivals increase in CPU accuracy/attempt volume, and later seasons increase the challenge. Difficulty is frozen on each run. CPU attempt counts are bounded to fit the actual shot animation cadence: the hardest final rival has eight attempts, rather than an unreachable thirteen-shot target. Existing active runs and old cached clients retain their original meter rules; new clients request balance version 2 and use canonical timing metadata.

## Install

1. Merge all files in this PR, including the three new spectator/contest assets and Career asset.
2. Run the full security/career-balance-v2.sql in Supabase SQL Editor. Requires installed Career v5. Transactional and repeatable. No existing coins, owned players or attributes are reset.
3. Refresh the game on BOTH multiplayer devices and create a new room. Refresh Career before selecting a season difficulty. Until SQL is installed, the updated Career screen reports the missing balance update instead of playing with mismatched timing.

## Validation

Two jsdom peers with a shared room transport exercised real per-shot publishing, opponent playback, ordering, duplicate/stale-state suppression, both directions of turn handover and final-result deferral. Classic online shared events and labelled Draft highlights were tested. These are presentation/protocol checks; the room transport is simulated, not a live two-device Supabase test.

PGlite tests install the balance patch twice, verify new server receipt-time scoring and narrower windows, compare Easy/Medium/Hard CPU scores, enforce difficulty locking and preserve legacy-client timing. Career UI tests run against actual SQL with Skia-backed court/dunk rendering and verify an unchanged RELEASE button through countdown/flight, difficulty selection, a completed season match, saved paths, cosmetics and dunk outcomes. Existing ranking, wallet, HTML sanitization, CSP/SRI and page boot checks run as regressions.

Legacy 3PT/Parket/Draft states are still practice/client-reported data; watching a shot does not make those scores authoritative. Online Blockout remains the separately server-controlled mode. No room RLS is relaxed and spectator messages include no account IDs, emails or tokens. Real mobile rendering, network jitter, concurrent live Supabase sessions and load still need acceptance testing after deployment.

## Review tests

From tests/multiplayer-v0960 run npm install, then npm test. Tests use exact direct dependency versions; Career SQL tests start from the existing tests/career-v5 baseline fixture. No test clocks are included in the deployed migration.
