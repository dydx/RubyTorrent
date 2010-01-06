## controller.rb -- cross-peer logic.
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

module RubyTorrent

## keeps pieces in order
class PieceOrder
  POP_RECALC_THRESH = 20 # popularity of all pieces is recalculated
                         # (expensive sort) when this number of pieces
                         # have arrived at any of the peers, OR:
  POP_RECALC_LIMIT = 30 # ... when this many seconds have passed when
                        # at least one piece has changed in
                        # popularity, or if we're in fuseki mode.
  def initialize(package)
    @package = package
    @order = nil
    @num_changed = 0
    @pop = Array.new(@package.pieces.length, 0)
    @jitter = Array.new(@package.pieces.length) { rand }
    @m = Mutex.new
    @last_recalc = nil
  end

  ## increment the popularity of a piece
  def inc(i) 
    @m.synchronize do
      @pop[i.to_i] += 1
      @num_changed += 1
    end
  end

  ## increment the popularity of multiple pieces
  def inc_all(bitfield, inc=1)
    @m.synchronize do
      bitfield.each_index do |i| 
        if bitfield[i]
          @pop[i] += inc
          @num_changed += 1
        end
      end
    end
  end

  def dec_all(bitfield)
    inc_all(bitfield, -1)
  end

  def each(in_fuseki, num_peers)
    if (@num_changed > POP_RECALC_THRESH) || @last_recalc.nil? || (((@num_changed > 0) || in_fuseki) && ((Time.now - @last_recalc) > POP_RECALC_LIMIT))
      rt_debug "* reordering pieces: (#@num_changed changed, last recalc #{(@last_recalc.nil? ? '(never)' : (Time.now - @last_recalc).round)}s ago)..."
      recalc_order(in_fuseki, num_peers)
    end

    @order.each { |i| yield i }
  end

  private

  def recalc_order(in_fuseki, num_peers)
    @m.synchronize do
      @num_changed = 0
      @order = (0 ... @pop.length).sort_by do |i|
        p = @package.pieces[i]
        @jitter[i] +
          if p.started? && !p.complete? # always try to complete a started piece
            pri = -1 + p.unclaimed_bytes.to_f / p.length
            rt_debug "   piece #{i} is started but not completed => priority #{pri} (#{p.percent_claimed.round}% claimed, #{p.percent_done.round}% done)"
            pri
          elsif p.complete? # don't need these
#            puts "   piece #{i} is completed => #{@pop.length}"
            @pop.length # a big number
          elsif in_fuseki # distance from (# peers) / 2
#            puts "     piece #{i} has fuseki score #{(@pop[i] - (num_peers / 2)).abs}"
            (@pop[i] - (num_peers / 2)).abs
          else
#            puts "     piece #{i} has popularity #{@pop[i]}"
            @pop[i]
          end
      end
    end
    @last_recalc = Time.now
    rt_debug "* new piece priority: " + @order[0...15].map { |x| x.to_s }.join(', ') + " ..."
  end
end

