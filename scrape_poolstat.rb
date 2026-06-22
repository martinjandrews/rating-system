#!/usr/bin/env ruby
# Scrapes match results from a poolstat.net.au matches page and its corresponding
# finals page, combining both into a single CSV suitable for load_matches.rb.
#
# For individual competitions (most events), the frame scores are read directly
# from the matches/finals pages.
#
# For team competitions (where teams play each other and individual player
# match-ups are on separate scoresheet pages), the script detects the format,
# collects all scoresheet URLs from the main page, then fetches and parses each
# scoresheet to extract individual player vs player frame results.
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
require 'fileutils'

RESULTS_DIR = 'results'
FileUtils.mkdir_p(RESULTS_DIR)

USAGE = "Usage: ruby scrape_poolstat.rb <matches-url> [output.csv]\n" \
        "       ruby scrape_poolstat.rb --file <urls.txt>"

SUPPORTED_SEGMENTS = %w[/matches/ /knockout/].freeze

def supported_url?(url)
  SUPPORTED_SEGMENTS.any? { |seg| url.include?(seg) }
end

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
    [url, File.join(RESULTS_DIR, "#{slug.tr('-', '_')}.csv")]
  end
else
  abort USAGE unless ARGV[0]
  abort "Expected a URL containing #{SUPPORTED_SEGMENTS.join(' or ')}" unless supported_url?(ARGV[0])
  slug = ARGV[0].split('/').last
  urls_with_outputs = [[ARGV[0], ARGV[1] || File.join(RESULTS_DIR, "#{slug.tr('-', '_')}.csv")]]
end

# ---------------------------------------------------------------------------- helpers

def fetch_html(url, silent: false)
  response = Net::HTTP.get_response(URI(url))
  unless response.is_a?(Net::HTTPSuccess)
    warn "  HTTP #{response.code} from #{url} — skipping" unless silent
    return nil
  end
  response.body
rescue => e
  warn "  Error fetching #{url}: #{e.message} — skipping" unless silent
  nil
end

# Returns [[byte_offset, 'YYYY-MM-DD'], ...] for every round/date caption in html.
# Handles caption formats like:
#   "DD-MM-YYYY - Round N"
#   "DD-MM-YYYY - Main - Round N"
#   "DD-MM-YYYY - Grand Final Round N"
def extract_date_positions(html)
  positions = []
  html.scan(/(\d{2}-\d{2}-\d{4}) - (?:[^<]*?)(?:Round|\w+ Final)/) do
    positions << [
      Regexp.last_match.begin(0),
      Date.strptime(Regexp.last_match(1), '%d-%m-%Y').strftime('%Y-%m-%d')
    ]
  end
  positions
end

# Given a byte position and the list of date positions, returns the date whose
# caption immediately precedes pos.
def date_at(pos, date_positions)
  date_positions.select { |dpos, _| dpos < pos }.last&.last
end

# ---------------------------------------------------------------------------- format detection

# Team competitions have /team-stats/ links in the hometeam cells.
def teams_competition?(html)
  html.include?('/team-stats/')
end

# Knockout brackets use player/homecell + score cells keyed by cell_N_H/A IDs.
def knockout_competition?(html)
  html.include?('class="player homecell') && html.include?('data-id="cell_')
end

# ---------------------------------------------------------------------------- individual competitions

def scrape_individuals(html)
  date_positions = extract_date_positions(html)
  rows = []

  # Each played match has three consecutive tds: hometeam | score | awayteam.
  # Scores look like: <span class="csc-score-3">0 (8)</span>:<span ...>(6) 1</span>
  # The number in parens is the frame count; the outside 0/1 is the match result.
  # Finals pages use <span class="csc-score-">11</span> — raw frame count, no parens.
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

    rows << [date_at(match_pos, date_positions), home, away, home_frames, away_frames]
  end

  rows
end

# ---------------------------------------------------------------------------- knockout brackets

