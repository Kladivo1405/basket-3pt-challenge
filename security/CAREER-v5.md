# Career v0.95.0

Career is a separate game section opened from the main menu. Existing games, Draft, Blockout and their economy are unchanged. Uses the same Supabase login but separate private Career XP, coins, player ownership and seasons. Old local prototype saves and demo boosts are deliberately not imported.

## Install
1. Merge this PR, including career.html and both career-*-v0950.js files beside index.html.
2. Run the complete security/career-v5.sql in Supabase SQL Editor (requires installed room security v1). Transactional and repeatable.
3. Run security/verify-career-v5.sql. Account API, all_tables_rls, real_server_clock and api_search_path should be true; anonymous/private access should be false. The existing economy audit now recognizes this reviewed Career RPC.
4. Reload the main game, sign in, then open CAREER. Choose a development path in My Player before starting a session.

## Player development
Each collected player independently chooses a permanent 3PT, Free Throw or Dunk specialty. That attribute gets up to 10 extra potential (maximum 99) and 25% cheaper upgrades. Other attributes remain trainable. Recruiting/switching preserves every owned player's development path, upgrades, jersey and number. Starter attributes 12, base potential 20; stronger prospects unlock at account levels 3, 6 and 10. XP costs grow by 24% per level; attribute costs grow toward potential. Career has no energy timers or paid attributes.

## Gameplay and trust boundary
3PT and Free Throw drills have five server-scored shots. The relevant attribute widens the release target; a 1.4-second triangular meter half-cycle uses server receipt time. Each next shot has a 760ms cooldown. Dunk has six rhythm cues; three clean completions unlock an eight-cue signature. The server evaluates cue timing, missed cues and extra taps.

Solo seasons contain four 30-second CPU duels. Bot scores come from a private server seed; clients never submit a score, hit, win, XP or coin amount. The server settles expired matches on the next get/action, grants results once, and applies a completion bonus on the fourth game. Next seasons increase rival difficulty. Daily/weekly UTC challenges use server counters and claim once; cosmetics require real Career milestones. Hidden/abandoned training sessions pay nothing; a match already past its deadline may settle before a late abandon.

All mutations are serialized per account and carry idempotent request UUIDs, with seven-day retry receipts. Private tables have RLS and no anonymous/account grants; only the authenticated command RPC is exposed, with a pinned search_path and account derived from auth.uid(). Profile look inputs and development paths are allowlisted. No direct shared-wallet/profile updates occur. Raw HTML output uses the existing bundled DOMPurify/security helper, SRI pins all external scripts, and CSP blocks inline script handlers.

Career requires internet. The UI estimates server receipt timing from RPC latency; variable real networks can still change the feel. Active sessions can be resumed after reopening; the original deadline stays in effect. Local prototype progress is not trusted or migrated. Online Career remains a clearly labelled unavailable flow preview; existing online Blockout continues to work separately.

## Validation and remaining work
PGlite integration tests install twice and cover authentication, per-account ownership, immutable specialties, upgrade costs/caps, server timing/cooldowns, private bot seed, rhythm completion, exactly-once rewards, challenges, abandon and a complete four-game season. jsdom client tests use the actual SQL RPC through real UI controls for specialization, training, cosmetics, results, solo expiry, resume and account changes. Main-game XSS/CSP/SRI and full boot regressions are also run.

These are local PostgreSQL-compatible and simulated browser checks, not a live Supabase/Android/mobile visual certification or a multi-connection load test. After installation, test touch/keyboard release timing, 3PT versus free throw attribute effects, all specialties, outfits, clean/failed dunk, late timeout, reconnect, two devices on the same account and returning to the existing game modes. Legal-input automation/collusion are not solved; do not market this or the shared practice economy as cheatproof.
