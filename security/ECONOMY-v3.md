# Bounded practice progression and wardrobe security — v0.93.0

The supplied production RPC definitions confirm that wardrobe access is already
bound to `auth.uid()`. Purchase and daily-claim functions already lock the wallet.
They do not show a way to edit someone else's balance through those functions.

Confirmed issues: the old award RPC accepts arbitrary client amounts (bounded to
60 per call), checks its rolling 500-coin limit before acquiring a wallet lock,
and allows parallel requests to race the quota. The outfit setter accepts any
small JSON without checking purchased ownership. Profiles/stats/history permit
direct client writes to the user's own XP and result counters. RPCs grant EXECUTE
to the unauthenticated `anon` role and use `search_path=public`. The source also
uses `bu_add_friend`, which the earlier narrow audit name filter missed.

## Changes

- Replace direct XP/stat/history updates with one transactional, user-bound
  practice receipt. Duplicate event IDs do not duplicate XP, coins or counters.
  Practice match rewards remain 50/20 XP and 25/8 coins. Solo XP is bounded to
  0–90 per event. Rolling hourly caps are 1,000 practice XP and 500 practice coins;
  daily rewards remain separate. Lock the profile/wallet before applying totals.
- Revoke the legacy arbitrary-amount coin RPC and old friend-add API. Keep
  authenticated guests supported; unauthenticated RPC access is removed.
- Profiles retain own reads, zero-XP creation and bounded cosmetic nickname/avatar edits. Profile timestamps are server-managed.
  Direct balance, XP, stat, history, friendship and log writes are revoked,
  including legacy column-level grants. No profiles or saved XP are deleted. Legacy hourly coin awards count toward the new rolling coin cap.
- Outfit saves validate allowed fields/colors and owned catalog items on the
  server. Confirmed purchases still use the live public shop catalog. The catalog
  was read with its published read-only API: 44 items, no player records.
- Invalid/unowned old outfit fields reset to defaults. Existing purchases remain
  owned. Already-worn Champion Gold is grandfathered; new reported draft wins
  grant its server-side entitlement. This is still based on a practice result.
- Daily rewards keep row locking and use UTC dates consistently in client/server.
  Purchases remain idempotent, reject invalid prices and protect the balance.
- Pin reviewed RPC namespaces to `pg_catalog`, qualify application tables and
  grant only exact required authenticated signatures. Do not re-grant old overloads.
- Replace friend-add with an account-bound, limited, duplicate-safe implementation.
  Duplicate nicknames require the unique friend code. Friend lists expose the
  existing display/stats/outfit fields, not UUIDs or emails.
- Serialize/limit activity writes and retire the redundant unrestricted visit
  writer. `p_owner` remains only a self-reported analytics device tag; it is never
  used for authorization. Anonymous Auth signup abuse controls remain a project
  configuration review item.
- Do not apply a pending reward, outfit or purchase response to a different account
  after sign-out/sign-in. Failed cloud saves show an error instead of a fake grant.

## Deployment

1. Merge the companion web-client PR first (v0.93.0). The existing
   `rankings-v0920.js` asset is unchanged and still required.
2. Run `security/economy-v3.sql` in Supabase SQL Editor. It requires room security
   v1, runs in one transaction and can be repeated. During the gap the new client
   pauses cloud XP/coin receipts; gameplay and leaderboard results are unaffected.
3. Refresh all clients, including the Android launcher. Old clients cannot update
   XP after the migration because their direct writes are intentionally blocked.
4. Run `security/verify-economy-v3.sql` and return its JSON report. Only
   `nickname_edit` and `new_progress_api` should be true; other boolean fields
   should be false, unrestricted room policies zero, and unreviewed RPCs empty.
5. Play a new match and check saved XP/coins, then check that an owned cosmetic
   persists after refresh. No production SQL has been executed by this agent.

## Validation

Actual SQL installed twice in PGlite PostgreSQL against production-shaped tables
and the 44-item public catalog. Tests cover anon/legacy API rejection, own-profile
editing, direct XP/balance/stat/history denial, unowned/malformed outfit rejection,
paid/free outfit persistence, real-price checks even with a spoofed temporary
table, duplicate purchases, insufficient funds, duplicate receipts, hourly caps,
once-per-UTC-day rewards, account-scoped friends and the activity limit. PGlite
uses one backend: these tests do not claim multi-connection race testing; quota
serialization is enforced by PostgreSQL advisory and row locks in the SQL.

Real client handlers under jsdom verify one confirmed receipt for progress,
duplicate handling, cosmetic profile saves, no legacy coin call/direct XP upsert,
and failed/stale-account response rejection. Existing gameplay, precise 3PT timing,
ranking/XSS/CSP/integrity, wardrobe and all 15 Dunk combinations are regression
tested. These are local tests, not real Android or production Supabase validation.

## Remaining limits

Clients still report wins and solo XP. Server-chosen/bounded awards do not prove
honest gameplay and a malicious client can farm within the caps. Historical XP
and results are preserved, not retroactively verified. Authoritative gameplay and
reward validation is required before competitive prizes or real-money value.
The final verification lists any other exposed SECURITY DEFINER RPCs that were
not in the supplied audit. Supabase Auth redirects/CAPTCHA/signup limits and
administrator MFA/backups cannot be verified from these function definitions.
