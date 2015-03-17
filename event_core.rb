require 'fcntl'
require 'monitor'

# TODO:
# - ThreadSource (source updated safely from another thread)
# - Removal of sources
# - Convenience functions add_timeout, add_idle

module EventCore

  class Event

  end

  class Source

    def initialize
      @triggers = []
      @closed = false
      @ready = false
      @timeout_secs = nil
    end

    def ready?
      @ready
    end

    def ready!(event_data=nil)
      @ready = true
      @event_data = event_data
    end

    def timeout
      @timeout_secs
    end

    def select_io()
      nil
    end

    def consume_event_data!
      raise "Source not ready: #{self}" unless ready?
      data = @event_data
      @event_data = nil
      @ready = false
      data
    end

    def event_factory(event_data)
      event_data
    end

    def closed?
      @closed
    end

    def close!
      @closed = true
      @triggers = []
    end

    # Add a trigger callback block to call each time an event is ready.
    # If the source has an event instance it will be passed to the block.
    # If the block returns with 'next true' it will be removed from the source.
    def add_trigger(&block)
      @triggers << block
    end

    def notify_triggers()
      event_data = consume_event_data!
      event = event_factory(event_data)
      @triggers.delete_if do |trigger|
        trigger.call(event)
      end
    end
  end

  class PipeSource < Source

    attr_reader :rio, :wio

    def initialize
      super()
      @rio, @wio = IO.pipe
      @rio.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC | Fcntl::O_NONBLOCK)
      #@wio.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC | Fcntl::O_NONBLOCK)
      @buffer_size = 4096
    end

    def select_io
      @rio
    end

    def consume_event_data!
      @rio.read_nonblock(@buffer_size)
    end

    def closed?
      @rio.closed?
    end

    def close!
      super.close
      @rio.close unless @rio.closed?
      @wio.close unless @wio.closed?
    end

  end

  class UnixSignalSource < PipeSource

    def initialize(*signals)
      super()
      @signals = signals.map { |sig| sig.is_a?(Integer) ? Signal.signame(sig) : sig.to_s}
      @signals.each do |sig_name|
        Signal.trap(sig_name) do |signo|
          puts "TRAP SIG #{signo}"
          @wio.write("#{signo}\n")
        end
      end
    end

    def event_factory(event_data)
      event_data.split('\n').map { |datum| datum.to_i }
    end

  end

  class TimeoutSource < Source
    def initialize(secs)
      super()
      @timeout_secs = secs
      @next_timestamp = Time.now.to_f + secs
    end

    def ready?
      return true if @ready

      now = Time.now.to_f
      if now >= @next_timestamp
        ready!
        @next_timestamp = now + @timeout_secs
        return true
      end
      false
    end
  end

  class EventLoop

    def initialize
      @sources = []

      # Only ever set @do_quit through the quit() method!
      # Otherwise the state of the loop will be undefiend
      @do_quit = false
      @quit_source = PipeSource.new
      @quit_source.add_trigger {|event| @do_quit = true }
      @sources << @quit_source

      # We use a monitor, not a mutex, becuase Ruby mutexes are not reentrant,
      # and we need reentrancy to be able to add sources from within trigger callbacks
      @monitor = Monitor.new
    end

    # Add an event source to check in the loop. You can do this from any thread,
    # or from trigger callbacks, or whenever you please.
    def add_source(source)
      @monitor.synchronize {
        @sources << source
      }
    end

    def quit
      # Does not require locking. If any data comes through in what ever form,
      # we quit the loop
      @quit_source.wio.write('q')
    end

    def run
      loop do
        step
        break if @do_quit
      end
    end

    def step
      @monitor.synchronize {
        _step
      }
    end

    private
    def _step
      # This function assumes it's holding the lock on @monitor

      # Collect sources
      ready_sources = []
      select_sources_by_ios = {}
      timeouts = []

      @sources.delete_if do |source|
        if source.closed?
          true
        else
          ready_sources << source if source.ready?

          unless source.select_io.nil?
            select_sources_by_ios[source.select_io] = source
          end

          timeouts << source.timeout unless source.timeout.nil?

          false
        end
      end

      # Dispatch all sources marked ready
      ready_sources.each { |source|
        source.notify_triggers
      }

      # Note1: select_sources_by_ios is never empty - we always have the quit source in there.
      #        We need that assumption to ensure timeouts work
      # Note2: timeouts.min is nil if there are no timeouts, causing infinite blocking - as intended
      read_ios, write_ios, exception_ios = IO.select(select_sources_by_ios.keys, [], [], timeouts.min)

      # On timeout read_ios will be nil
      unless read_ios.nil?
        read_ios.each { |io|
          select_sources_by_ios[io].notify_triggers
        }
      end

    end
  end

end

loop = EventCore::EventLoop.new
signals = EventCore::UnixSignalSource.new(1, 2)
signals.add_trigger { |event|
  puts "EVENT: #{event}"
  loop.quit if event.first == 2
}
loop.add_source(signals)

timeout = EventCore::TimeoutSource.new(2.0)
timeout.add_trigger { |event| puts "Time: #{Time.now.sec}"}
loop.add_source(timeout)

i = 0
timeout2 = EventCore::TimeoutSource.new(0.24)
timeout2.add_trigger {|event|
  puts "-- #{Time.now.sec}"
  i += 1
  next true if i == 10
}
loop.add_source(timeout2)

loop.run
puts "Loop exited gracefully"
