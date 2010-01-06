## peer.rb -- bitttorrent peer ("wire") protocol.
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

require 'socket'
require 'thread'
require "rubytorrent/message"

module RubyTorrent

module ArrayToBitstring
  def to_bitstring
    ret = "\0"
    bit = 7
    map do |b|
      if bit == -1
        ret += "\0"
        bit = 7
      end
      ret[ret.length - 1] |= (1 << bit) if b
      bit -= 1
    end
    ret
  end
end

module ArrayDelete2
  ## just like delete but returns the *array* element deleted rather
  ## than the argument. someone should file an rcr.
  def delete2(el)
    i = index el
    unless i.nil?
      ret = self[i]
      delete_at i
      ret
    else
      nil
    end
  end
end

module StringToBarray
  include StringMapBytes
  def to_barray
    self.map_bytes do |b|
      (0 .. 7).map { |i| (b & (1 << (7 - i))) != 0 }
    end.flatten
  end
end

## estimate a rate. basically copied from bram's code.
class RateMeter
  attr_reader :amt

  def initialize(window=20)
    @window = window.to_f
    @amt = 0
    @rate = 0
    @last = @since = Time.now - 1
    @m = Mutex.new
  end

  def add(new_amt)
    now = Time.now
    @m.synchronize do
      @amt += new_amt
      @rate = ((@rate * (@last - @since)) + new_amt).to_f / (now - @since)
      @last = now
      @since = [@since, now - @window].max
    end
  end

  def rate
    (@rate * (@last - @since)).to_f / (Time.now - @since)
  end

  def bytes_until(new_rate)
    [(new_rate.to_f * (Time.now - @since)) - (@rate * (@last - @since)), 0].max
  end
end

class ProtocolError < StandardError; end

## The PeerConnection object deals with all the protocol issues. It
## keeps state information as to the connection and the peer. It is
## tightly integrated with the Controller object.
##
## Remember to be "strict in what you send, lenient in what you
## accept".
class PeerConnection
  extend AttrReaderQ
  include EventSource

  attr_reader :peer_pieces, :name
  attr_reader_q :running, :choking, :interested, :peer_choking,
                :peer_interested, :snubbing
  event :peer_has_piece, :peer_has_pieces, :received_block, :sent_block,
        :requested_block

  BUFSIZE = 8192
  MAX_PEER_REQUESTS = 5 # how many peer requests to keep queued
  MAX_REQUESTS = 5 # how many requests for blocks to keep current
  MIN_REQUESTS = 1 # get more blocks from controller when this limit is reached
  REQUEST_TIMEOUT = 60 # number of seconds after sending a request before we
                       # decide it's been forgotten

  def initialize(name, controller, socket, package)
    @name = name
    @controller = controller
    @socket = socket
    @package = package
    @running = false

    ## my state
    @want_blocks = [].extend(ArrayDelete2) # blocks i want
    @want_blocks_m = Mutex.new
    @choking = true
    @interested = false
    @snubbing = false

    ## peer's state
    @peer_want_blocks = [].extend(ArrayDelete2)
    @peer_choking = true # assumption of initial condition
    @peer_interested = false # ditto
    @peer_pieces = Array.new(@package.num_pieces, false) # ditto
    @peer_virgin = true # does the peer have any pieces at all?

    ## connection stats
    @dlmeter = RateMeter.new
    @ulmeter = RateMeter.new

    @send_q = Queue.new # output thread takes messages from here and
                        # puts them on the wire
  end

  def pending_recv; @want_blocks.find_all { |b| b.requested? }.length; end
  def pending_send; @peer_want_blocks.length; end

  def start
    @running = true
    @time = {:start => Time.now}

    Thread.new do # start input thread
      begin
        while @running; input_thread_step; end
      rescue SystemCallError, IOError, ProtocolError => e
        rt_debug "#{self} (input): #{e.message}, releasing #{@want_blocks.length} claimed blocks and dying"
#        rt_debug e.backtrace.join("\n")
        @running = false
        @controller.forget_blocks @want_blocks
      end
    end

    Thread.new do # start output thread
      begin
        while @running; output_thread_step; end
      rescue SystemCallError, IOError, ProtocolError => e
        rt_debug "#{self} (output): #{e.message}, releasing #{@want_blocks.length} claimed blocks and dying"
