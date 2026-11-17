# Career presentation v0.95.1

Career 3PT/free-throw/solo sessions now mount the exact FTAnim canvas renderer from the existing game (long distance for 3PT/solo, line distance for free throw). Dunk uses the extracted existing Dunk Contest drawStage/drawAthlete renderer for run-up, jump, trick and rim finish. These are presentation-only adapters; no existing game module or server progression rules are changed. Canonical server outcomes drive hit/miss and clean/failed finish.

The Career player jersey and number are passed before the first frame. Shooting controls remain locked through flight. A final result waits for its animation; polling cannot replace the ending early. Leaving destroys the animation. Unlocked Windmill now has an explicit entry in Training.

A player without a development path sees only the three path choices and the back-to-game link. Career navigation appears after the saved choice. Recruiting another player without a path opens the same gate; previous players keep their paths. Existing chosen paths are preserved.

Install: merge all files in this PR and refresh Career. No new SQL is needed; the already-installed Career v5 API still applies. Old versioned files are retained for cached pages.

Tests: actual PGlite RPCs and Skia-backed canvas rendering through jsdom cover first-screen gating, saved specialization, five real FTAnim flights, 3PT mounting/cleanup, six-cue two-hand dunk, unlocked eight-cue Windmill, delayed summaries and a second player's separate path. Pixel buffers were generated and inspected for free throw and rim finish. These are renderer/UI simulation checks, not a real mobile browser test. Run: cd tests/career-v5 && npm install && npm test.