def scrape_knockout(html)
  # Player names are in <td id="cell_N_H/A" class="player homecell/awaycell ...">
  players = {}
  html.scan(/<td id="(cell_\d+_[HA])"[^>]*class="player[^"]*"[^>]*>(.*?)<\/td>/m) do |cell_id, name|
    players[cell_id] = name.strip
  end

  # Scores are in <td class="score ..." data-id="cell_N_H/A">SCORE</td>
  scores = {}
  html.scan(/<td[^>]*class="score new[^"]*"[^>]*data-id="(cell_\d+_[HA])"[^>]*>(\d+)<\/td>/) do |cell_id, score|
    scores[cell_id] = score.to_i
  end

  # Dates per match code come from the embedded dataDraws JSON blob.
  # Format: "CODE":["CODE","...","...","YYYY-MM-DD",...]
  dates = {}
  html.scan(/"(\d+)":\["[^"]*","[^"]*","[^"]*","(\d{4}-\d{2}-\d{2})"/) do |code, date|
    dates[code] = date
  end

  # Pair up by match code; skip unplayed matches (both scores 0 or player missing)
  codes = players.keys.map { |k| k[/cell_(\d+)_/, 1] }.uniq.sort_by(&:to_i)
  rows  = []
  codes.each do |code|
    h_id = "cell_#{code}_H"
    a_id = "cell_#{code}_A"
    next unless players[h_id] && players[a_id]
    next unless scores[h_id] && scores[a_id]
    next if scores[h_id] == 0 && scores[a_id] == 0
    rows << [dates[code], players[h_id], players[a_id], scores[h_id], scores[a_id]]
  end
  rows
end

# ---------------------------------------------------------------------------- team competitions

def scrape_teams(html, base_url)
  date_positions = extract_date_positions(html)

  # Collect unique scoresheet paths and their positions in the document (for
  # date assignment). The first occurrence of each path determines the date.
  seen = {}
  scoresheet_refs = []
  html.scan(/href="(\/[^"]*scoresheet\/\d+\/[^"]+)"/) do
    path = Regexp.last_match(1)
    pos  = Regexp.last_match.begin(0)
    next if seen[path]
    seen[path] = true
    scoresheet_refs << [path, date_at(pos, date_positions)]
  end

  return [] if scoresheet_refs.empty?

  warn "  Found #{scoresheet_refs.size} team scoresheets"
  rows = []

  scoresheet_refs.each_with_index do |(path, date), i|
    scoresheet_html = fetch_html("#{base_url}#{path}", silent: true)
    unless scoresheet_html
      warn "  Scoresheet #{i + 1}/#{scoresheet_refs.size}: fetch failed — #{path}"
      next
    end
    sheet_rows = parse_scoresheet(scoresheet_html, date)
    label = path.split('/').last
    warn "  Scoresheet #{i + 1}/#{scoresheet_refs.size}: #{sheet_rows.size} frames — #{label}"
    rows += sheet_rows
  end

  rows
end

# Extracts individual player frame results from a team scoresheet page.
# Only processes "Singles #N" tables — the "Legend" summary table is skipped.
# Each row in a Singles table is one frame: home player wins (1-0) or loses (0-1).
def parse_scoresheet(html, date)
  rows = []

  # Split by <table class="table-results"> blocks, keeping only Singles tables.
  html.scan(/<table[^>]*class="table-results"[^>]*>(.*?)<\/table>/m) do |table_match|
    table = table_match[0]
    next unless table.match?(/<caption[^>]*>\s*Singles/i)

    # Each row: home player (tdl + player_N class) | home score (tdc + rb, 0 or 1)
    #           | away score (tdc, 0 or 1) | away player (tdr + player_N class)
    #
    # The Legend table has "N - N" style scores so those rows don't match (0|1).
    table.scan(/
      <td[^>]*\btdl\b[^>]*\bplayer_\d+\b[^>]*>.*?<a[^>]*>(.*?)<\/a>.*?<\/td>
      .*?
      <td[^>]*\btdc\b[^>]*\brb\b[^>]*>\s*(0|1)\s*<\/td>
      [^<]*
      <td[^>]*\btdc\b[^>]*>\s*(0|1)\s*<\/td>
      .*?
      <td[^>]*\btdr\b[^>]*\bplayer_\d+\b[^>]*>.*?<a[^>]*>(.*?)<\/a>
    /xm) do |home, home_score, away_score, away|
      home = home.strip
      away = away.strip
      next if home.empty? || away.empty?
      rows << [date, home, away, home_score.to_i, away_score.to_i]
    end
  end

  rows
end

# ---------------------------------------------------------------------------- main scrape entry point

def scrape(url, silent: false)
  html = fetch_html(url, silent: silent)
  return [] unless html

  if knockout_competition?(html)
    scrape_knockout(html)
  elsif teams_competition?(html)
    uri = URI(url)
    scrape_teams(html, "#{uri.scheme}://#{uri.host}")
  else
    scrape_individuals(html)
  end
end

# ---------------------------------------------------------------------------- per-URL processing

urls_with_outputs.each do |url, output|
  abort "Expected a URL containing #{SUPPORTED_SEGMENTS.join(' or ')}: #{url}" unless supported_url?(url)

  puts "\n#{output}"
  puts "  Fetching: #{url}"
  rows = scrape(url)
  if rows.empty?
    warn "  No match scores — ignoring"
    next
  end
  puts "  #{rows.size} matches found"

  # /matches/ pages have a companion /finals/ page; /knockout/ pages do not.
  if url.include?('/matches/')
    finals_url = url.sub('/matches/', '/finals/')
    puts "  Fetching finals: #{finals_url}"
    finals_rows = scrape(finals_url, silent: true)
    unless finals_rows.empty?
      puts "  #{finals_rows.size} matches found"
      rows += finals_rows
    end
  end

  CSV.open(output, 'w') do |csv|
    csv << %w[date player_a player_b score_a score_b]
    rows.each { |row| csv << row }
  end
  puts "  Wrote #{rows.size} matches to #{output}"
end