#        rt_debug e.backtrace.join("\n")
        @running = false
        @controller.forget_blocks @want_blocks
      end
    end

    ## queue the initial messages
    queue_message(:bitfield, {:bitfield => @package.pieces.map { |p| p.complete? }.extend(ArrayToBitstring).to_bitstring})

    ## and that's it. if peer sends a bitfield, we'll send an
    ## interested and start requesting blocks at that point.  if they
    ## don't, it means they don't have any pieces, so we can just sit
    ## tight.
    self
  end

  ## the Controller calls this from heartbeat thread to tell us
  ## whether to choke or not.
  def choke=(now_choke)
    queue_message(now_choke ? :choke : :unchoke) unless @choking == now_choke
    @choking = now_choke
  end

  ## the Controller calls this from heartbeat thread to tell us
  ## whether to snub or not.
  def snub=(now_snub)
    unless @snubbing = now_snub
      @snubbing = now_snub
      choke = true if @snubbing
    end
  end

  def peer_complete?; @peer_pieces.all?; end
  def last_send_time; @time[:send]; end
  def last_recv_time; @time[:recv]; end
  def last_send_block_time; @time[:send_block]; end
  def last_recv_block_time; @time[:recv_block]; end
  def start_time; @time[:start]; end
  def dlrate; @dlmeter.rate; end
  def ulrate; @ulmeter.rate; end
  def dlamt; @dlmeter.amt; end
  def ulamt; @ulmeter.amt; end
  def piece_available?(index); @peer_pieces[index]; end
  def to_s; "<peer: #@name>"; end

  ## called by Controller in the event that a request needs to be
  ## rescinded.
  def cancel(block)
    wblock = @want_blocks_m.synchronize { @want_blocks.delete2 block }
    unless wblock.nil? || !wblock.requested?
      rt_debug "#{self}: sending cancel for #{wblock}"
      queue_message(:cancel, {:index => wblock.pindex, :begin => wblock.begin,
                              :length => wblock.length})
    end
    get_want_blocks unless wblock.nil?
  end

  def shutdown
    rt_debug "#{self.to_s}: shutting down"
    @running = false
    @socket.close rescue nil
  end

  ## Controller calls this to tell us that a complete piece has been
  ## received.
  def have_piece(piece)
    queue_message(:have, {:index => piece.index})
  end

  ## Controller calls this to tell us to send a keepalive
  def send_keepalive
#    rt_debug "* sending keepalive!"
    queue_message(:keepalive)
  end

  ## this is called both by input_thread_step and by the controller's
  ## heartbeat thread. it sends as many pending blocks as it can while
  ## keeping the amount below 'ullim', and sends as many requests as
  ## it can while keeping the amount below 'dllim'.
  ## 
  ## returns the number of bytes requested and sent
  def send_blocks_and_reqs(dllim=nil, ullim=nil)
    sent_bytes = 0
    reqd_bytes = 0

    @want_blocks_m.synchronize do
      @want_blocks.each do |b|
#        puts "[][] #{self}: #{b} is #{b.requested? ? 'requested' : 'NOT requested'} and has time_elapsed of #{b.requested? ? b.time_elapsed.round : 'n/a'}s"
        if b.requested? && (b.time_elapsed > REQUEST_TIMEOUT)
          rt_warning "#{self}: for block #{b}, time elapsed since request is #{b.time_elapsed} > #{REQUEST_TIMEOUT}, assuming peer forgot about it"
          @want_blocks.delete b
          @controller.forget_blocks [b]
        end
      end
    end

    ## send :requests
    unless @peer_choking || !@interested
      @want_blocks_m.synchronize do
        @want_blocks.each do |b|
          break if dllim && (reqd_bytes >= dllim)
          next if b.requested?
          
          if @package.pieces[b.pindex].complete?
            # not sure that this will ever happen, but...
            rt_warning "#{self}: deleting scheduled block for already-complete piece #{b}"
            @want_blocks.delete b
            next
          end

          queue_message(:request, {:index => b.pindex, :begin => b.begin,
                                   :length => b.length})
          reqd_bytes += b.length
          b.requested = true
          b.mark_time
          send_event(:requested_block, b)
        end
      end
    end

    ## send blocks