## The Controller manages all PeerConnections for a single Package. It
## instructs them to request blocks, and tells them whether to choke
## their connections or not. It also reports progress to the tracker.
##
## Incoming, post-handshake peer connections are added by the Server
## via calling add_connection; deciding to accept these is the
## Controller's responsibility, as is connecting to any new peers.
class Controller
  include EventSource
  extend AttrReaderQ, MinIntervalMethods

  ## general behavior parameters
  HEARTBEAT = 5 # seconds between iterations of the heartbeat
  MAX_PEERS = 15 # hard limit on the number of peers
  ENDGAME_PIECE_THRESH = 5  # (wild guess) number of pieces remaining
                            # before we trigger end-game mode
  FUSEKI_PIECE_THRESH = 2 # number of pieces we must have before
                          # getting out of fuseki mode. in fuseki
                          # ("opening", if you're not a weiqi/go fan)
                          # mode, rather than ranking pieces by
                          # rarity, we rank them by how distant their
                          # popularity is from (# peers) / 2, and we're
                          # also stingly in handing out requests.
  SPAWN_NEW_PEER_THRESH = 0.75 # portion of the download rate above
                               # which we'll stop making new peer
                               # connections
  RATE_WINDOW = 20 # window size (in seconds) of the rate calculation.
                   # presumably this should be the same as the window
                   # used in the RateMeter class.

  ## tracker parameters. when we can't access a tracker, we retry at
  ## DEAD_TRACKER_INITIAL_DELAY seconds and double that after every
  ## failure, capping at DEAD_TRACKER_MAX_DELAY.
  DEAD_TRACKER_INITIAL_INTERVAL = 5
  DEAD_TRACKER_MAX_INTERVAL = 3600

  ## single peer parameters
  KEEPALIVE_INTERVAL = 120 # seconds of silence before sending a keepalive
  SILENT_DEATH_INTERVAL = 240 # seconds of silence before we drop a peer
  BOREDOM_DEATH_INTERVAL = 120 # seconds of existence with no downloaded data
                               # at which we drop a peer in favor of
                               # an incoming peer (unless the package
                               # is complete)

  BLOCK_SIZE = 2**15 # send this size blocks. need to find out more
                     # about this parameter: how does it affect
                     # transfer rates?

  ## antisnubbing
  ANTISNUB_RATE_THRESH = 1024 # if the total bytes/second across all
                              # peers falls below this threshold, we
                              # trigger anti-snubbing mode
  ANTISNUB_INTERVAL = 60 # seconds of no blocks from a peer before we
                         # add an optimistic unchoke slot when in
                         # anti-snubbing mode.

  ## choking and optimistic unchoking parameters
  NUM_FRIENDS = 4 # number of peers unchoked due to high download rates
  CALC_FRIENDS_INTERVAL = 10 # seconds between recalculating choked
                             # status for each peer
  CALC_OPTUNCHOKES_INTERVAL = 30 # seconds between reassigning
                                 # optimistic unchoked status
  NUM_OPTUNCHOKES = 1  # number of optimistic unchoke slots
                       # (not including any temporary ones
                       # generated in anti-snubbing mode.
  NEW_OPTUNCHOKE_PROB = 0.5 # peers are ranked by the age of
                                    # their connection, and optimistic
                                    # unchoking slots are given with
                                    # probability p*(1-p)^r, where r
                                    # is the rank and p is this number.

  attr_accessor :package, :info_hash, :tracker, :ulratelim, :dlratelim,
                :http_proxy
  attr_reader_q :running
  event :trying_peer, :forgetting_peer, :added_peer, :removed_peer,
        :received_block, :sent_block, :have_piece, :discarded_piece,
        :tracker_connected, :tracker_lost, :requested_block

  def initialize(server, package, info_hash, trackers, dlratelim=nil, ulratelim=nil, http_proxy=ENV["http_proxy"])
    @server = server
    @info_hash = info_hash
    @package = package
    @trackers = trackers
    @http_proxy = http_proxy

    @dlratelim = dlratelim
    @ulratelim = ulratelim

    @peers = [].extend(ArrayShuffle)
    @peers_m = Mutex.new
    @thread = nil

    @tracker = nil
    @last_tracker_attempt = nil
    @tracker_delay = DEAD_TRACKER_INITIAL_INTERVAL

    ## friends
    @num_friends = 0
    @num_optunchokes = 0
    @num_snubbed = 0

    ## keep track of the popularity of the pieces so as to assign
    ## blocks optimally to peers.
    @piece_order = PieceOrder.new @package

    @running = false
  end

  def dlrate; @peers.inject(0) { |s, p| s + p.dlrate }; end
  def ulrate; @peers.inject(0) { |s, p| s + p.ulrate }; end
  def dlamt; @peers.inject(0) { |s, p| s + p.dlamt }; end
  def ulamt; @peers.inject(0) { |s, p| s + p.ulamt }; end
  def num_peers; @peers.length; end

  def start
    raise "already" if @running

    find_tracker

    @in_endgame = false
    @in_antisnub = false
    @in_fuseki = false
    @running = true
    @thread = Thread.new do
      while @running
        step
        sleep HEARTBEAT
      end
    end

    @peers.each { |p| p.start unless p.running? }

    self
  end

  def shutdown
    @running = false
    @tracker.stopped unless @tracker.nil? rescue TrackerError
    @thread.join(0.2)
    @peers.each { |c| c.shutdown }
    self
  end

  def to_s
    "<#{self.class}: package #{@package}>"
  end

  ## this could be called at any point by the Server, if it receives
  ## incoming peer connections.
  def add_peer(p)
    accept = true

    if @peers.length >= MAX_PEERS && !@package.complete?
      oldp = @peers.find { |x| !x.running? || ((x.dlamt == 0) && ((Time.now - x.start_time) > BOREDOM_DEATH_INTERVAL)) }

      if oldp
        rt_debug "killing peer for being boring: #{oldp}" 
        oldp.shutdown
      else
        rt_debug "too many peers, ignoring #{p}"
        p.shutdown
        accept = false
      end
    end

    if accept
      p.on_event(self, :received_block) { |peer, block| received_block(block, peer) }
      p.on_event(self, :peer_has_piece) { |peer, piece| peer_has_piece(piece, peer) }
      p.on_event(self, :peer_has_pieces) { |peer, bitfield| peer_has_pieces(bitfield, peer) }
      p.on_event(self, :sent_block) { |peer, block| send_event(:sent_block, block, peer.name) }
      p.on_event(self, :requested_block) { |peer, block| send_event(:requested_block, block, peer.name) }

      @peers_m.synchronize do
        @peers.push p
        ## it's important not to call p.start (which triggers the
        ## bitfield message) until it's been added to @peer, such that
        ## any :have messages that might happen from other peers in
        ## the mean time are propagated to it.
        ##
        ## of course that means we need to call p.start within the
        ## mutex context so that the reaper section of the heartbeat
        ## doesn't kill it between push and start.
        ##
        ## ah, the joys of threaded programming.
        p.start if @running
      end

      send_event(:added_peer, p.name)
    end
  end

  def received_block(block, peer)
    if @in_endgame
      @peers_m.synchronize { @peers.each { |p| p.cancel block if p.running? && (p != peer)} }
    end
    send_event(:received_block, block, peer.name)

    piece = @package.pieces[block.pindex] # find corresponding piece
    if piece.complete?
      if piece.valid?
        @peers_m.synchronize { @peers.each { |peer| peer.have_piece piece } }
        send_event(:have_piece, piece)
      else
        rt_warning "#{self}: received data for #{piece} does not match SHA1 hash, discarding"
        send_event(:discarded_piece, piece)
        piece.discard
      end
    end
  end

  def peer_has_piece(piece, peer)
    @piece_order.inc piece.index
  end

  def peer_has_pieces(bitfield, peer)
    @piece_order.inc_all bitfield
  end

  ## yield all desired blocks, in order of desire. called by peers to
  ## refill their queues.
  def claim_blocks
    @piece_order.each(@in_fuseki, @peers.length) do |i|
      p = @package.pieces[i]
      next if p.complete?
