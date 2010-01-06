## rtpeer-ncurses.rb -- RubyTorrent ncurses BitTorrent peer.
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

require "rubytorrent"
require "ncurses"
require "optparse"

def die(x); $stderr << "#{x}\n" && exit(-1); end

dlratelim = nil
ulratelim = nil

opts = OptionParser.new do |opts|
  opts.banner = 
%{Usage: rtpeer-ncurses [options] <torrent> [<target>]

rtpeer-ncurses is a very simple ncurses-based BitTorrent peer. You can use it
to download .torrents or to seed them.

<torrent> is a .torrent filename or URL.
<target> is a file or directory on disk. If not specified, the default value
  from <torrent> will be used.
[options] are:
}

  opts.on("-l", "--log FILENAME",
          "Log events to FILENAME (for debugging)") do |fn|
    RubyTorrent::log_output_to(fn)
  end

  opts.on("-d", "--downlimit LIMIT", Integer,
          "Limit download rate to LIMIT kb/s") do |x|
    dlratelim = x * 1024
  end

  opts.on("-u", "--uplimit LIMIT", Integer,
          "Limit upload rate to LIMIT kb/s") do |x|
    ulratelim = x * 1024
  end

  opts.on_tail("-h", "--help", "Show this message") do
    puts opts
    exit
  end
end

opts.parse!(ARGV)
proxy = ENV["http_proxy"]
torrent = ARGV.shift or (puts opts; exit)
dest = ARGV.shift

class Numeric
  def to_sz
    if self < 1024
      "#{self.round}b"
    elsif self < 1024 ** 2
      "#{(self / 1024 ).round}k"
    elsif self < 1024 ** 3
      sprintf("%.1fm", self.to_f / (1024 ** 2))
    else
      sprintf("%.2fg", self.to_f / (1024 ** 3))
    end
  end

  MIN = 60
  HOUR = 60 * MIN
  DAY = 24 * HOUR

  def to_time
    if self < MIN
      sprintf("0:%02d", self)
    elsif self < HOUR
      sprintf("%d:%02d", self / MIN, self % MIN)
    elsif self < DAY
      sprintf("%d:%02d:%02d", self / HOUR, (self % HOUR) / MIN, (self % HOUR) % MIN)
    else
      sprintf("%dd %d:%02d:%02d", self / DAY, (self % DAY) / HOUR, ((self % DAY) % HOUR) / MIN, ((self % DAY) % HOUR) % MIN)
    end
  end
end

class NilClass
  def to_time; "--:--"; end
  def to_sz; "-"; end
end

class Display
  STALL_SECS = 15

  attr_accessor :fn, :dest, :status,:dlamt, :ulamt, :dlrate, :ulrate,
                :conn_peers, :fail_peers, :untried_peers, :tracker,
                :errcount, :completed, :total, :rate, :use_rate

  def initialize(window)
    @window = window
    @need_update = true

    @fn = ""
    @dest = ""
    @status = ""
    @completed = 0
    @total = 0
    @dlamt = 0
    @dlrate = 0
    @ulamt = 0
    @ulrate = 0
    @rate = 0
    @conn_peers = 0
    @fail_peers = 0
    @untried_peers = 0
    @tracker = "not connected"
    @errcount = 0
    @dlblocks = 0
    @ulblocks = 0

    @got_blocks = 0
    @sent_blocks = 0
    @last_got_block = nil
    @last_sent_block = nil
    @start_time = nil

    @use_rate = false
  end

  def got_block
    @got_blocks += 1
    @last_got_block = Time.now
  end

  def sent_block
    @sent_blocks += 1
    @last_sent_block = Time.now
  end

  def sigwinch_handler(sig = nil)
    @need_update = true
  end

  def start_timer
    @start_time = Time.now
  end

  def draw
    if @need_update
      update_size 
      @window.erase
    end

    complete_width = [@cols - 23, 0].max
    complete_ticks = ((@completed.to_f / @total) * complete_width)

    elapsed = (@start_time ? Time.now - @start_time : nil)
    rate = (use_rate ? @rate : @dlrate)
    remaining = rate && (rate > 0 ? (@total - @completed).to_f / rate : nil)

    dlstall = @last_got_block && ((Time.now - @last_got_block) > STALL_SECS)
    ulstall = @last_sent_block && ((Time.now - @last_sent_block) > STALL_SECS)
      
    line = 1
    [
      "Contents: #@fn",
      "    Dest: #@dest",
      "",
      "  Status: #@status",
      "Progress: [" + ("#" * complete_ticks),
      "    Time: elapsed #{elapsed.to_time}, remaining #{remaining.to_time}",
      "Download: #{@dlamt.to_sz} at #{dlstall ? '(stalled)' : @dlrate.to_sz + '/s'}",
      "  Upload: #{@ulamt.to_sz} at #{ulstall ? '(stalled)' : @ulrate.to_sz + '/s'}",
      "   Peers: connected to #@conn_peers (#@fail_peers failed, #@untried_peers untried)",
      " Tracker: #@tracker",
      "  Errors: #@errcount",
    ].each do |s|
      break if line > @rows
      @window.mvaddnstr(line, 2, s + (" " * @cols), @cols - 4)
      line += 1
    end

    ## progress bar tail
    @window.mvaddstr(5, @cols - 11, sprintf("] %.2f%%  ", (@completed.to_f / @total) * 100.0))
    @window.mvaddnstr(7, 31, "|" + ("#" * (@dlrate / 1024)) + (" " * @cols), @cols - 31 - 2)
    @window.mvaddnstr(8, 31, "|" + ('#' * (@ulrate / 1024)) + (" " * @cols), @cols - 31 - 2)

    @window.box(0,0)