#    rt_debug "sending blocks. choking? #@choking, choked? #@peer_choking, ul rate #{ulrate}b/s, limit #@ulmeterlim" unless @peer_want_blocks.empty?
    unless @choking || !@peer_interested
      while !@peer_want_blocks.empty?
        break if ullim && (sent_bytes >= ullim)
        if (b = @peer_want_blocks.shift)
          sent_bytes += b.length
          @send_q.push b
          @time[:send_block] = Time.now
          send_event(:sent_block, b)
        end
      end
    end

    get_want_blocks

    [reqd_bytes, sent_bytes]
  end

  private

  ## re-calculate whether we're interested or not. triggered by
  ## received :have and :bitfield messages.
  def recalc_interested
    show_interest = !@peer_virgin || (@package.pieces.detect do |p|
      !p.complete? && @peer_pieces[p.index]
    end) != nil

    queue_message(show_interest ? :interested : :uninterested) unless show_interest == @interested
    if ((@interested = show_interest) == false)
      @want_blocks_m.synchronize do
        @controller.forget_blocks @want_blocks
        @want_blocks.clear
      end
    end
  end

  ## take a message/block from the send_q and place it on the wire. blocking.
  def output_thread_step
    obj = @send_q.deq
    case obj
    when Message
#      rt_debug "output: sending message #{obj}" + (obj.id == :request ? " (request queue size #{@want_blocks.length})" : "")
      send_bytes obj.to_wire_form
      @time[:send] = Time.now
    when Block
#      rt_debug "output: sending block #{obj}"
      send_bytes Message.new(:piece, {:length => obj.length, :index => obj.pindex, :begin => obj.begin}).to_wire_form
      obj.each_chunk(BUFSIZE) { |c| send_bytes c }
      @time[:send] = Time.now
      @ulmeter.add obj.length
#      rt_debug "sent block #{obj} ul rate now #{(ulrate / 1024.0).round}kb/s"
    else
      raise "don't know what to do with #{obj}"
    end
  end

  ## take bits from the wire and respond to them. blocking.
  def input_thread_step
    case (obj = read_from_wire)
    when Block
      handle_block obj
    when Message
      handle_message obj
    else
      raise "don't know what to do with #{obj.inspect}"
    end

    ## to enable immediate response, if there are no rate limits,
    ## we'll send the blocks and reqs right here. otherwise, the
    ## controller will call this at intervals.
    send_blocks_and_reqs if @controller.dlratelim.nil? && @controller.ulratelim.nil?
  end

  ## take bits from the wire and make a message/block out of them. blocking.
  def read_from_wire
    len = nil
    while (len = recv_bytes(4).from_fbbe) == 0
      @time[:recv] = Time.now
#      rt_debug "* hey, a keepalive!"
    end

    id = recv_bytes(1)[0]

    if Message::WIRE_IDS[id] == :piece # add a block
      len -= 9
      m = Message.from_wire_form(id, recv_bytes(8))
      b = Block.new(m.index, m.begin, len)
      while len > 0
        thislen = [BUFSIZE, len].min
        b.add_chunk recv_bytes(thislen)
        len -= thislen
      end
      @time[:recv] = @time[:recv_block] = Time.now
      b
    else # add a message
      m = Message.from_wire_form(id, recv_bytes(len - 1))
#      rt_debug "input: read message #{m}"
      @time[:recv] = Time.now
      m
    end
  end

  def handle_block(block)
    wblock = @want_blocks_m.synchronize { @want_blocks.delete2 block }

    return rt_warning("#{self}: peer sent unrequested (possibly cancelled) block #{block}") if wblock.nil? || !wblock.requested?

    @dlmeter.add block.have_length
#    rt_debug "received block #{block}, dl rate now #{(dlrate / 1024.0).round}kb/s"

    piece = @package.pieces[block.pindex] # find corresponding piece
    piece.add_block block
    send_event(:received_block, block)
    get_want_blocks
  end

  def send_bytes(s)
    if s.nil?
      raise "can't send nil"
    elsif s.length > 0
      @socket.send(s, 0)
    end
  end

  def recv_bytes(len)
    if len < 0
      raise "can't recv negative bytes"
    elsif len == 0
      ""
    elsif len > 512 * 1024 # 512k
      raise ProtocolError, "read size too big."
    else
      r = ""
      zeros = 0
      while r.length < len
        x = @socket.recv(len - r.length)
        raise IOError, "zero bytes received" if x.length == 0
        r += x
      end
      r
    end
  end

  def handle_message(m)
    case m.id
    when :choke
