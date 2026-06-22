require 'json'
require_relative 'player'
require_relative 'frame'
require_relative 'match'
require_relative 'id_counters'
require_relative 'bradley_terry'

class RatingEngine
  attr_reader :players, :matches, :baseline, :scale

  def initialize(baseline: 500.0, scale: BradleyTerry::SCALE_S)
    @players  = {}
    @matches  = []
    @baseline = baseline
    @scale    = scale
  end

  # ---------------------------------------------------------------- players

  def add_player(name)
    pid = IdCounters.next_player_id
    @players[pid] = Player.new(id: pid, name: name, rating: @baseline)
    pid
  end

  def get_player(player_id)
    raise KeyError, "Unknown player id #{player_id}" unless @players.key?(player_id)
    @players[player_id]
  end

  # ---------------------------------------------------------------- matches

  # frames: array of winner_ids, one per frame.
  def record_match(player_a_id, player_b_id, frames)
    raise ArgumentError, "A match must have at least one frame" if frames.empty?
    unless @players.key?(player_a_id) && @players.key?(player_b_id)
      raise KeyError, "Both players must be added via add_player first"
    end

    frames.each do |winner_id|
      unless [player_a_id, player_b_id].include?(winner_id)
        raise ArgumentError, "Frame winner #{winner_id} isn't in this match"
      end
    end

    match_id   = IdCounters.next_match_id
    frame_objs = frames.map { |winner_id| Frame.new(winner_id) }
    @matches << Match.new(id: match_id, player_a_id: player_a_id, player_b_id: player_b_id, frames: frame_objs)
    match_id
  end

  # ---------------------------------------------------------------- rating

  def recompute_ratings(ridge_lambda: 1.0)
    result = BradleyTerry.fit_ratings(
      all_frame_rows,
      baseline:     @baseline,
      scale:        @scale,
      ridge_lambda: ridge_lambda
    )
    result.ratings.each do |pid, rating|
      @players[pid].rating           = rating
      @players[pid].rating_deviation = result.rating_deviation[pid] || @players[pid].rating_deviation
      @players[pid].games_played     = result.games_played[pid] || 0
    end
  end

  # ---------------------------------------------------------------- predict

  # Probability that player_a wins a single frame against player_b.
  def predict(player_a_id, player_b_id)
    ra = get_player(player_a_id).rating
    rb = get_player(player_b_id).rating
    BradleyTerry.win_probability(ra, rb, @scale)
  end

  # Probability that player_a wins a race-to-N match, via dynamic programming.
  def predict_match(player_a_id, player_b_id, race_to:)
    p     = predict(player_a_id, player_b_id)
    cache = {}
    prob  = lambda do |a_wins, b_wins|
      return 1.0 if a_wins == race_to
      return 0.0 if b_wins == race_to
      cache[[a_wins, b_wins]] ||=
        p * prob.call(a_wins + 1, b_wins) + (1 - p) * prob.call(a_wins, b_wins + 1)
    end
    prob.call(0, 0)
  end

  # ---------------------------------------------------------------- output

  def leaderboard
    @players.values.sort_by { |p| -p.rating }
  end

  def print_ratings
    printf "%-20s %10s %8s %8s\n", "Player", "Rating", "+/-", "Games"
    leaderboard.each do |p|
      printf "%-20s %10.1f %8.1f %8d\n", p.name, p.rating, p.rating_deviation, p.games_played
    end
  end

  # ---------------------------------------------------------------- persist

  def to_h
    {
      baseline: @baseline,
      scale:    @scale,
      players:  @players.values.map(&:to_h),
      matches:  @matches.map(&:to_h)
    }
  end

  def save(path)
    File.write(path, JSON.pretty_generate(to_h))
  end

  def self.load(path)
    data   = JSON.parse(File.read(path), symbolize_names: true)
    engine = new(baseline: data[:baseline], scale: data[:scale])

    data[:players].each do |pd|
      p = Player.new(
        id: pd[:id], name: pd[:name], rating: pd[:rating],
        rating_deviation: pd[:rating_deviation], games_played: pd[:games_played]
      )
      engine.players[p.id] = p
    end

    data[:matches].each do |md|
      frames = md[:frames].map { |f| Frame.new(f[:winner_id]) }
      engine.matches << Match.new(
        id: md[:id], player_a_id: md[:player_a_id], player_b_id: md[:player_b_id], frames: frames
      )
    end

    IdCounters.reset_player_counter(engine.players.keys.max) if engine.players.any?
    IdCounters.reset_match_counter(engine.matches.map(&:id).max) if engine.matches.any?

    engine
  end

  private

  def all_frame_rows
    @matches.flat_map do |match|
      match.frames.map { |f| [match.player_a_id, match.player_b_id, f.winner_id] }
    end
  end
end
