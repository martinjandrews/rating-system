#!/usr/bin/env ruby
# Scrapes match results from a poolstat.net.au matches page and its corresponding
# finals page, combining both into a single CSV suitable for load_matches.rb.
#
# The finals URL is derived automatically by substituting "matches" for "finals".
# The output filename defaults to the URL slug (e.g. 2026_kings_cup.csv).
#
# Usage: ruby scrape_poolstat.rb <matches-url> [output.csv]
# Example: ruby scrape_poolstat.rb https://www.poolstat.net.au/acteba/matches/8348/2026-kings-cup

require 'net/http'
require 'uri'
require 'csv'
require 'date'

matches_url = ARGV[0]
abort "Usage: ruby scrape_poolstat.rb <matches-url> [output.csv]" unless matches_url
abort "Expected a URL containing '/matches/'" unless matches_url.include?('/matches/')

finals_url = matches_url.sub('/matches/', '/finals/')
slug       = matches_url.split('/').last          # e.g. "2026-kings-cup"
output     = ARGV[1] || "#{slug.tr('-', '_')}.csv"

def scrape(url)
  response = Net::HTTP.get_response(URI(url))
  unless response.is_a?(Net::HTTPSuccess)
    warn "  HTTP #{response.code} from #{url} — skipping"
    return []
  end
  html = response.body

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
  # Finals pages use <span class="csc-score-">11</span> — raw number, no parens.
  pattern = /
    <td[^>]*hometeam[^>]*>(.*?)<\/td>
    \s*
    <td[^>]*score[^>]*hscore[^>]*>(.*?)<\/td>
    \s*
    <td[^>]*awayteam[^>]*>(.*?)<\/td>
  /xm

  html.scan(pattern) do |home_html, score_html, away_html|
    match_pos = Regexp.last_match.begin(0)
    next if away_html.include?('BYE') || score_html.include?('NR')

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

    date = date_positions.select { |pos, _| pos < match_pos }.last&.last
    rows << [date, home, away, home_frames, away_frames]
  end

  rows
rescue => e
  warn "  Error fetching #{url}: #{e.message} — skipping"
  []
end

puts "Fetching rounds:  #{matches_url}"
rows = scrape(matches_url)
abort "No matches found — check the URL or page structure" if rows.empty?
puts "  #{rows.size} matches found"

puts "Fetching finals:  #{finals_url}"
finals_rows = scrape(finals_url)
if finals_rows.empty?
  warn "  No finals matches found — continuing without"
else
  puts "  #{finals_rows.size} matches found"
  rows += finals_rows
end

CSV.open(output, 'w') do |csv|
  csv << %w[date player_a player_b score_a score_b]
  rows.each { |row| csv << row }
end

puts "Wrote #{rows.size} matches to #{output}"
