# 8-Ball Rating System Prototype

A working prototype of a FargoRate-style rating system built entirely on
open, published statistics (Bradley-Terry maximum-likelihood ratings),
with the same "100 points = 2:1 win odds" logarithmic scale.

## Files

- `models.py` — `Player`, `Match`, `Frame` data classes. A match has two
  players and a list of frames; each frame has a breaker and a winner.
  The match winner is *derived* (most frames won), never stored directly.
- `bradley_terry.py` — the actual rating math: a batch maximum-likelihood
  solver (Newton-Raphson / IRLS) that fits one strength value per player
  plus a single global "break advantage" term, from every recorded frame.
- `engine.py` — `RatingEngine`: the API you actually use. Add players,
  record matches, recompute ratings, predict outcomes, save/load to JSON.
- `demo.py` — runnable example: simulates a season of matches from known
  "true" ratings and checks that the fitted ratings/scale/break-advantage
  recover sensible values.

## Quick start

```python
from rating_system import RatingEngine

engine = RatingEngine(baseline=500.0)   # 500 = average player, like FargoRate's mid-range

alice = engine.add_player("Alice")
bob = engine.add_player("Bob")

# Record a match: race to 3, with breaker alternating each frame.
engine.record_match(alice, bob, frames=[
    (alice, alice),   # Alice broke, Alice won the frame
    (bob, bob),       # Bob broke, Bob won the frame
    (alice, bob),     # Alice broke, Bob won the frame
    (bob, alice),     # Bob broke, Alice won the frame  (Alice wins match 3-1)
])

engine.recompute_ratings()
engine.print_ratings()

engine.predict(alice, bob, breaker_id=alice)          # P(Alice wins a single frame, she breaks)
engine.predict_match(alice, bob, race_to=5)           # P(Alice wins a race-to-5 match)

engine.save("ratings.json")
reloaded = RatingEngine.load("ratings.json")
```

Run the included demo:

```
python3 -m rating_system.demo
```

## How the math works

Every **frame** (not match) is one data point. For a frame between
player *i* and player *j*:

```
logit(P(i wins)) = theta_i - theta_j + b * breakterm
```

`breakterm` is +1 if *i* broke and -1 if *j* broke; `b` is a single
global parameter — "how many log-odds is the break worth" — learned
jointly with every player's strength `theta` from the entire match
history in one batch fit (Newton-Raphson on the logistic likelihood).
This is the open, well-studied **Bradley-Terry model**, the same family
FargoRate is built on, just without the proprietary implementation.

Ratings are then put on the FargoRate-style scale:

```
P(i beats j) = 1 / (1 + 10^(-(R_i - R_j)/S)),   S = 100 / log10(2) ~= 332.19
```

so a 100-point gap always means 2:1 odds, exactly as requested. `theta`
and `R` are just two unit systems for the same number (`theta` in
natural log-odds, `R` rescaled so 100 points = 2:1) — see
`rating_to_theta` / `theta_to_rating` in `bradley_terry.py`.

### Why a batch fit, not pure incremental Elo

FargoRate is described as recomputing from full history rather than only
ever nudging a number after each game — "we forget everything, run
through every match and recalculate." This prototype does the same: call
`recompute_ratings()` after adding new matches and every player's rating
is refit from *all* recorded frames at once. This avoids order-of-play
artifacts that pure incremental Elo can suffer from, and it's what makes
the "robustness" behaviour below work automatically.

### Built-in "robustness" (confidence) without a separate rule

The solver applies a small L2 ridge penalty pulling every player's
strength toward the baseline rating. Because the *likelihood*'s pull on
a player's rating scales with how many frames they've played, but the
*ridge penalty*'s pull is constant, the practical effect is:

- Players with few recorded frames sit close to the baseline and move a
  lot per new result.
- Players with a long track record are barely moved by the ridge term
  and are governed almost entirely by their actual results.

This reproduces FargoRate's "small wagon moves more" idea as a natural
consequence of the math, rather than a bolted-on special case. The
per-player `rating_deviation` reported alongside each rating (derived
from the inverse-Hessian / Fisher information of the fit) gives you a
Glicko-style uncertainty band for free — useful for deciding when a
rating is "established" vs still settling.

### Break advantage as a first-class, estimated quantity

Rather than assuming a fixed value for how much breaking matters, the
model estimates it from your actual data, expressed directly in rating
points (e.g. "breaking is worth ~25 points" in the demo's simulated
data, recovered from observed frame outcomes alone). This lets the
system stay self-correcting as playing conditions, table/cloth
differences, or rule sets change over time.

### Match-level prediction

`predict_match()` builds the full race-to-N probability via dynamic
programming over per-frame win probabilities (accounting for alternating
break), rather than assuming match win probability is some simple
function of single-frame odds — this matters because the breaker
advantage means each frame in a race isn't an identical coin flip.

## Known simplifications / next steps

- **Ridge strength is a single tunable constant** (`ridge_lambda` in
  `recompute_ratings`). It was not fit against real league data — once
  you have actual results, this (and the corresponding `rating_deviation`
  scale) should be calibrated, e.g. by checking how well predicted odds
  match observed outcomes (calibration plot) on held-out matches.
- **No time decay**: this fits the entire history with equal weight.
  FargoRate-like systems often down-weight old results; that could be
  added as a per-frame weight in the IRLS step without changing the
  architecture.
- **No handicapping/spotting logic**: only raw ratings and predicted
  odds are produced here; a handicap race-length calculator could be
  layered on `predict_match()`.
- **Single global break-advantage term**: currently one number for the
  whole player pool. Could be extended to vary by table size/conditions,
  or even per-player (some players benefit more from breaking than
  others) if you want that level of detail later.
- **Newton-Raphson assumes a well-connected comparison graph.** If your
  player pool splits into disconnected clusters who never play each
  other, ratings within a cluster will still be well-determined relative
  to each other, but cross-cluster comparisons are not meaningful until
  some games connect them — same caveat that applies to any Elo/Bradley-
  Terry-style system.
