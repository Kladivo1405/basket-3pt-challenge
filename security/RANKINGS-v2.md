# Per-game rankings and precise 3PT timing — v0.92.0

The 60-second 3PT game previously discarded milliseconds, counted the final shot
animation against the displayed time, and chose multiplayer winners by points.
It now ranks made baskets descending, then elapsed milliseconds ascending. For
example, 25 makes at 41.998s beats 25 at 42.123s. Exact ties share a rank. Time is
measured with a monotonic clock from first release to last release; a timeout
uses 60.000s. A shot released at or after the deadline is rejected, even if the
display timer has not ticked yet. Manual exits do not submit leaderboard runs.

## Boards

| Board | Ordering | Separate categories |
| --- | --- | --- |
| 3PT 60 seconds | Makes, faster time | Shared solo / multiplayer human runs |
| 3PT Classic | Points, makes | Standard, UTC daily challenge, each special challenge |
| Free Throw | Longest streak | Solo |
| Draft | Season wins, fewer losses | Solo, UTC daily draft; completed 82-game seasons |
| Parket | Match wins, fewer losses | Online, CPU Easy / Medium / Hard |
| Blockout | Match wins, fewer losses | Online, CPU Easy / Medium / Hard |
| Dunk Contest | Score, perfect cues | Every difficulty × every trick |

New match IDs distinguish legitimate rematches with identical scores from replayed
completion notifications. Account-bound server event IDs and local event IDs
prevent duplicate match totals. Best-only boards retain the better result.
Existing legacy tables and their records are not deleted or automatically trusted
as new submissions. New records begin on the new boards. Device bests remain
available when online ranking is unavailable.

## Additional security changes

The wardrobe no longer falls through to a local success when a cloud purchase,
daily reward or coin award fails. Purchases are disabled while pending; failure
messages are displayed, and only confirmed purchases unlock items in cloud mode.
This client fix does not establish that the underlying economy RPCs are secure.

Rankings live in the non-exposed `bu_private` schema. API clients cannot write or
read those tables directly. Server functions bind writes to `auth.uid()`, validate
board/variant/result bounds, enforce quotas and replay protection, and expose
only display names, rank and canonical results on public reads. Timed submissions
require a user-owned single-use ticket; shot count/makes/points are recomputed
from a boolean result array and elapsed time is checked against the ticket with
network tolerance. This is not authoritative shot validation: a malicious client
can still fabricate a plausible game. The UI explicitly calls these practice
leaderboards. Competitive prizes, payments and verified anti-cheat remain out of
scope until authoritative server gameplay/reward checks are implemented.

## Deployment

1. Merge the pull request containing `index.html` AND `rankings-v0920.js`. The new
   asset is versioned and pinned by SHA-384 integrity; do not upload only index.
2. Run `security/per-game-rankings-v2.sql` in Supabase SQL Editor. It requires the
   previously installed room-security v1, runs transactionally and is repeatable.
   Until it is installed, the game remains playable and new records stay local.
3. Refresh both clients. Play a new timed run and check its makes and precise time
   in the 3PT leaderboard, including a tied-makes multiplayer result.
4. For the remaining security audit, run `security/security-followup-audit.sql`
   and export its result as CSV. It reads definitions/permissions for wardrobe,
   friends and activity RPCs, not account passwords or player rows. Those function
   bodies have not yet been supplied and cannot be certified from the client.
   The earlier room-security verification result is also still outstanding.

## Validation

- Actual SQL installed twice in PGlite PostgreSQL with eight accounts: made-shot
  ordering, millisecond ties/shared ranks, retained personal bests, replay and
  foreign-ticket rejection, malformed results/score/timing rejection, all seven
  boards, separated variants, 82-game seasons and cumulative wins/losses.
- Real browser-module handlers under jsdom: leaderboard filters and XSS payloads,
  all 25 shots with delayed final animation, exact deadline rejection, timeout,
  quit exclusion, duplicate match notifications and successful/failed cloud shop
  flows. Full page boots with the versioned JS asset served by a local resource
  loader and offline Auth stub.
- Existing Parket/3PT XSS and control regressions; all 15 Dunk trick/difficulty
  combinations, input handlers, pause/exit, one XP callback and native Canvas
  renders; exact inline CSP hashes and both external dependency integrity hashes.

These are local tests, not a production Supabase or real Android-device test.
The web client cannot confirm Auth CAPTCHA/rate limits, backups/admin MFA, or the
body of existing XP/coin RPCs. Users can currently edit their own XP through the
old profile API; existing stats are player-reported and must not be treated as
verified competitive results. No claim of complete security is made.