#      rt_debug "+ considering piece #{p}"
      if @in_endgame
        p.each_empty_block(BLOCK_SIZE) { |b| yield b }
      else
        p.each_unclaimed_block(BLOCK_SIZE) do |b|
          if yield b
            p.claim_block b
            return if @in_fuseki # fuseki shortcut
          end
        end
      end
    end
  end

  def forget_blocks(blocks)
#    rt_debug "#{self}: forgetting blocks #{blocks.join(', ')}"
    blocks.each { |b| @package.pieces[b.pindex].unclaim_block b }
  end

  def peer_info
    @peers.map do |p|
      next nil unless p.running?
      {:name => p.name, :seed => p.peer_complete?,
       :dlamt => p.dlamt, :ulamt => p.ulamt,
       :dlrate => p.dlrate, :ulrate => p.ulrate,
       :pending_send => p.pending_send, :pending_recv => p.pending_recv,
       :interested => p.interested?, :peer_interested => p.peer_interested?,
       :choking => p.choking?, :peer_choking => p.peer_choking?,
       :snubbing => p.snubbing?,
       :we_desire => @package.pieces.inject(0) do |s, piece|
          s + (!piece.complete? && p.piece_available?(piece.index) ? 1 : 0)
        end,
       :they_desire => @package.pieces.inject(0) do |s, piece|
          s + (piece.complete? && !p.piece_available?(piece.index) ? 1 : 0)
        end,
       :start_time => p.start_time
      }
    end.compact
  end

  private

  def find_tracker
    return if @tracker || (@last_tracker_attempt && (Time.now - @last_tracker_attempt) < @tracker_delay)

    @last_tracker_attempt = Time.now
    Thread.new do
      @trackers.each do |tracker|
        break if @tracker
        rt_debug "trying tracker #{tracker}"
        tc = TrackerConnection.new(tracker, @info_hash, @package.size, @server.port, @server.id, nil, 50, @http_proxy)
        begin
          @tracker = tc.started
          tc.already_completed if @package.complete?
          @tracker_delay = DEAD_TRACKER_INITIAL_INTERVAL
          send_event(:tracker_connected, tc.url)
        rescue TrackerError => e
          rt_debug "couldn't connect: #{e.message}"
        end
      end
    end

    @tracker_delay = [@tracker_delay * 2, DEAD_TRACKER_MAX_INTERVAL].min if @tracker.nil?
    rt_warning "couldn't connect to tracker, next try in #@tracker_delay seconds" if @tracker.nil?
  end

  def add_a_peer
    return false if @tracker.nil? || (@peers.length >= MAX_PEERS) || @package.complete? || (@num_friends >= NUM_FRIENDS) || (@dlratelim && (dlrate > (@dlratelim * SPAWN_NEW_PEER_THRESH)))

    @tracker.peers.shuffle.each do |peer|
