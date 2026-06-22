require_relative 'frame'

class Match
  attr_reader :id, :player_a_id, :player_b_id, :frames, :played_at

  def initialize(id:, player_a_id:, player_b_id:, frames:)
    @id = id
    @player_a_id = player_a_id
    @player_b_id = player_b_id
    @frames = frames
    @played_at = Time.now.to_f
  end

  def frame_wins(player_id)
    @frames.count { |f| f.winner_id == player_id }
  end

  def winner_id
    a_wins = frame_wins(@player_a_id)
    b_wins = frame_wins(@player_b_id)
    return nil if a_wins == b_wins
    a_wins > b_wins ? @player_a_id : @player_b_id
  end

  def to_h
    {
      id: @id,
      player_a_id: @player_a_id,
      player_b_id: @player_b_id,
      frames: @frames.map { |f| { winner_id: f.winner_id } },
      winner_id: winner_id
    }
  end
end
