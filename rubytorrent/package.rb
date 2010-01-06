## package.rb -- RubyTorrent <=> filesystem interface.
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

require 'thread'
require 'digest/sha1'

## A Package is the connection between the network and the
## filesystem. There is one Package per torrent. Each Package is
## composed of one or more Pieces, as determined by the MetaInfoInfo
## object, and each Piece is composed of one or more Blocks, which are
## transmitted over the PeerConnection with :piece comments.

module RubyTorrent

## Range plus a lot of utility methods
class AwesomeRange < Range
  def initialize(start, endd=nil, exclude_end=false)
    case start
    when Integer
      raise ArgumentError, "both start and endd must be specified" if endd.nil?
      super(start, endd, exclude_end)
    when Range
      super(start.first, start.last, start.exclude_end?)
    else
      raise ArgumentError, "start should be an Integer or a Range, is a #{start.class}"
    end
  end

  ## range super-set: does this range encompass 'o'?
  def rss?(o)
    (first <= o.first) &&
      ((last > o.last) || (o.exclude_end? && (last == o.last)))
  end

  ## range intersection
  def rint(o)
    ## three cases. either:
    ## a) our left endpoint is within o
    if ((first >= o.first) &&
      ((first < o.last) || (!o.exclude_end? && (first == o.last))))
      if last < o.last
        AwesomeRange.new(first, last, exclude_end?)
      elsif last > o.last
        AwesomeRange.new(first, o.last, o.exclude_end?)
      else # ==
        AwesomeRange.new(first, last, exclude_end? || o.exclude_end?)
      end
    ## b) our right endpoint is within o
    elsif (((last > o.first) || (!exclude_end? && (last == o.first))) && ((last < o.last) || (!o.exclude_end? && (last == o.last))))
      AwesomeRange.new([first, o.first].max, last, exclude_end?)
    ## c) we encompass o
    elsif rss?(o)
      o
    else
      nil
    end
  end
  
  ## range continuity
  def rcont?(o)
    (first == o.last) || (last == o.first) || (rint(o) != nil)
  end

  ## range union: only valid for continuous ranges
  def runion(o)
    if last > o.last
      AwesomeRange.new([first, o.first].min, last, exclude_end?)
    elsif o.last > last
      AwesomeRange.new([first, o.first].min, o.last, o.exclude_end?)
    else # equal
      AwesomeRange.new([first, o.first].min, last, (exclude_end? && o.exclude_end?))
    end
  end

  ## range difference. returns an array of 0, 1 or 2 ranges.
  def rdiff(o)
    return [] if o == self
    ret = []
    int = rint o
    return [] if int == self
    return [self] if int == nil
    raise RangeError, "can't subtract a range that doesn't have an exclusive end" unless int.exclude_end?
    if int.first > first
      ret << AwesomeRange.new(first, int.first, true)
    end
    ret + [AwesomeRange.new(int.last, last, exclude_end?)]
  end
end