#      rt_debug "#{self}: peer choking (was #{@peer_choking})"
      @peer_choking = true
      @want_blocks_m.synchronize do
        @controller.forget_blocks @want_blocks
        @want_blocks.clear
      end

    when :unchoke
#      rt_debug "#{self}: peer not choking (was #{@peer_choking})"
      @peer_choking = false

    when :interested
#      rt_debug "peer interested (was #{@peer_interested})"
      @peer_interested = true

    when :uninterested
#      rt_debug "peer not interested (was #{@peer_interested})"
      @peer_interested = false
      
    when :have
#      rt_debug "peer has piece #{m.index}"
      rt_warning "#{self}: peer already has piece #{m.index}" if @peer_pieces[m.index]
      @peer_pieces[m.index] = true
      @peer_virgin = false
      send_event(:peer_has_piece, m)
      recalc_interested

    when :bitfield
#      rt_debug "peer reports bitfield #{m.bitfield.inspect}"
      barray = m.bitfield.extend(StringToBarray).to_barray

      expected_pieces = @package.num_pieces - (@package.num_pieces % 8) + ((@package.num_pieces % 8) == 0 ? 0 : 8)
      raise ProtocolError, "invalid length in bitfield message (package has #{@package.num_pieces} pieces; bitfield should be size #{expected_pieces} but is #{barray.length} pieces)" unless barray.length == expected_pieces

      @peer_pieces.each_index { |i| @peer_pieces[i] = barray[i] }
      @peer_virgin = false
      send_event(:peer_has_pieces, barray)
      recalc_interested
      get_want_blocks

    when :request
      return rt_warning("#{self}: peer requests invalid piece #{m.index}") unless m.index < @package.num_pieces
      return rt_warning("#{self}: peer requests a block but we're choking") if @choking
      return rt_warning("#{self}: peer requests a block but isn't interested") unless @peer_interested
      return rt_warning("#{self}: peer requested too many blocks, ignoring") if @peer_want_blocks.length > MAX_PEER_REQUESTS

      piece = @package.pieces[m.index]
      return rt_warning("#{self}: peer requests unavailable block from piece #{piece}") unless piece.complete?

      @peer_want_blocks.push piece.get_complete_block(m.begin, m.length)

    when :piece
      raise "can't handle piece here"

    when :cancel
      b = Block.new(m.index, m.begin, m.length)
#      rt_debug "peer cancels #{b}"
      if @peer_want_blocks.delete2(b) == nil
        rt_warning "#{self}: peer wants to cancel unrequested block #{b}"
      end

    else
      raise "unknown message #{type}"
    end
  end

  ## queues a message for delivery. (for :piece messages, this
  ## transmits everything but the piece itself)
  def queue_message(id, args=nil)
    @send_q.push Message.new(id, args)
  end

  ## talks to Controller and get some new blocks to request. could be
  ## slow. this is presumably called whenever the queue of requests is
  ## too small.
  def get_want_blocks
    return if (@want_blocks.length >= MIN_REQUESTS) || @peer_virgin || @peer_choking || !@interested

    rej_count = 0
    acc_count = 0
    @controller.claim_blocks do |b|
      break if @want_blocks.length >= MAX_REQUESTS
      if @peer_pieces[b.pindex] && !@want_blocks.member?(b)
        rt_debug "! #{self}: starting new piece #{@package.pieces[b.pindex]}" unless @package.pieces[b.pindex].started?

#        rt_debug "#{self}: added to queue block #{b}"
#        puts "#{self}: claimed block #{b}"
        @want_blocks.push b
        acc_count += 1
        true
      else
#        puts "#{self}: cont offers block #{b} but peer has? #{@peer_pieces[b.pindex]} i already want? #{@want_blocks.member? b}" if rej_count < 10
        rej_count += 1
        false
      end
    end
 #   puts "#{self}: ... and #{rej_count} more (peer has #{@peer_pieces.inject(0) { |s, p| s + (p ? 1 : 0) }} pieces)... " if rej_count >= 10
#    puts "#{self}: accepted #{acc_count} blocks, rejected #{rej_count} blocks"
  end
end

end
