## typedstruct.rb -- type-checking struct, for bencoded objects.
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

require "rubytorrent/bencoding"

module RubyTorrent

module ArrayToH
  def to_h
    inject({}) { |h, (k, v)| h[k] = v; h } # found this neat trick on the internet
  end
end

module HashMapHash
  def map_hash
    a = map { |k, v| yield k, v }.extend(ArrayToH).to_h
  end
end

class TypedStructError < StandardError; end

## type-checking struct meant for easy translation from and to
## bencoded dicts.
class TypedStruct
  attr_accessor :dirty
  attr_reader :fields # writer below

  def initialize
    @required = {}
    @label = {}
    @coerce = {}
    @field = {}
    @array = {}
    @dirty = false
    @values = {}

    yield self if block_given?

    @field.each do |f, type|
      @required[f] ||= false
      @label[f] ||= f.to_s
      @array[f] ||= false
    end
  end

  def method_missing(meth, *args)
    if meth.to_s =~ /^(.*?)=$/
#      p [meth, args]

      f = $1.intern
      raise ArgumentError, "no such value #{f}" unless @field.has_key? f

      type = @field[f]
      o = args[0]
      if @array[f]
        raise TypeError, "for #{f}, expecting Array, got #{o.class}" unless o.kind_of? ::Array
        o.each { |e| raise TypeError, "for elements of #{f}, expecting #{type}, got #{e.class}" unless e.kind_of? type }
        @values[f] = o
        @dirty = true
      else
        raise TypeError, "for #{f}, expecting #{type}, got #{o.class}" unless o.kind_of? type
        @values[f] = o
        @dirty = true
      end
    else
      raise ArgumentError, "no such value #{meth}" unless @field.has_key? meth
#      p [meth, @values[meth]]

      @values[meth]
    end
  end

  [:required, :array].each do |f|
    class_eval %{
      def #{f}(*args)
        args.each do |x|
          raise %q{unknown field "\#{x}" in #{f} list} unless @field[x]
          @#{f}[x] = true
        end
      end
    }
  end

  [:field , :label, :coerce].each do |f|
    class_eval %{
      def #{f}(hash)
        hash.each { |k, v| @#{f}[k] = v }
      end
    }
  end

  ## given a Hash from a bencoded dict, parses it according to the
  ## rules you've set up with field, required, label, etc.
  def parse(dict)
    @required.each do |f, reqd|
      flabel = @label[f]
      raise TypedStructError, "missing required parameter #{flabel} (dict has #{dict.keys.join(', ')})" if reqd && !(dict.member? flabel)

      if dict.member? flabel
        v = dict[flabel]
        if @coerce.member? f
          v = @coerce[f][v]
        end
        if @array[f]
          raise TypeError, "for #{flabel}, expecting Array, got #{v.class} instead" unless v.kind_of? ::Array
        end
        self.send("#{f}=", v)
      end
    end

    ## disabled the following line as applications seem to put tons of
    ## weird fields in their .torrent files.
    # dict.each { |k, v| raise TypedStructError, %{unknown field "#{k}"} unless @field.member?(k.to_sym) || @label.values.member?(k) }
  end

  def to_bencoding
    @required.each { |f, reqd| raise ArgumentError, "missing required parameter #{f}" if reqd && self.send(f).nil? }
    @field.extend(HashMapHash).map_hash { |f, type| [@label[f], self.send(f)] }.to_bencoding
  end
end

end
