require_relative 'rating_engine'

def simulate_frame(true_rating_a, true_rating_b, scale)
  p_a = 1.0 / (1.0 + 10.0**(-(true_rating_a - true_rating_b) / scale))
  rand < p_a
end

def main
  srand(42)
  engine = RatingEngine.new(baseline: 500.0)

  true_ratings = {
    "Alice Smith"  => 650.0,
    "Bob Jones"    => 550.0,
    "Carol Davis"  => 500.0,
    "Dave Wilson"  => 420.0
  }
  scale = engine.scale

  ids   = true_ratings.keys.each_with_object({}) { |name, h| h[name] = engine.add_player(*name.split(' ', 2)) }
  names = true_ratings.keys

  60.times do
    a_name, b_name = names.sample(2)
    a_id,   b_id   = ids[a_name], ids[b_name]
    race_to        = [3, 5].sample
    frames         = []
    a_wins = b_wins = 0

    while a_wins < race_to && b_wins < race_to
      a_won_frame = simulate_frame(true_ratings[a_name], true_ratings[b_name], scale)
      winner_id   = a_won_frame ? a_id : b_id
      frames << winner_id
      a_won_frame ? a_wins += 1 : b_wins += 1
    end

    engine.record_match(a_id, b_id, frames)
  end

  engine.recompute_ratings

  puts "=== Fitted ratings (ground truth in brackets) ==="
  engine.leaderboard.each do |p|
    printf "%-8s fitted=%7.1f  true=%6.1f  +/-%5.1f  games=%d\n",
      p.name, p.rating, true_ratings[p.name], p.rating_deviation, p.games_played
  end

  puts "\n=== Scale check ==="
  odds_100 = BradleyTerry.win_probability(600.0, 500.0) /
             (1 - BradleyTerry.win_probability(600.0, 500.0))
  printf "Win odds for a 100-point favourite: %.3f (target: 2.000)\n", odds_100

  puts "\n=== Single-frame prediction: Alice vs Dave ==="
  a_id = ids["Alice Smith"]
  d_id = ids["Dave Wilson"]
  printf "P(Alice wins frame) = %.3f\n", engine.predict(a_id, d_id)

  puts "\n=== Match prediction: Alice vs Dave, race to 5 ==="
  prob = engine.predict_match(a_id, d_id, race_to: 5)
  printf "P(Alice wins the match) = %.3f\n", prob

  engine.save("/tmp/ratings_demo_ruby.json")
  reloaded = RatingEngine.load("/tmp/ratings_demo_ruby.json")
  printf "\nReloaded engine has %d players and %d matches.\n",
    reloaded.players.size, reloaded.matches.size
end

main