## a Covering is a set of non-overlapping ranges within a given start
## point and endpoint.
class Covering
  attr_accessor :domain, :ranges

  ## 'domain' should be an AwesomeRange determining the start and end
  ## point. 'ranges' should be an array of non-overlapping
  ## AwesomeRanges sorted by start point.
  def initialize(domain, ranges=[])
    @domain = domain
    @ranges = ranges
  end

  def complete!; @ranges = [@domain]; self; end
  def complete?; @ranges == [@domain]; end
  def empty!; @ranges = []; self; end
  def empty?; @ranges == []; end

  ## given a covering of size N and a new range 'r', returns a
  ## covering of size 0 <= s <= N + 1 that doesn't cover the range
  ## given by 'r'.
  def poke(r)
    raise ArgumentError, "#{r} outside of domain #@domain" unless @domain.rss? r
    Covering.new(@domain, @ranges.inject([]) do |set, x|
      if x.rint(r) != nil
        set + x.rdiff(r)
      else
        set + [x]
      end
    end)
  end

  ## given a covering of size N and a new range 'r', returns a
  ## covering of size 0 < s <= N + 1 that also covers the range 'r'.
  def fill(r)
    raise ArgumentError, "#{r} outside of domain #@domain" unless @domain.rss? r
    Covering.new(@domain, @ranges.inject([]) do |set, x|
      ## r contains the result of the continuing merge. if r is nil,
      ## then we've already added it, so we just copy x.
      if r.nil? then set + [x] else
        ## otoh, if r is there, we try and merge in the current
        ## element.
        if r.rcont? x
          ## if we can merge, keep the union in r and don't add
          ## anything
          r = r.runion x
          set
        ## if we can't merge it, we'll see if it's time to add it. we
        ## know that r and x don't overlap because r.mergable?(x) was
        ## false, so we can simply compare the start points to see
        ## whether it should come before x.
        elsif r.first < x.first
          s = set + [r, x] # add both 
          r = nil
          s
        else set + [x] ## no merging or adding, so we just copy x.
        end
      end
    ## if 'r' still hasn't been added, it should be the last element,
    ## we add it here.
    end.push(r).compact)
  end

  ## given an array of non-overlapping ranges sorted by start point,
  ## and a range 'domain', returns the first range from 'domain' not
  ## covered by any range in the array.
  def first_gap(domain=@domain)
    start = domain.first
    endd = nil
    excl = nil
    @ranges.each do |r|
      next if r.last < start

      if r.first > start # found a gap
        if r.first < domain.last
          return AwesomeRange.new(start, r.first, false)
        else # r.first >= domain.last, so use domain's exclusion
          return AwesomeRange.new(start, domain.last, domain.exclude_end?)
        end
      else # r.first <= start
        start = r.last unless r.last < start
        break if start > domain.last
      end
    end

    if (start >= domain.last)
      ## entire domain was covered
      nil
    else
      ## tail end of the domain uncovered
      AwesomeRange.new(start, domain.last, domain.exclude_end?)
    end
  end

  def ==(o); o.domain == self.domain && o.ranges == self.ranges; end
end

## Blocks are very simple chunks of data which exist solely in
## memory. they are the basic currency of the bittorrent protocol. a
## Block can be divided into "chunks" (no intelligence there; it's
## solely for the purposes of buffered reading/writing) and one or
## more Blocks comprises a Piece.
class Block
  attr_accessor :pindex, :begin, :length, :data, :requested

  def initialize(pindex, beginn, length)
    @pindex = pindex
    @begin = beginn
    @length = length
    @data = nil
    @requested = false
    @time = nil
  end

  def requested?; @requested; end
  def have_length; @data.length; end
  def complete?; @data && (@data.length == @length); end
  def mark_time; @time = Time.now; end
  def time_elapsed; Time.now - @time; end

  def to_s
    "<block: p[#{@pindex}], #@begin + #@length #{(data.nil? || (data.length == 0) ? 'emp' : (complete? ? 'cmp' : 'inc'))}>"
  end

  ## chunk can only be added to blocks in order
  def add_chunk(chunk)
    @data = "" if @data.nil?
    raise "adding chunk would result in too much data (#{@data.length} + #{chunk.length} > #@length)" if (@data.length + chunk.length) > @length
    @data += chunk
    self
  end

  def each_chunk(blocksize)
    raise "each_chunk called on incomplete block" unless complete?
    start = 0
    while(start < @length)
      yield data[start, [blocksize, @length - start].min]
      start += blocksize
    end
  end

  def ==(o)
    o.is_a?(Block) && (o.pindex == self.pindex) && (o.begin == self.begin) &&
      (o.length == self.length)
  end
end

