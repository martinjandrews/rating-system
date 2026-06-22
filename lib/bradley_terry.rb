# Batch maximum-likelihood (Bradley-Terry) rating solver.
#
# Model
# -----
# Each frame (not match) is one binary trial. For a frame between player i
# and player j where i is "player_a" and j is "player_b":
#
#   logit(P(i wins)) = theta_i - theta_j
#
# theta values live in natural log-odds units. We convert to/from a display
# rating scale where a 100-point gap means a 2:1 win probability, matching
# FargoRate's published behaviour:
#
#   P = 1 / (1 + 10^(-(R_i - R_j)/S)),   S = 100 / log10(2) ~= 332.19
#
# Fitting is done via Newton-Raphson (IRLS) with L2 ridge regularization.
# All matrix operations use plain Ruby arrays so there are no gem dependencies.

module BradleyTerry
  SCALE_S = 100.0 / Math.log10(2.0)  # ~= 332.1928
  LN10    = Math.log(10.0)

  FrameObservation = Struct.new(:a_idx, :b_idx, :a_won)
  FitResult        = Struct.new(:ratings, :rating_deviation, :games_played)

  def self.rating_to_theta(rating, baseline, scale = SCALE_S)
    (rating - baseline) * LN10 / scale
  end

  def self.theta_to_rating(theta, baseline, scale = SCALE_S)
    baseline + theta * scale / LN10
  end

  def self.win_probability(rating_i, rating_j, scale = SCALE_S)
    1.0 / (1.0 + 10.0**(-(rating_i - rating_j) / scale))
  end

  # frame_rows: array of [player_a_id, player_b_id, winner_id], one per frame.
  def self.fit_ratings(
    frame_rows,
    baseline: 500.0,
    scale: SCALE_S,
    ridge_lambda: 1.0,
    max_iter: 100,
    tol: 1e-8,
    compute_uncertainty: true
  )
    return FitResult.new({}, {}, {}) if frame_rows.empty?

    player_ids = frame_rows.flat_map { |row| [row[0], row[1]] }.uniq.sort
    idx_of     = player_ids.each_with_index.to_h
    n          = player_ids.size

    obs          = []
    games_played = player_ids.each_with_object({}) { |pid, h| h[pid] = 0 }

    frame_rows.each do |a_id, b_id, winner_id|
      a_won = winner_id == a_id ? 1 : 0
      obs << FrameObservation.new(idx_of[a_id], idx_of[b_id], a_won)
      games_played[a_id] += 1
      games_played[b_id] += 1
    end

    reg   = Array.new(n, ridge_lambda)
    beta  = Array.new(n, 0.0)
    h_mat = Array.new(n) { Array.new(n, 0.0) }

    # Each frame has exactly two non-zero entries in X (+1 for a, -1 for b),
    # so we update grad and H directly from observation pairs — O(m) per
    # iteration instead of the O(m·n²) dense loop.
    max_iter.times do
      grad  = Array.new(n, 0.0)
      h_mat = Array.new(n) { Array.new(n, 0.0) }

      obs.each do |o|
        eta = beta[o.a_idx] - beta[o.b_idx]
        p_k = sigmoid(eta)
        w_k = [p_k * (1.0 - p_k), 1e-6].max
        r   = o.a_won - p_k

        grad[o.a_idx] += r
        grad[o.b_idx] -= r

        h_mat[o.a_idx][o.a_idx] -= w_k
        h_mat[o.a_idx][o.b_idx] += w_k
        h_mat[o.b_idx][o.a_idx] += w_k
        h_mat[o.b_idx][o.b_idx] -= w_k
      end

      n.times do |j|
        grad[j]      -= reg[j] * beta[j]
        h_mat[j][j]  -= reg[j]
      end

      step = mat_solve(h_mat, grad)
      break if step.nil?

      beta_new  = beta.zip(step).map { |b, s| b - s }
      converged = beta_new.zip(beta).map { |a, b| (a - b).abs }.max < tol
      beta      = beta_new
      break if converged
    end

    # Centre thetas so mean sits at 0 → ratings centred on baseline.
    mean_theta = beta.sum / n
    thetas     = beta.map { |t| t - mean_theta }

    ratings = {}
    player_ids.each { |pid| ratings[pid] = theta_to_rating(thetas[idx_of[pid]], baseline, scale) }

    # Approximate per-player standard error from diagonal of inverse Hessian.
    # Skipped when compute_uncertainty: false — mat_inv is O(n³) and slow for
    # large player pools.
    rating_deviation = {}
    if compute_uncertainty
      begin
        neg_h = h_mat.map { |row| row.map { |v| -v } }
        cov   = mat_inv(neg_h)
        player_ids.each do |pid|
          i = idx_of[pid]
          se_theta = Math.sqrt([cov[i][i], 0.0].max)
          rating_deviation[pid] = se_theta * scale / LN10
        end
      rescue
        player_ids.each { |pid| rating_deviation[pid] = Float::NAN }
      end
    end

    FitResult.new(ratings, rating_deviation, games_played)
  end

  # --- matrix helpers (pure Ruby, no deps) ---

  def self.dot(a, b)
    a.zip(b).sum { |ai, bi| ai * bi }
  end

  def self.sigmoid(z)
    1.0 / (1.0 + Math.exp(-z.clamp(-500.0, 500.0)))
  end

  # Solve A*x = b via Gaussian elimination with partial pivoting.
  # Returns x, or nil if the matrix is singular.
  def self.mat_solve(a_orig, b_orig)
    sz = b_orig.size
    a  = a_orig.map(&:dup)
    b  = b_orig.dup

    sz.times do |col|
      max_row = (col...sz).max_by { |r| a[r][col].abs }
      a[col], a[max_row] = a[max_row], a[col]
      b[col], b[max_row] = b[max_row], b[col]

      pivot = a[col][col]
      return nil if pivot.abs < 1e-14

      (col + 1...sz).each do |row|
        factor = a[row][col] / pivot
        sz.times { |j| a[row][j] -= factor * a[col][j] }
        b[row] -= factor * b[col]
      end
    end

    x = Array.new(sz, 0.0)
    (sz - 1).downto(0) do |i|
      x[i] = b[i]
      (i + 1...sz).each { |j| x[i] -= a[i][j] * x[j] }
      x[i] /= a[i][i]
    end
    x
  end

  # Invert a square matrix via Gauss-Jordan elimination on the augmented matrix.
  # Raises on singular input.
  def self.mat_inv(a_orig)
    sz = a_orig.size
    a  = a_orig.map { |row| row.dup + Array.new(sz, 0.0) }
    sz.times { |i| a[i][sz + i] = 1.0 }

    sz.times do |col|
      max_row = (col...sz).max_by { |r| a[r][col].abs }
      a[col], a[max_row] = a[max_row], a[col]

      pivot = a[col][col]
      raise "Singular matrix" if pivot.abs < 1e-14

      (2 * sz).times { |j| a[col][j] /= pivot }

      sz.times do |row|
        next if row == col
        factor = a[row][col]
        (2 * sz).times { |j| a[row][j] -= factor * a[col][j] }
      end
    end

    sz.times.map { |i| a[i][sz, sz] }
  end
end