#        rt_debug "]] comparing: #{peer.ip} vs #{@server.ip} and #{peer.port} vs #{@server.port} (tried? #{peer.tried?})"
      next if peer.tried? || ((peer.ip == @server.ip) && (peer.port == @server.port)) rescue next

      peername = "#{peer.ip}:#{peer.port}"
      send_event(:trying_peer, peername)

      Thread.new do # this may ultimately result in a call to add_peer
        sleep rand(10)
        rt_debug "=> making outgoing connection to #{peername}"
        begin
          peer.tried = true
          socket = TCPSocket.new(peer.ip, peer.port)
          @server.add_connection(peername, self, socket)
        rescue SocketError, SystemCallError, Timeout::Error => e
          rt_debug "couldn't connect to #{peername}: #{e}"
          send_event(:forgetting_peer, peername)
        end
      end
      break
    end
    true
  end

  def refresh_tracker
    return if @tracker.nil?

    @tracker.downloaded = dlamt
    @tracker.uploaded = ulamt
    @tracker.left = @package.size - @package.bytes_completed
    begin
      @tracker.refresh
    rescue TrackerError
      send_event(:tracker_lost, @tracker.url)
      @tracker = nil
      find_tracker # find a new one
    end
  end

  def calc_friends
    @num_friends = 0

    if @package.complete?
      @peers.sort_by { |p| -p.ulrate }.each do |p|
        next if p.snubbing? || !p.running?
        p.choke = (@num_friends >= NUM_FRIENDS)
        @num_friends += 1 if p.peer_interested?
      end
    else
      @peers.sort_by { |p| -p.dlrate }.each do |p|
        next if p.snubbing? || !p.running?
        p.choke = (@num_friends >= NUM_FRIENDS)
        @num_friends += 1 if p.peer_interested?
      end
    end
  end
  min_interval :calc_friends, CALC_FRIENDS_INTERVAL

  def calc_optunchokes
    rt_debug "* calculating optimistic unchokes..."
    @num_optunchokes = 0

    if @in_antisnub
      ## count up the number of our fair weather friends: peers who
      ## are interested and whom we're not choking, but who haven't
      ## sent us a block for ANTISNUB_INTERVAL seconds. for each of
      ## these, we add an extra optimistic unchoking slot to our usual
      ## NUM_OPTUNCHOKES slots. in actuality that's the number of
      ## friends PLUS the number of optimistic unchokes who are
      ## snubbing us, but that's not a big deal, as long as we cap the
      ## number of extra slots at NUM_FRIENDS.
      @num_optunchokes -= @peers.inject(0) { |s, p| s + (p.running? && p.peer_interested? && !p.choking? && (Time.now - (p.last_recv_block_time || p.start_time) > ANTISNUB_INTERVAL) ? 1 : 0) }
      @num_optunchokes = [-NUM_FRIENDS, @num_optunchokes].max
      rt_debug "* anti-snubbing mode, #{-@num_optunchokes} extra optimistic unchoke slots"
    end

    ## i love ruby
    @peers.find_all { |p| p.running? }.sort_by { |p| p.start_time }.reverse.each do |p|
      break if @num_optunchokes >= NUM_OPTUNCHOKES
      next if p.snubbing?
