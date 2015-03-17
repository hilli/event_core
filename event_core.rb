require 'fcntl'

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
      raise "Source not ready" unless ready?
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
    end

    def add_trigger(&block)
      @triggers << block
    end

    def notify_triggers()
      event_data = consume_event_data!()
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
      @wio.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC | Fcntl::O_NONBLOCK)
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
          @wio.write_nonblock("#{signo}\n")
          # FIXME: ensure written, pipe is async
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
      now = Time.now.to_f
      if now >= @next_timestamp
        ready!
        @next_timestamp = now + @timeout_secs
      end
      false
    end
  end

  class EventLoop

    def initialize
      @sources = []

      @quit_source = PipeSource.new
      @quit_source.add_trigger {|event| raise "Loop Quit: #{event}"}
      @sources << @quit_source
    end

    def add_source(source)
      @sources << source
    end

    def quit
      @quit_source.wio.write_nonblock('q')
    end

    def run

      while true
        puts "Loop"

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

        unless select_sources_by_ios.empty?
          puts "Selecting: #{select_sources_by_ios}"
          # Note: timeouts.min is nil if there are no timeouts, causing infinite blocking as intended
          read_ios, write_ios, exception_ios = IO.select(select_sources_by_ios.keys, [], [], timeouts.min)

          if read_ios.nil?
            # timed out
          else
            read_ios.each { |io|
              puts "READY: #{io}"
              ready_sources << select_sources_by_ios[io]
            }
          end
        end

        # Dispatch all sources marked ready
        ready_sources.each { |source|
          source.notify_triggers
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

timeout2 = EventCore::TimeoutSource.new(0.5)
timeout2.add_trigger {|event| puts "."}
loop.add_source(timeout2)

loop.run
