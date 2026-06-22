#!/usr/bin/env ruby
# Scrapes match results from a poolstat.net.au matches or finals page and writes
# (or appends to) a CSV suitable for load_matches.rb.
#
# Usage: ruby scrape_poolstat.rb <url> [output.csv] [--append]
# Example: ruby scrape_poolstat.rb https://www.poolstat.net.au/acteba/matches/8348/2026-kings-cup kings_cup_2026.csv
# Example: ruby scrape_poolstat.rb https://www.poolstat.net.au/ACTEBA/finals/8348/2026-kings-cup kings_cup_2026.csv --append

require 'net/http'
require 'uri'
require 'csv'
require 'date'

url    = ARGV[0]
output = ARGV.reject { |a| a.start_with?('--') }[1] || 'scraped_matches.csv'
append = ARGV.include?('--append')

abort "Usage: ruby scrape_poolstat.rb <url> [output.csv] [--append]" unless url

html = Net::HTTP.get(URI(url))

# Collect date captions and their byte positions so we can assign each match
# to the round date that precedes it in the document.
# Matches pages use "DD-MM-YYYY - Round N", finals pages use "DD-MM-YYYY - Grand Final..."
date_positions = []
html.scan(/(\d{2}-\d{2}-\d{4}) - (?:Round|Grand Final)/) do
  date_positions << [
    Regexp.last_match.begin(0),
    Date.strptime(Regexp.last_match(1), '%d-%m-%Y').strftime('%Y-%m-%d')
  ]
end

rows = []

# Each played match has three consecutive tds: hometeam | score | awayteam.
# Scores look like: <span class="csc-score-3">0 (3)</span>:<span ...>(8) 1</span>
# The number in parens is the frame count; we ignore the match-level 0/1 outside.
pattern = /
  <td[^>]*hometeam[^>]*>(.*?)<\/td>   # home player cell
  \s*
  <td[^>]*score[^>]*hscore[^>]*>(.*?)<\/td>  # score cell
  \s*
  <td[^>]*awayteam[^>]*>(.*?)<\/td>   # away player cell
/xm

html.scan(pattern) do |home_html, score_html, away_html|
  match_pos = Regexp.last_match.begin(0)

  # Skip BYEs and unplayed (NR) rows
  next if away_html.include?('BYE') || score_html.include?('NR')

  # Extract frame counts from the two csc-score-N spans.
  # Matches page: <span class="csc-score-3">0 (8)</span>  — number is in parens
  # Finals page:  <span class="csc-score-">11</span>       — number is the whole content
  spans = score_html.scan(/<span class="csc-score-[^"]*">(.*?)<\/span>/m)
                    .flatten
                    .map { |s| s.gsub(/<[^>]+>/, '').strip }
  next if spans.size < 2

  home_frames = spans[0][/\((\d+)\)/, 1]&.to_i || spans[0][/\A\s*(\d+)\s*\z/, 1]&.to_i
  away_frames = spans[1][/\((\d+)\)/, 1]&.to_i || spans[1][/\A\s*(\d+)\s*\z/, 1]&.to_i
  next unless home_frames && away_frames

  home = home_html.gsub(/<[^>]+>/, '').strip
  away = away_html.gsub(/<[^>]+>/, '').strip
  next if home.empty? || away.empty?

  # Use the last date caption that appears before this match in the document
  date = date_positions.select { |pos, _| pos < match_pos }.last&.last

  rows << [date, home, away, home_frames, away_frames]
end

abort "No matches found — check the URL or page structure" if rows.empty?

if append && File.exist?(output)
  CSV.open(output, 'a') do |csv|
    rows.each { |row| csv << row }
  end
  puts "Appended #{rows.size} matches to #{output}"
else
  CSV.open(output, 'w') do |csv|
    csv << %w[date player_a player_b score_a score_b]
    rows.each { |row| csv << row }
  end
  puts "Wrote #{rows.size} matches to #{output}"
end