#      rt_debug "* considering #{p}: #{p.peer_interested?} and #{@num_optunchokes < NUM_OPTUNCHOKES} and #{rand(0.999) < NEW_OPTUNCHOKE_PROB}"
      if p.peer_interested? && (rand < NEW_OPTUNCHOKE_PROB)
        rt_debug "  #{p}: awarded optimistic unchoke"
        p.choke = false
        @num_optunchokes += 1
      end
    end
  end
  min_interval :calc_optunchokes, CALC_OPTUNCHOKES_INTERVAL

  ## the "heartbeat". all time-based actions are triggered here.
  def step
    ## see if we should be in antisnubbing mode
    if !@package.complete? && (dlrate < ANTISNUB_RATE_THRESH)
      rt_debug "= dl rate #{dlrate} < #{ANTISNUB_RATE_THRESH}, in antisnub mode" if !@in_antisnub
      @in_antisnub = true
    else
      rt_debug "= dl rate #{dlrate} >= #{ANTISNUB_RATE_THRESH}, out of antisnub mode" if @in_antisnub
      @in_antisnub = false
    end

    ## see if we should be in fuseki mode
    if !@package.complete? && (@package.pieces_completed < FUSEKI_PIECE_THRESH)
      rt_debug "= num pieces #{@package.pieces_completed} < #{FUSEKI_PIECE_THRESH}, in fuseki mode" if !@in_fuseki
      @in_fuseki = true
    else
      rt_debug "= num pieces #{@package.pieces_completed} >= #{FUSEKI_PIECE_THRESH}, out of fuseki mode" if @in_fuseki
      @in_fuseki = false
    end

    ## see if we should be in endgame mode
    if @package.complete?
      rt_debug "= left endgame mode" if @in_endgame
      @in_endgame = false
    elsif (@package.pieces.length - @package.pieces_completed) <= ENDGAME_PIECE_THRESH
      rt_debug "= have #{@package.pieces_completed} pieces, in endgame mode"
      @in_endgame = true
    end

