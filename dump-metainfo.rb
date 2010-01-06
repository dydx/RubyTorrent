## dump-metainfo.rb -- command-line .torrent dumper
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

require 'rubytorrent'

def dump_metainfoinfo(mii)
  if mii.single?
      <<EOS
       length: #{mii.length / 1024}kb
     filename: #{mii.name}
EOS
  else
    mii.files.map do |f|
        <<EOS
   - filename: #{File.join(mii.name, f.path)}
       length: #{f.length}
EOS
    end.join + "\n"
  end + <<EOS
 piece length: #{mii.piece_length / 1024}kb 
       pieces: #{mii.pieces.length / 20}
EOS
end

def dump_metainfo(mi)
    <<EOS
#{dump_metainfoinfo(mi.info).chomp}
     announce: #{mi.announce}
announce-list: #{(mi.announce_list.nil? ? "<not specified>" : mi.announce_list.map { |x| x.join(', ') }.join('; '))}
creation date: #{mi.creation_date || "<not specified>"}
   created by: #{mi.created_by || "<not specified>"}
      comment: #{mi.comment || "<not specified>"}
EOS
end

if ARGV.length == 1
  fn = ARGV[0]
  begin
    puts dump_metainfo(RubyTorrent::MetaInfo.from_location(fn))
  rescue RubyTorrent::MetaInfoFormatError, RubyTorrent::BEncodingError => e
    puts "Can't parse #{fn}: maybe not a .torrent file?"
  end
else
  puts "Usage: dump-metainfo <filename>"
end