## a Piece is the basic unit of the .torrent metainfo file (though not
## of the bittorrent protocol). Pieces store their data directly on
## disk, so many operations here will be slow. each Piece stores data
## in one or more file pointers.
##
## unlike Blocks and Packages, which are either complete or
## incomplete, a Piece can be complete but not valid, if the SHA1
## check fails. thus, a call to piece.complete? is not sufficient to
## determine whether the data is ok to use or not.
##
## Pieces handle all the trickiness involved with Blocks: taking in
## Blocks from arbitrary locations, writing them out to the correct
## set of file pointers, keeping track of which sections of the data
## have been filled, claimed but not filled, etc.
class Piece
  include EventSource

  attr_reader :index, :start, :length
  event :complete

  def initialize(index, sha1, start, length, files, validity_assumption=nil)
    @index = index
    @sha1 = sha1
    @start = start
    @length = length
    @files = files # array of [file pointer, mutex, file length]
    @valid = nil

    ## calculate where we start and end in terms of the file pointers.
    @start_index = 0
    sum = 0
    while(sum + @files[@start_index][2] <= @start)
      sum += @files[@start_index][2]
      @start_index += 1
    end
    ## now sum + @files[@start_index][2] > start, and sum <= start
    @start_offset = @start - sum

    ## sections of the data we have
    @have = Covering.new(AwesomeRange.new(0 ... @length)).complete!
    @valid = validity_assumption
    @have.empty! unless valid?

    ## sections of the data someone has laid claim to but hasn't yet
    ## provided. a super-set of @have.
    @claimed = Covering.new(AwesomeRange.new(0 ... @length))

    ## protects @claimed, @have
    @state_m = Mutex.new
  end

  def to_s
    "<piece #@index: #@start + #@length #{(complete? ? 'cmp' : 'inc')}>"
  end

  def complete?; @have.complete?; end
  def started?; !@claimed.empty? || !@have.empty?; end

  def discard # discard all data
    @state_m.synchronize do
      @have.empty!
      @claimed.empty!
    end
    @valid = false
  end

  def valid?
    return @valid unless @valid.nil?
    return (@valid = false) unless complete?

    data = read_bytes(0, @length)
    if (data.length != @length)
      @valid = false
    else
      @valid = (Digest::SHA1.digest(data) == @sha1)
    end
  end

  def unclaimed_bytes
    r = 0
    each_gap(@claimed) { |start, len| r += len }
    r
  end

  def empty_bytes
    r = 0
    each_gap(@have) { |start, len| r += len }
    r
  end

  def percent_claimed; 100.0 * (@length.to_f - unclaimed_bytes) / @length; end
  def percent_done; 100.0 * (@length.to_f - empty_bytes) / @length; end

  def each_unclaimed_block(max_length)
    raise "no unclaimed blocks in a complete piece" if complete?

    each_gap(@claimed, max_length) do |start, len|
      yield Block.new(@index, start, len)
    end
  end

  def each_empty_block(max_length)
    raise "no empty blocks in a complete piece" if complete?

    each_gap(@have, max_length) do |start, len|
      yield Block.new(@index, start, len)
    end
  end

  def claim_block(b)
    @state_m.synchronize do
      @claimed = @claimed.fill AwesomeRange.new(b.begin ... (b.begin + b.length))
    end
  end

  def unclaim_block(b)
    @state_m.synchronize do
      @claimed = @claimed.poke AwesomeRange.new(b.begin ... (b.begin + b.length))
    end
  end

  ## for a complete Piece, returns a complete Block of specified size
  ## and location.
  def get_complete_block(beginn, length)
    raise "can't make block from incomplete piece" unless complete?
    raise "invalid parameters #{beginn}, #{length}" unless (length > 0) && (beginn + length) <= @length

    b = Block.new(@index, beginn, length)
    b.add_chunk read_bytes(beginn, length) # returns b
  end

  ## we don't do any checking that this block has been claimed or not.
  def add_block(b)
    @valid = nil
    write = false
    new_have = @state_m.synchronize { @have.fill AwesomeRange.new(b.begin ... (b.begin + b.length)) }
    if new_have != @have
      @have = new_have
      write = true
    end
    
    write_bytes(b.begin, b.data) if write
    send_event(:complete) if complete?
  end

  private

  ## yields successive gaps from 'array' between 0 and @length
  def each_gap(covering, max_length=nil)
    return if covering.complete?

    range_first = 0
    while true
      range = covering.first_gap(range_first ... @length)
      break if range.nil? || (range.first == range.last)
      start = range.first

      while start < range.last
        len = range.last - start
        len = max_length if max_length && (max_length < len)
        yield start, len
        start += len
      end

      range_first = range.last
    end
  end

  def write_bytes(start, data); do_bytes(start, 0, data); end
  def read_bytes(start, length); do_bytes(start, length, nil); end

  ## do the dirty work of splitting the read/writes across multiple
  ## file pointers to possibly incomplete, possibly overcomplete files
  def do_bytes(start, length, data)
    raise ArgumentError, "invalid start" if (start < 0) || (start > @length)
