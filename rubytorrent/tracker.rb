## tracker.rb -- bittorrent tracker protocol.
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

require 'open-uri'
require 'timeout'
require "rubytorrent"

module RubyTorrent

module HashAddition
  def +(o)
    ret = self.dup
    o.each { |k, v| ret[k] = v }
    ret
  end
end

## am i insane or does 'uniq' not use == or === for some insane
## reason? wtf is that about?
module ArrayUniq2
  def uniq2
    ret = []
    each { |x| ret.push x unless ret.member? x }
    ret
  end
end

class TrackerResponsePeer
  attr_writer :tried

  def initialize(dict=nil)
    @s = TypedStruct.new do |s|
      s.field :peer_id => String, :ip => String, :port => Integer
      s.required :ip, :port
      s.label :peer_id => "peer id"
    end

    @s.parse(dict) unless dict.nil?
    @connected = false
    @tried = false
  end

  def tried?; @tried; end

  def method_missing(meth, *args)
    @s.send(meth, *args)
  end

  def ==(o); (self.ip == o.ip) && (self.port == o.port); end

  def to_s
    %{<#{self.class}: ip=#{self.ip}, port=#{self.port}>}
  end
end

class TrackerResponse
  def initialize(dict=nil)
    @s = TypedStruct.new do |s|
      s.field :interval => Integer, :complete => Integer,
              :incomplete => Integer, :peers => TrackerResponsePeer
      s.array :peers
      s.required :peers #:interval, :complete, :incomplete, :peers
      s.coerce :peers => lambda { |x| make_peers x }
    end

    @s.parse(dict) unless dict.nil?

    peers.extend ArrayShuffle
  end

  def method_missing(meth, *args)
    @s.send(meth, *args)
  end

  private

  def make_peers(x)
    case x
    when Array
      x.map { |e| TrackerResponsePeer.new e }.extend(ArrayUniq2).uniq2
    when String
      x.unpack("a6" * (x.length / 6)).map do |y|
        TrackerResponsePeer.new({"ip" => (0..3).map { |i| y[i] }.join('.'),
                                 "port" => (y[4] << 8) + y[5] })
      end.extend(ArrayUniq2).uniq2
    else
      raise "don't know how to make peers array from #{x.class}"
    end
  end
end

class TrackerError < StandardError; end

class TrackerConnection
  attr_reader :port, :left, :peer_id, :last_conn_time, :url, :in_force_refresh
  attr_accessor :uploaded, :downloaded, :left, :numwant

  def initialize(url, info_hash, length, port, peer_id, ip=nil, numwant=50, http_proxy=ENV["http_proxy"])
    @url = url
    @hash = info_hash
    @length = length
    @port = port
    @uploaded = @downloaded = @left = 0
    @ip = ip
    @numwant = numwant
    @peer_id = peer_id
    @http_proxy = http_proxy
    @state = :stopped
    @sent_completed = false
    @last_conn_time = nil
    @tracker_data = nil
    @compact = true
    @in_force_refresh = false
  end

  def already_completed; @sent_completed = true; end
  def sent_completed?; @sent_completed; end

  def started
    return unless @state == :stopped
    @state = :started
    @tracker_data = send_tracker "started"
    self
  end

  def stopped
    return unless @state == :started
    @state = :stopped
    @tracker_data = send_tracker "stopped"
    self
  end
  
  def completed
    return if @sent_completed
    @tracker_data = send_tracker "completed"
    @sent_completed = true
    self
  end

  def refresh
    return unless (Time.now - @last_conn_time) >= (interval || 0)
    @tracker_data = send_tracker nil
  end

  def force_refresh
    return if @in_force_refresh
    @in_force_refresh = true
    @tracker_data = send_tracker nil
    @in_force_refresh = false
  end

  [:interval, :seeders, :leechers, :peers].each do |m|
    class_eval %{
      def #{m}
        if @tracker_data then @tracker_data.#{m} else nil end
      end
    }
  end

  private

  def send_tracker(event)
    resp = nil
    if @compact
      resp = get_tracker_response({ :event => event, :compact => 1 })
      if resp["failure reason"]
        @compact = false
      end
    end
       
    resp = get_tracker_response({ :event => event }) unless resp
    raise TrackerError, "tracker reports error: #{resp['failure reason']}" if resp["failure reason"]
    
    TrackerResponse.new(resp)
  end

  def get_tracker_response(opts)
    target = @url.dup
    opts.extend HashAddition
    opts += {:info_hash => @hash, :peer_id => @peer_id,
      :port => @port, :uploaded => @uploaded, :downloaded => @downloaded,
      :left => @left, :numwant => @numwant, :ip => @ip}
    target.query = opts.map do |k, v|
      unless v.nil?
        ek = URI.escape(k.to_s) # sigh
        ev = URI.escape(v.to_s, /[^a-zA-Z0-9]/)
        "#{ek}=#{ev}"
      end
    end.compact.join "&"

    rt_debug "connecting to #{target.to_s} ..."

    ret = nil
    begin
      target.open(:proxy => @http_proxy) do |resp|
        BStream.new(resp).each do |e|
          if ret.nil?
            ret = e
          else
            raise TrackerError, "don't understand tracker response (too many objects)"
          end
        end
      end
    rescue SocketError, EOFError, OpenURI::HTTPError, RubyTorrent::TrackerError, Timeout::Error, SystemCallError, NoMethodError => e
      raise TrackerError, e.message
    end
    @last_conn_time = Time.now

    raise TrackerError, "empty tracker response" if ret.nil?
    raise TrackerError, "don't understand tracker response (not a dict)" unless ret.kind_of? ::Hash
    ret
  end
end

end
