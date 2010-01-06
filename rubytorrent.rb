## rubytorrent.rb -- top-level RubyTorrent file.
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

require 'rubytorrent/util'
require 'rubytorrent/bencoding'
require 'rubytorrent/metainfo'
require 'rubytorrent/tracker'
require 'rubytorrent/package'
require 'rubytorrent/server'

require "socket"
Socket.do_not_reverse_lookup = true

module RubyTorrent
  VERSION = 0.3

## the top-level class for RubyTorrent.
class BitTorrent
  include EventSource
  event :trying_peer, :forgetting_peer, :added_peer, :removed_peer,
        :received_block, :sent_block, :have_piece, :discarded_piece, :complete,
        :tracker_connected, :tracker_lost, :requested_block

  @@server = nil

  ## hash arguments: host, port, dlratelim, ulratelim
  def initialize(metainfo, *rest)
    args, rest = RubyTorrent::get_args(rest, :host, :port, :dlratelim, :ulratelim, :http_proxy)
    out = rest.shift
    raise ArgumentError, "wrong number of arguments (expected 0/1, got #{rest.length})" unless rest.empty?

    case metainfo
    when MetaInfo
      @metainfo = metainfo
    when String
      @metainfo = MetaInfo.from_location(metainfo)
    when IO
      @metainfo = MetaInfo.from_stream(metainfo)
    else
      raise ArgumentError, "'metainfo' should be a String, IO or RubyTorrent::MetaInfo object"
    end

    case out
    when Package
      @package = out
    else
      @package = Package.new(@metainfo, out)
    end

    unless @@server
      @@server = RubyTorrent::Server.new(args[:host], args[:port], args[:http_proxy])
      @@server.start
    end

    @cont = @@server.add_torrent(@metainfo, @package, args[:dlratelim], args[:ulratelim])

    @cont.relay_event self, :trying_peer, :forgetting_peer, :added_peer,
                            :removed_peer, :received_block, :sent_block,
                            :have_piece, :discarded_piece, :tracker_connected,
                            :tracker_lost, :requested_block
    @package.relay_event self, :complete
  end

  def ip; @@server.ip; end
  def port; @@server.port; end
  def peer_info; @cont.peer_info; end
  def shutdown; @cont.shutdown; end
  def shutdown_all; @@server.shutdown; end
  def complete?; @package.complete?; end
  def bytes_completed; @package.bytes_completed; end
  def percent_completed; @package.percent_completed; end
  def pieces_completed; @package.pieces_completed; end
  def dlrate; @cont.dlrate; end
  def ulrate; @cont.ulrate; end
  def dlamt; @cont.dlamt; end
  def ulamt; @cont.ulamt; end
  def num_pieces; @package.num_pieces; end
  def tracker; (@cont.tracker ? @cont.tracker.url : nil); end
  def num_possible_peers; (@cont.tracker ? @cont.tracker.peers.length : 0); end
  def num_active_peers; @cont.num_peers; end
  def total_bytes; @package.size; end
end

end
