#!/usr/bin/env ruby
# Usage: ruby load_matches.rb matches.csv [--save ratings.json]

require 'csv'
require_relative 'lib/rating_engine'

csv_path  = ARGV[0]
save_path = ARGV[ARGV.index('--save') + 1] if ARGV.include?('--save')

abort "Usage: ruby load_matches.rb matches.csv [--save ratings.json]" unless csv_path
abort "File not found: #{csv_path}" unless File.exist?(csv_path)

engine     = RatingEngine.new(baseline: 500.0)
player_ids = {}  # name -> id

rows_loaded = 0
skipped     = 0

CSV.foreach(csv_path, headers: true) do |row|
  player_a = row['player_a']&.strip
  player_b = row['player_b']&.strip
  score_a  = row['score_a']&.strip&.to_i
  score_b  = row['score_b']&.strip&.to_i

  unless player_a && player_b && row['score_a'] && row['score_b']
    warn "Skipping incomplete row: #{row.to_h}"
    skipped += 1
    next
  end

  if player_a == player_b
    warn "Skipping row where both players are the same: #{player_a}"
    skipped += 1
    next
  end

  if score_a < 0 || score_b < 0 || (score_a + score_b) == 0
    warn "Skipping row with invalid scores: #{score_a}-#{score_b}"
    skipped += 1
    next
  end

  [player_a, player_b].each do |full_name|
    player_ids[full_name] ||= engine.add_player(*full_name.split(' ', 2))
  end

  a_id   = player_ids[player_a]
  b_id   = player_ids[player_b]
  frames = [a_id] * score_a + [b_id] * score_b

  engine.record_match(a_id, b_id, frames)
  rows_loaded += 1
end

abort "No valid match rows found in #{csv_path}" if rows_loaded == 0

engine.recompute_ratings

puts "=== Ratings (#{rows_loaded} matches, #{engine.players.size} players) ==="
engine.print_ratings

if save_path
  engine.save(save_path)
  puts "\nSaved to #{save_path}"
end
