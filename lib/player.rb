class Player
  attr_accessor :id, :name, :rating, :rating_deviation, :games_played, :created_at

  def initialize(id:, name:, rating: 500.0, rating_deviation: 350.0, games_played: 0)
    @id = id
    @name = name
    @rating = rating
    @rating_deviation = rating_deviation
    @games_played = games_played
    @created_at = Time.now.to_f
  end

  def to_h
    {
      id: @id,
      name: @name,
      rating: @rating.round(1),
      rating_deviation: @rating_deviation.round(1),
      games_played: @games_played
    }
  end
end
