module IdCounters
  @player_id = 0
  @match_id  = 0

  def self.next_player_id
    @player_id += 1
  end

  def self.next_match_id
    @match_id += 1
  end

  def self.reset_player_counter(n)
    @player_id = n
  end

  def self.reset_match_counter(n)
    @match_id = n
  end
end