#    @got_blocks -= 1 unless @got_blocks == 0
#    @sent_blocks -= 1 unless @sent_blocks == 0
  end

  private

  def update_size
    rows = []
    cols = []
    ## jesus CHRIST this is a shitty interface.
    @window.getmaxyx(rows, cols)
    @rows = rows[0]
    @cols = cols[0]
    @need_update = false
  end
end

begin
  mi = RubyTorrent::MetaInfo.from_location(torrent, proxy)
rescue RubyTorrent::MetaInfoFormatError, RubyTorrent::BEncodingError => e
  die %{Error: can\'t parse metainfo file "#{torrent}"---maybe not a .torrent?}
rescue RubyTorrent::TypedStructError => e
  $stderr << <<EOS
error parsing metainfo file, and it's likely something I should know about.
please email the torrent file to wmorgan-rubytorrent-bug@masanjin.net,
along with this backtrace: (this is RubyTorrent version #{RubyTorrent::VERSION})
EOS

  raise e
rescue IOError, SystemCallError => e
  $stderr.puts %{Error: can't read file "#{torrent}": #{e.message}}
  exit
end

unless dest.nil?
  if FileTest.directory?(dest) && mi.info.single?
    dest = File.join(dest, mi.info.name)
  elsif FileTest.file?(dest) && mi.info.multiple?
    die %{Error: .torrent contains multiple files, but "#{dest}" is a single file (must be a directory)}
  end
end

def handle_any_input(display)
  case(Ncurses.getch())
  when ?q, ?Q
    Ncurses.curs_set(1)
    Ncurses.endwin()
    exit
  when Ncurses::KEY_RESIZE
    display.sigwinch_handler
  end
end

Ncurses.initscr

begin
  Ncurses.nl()
  Ncurses.noecho()
  Ncurses.curs_set(0)
  Ncurses.stdscr.nodelay(true)
  Ncurses.timeout(0)

  display = Display.new Ncurses.stdscr
  display.status = "checking file on disk..."
  display.dest = File.expand_path(dest || mi.info.name) + (mi.single? ? "" : "/")
  if mi.single?
    display.fn = "#{mi.info.name} (#{mi.info.length.to_sz} in one file)"
  else
    display.fn = "#{mi.info.name}/ (#{mi.info.total_length.to_sz} in #{mi.info.files.length} files)"
  end
  display.total = mi.info.num_pieces * mi.info.piece_length
  display.completed = 0
  display.draw; Ncurses.refresh

  display.use_rate = true
  display.start_timer
  num_pieces = 0
  start = Time.now
  every = 10
  package = RubyTorrent::Package.new(mi, dest) do |piece|
    num_pieces += 1
    if (num_pieces % every) == 0
      display.completed = (num_pieces * mi.info.piece_length)
      display.rate = display.completed.to_f / (Time.now - start)
      handle_any_input display
      display.draw; Ncurses.refresh
    end
  end

  display.status = "starting peer..."
  display.use_rate = false
  display.draw; Ncurses.refresh
  bt = RubyTorrent::BitTorrent.new(mi, package, :http_proxy => proxy, :dlratelim => dlratelim, :ulratelim => ulratelim)

  connecting = true
  bt.on_event(self, :received_block) do |s, b, peer|
    display.got_block
    connecting = false
  end
  bt.on_event(self, :sent_block) do |s, b, peer|
    display.sent_block
    connecting = false
  end
  bt.on_event(self, :discarded_piece) { |s, p| display.errcount += 1 }
  bt.on_event(self, :tracker_connected) do |s, url|
    display.tracker = url
    display.untried_peers = bt.num_possible_peers
  end
  bt.on_event(self, :tracker_lost) { |s, url| display.tracker = "can't connect to #{url}" }
  bt.on_event(self, :forgetting_peer) { |s, p| display.fail_peers += 1 }
  bt.on_event(self, :removed_peer, :added_peer) do |s, p|
    if (display.conn_peers = bt.num_active_peers) == 0
      connecting = true
    end
  end
  bt.on_event(self, :added_peer) { |s, p| display.conn_peers += 1 }
  bt.on_event(self, :trying_peer) { |s, p| display.untried_peers -= 1 unless display.untried_peers == 0 }

  display.total = bt.total_bytes
  display.start_timer

  while true
    handle_any_input(display)

    display.status = if bt.complete?
                       "seeding (download complete)"
                     elsif connecting
                       "connecting to peers"
                     else
                       "downloading"
                     end
    display.draw; Ncurses.refresh

    display.dlamt = bt.dlamt
    display.dlrate = bt.dlrate
    display.ulamt = bt.ulamt
    display.ulrate = bt.ulrate
    display.completed = bt.bytes_completed
    display.draw; Ncurses.refresh
    sleep(0.5)
  end
ensure
  Ncurses.curs_set(1)
  Ncurses.endwin()
end
