## server.rb -- make/receive and handshake all new peer connections.
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
require "rubytorrent/tracker"
require "rubytorrent/controller"
require "rubytorrent/peer"

module RubyTorrent

## The Server coordinates all Packages available on the machine. It
## instantiates one Controller for each Package. It's also responsible
## for the creation of all TCP connections---it sets up the TCP
## socket, receives incoming connections, validates handshakes, and
## hands them off to the appropriate Controller; it also creates
## outgoing connections (typically at Controllers' requests) and sends
## the handshake.
class Server
  attr_reader :port, :id, :http_proxy

  VERSION = 0
  PORT_RANGE=(6881 .. 6889)

  def initialize(hostname=nil, port=nil, http_proxy=ENV["http_proxy"])
    @http_proxy = http_proxy
    @server = nil
    if port.nil?
      @port = PORT_RANGE.detect do |p|
        begin
          @server = TCPServer.new(hostname, p)
          @port = p
        rescue Errno::EADDRINUSE
          @server = nil
        end
        !@server.nil?
      end
      raise Errno::EADDRINUSE, "ports #{PORT_RANGE}" unless @port
    else
      @server = TCPServer.new(hostname, port)
      @port = port
    end

    @id = "rubytor" + VERSION.chr + (1 .. 12).map { |x| rand(256).chr }.join
    @controllers = {}
  end

  def ip; @server.addr[3]; end

  def add_torrent(mi, package, dlratelim=nil, ulratelim=nil)
    @controllers[mi.info.sha1] = Controller.new(self, package, mi.info.sha1, mi.trackers, dlratelim, ulratelim, @http_proxy)
    @controllers[mi.info.sha1].start
  end

  def add_connection(name, cont, socket)
    begin
      shake_hands(socket, cont.info_hash)
      peer = PeerConnection.new(name, cont, socket, cont.package)
      cont.add_peer peer
    rescue ProtocolError => e
      socket.close rescue nil
    end
  end

  def start
    @shutdown = false
    @thread = Thread.new do
      begin
        while !@shutdown; receive; end
      rescue IOError, StandardError
        rt_warning "**** socket receive error, retrying"
        sleep 5
        retry
      end
    end
    self
  end

  def shutdown
    return if @shutdown
    @shutdown = true
    @server.close rescue nil

    @thread.join(0.2)
    @controllers.each { |hash, cont| cont.shutdown }
    self
  end

  def to_s
    "<#{self.class}: port #{port}, peer_id #{@id.inspect}>"
  end

  private

  def receive # blocking
    ssocket = @server.accept
    Thread.new do
      socket = ssocket

      begin
        rt_debug "<= incoming connection from #{socket.peeraddr[2]}:#{socket.peeraddr[1]}"
        hash, peer_id = shake_hands(socket, nil)
        cont = @controllers[hash]
        peer = PeerConnection.new("#{socket.peeraddr[2]}:#{socket.peeraddr[1]}", cont, socket, cont.package)
        cont.add_peer peer
      rescue SystemCallError, ProtocolError => e
        rt_debug "killing incoming connection: #{e}"
        socket.close rescue nil
      end
    end
  end

  ## if info_hash is nil here, the socket is treated as an incoming
  ## connection---it will wait for the peer's info_hash and respond
  ## with the same if it corresponds to a current download, otherwise
  ## it will raise a ProtocolError.
  ##
  ## if info_hash is not nil, the socket is treated as an outgoing
  ## connection, and it will send the info_hash immediately.
  def shake_hands(sock, info_hash)
#    rt_debug "initiating #{(info_hash.nil? ? 'incoming' : 'outgoing')} handshake..."
    sock.send("\023BitTorrent protocol\0\0\0\0\0\0\0\0", 0);
    sock.send("#{info_hash}#{@id}", 0) unless info_hash.nil?

    len = sock.recv(1)[0]
#    rt_debug "length #{len.inspect}"
    raise ProtocolError, "invalid handshake length byte #{len.inspect}" unless len == 19

    name = sock.recv(19)
#    rt_debug "name #{name.inspect}"
    raise ProtocolError, "invalid handshake protocol string #{name.inspect}" unless name == "BitTorrent protocol"

    reserved = sock.recv(8)
#    rt_debug "reserved: #{reserved.inspect}" 
   # ignore for now

    their_hash = sock.recv(20)
#    rt_debug "their info hash: #{their_hash.inspect}"

    if info_hash.nil?
      raise ProtocolError, "client requests package we don't have: hash=#{their_hash.inspect}" unless @controllers.has_key? their_hash
      info_hash = their_hash
      sock.send("#{info_hash}#{@id}", 0)
    else
      raise ProtocolError, "mismatched info hashes: us=#{info_hash.inspect}, them=#{their_hash.inspect}" unless info_hash == their_hash
    end

    peerid = sock.recv(20)
#    rt_debug "peer id: #{peerid.inspect}"
    raise ProtocolError, "connected to self" if peerid == @id

#    rt_debug "== handshake complete =="
    [info_hash, peerid]
  end
end

end
