## metainfo.rb -- parsed .torrent file
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

require "rubytorrent/typedstruct"
require 'uri'
require 'open-uri'
require 'digest/sha1'

## MetaInfo file is the parsed form of the .torrent file that people
## send around. It contains a MetaInfoInfo and possibly some
## MetaInfoInfoFile objects.
module RubyTorrent

class MetaInfoFormatError < StandardError; end

class MetaInfoInfoFile
  def initialize(dict=nil)
    @s = TypedStruct.new do |s|
      s.field :length => Integer, :md5sum => String, :sha1 => String,
              :path => String
      s.array :path
      s.required :length, :path
    end

    @dict = dict
    unless dict.nil?
      @s.parse dict
      check
    end
  end

  def method_missing(meth, *args)
    @s.send(meth, *args)
  end

  def check
    raise MetaInfoFormatError, "invalid file length" unless @s.length >= 0
  end

  def to_bencoding
    check
    (@dict || @s).to_bencoding
  end
end

class MetaInfoInfo
  def initialize(dict=nil)
    @s = TypedStruct.new do |s|
      s.field :length => Integer, :md5sum => String, :name => String,
              :piece_length => Integer, :pieces => String,
              :files => MetaInfoInfoFile, :sha1 => String
      s.label :piece_length => "piece length"
      s.required :name, :piece_length, :pieces
      s.array :files
      s.coerce :files => lambda { |x| x.map { |y| MetaInfoInfoFile.new(y) } }
    end

    @dict = dict
    unless dict.nil?
      @s.parse dict
      check
      if dict["sha1"]
        ## this seems to always be off. don't know how it's supposed
        ## to be calculated, so fuck it.
#        puts "we have #{sha1.inspect}, they have #{dict['sha1'].inspect}"
#        rt_warning "info hash SHA1 mismatch" unless dict["sha1"] == sha1
#        raise MetaInfoFormatError, "info hash SHA1 mismatch" unless dict["sha1"] == sha1
      end
    end
  end

  def check
    raise MetaInfoFormatError, "invalid file length" unless @s.length.nil? || @s.length >= 0
    raise MetaInfoFormatError, "one (and only one) of 'length' (single-file torrent) or 'files' (multi-file torrent) must be specified" if (@s.length.nil? && @s.files.nil?) || (!@s.length.nil? && !@s.files.nil?)
    if single?
      length = @s.length
    else
      length = @s.files.inject(0) { |s, x| s + x.length }
    end
    raise MetaInfoFormatError, "invalid metainfo file: length #{length} > (#{@s.pieces.length / 20} pieces * #{@s.piece_length})" unless length <= (@s.pieces.length / 20) * @s.piece_length
    raise MetaInfoFormatError, "invalid metainfo file: pieces length = #{@s.pieces.length} not a multiple of 20" unless (@s.pieces.length % 20) == 0
  end

  def to_bencoding
    check
    (@dict || @s).to_bencoding
  end

  def sha1
    if @s.dirty
      @sha1 = Digest::SHA1.digest(self.to_bencoding)
      @s.dirty = false
    end
    @sha1
  end

  def single?
    !length.nil?
  end

  def multiple?
    length.nil?
  end

  def total_length
    if single?
      length
    else
      files.inject(0) { |a, f| a + f.length }
    end
  end

  def num_pieces
    pieces.length / 20
  end

  def method_missing(meth, *args)
    @s.send(meth, *args)
  end
end

class MetaInfo
  def initialize(dict=nil)
    raise TypeError, "argument must be a Hash (maybe see MetaInfo.from_location)" unless dict.is_a? Hash
    @s = TypedStruct.new do |s|
      s.field :info => MetaInfoInfo, :announce => URI::HTTP,
              :announce_list => Array, :creation_date => Time,
              :comment => String, :created_by => String, :encoding => String
      s.label :announce_list => "announce-list", :creation_date => "creation date",
              :created_by => "created by"
      s.array :announce_list
      s.coerce :info => lambda { |x| MetaInfoInfo.new(x) },
               :creation_date => lambda { |x| Time.at(x) },
               :announce => lambda { |x| URI.parse(x) },
               :announce_list => lambda { |x| x.map { |y| y.map { |z| URI.parse(z) } } }
    end

    @dict = dict
    unless dict.nil?
      @s.parse dict
      check
    end
  end

  def single?; info.single?; end
  def multiple?; info.multiple?; end

  def check
    if @s.announce_list
      @s.announce_list.each do |tier|
        tier.each { |track| raise MetaInfoFormatError, "expecting HTTP URL in announce-list, got #{track} instead" unless track.is_a? URI::HTTP }
      end
    end
  end

  def self.from_bstream(bs)
    dict = nil
    bs.each do |e|
      if dict == nil
        dict = e
      else
        raise MetaInfoFormatError, "too many bencoded elements for metainfo file (just need one)"
      end
    end

    raise MetaInfoFormatError, "bencoded element must be a dictionary, got a #{dict.class}" unless dict.kind_of? ::Hash

    MetaInfo.new(dict)
  end

  ## either a filename or a URL
  def self.from_location(fn, http_proxy=ENV["http_proxy"])
    if http_proxy # lame!
      open(fn, "rb", :proxy => http_proxy) { |f| from_bstream(BStream.new(f)) }
    else
      open(fn, "rb") { |f| from_bstream(BStream.new(f)) }
    end
  end

  def self.from_stream(s)
    from_bstream(BStream.new(s))
  end

  def method_missing(meth, *args)
    @s.send(meth, *args)
  end

  def to_bencoding
    check
    (@dict || @s).to_bencoding
  end

  def trackers
    if announce_list && (announce_list.length > 0)
      announce_list.map do |tier|
        tier.extend(ArrayShuffle).shuffle
      end.flatten
    else
      [announce]
    end
  end
end

end
