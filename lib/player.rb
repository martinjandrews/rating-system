class Player
  attr_accessor :id, :first_name, :last_name, :rating, :rating_deviation, :games_played, :created_at

  def initialize(id:, first_name:, last_name: '', rating: 500.0, rating_deviation: 350.0, games_played: 0)
    @id = id
    @first_name = first_name
    @last_name = last_name
    @rating = rating
    @rating_deviation = rating_deviation
    @games_played = games_played
    @created_at = Time.now.to_f
  end

  def name
    [@first_name, @last_name].reject(&:empty?).join(' ')
  end

  def to_h
    {
      id: @id,
      first_name: @first_name,
      last_name: @last_name,
      rating: @rating.round(1),
      rating_deviation: @rating_deviation.round(1),
      games_played: @games_played
    }
  end
end
