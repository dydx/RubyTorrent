## util.rb -- miscellaneous RubyTorrent utility modules.
## Copyright 2005 William Morgan.
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

def rt_debug(*args)
  if $DEBUG || RubyTorrent.log
    stream = RubyTorrent.log || $stdout
    stream << args.join << "\n" 
    stream.flush
  end
end

def rt_warning(*args)
  if $DEBUG || RubyTorrent.log
    stream = RubyTorrent.log || $stderr
    stream << "warning: " << args.join << "\n" 
    stream.flush
  end
end

module RubyTorrent

@log = nil
def log_output_to(fn)
  @log = File.open(fn, "w")
end
attr_reader :log
module_function :log_output_to, :log


## parse final hash of pseudo-keyword arguments
def get_args(rest, *names)
  hash = rest.find { |x| x.is_a? Hash }
  if hash
    rest.delete hash
    hash.each { |k, v| raise ArgumentError, %{unknown argument "#{k}"} unless names.include?(k) }
  end

  [hash || {}, rest]
end
module_function :get_args

## "events": very similar to Observable, but cleaner, IMO. events are
## listened to and sent in instance space, but registered in class
## space. example:
##
## class C
##   include EventSource
##   event :goat, :boat
##
##   def send_events
##     send_event :goat
##     send_event(:boat, 3)
##   end
## end
##
## c = C.new
## c.on_event(:goat) { puts "got goat!" }
## c.on_event(:boat) { |x| puts "got boat: #{x}" }
##
## Defining them in class space is not really necessary, except as an
## error-checking mechanism.
module EventSource
  def on_event(who, *events, &b)
    @event_handlers ||= Hash.new { [] }
    events.each do |e|
      raise ArgumentError, "unknown event #{e} for #{self.class}" unless (self.class.class_eval "@@event_has")[e]
      @event_handlers[e] <<= [who, b]
    end
    nil
  end

  def send_event(e, *args)
    raise ArgumentError, "unknown event #{e} for #{self.class}" unless (self.class.class_eval "@@event_has")[e]
    @event_handlers ||= Hash.new { [] }
    @event_handlers[e].each { |who, proc| proc[self, *args] }
    nil
  end

  def unregister_events(who, *events)
    @event_handlers.each do |event, handlers|
      handlers.each do |ewho, proc|
        if (ewho == who) && (events.empty? || events.member?(event))
          @event_handlers[event].delete [who, proc]
        end
      end
    end
    nil
  end

  def relay_event(who, *events)
    @event_handlers ||= Hash.new { [] }
    events.each do |e|
      raise "unknown event #{e} for #{self.class}" unless (self.class.class_eval "@@event_has")[e]
      raise "unknown event #{e} for #{who.class}" unless (who.class.class_eval "@@event_has")[e]
      @event_handlers[e] <<= [who, lambda { |s, *a| who.send_event e, *a }]
    end
    nil
  end

  def self.append_features(mod)
    super(mod)
    mod.class_eval %q{
      @@event_has ||= Hash.new(false)
      def self.event(*args)
        args.each { |a| @@event_has[a] = true }
      end
    }
  end
end

## ensure that a method doesn't execute more frequently than some
## number of seconds. e.g.:
##
## def meth
##   ...
## end
## min_iterval :meth, 10
##
## ensures that "meth" won't be executed more than once every 10
## seconds.
module MinIntervalMethods
  def min_interval(meth, int)
    class_eval %{
      @@min_interval ||= {}
      @@min_interval[:#{meth}] = [nil, #{int.to_i}]
      alias :min_interval_#{meth} :#{meth}
      def #{meth}(*a, &b)
        last, int = @@min_interval[:#{meth}]
        unless last && ((Time.now - last) < int)
          min_interval_#{meth}(*a, &b) 
          @@min_interval[:#{meth}][0] = Time.now
        end
      end
    }
  end
end

## boolean attributes now get question marks in their accessors
## don't forget to 'extend' rather than 'include' this one
module AttrReaderQ
  def attr_reader_q(*args)
    args.each { |v| class_eval "def #{v}?; @#{v}; end" }
  end
  
  def attr_writer_q(*args)
    args.each { |v| attr_writer v }
  end
  
  def attr_accessor_q(*args)
    attr_reader_q args
    attr_writer_q args
  end
end

module ArrayShuffle
  def shuffle!
    each_index do |i|
      j = i + rand(self.size - i);
      self[i], self[j] = self[j], self[i]
    end
  end

  def shuffle
    self.clone.shuffle! # dup doesn't preserve shuffle! method
  end
end

module StringMapBytes
  def map_bytes
    ret = []
    each_byte { |x| ret.push(yield(x)) }
    ret
  end
end

end
