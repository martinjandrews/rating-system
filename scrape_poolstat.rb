#!/usr/bin/env ruby
# Scrapes match results from a poolstat.net.au matches page and its corresponding
# finals page, combining both into a single CSV suitable for load_matches.rb.
#
# The finals URL is derived automatically by substituting "matches" for "finals".
# The output filename defaults to the URL slug (e.g. 2026_kings_cup.csv).
#
# Usage (single):   ruby scrape_poolstat.rb <matches-url> [output.csv]
# Usage (bulk):     ruby scrape_poolstat.rb --file <urls.txt>
#
# The URL file should contain one matches URL per line; blank lines and lines
# starting with # are ignored. Each URL writes its own slug-named output file.

require 'net/http'
require 'uri'
require 'csv'
require 'date'

USAGE = "Usage: ruby scrape_poolstat.rb <matches-url> [output.csv]\n" \
        "       ruby scrape_poolstat.rb --file <urls.txt>"

if ARGV.include?('--file')
  file_arg = ARGV[ARGV.index('--file') + 1]
  abort USAGE unless file_arg
  abort "File not found: #{file_arg}" unless File.exist?(file_arg)
  urls = File.readlines(file_arg, chomp: true)
              .map(&:strip)
              .reject { |l| l.empty? || l.start_with?('#') }
  abort "No URLs found in #{file_arg}" if urls.empty?
  urls_with_outputs = urls.map do |url|
    slug = url.split('/').last
    [url, "#{slug.tr('-', '_')}.csv"]
  end
else
  abort USAGE unless ARGV[0]
  abort "Expected a URL containing '/matches/'" unless ARGV[0].include?('/matches/')
  slug = ARGV[0].split('/').last
  urls_with_outputs = [[ARGV[0], ARGV[1] || "#{slug.tr('-', '_')}.csv"]]
end

def scrape(url, silent: false)
  response = Net::HTTP.get_response(URI(url))
  unless response.is_a?(Net::HTTPSuccess)
    warn "  HTTP #{response.code} from #{url} — skipping" unless silent
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

urls_with_outputs.each do |matches_url, output|
  abort "Expected a URL containing '/matches/': #{matches_url}" unless matches_url.include?('/matches/')
  finals_url = matches_url.sub('/matches/', '/finals/')

  puts "\n#{output}"
  puts "  Fetching rounds: #{matches_url}"
  rows = scrape(matches_url)
  if rows.empty?
    warn "  No matches found — skipping"
    next
  end
  puts "  #{rows.size} matches found"

  puts "  Fetching finals: #{finals_url}"
  finals_rows = scrape(finals_url, silent: true)
  unless finals_rows.empty?
    puts "  #{finals_rows.size} matches found"
    rows += finals_rows
  end

  CSV.open(output, 'w') do |csv|
    csv << %w[date player_a player_b score_a score_b]
    rows.each { |row| csv << row }
  end
  puts "  Wrote #{rows.size} matches to #{output}"
end
