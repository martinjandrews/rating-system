# Project: 8-Ball Rating System

## What this is
A prototype rating system for 8-ball pool, conceptually similar to
FargoRate, built entirely on open/published statistics (we don't have
access to FargoRate's actual code -- it's proprietary -- so this
reconstructs the same general approach from public building blocks).

## Domain model (do not casually change without discussion)
- A **Match** is played between exactly two players and consists of one
  or more **Frames**.
- Each **Frame** has exactly one breaker and exactly one winner (both
  must be one of the two match players).
- The match winner is **derived**, not stored: whoever won more frames.
  Never add a stored "match winner" field -- it must stay computed from
  frame results, or it can silently desync from the actual frame data.
- Rating math operates on **frames**, not matches. A 5-frame match is 5
  independent pieces of evidence, not one. Don't aggregate to the match
  level before fitting ratings.

## Rating math (the part that matters most)
- Core model: **Bradley-Terry** maximum-likelihood ratings. Each player
  has a latent strength `theta`; `logit(P(i beats j)) = theta_i - theta_j
  + b * breakterm`, where `breakterm` is +1/-1 depending who broke that
  frame, and `b` is a single global learned "break advantage" parameter.
- Display scale: **100 rating points = 2:1 win odds** (matches
  FargoRate's published behavior), via
  `P(i beats j) = 1 / (1 + 10^(-(R_i - R_j)/S))`, `S = 100/log10(2) ≈
  332.19`. This constant is `SCALE_S` in `bradley_terry.py` -- treat it
  as fixed/load-bearing, not a magic number to "clean up".
- Baseline rating (average player) is currently 500.0, matching
  FargoRate's rough scale conventions. Configurable via `RatingEngine(baseline=...)`.
- Fitting is done as a **full batch recompute** (Newton-Raphson/IRLS)
  over the entire frame history each time `recompute_ratings()` is
  called -- intentionally mirroring FargoRate's "forget everything and
  recompute from history" philosophy rather than pure incremental Elo.
  Don't convert this to a pure incremental/online update without
  discussing it first -- it changes the system's behavior in ways that
  need to be deliberate (e.g. order-of-play artifacts).
- Ridge regularization (`ridge_lambda`, `break_ridge_lambda` in
  `fit_ratings`) pulls under-evidenced players toward baseline. This is
  what produces FargoRate-like "small wagon moves more" behavior. It is
  currently **untuned against real data** -- if real league results
  become available, calibrate this against observed vs. predicted
  outcomes (e.g. a calibration plot / log-loss check) rather than
  guessing.

## File map
- `models.py` -- Player / Match / Frame dataclasses.
- `bradley_terry.py` -- the actual MLE solver + scale conversions
  (`rating_to_theta`, `theta_to_rating`, `win_probability`,
  `win_probability_with_break`). This is the file to read first to
  understand the math.
- `engine.py` -- `RatingEngine`: the public API (add_player,
  record_match, recompute_ratings, predict, predict_match, save/load).
- `demo.py` -- runnable simulation against known ground-truth ratings,
  used as a sanity check that fitting recovers sensible values and the
  scale constant behaves correctly. Run via `python3 -m rating_system.demo`.
- `README.md` -- fuller writeup of the design rationale; read this
  before making structural changes.

## Known gaps / explicitly deferred (don't "fix" silently)
- No time-decay weighting of older results yet.
- Break-advantage is a single global parameter, not per-player or
  per-condition (table size, cloth, etc.).
- No handicapping/spotting calculator on top of `predict_match()`.
- Ridge strength is a guessed constant, not fit from real data.
If you want to tackle any of these, flag it and discuss the approach
before implementing -- they affect the statistical properties of the
whole system, not just one function.

## Working conventions
- Keep `bradley_terry.py` dependency-light (numpy only). Don't add heavy
  ML dependencies for what is currently a fairly small logistic
  regression.
- Any change to `SCALE_S` or the baseline rating affects every existing
  stored rating's meaning -- treat as a breaking change requiring a
  migration note, not a casual edit.
- When adding tests or new simulations, follow `demo.py`'s pattern of
  simulating from known ground-truth ratings and checking the fit
  recovers them, rather than just eyeballing plausibility.
