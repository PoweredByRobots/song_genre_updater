#!/usr/bin/env ruby

require 'bundler/setup'
require 'musicbrainz'
require 'mysql2'
require 'pry'

def options
  { host: ENV['SONGS_DB_HOSTNAME'],
    username: ENV['SONGS_DB_USER'],
    password: ENV['SONGS_DB_PWD'],
    database: ENV['SONGS_DB_NAME'] }
end

def preserve_genres
  %w(Christmas art01 fraser18 dhr)
end

def mysql_client
  @mysql_client ||= Mysql2::Client.new(options)
end

def musicbrainz_client
  @musicbrainz_client ||= MusicBrainz::Client.new
end

def pause
  sleep 10
end

def remove_already_processed(songs)
  pruned = []
  songs.each do |song|
    next if processed_ids.include? song.first
    pruned << song
  end
  pruned
end

def filename
  'processed.songs'
end

def processed_ids
  create_file if file_not_found?
  File.readlines(filename).map(&:to_i)
end

def create_file
  File.write(filename, '')
end

def file_not_found?
  !File.file?(filename)
end

def sterilize(genres)
  genres.map(&:downcase) & preserve_genres.map(&:downcase)
end

def update_song(id, artist, title, existing_genres)
  @remaining -= 1
  add_to_list(id)
  puts "\n#{artist} - #{title}..."
  genres = lookup_genres(artist, title) || existing_genres
  return if genres == existing_genres
  update_genres(id, genres)
end

def add_to_list(id)
  File.open(filename, 'a') { |f| f.puts(id) }
end

def lookup_songlist(songs = [])
  sql = 'SELECT ID, title, artist, grouping FROM songlist ' \
        "WHERE songtype = \'S\'"
  results = mysql_client.query(sql)
  results.each do |s|
    songs << [
      s['ID'],
      s['artist'].to_s,
      s['title'],
      s['grouping'].split(', ')
    ]
  end
  remove_already_processed(songs)
end

def find_tags(recordings)
  tag_data = []
  song_data = Hash[recordings.map { |key, value| [key, value] }]
  song_data.each do |song|
    tag_data << nested_hash_value(song, 'tags')
  end
  tag_data
end

def find_genres(tag_data)
  genres = []
  tag_data.each do |tag|
    next if tag.nil?
    tag.each { |genre| genres << genre['name'] }
  end
  genres
end

def lookup_genres(artist, title)
  recordings = musicbrainz_lookup(artist, title)
  return if recordings.nil? || recordings.empty?
  puts '-> song found'
  tag_data = find_tags(recordings)
  return unless tag_data.first
  puts '-> tags found'
  genres = find_genres(tag_data)
  return if genres.empty?
  puts "-> genres found: #{genres}"
  genres
end

def musicbrainz_lookup(artist, title)
  pause
  query = { artist: artist, recording: title }
  musicbrainz_client.recordings q: query
rescue => error
  puts "MusicBrainz error: #{error.message}"
end

def update_genres(id, genres)
  sql = "UPDATE songlist SET grouping = \'#{genres.join(', ')}\' " \
        "WHERE id = #{id}"
  puts 'Updating records'
  mysql_client.query(sql)
rescue => error
  puts "Skipping #{id}\n#{error.message}"
  @mysql_error_count += 1
  abort('Too many db errors') if @mysql_error_count > 3
end

def nested_hash_value(obj, key)
  if obj.respond_to?(:key?) && obj.key?(key)
    obj[key]
  elsif obj.respond_to?(:each)
    r = nil
    obj.find { |*a| r = nested_hash_value(a.last, key) }
    r
  end
end

def configure_musicbrainz
  MusicBrainz.configure do |c|
    c.app_name = 'My Music App'
    c.app_version = '0.1'
    c.contact = 'your@email.com'
  end
end

system 'clear'

configure_musicbrainz
songs = lookup_songlist
@remaining = songs.count
@mysql_error_count = 0

puts "-==[#{@remaining}]==- songs to go!"

songs.each do |id, artist, title, genres|
  update_song(id, artist, title, genres)
end