#     puts "  heartbeat: dlrate #{(dlrate / 1024.0).round}kb/s (lim #{(@dlratelim ? (@dlratelim / 1024.0).round : 'none')}) ulrate #{(ulrate / 1024.0).round}kb/s (lim #{(@ulratelim ? (@ulratelim / 1024.0).round : 'none')}) endgame? #@in_endgame antisnubbing? #@in_antisnub fuseki? #@in_fuseki"
#      @package.pieces.each do |p|
#        next if p.complete? || !p.started?
#        l1 = 0
#        p.each_unclaimed_block(9999999) { |b| l1 += b.length }
#        l2 = 0
#        p.each_empty_block(9999999) { |b| l2 += b.length }
#        puts "  heartbeat: #{p.index}: #{l1} unclaimed bytes, #{l2} unfilled bytes"
#      end

    ## find a tracker if we aren't already connected to one
    find_tracker if @tracker.nil?

    if @package.complete? # if package is complete...
      ## kill all peers who are complete as well, as per bram's client
      @peers.each { |p| p.shutdown if p.peer_complete? }
      @tracker.completed unless @tracker.nil? || @tracker.sent_completed?
      ## reopen all files as readonly (dunno why, just seems like a
      ## good idea)
      @package.reopen_ro unless @package.ro?
    end

    ## kill any silent connections, and anyone who hasn't sent or
    ## received data in a long time.
    @peers_m.synchronize do
      @peers.each do |p|
        next unless p.running?
        if ((Time.now - (p.last_send_time || p.start_time)) > SILENT_DEATH_INTERVAL)
          rt_warning "shutting down peer #{p} for silence/boredom"
          p.shutdown 
        end
      end
    end

    ## discard any dead connections
    @peers_m.synchronize do
      @peers.delete_if do |p|
        !p.running? && begin
          p.unregister_events self
          @piece_order.dec_all p.peer_pieces                 
          rt_debug "burying corpse of #{p}"
          send_event(:removed_peer, p)
          true
        end
      end
    end

    ## get more peers from the tracker, if all of the following are true:
    ## a) the package is incomplete (i.e. we're downloading, not uploading)
    ## b) we're connected to a tracker
    ## c) we've tried all the peers we've gotten so far
    ## d) the tracker hasn't already reported the maximum number of peers
    if !@package.complete? && @tracker && (@tracker.peers.inject(0) { |s, p| s + (p.tried? ? 0 : 1) } == 0) && (@tracker.numwant <= @tracker.peers.length)
      rt_debug "* getting more peers from the tracker"
      @tracker.numwant += 50
      unless @tracker.in_force_refresh
        Thread.new do
          begin
            @tracker.force_refresh
          rescue TrackerError
          end
        end
      end
    end

    ## add peer if necessary
    3.times { add_a_peer } # there's no place like home


    ## iterate choking policy
    calc_friends
    calc_optunchokes

    ## this is needed. sigh.
    break unless @running

    ## send keepalives 
    @peers_m.synchronize { @peers.each { |p| p.send_keepalive if p.running? && p.last_send_time && ((Time.now - p.last_send_time) > KEEPALIVE_INTERVAL) } }

    ## now we apportion our bandwidth amongst all the peers. we'll go
    ## through them at random, dump everything we can, and move on iff
    ## we don't expect to hit our bandwidth cap.
    dllim = @dlratelim.nil? ? nil : (@dlratelim.to_f * (RATE_WINDOW.to_f + HEARTBEAT)) - (dlrate.to_f * RATE_WINDOW)
    ullim = @ulratelim.nil? ? nil : (@ulratelim.to_f * (RATE_WINDOW.to_f + HEARTBEAT)) - (ulrate.to_f * RATE_WINDOW)
    dl = ul = 0
    @peers.shuffle.each do |p|
      break if (dllim && (dl >= dllim)) || (ullim && (ul >= ullim))
      if p.running?
        pdl, pul = p.send_blocks_and_reqs(dllim && (dllim - dl), ullim && (ullim - ul))
        dl += pdl
        ul += pul
      end
    end

    ## refresh tracker stats
    refresh_tracker if @tracker
  end
end

end