#    raise "invalid length" if (length < 0) || (start + length > @length)

    start += @start_offset
    index = @start_index
    sum = 0
    while(sum + @files[index][2] <= start)
      sum += @files[index][2]
      index += 1
    end
    offset = start - sum

    done = 0
    abort = false
    if data.nil?
      want = length
      ret = ""
    else
      want = data.length
      ret = 0
    end
    while (done < want) && !abort
      break if index > @files.length
      fp, mutex, size = @files[index]
      mutex.synchronize do
        fp.seek offset
        here = [want - done, size - offset].min
        if data.nil?
#          puts "> reading #{here} bytes from #{index} at #{offset}"
          s = fp.read here
#          puts "> got #{(s.nil? ? s.inspect : s.length)} bytes"
          if s.nil?
            abort = true
          else
            ret += s
            abort = true if s.length < here
#            puts "fp.tell is #{fp.tell}, size is #{size}, eof #{fp.eof?}"
            if (fp.tell == size) && !fp.eof?
              rt_warning "file #{index}: not at eof after #{size} bytes, truncating"
              fp.truncate(size - 1)
            end
          end
        else
#          puts "> writing #{here} bytes to #{index} at #{offset}"
          x = fp.write data[done, here]
          ret += here
#          @files[index][0].flush
        end
        done += here
      end
      index += 1
      offset = 0
    end

    ret
  end
end

## finally, the Package. one Package per Controller so we don't do any
## thread safety stuff in here.
class Package
  include EventSource

  attr_reader :pieces, :size
  event :complete

  def initialize(metainfo, out=nil, validity_assumption=nil)
    info = metainfo.info

    created = false
    out ||= info.name
    case out
    when File
      raise ArgumentError, "'out' cannot be a File for a multi-file .torrent" if info.multiple?
      fstream = out
    when Dir
      raise ArgumentError, "'out' cannot be a Dir for a single-file .torrent" if info.single?
      fstream = out
    when String
      if info.single?
        rt_debug "output file is #{out}"
        begin
          fstream = File.open(out, "rb+")
        rescue Errno::ENOENT
	  created = true
          fstream = File.open(out, "wb+")
        end
      else
        rt_debug "output directory is #{out}"
        unless File.exists? out
          Dir.mkdir(out)
          created = true
        end
        fstream = Dir.open(out)
      end
    else
      raise ArgumentError, "'out' should be a File, Dir or String object, is #{out.class}"
    end

    @ro = false
    @size = info.total_length
    if info.single?
      @files = [[fstream, Mutex.new, info.length]]
    else
      @files = info.files.map do |finfo|
        path = File.join(finfo.path[0, finfo.path.length - 1].inject(fstream.path) do |path, el|
          dir = File.join(path, el)
          unless File.exist? dir
            rt_debug "making directory #{dir}"
            Dir.mkdir dir
          end
          dir
        end, finfo.path[finfo.path.length - 1])
        rt_debug "opening #{path}..."
        [open_file(path), Mutex.new, finfo.length]
      end
    end

    i = 0
    @pieces = info.pieces.unpack("a20" * (info.pieces.length / 20)).map do |hash|
      start = (info.piece_length * i)
      len = [info.piece_length, @size - start].min
      p = Piece.new(i, hash, start, len, @files, (created ? false : validity_assumption))
      p.on_event(self, :complete) { send_event(:complete) if complete? }
      yield p if block_given?
      (i += 1) && p
    end

    reopen_ro if complete?
  end

  def ro?; @ro; end
  def reopen_ro
    raise "called on incomplete package" unless complete?
    return if @ro
    
    rt_debug "reopening all files with mode r"
    @files = @files.map do |fp, mutex, size|
      [fp.reopen(fp.path, "rb"), mutex, size]
    end
    @ro = true
  end

  def complete?; @pieces.detect { |p| !p.complete? || !p.valid? } == nil; end

  def bytes_completed
    @pieces.inject(0) { |s, p| s + (p.complete? ? p.length : 0) }
  end

  def pieces_completed
    @pieces.inject(0) { |s, p| s + (p.complete? ? 1 : 0) }
  end

  def percent_completed
    100.0 * pieces_completed.to_f / @pieces.length.to_f
  end

  def num_pieces; @pieces.length; end

  def to_s
    "<#{self.class} size #@size>"
  end

  private

  def open_file(path)
    begin
      File.open(path, "rb+")
    rescue Errno::ENOENT
      File.open(path, "wb+")
    end
  end
end

end
