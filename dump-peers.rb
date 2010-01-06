## dump-peers.rb -- command-line peer lister
## Copyright 2004 William Morgan.
##
## This file is part of RubyTorrent. RubyTorrent is free software;
## you can redistribute it and/or modify it under the terms of version
## 2 of the GNU General Public License as published by the Free
## Software Foundation.
##
## RubyTorrent is distributed in the hope that it will be useful, but
## WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
## General Public License (in the file COPYING) for more details.

require "rubytorrent"

def die(x); $stderr << "#{x}\n" && exit(-1); end
def dump_peer(p)
  "#{(p.peer_id.nil? ? '<not specified>' : p.peer_id.inspect)} on #{p.ip}:#{p.port}"
end
  
fn = ARGV.shift or raise "first argument must be .torrent file"

mi = nil
begin
  mi = RubyTorrent::MetaInfo.from_location(fn)
rescue RubyTorrent::MetaInfoFormatError, RubyTorrent::BEncodingError => e
  die "error parsing metainfo file #{fn}---maybe not a .torrent?"
end

# complete abuse
mi.trackers.each do |track|
  puts "#{track}:"

  tc = RubyTorrent::TrackerConnection.new(track, mi.info.sha1, mi.info.total_length, 9999, "rubytorrent.dumppeer") # complete abuse, i know
  begin
    tc.force_refresh
    puts "<no peers>" if tc.peers.length == 0
    tc.peers.each do |p|
      puts dump_peer(p)
    end
  rescue RubyTorrent::TrackerError => e
    puts "error connecting to tracker: #{e.message}"
  end
end

