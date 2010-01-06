## message.rb -- peer wire protocol message parsing/composition
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

## we violate the users' namespaces here. but it's not in too
## egregious of a way, and it's a royal pita to remove, so i'm keeping
## it in for the time being.
class String
  def from_fbbe # four-byte big-endian integer
    raise "fbbe must be four-byte string (got #{self.inspect})" unless length == 4
    (self[0] << 24) + (self[1] << 16) + (self[2] << 8) + self[3]
  end
end

class Integer
  def to_fbbe # four-byte big-endian integer
    raise "fbbe must be < 2^32" unless self <= 2**32
    raise "fbbe must be >= 0" unless self >= 0
    s = "    "
    s[0] = (self >> 24) % 256
    s[1] = (self >> 16) % 256
    s[2] = (self >>  8) % 256
    s[3] = (self      ) % 256
    s
  end
end

module RubyTorrent

module StringExpandBits
  include StringMapBytes

  def expand_bits # just for debugging purposes
    self.map_bytes do |b|
      (0 .. 7).map { |i| ((b & (1 << (7 - i))) == 0 ? "0" : "1") }
    end.flatten.join
  end
end

class Message
  WIRE_IDS = [:choke, :unchoke, :interested, :uninterested, :have, :bitfield,
              :request, :piece, :cancel]

  attr_accessor :id

  def initialize(id, args=nil)
    @id = id
    @args = args
  end

  def method_missing(meth)
    if @args.has_key? meth
      @args[meth]
    else
      raise %{no such argument "#{meth}" to message #{self.to_s}}
    end
  end

  def to_wire_form
    case @id
    when :keepalive
      0.to_fbbe
    when :choke, :unchoke, :interested, :uninterested
      1.to_fbbe + WIRE_IDS.index(@id).chr
    when :have
      5.to_fbbe + 4.chr + @args[:index].to_fbbe
    when :bitfield
      (@args[:bitfield].length + 1).to_fbbe + 5.chr + @args[:bitfield]
    when :request, :cancel
      13.to_fbbe + WIRE_IDS.index(@id).chr + @args[:index].to_fbbe +
        @args[:begin].to_fbbe + @args[:length].to_fbbe
    when :piece
      (@args[:length] + 9).to_fbbe + 7.chr + @args[:index].to_fbbe +
        @args[:begin].to_fbbe
    else
      raise "unknown message type #{id}"
    end
  end

  def self.from_wire_form(idnum, argstr)
    type = WIRE_IDS[idnum]

    case type
    when :choke, :unchoke, :interested, :uninterested
      raise ProtocolError, "invalid length #{argstr.length} for #{type} message" unless argstr.nil? or (argstr.length == 0)
      Message.new(type)

    when :have
      raise ProtocolError, "invalid length #{str.length} for #{type} message" unless argstr.length == 4
      Message.new(type, {:index => argstr[0,4].from_fbbe})
      
    when :bitfield
      Message.new(type, {:bitfield => argstr})

    when :request, :cancel
      raise ProtocolError, "invalid length #{argstr.length} for #{type} message" unless argstr.length == 12
      Message.new(type, {:index => argstr[0,4].from_fbbe,
                         :begin => argstr[4,4].from_fbbe,
                         :length => argstr[8,4].from_fbbe})
    when :piece
      raise ProtocolError, "invalid length #{argstr.length} for #{type} message" unless argstr.length == 8
      Message.new(type, {:index => argstr[0,4].from_fbbe,
                         :begin => argstr[4,4].from_fbbe})
    else
      raise "unknown message #{type.inspect}"
    end
  end

  def to_s
    case @id
    when :bitfield
      %{bitfield <#{@args[:bitfield].extend(StringExpandBits).expand_bits}>}
    else
      %{#@id#{@args.nil? ? "" : "(" + @args.map { |k, v| "#{k}=#{v.to_s.inspect}" }.join(", ") + ")"}}
    end
  end
end

end
