EventCore - General Purpose Main Loop for Ruby
==============================================
Travis CI Status: ![Travis CI Build Status](https://travis-ci.org/kamstrup/event_core.svg?branch=master)

Provides the core of a fully asynchronous application. Modeled for simplicity and robustness,
less so for super high load or real time environments. Reservations aside, EventCore should
still easily provide low enough latency and high enough throughput for most applications.

Features:
 - Call async functions in a sync calling style, like C# async/await
 - Timeouts.
 - Fire-once events.
 - Fire-repeatedly events.
 - Thread safety.
 - Simple idiom for integrating with external threads.
 - Unix signals dispatched on the main loop to avoid the dreaded "trap context".
 - Core is parked in a ```select()``` when the loop is idle to incur negligible load on the system.
 - Async process controls - aka Process.spawn() with callbacks on the main loop thread and automatic reaping of children.

EventCore is heavily inspired by the proven architecture of the GLib main loop from the GNOME project.
Familiarity with that API should not be required though, the EventCore API is small an easy to learn.

Examples
--------

Do something every 200ms for 3s then quit:

```rb
require 'event_core'
loop = EventCore::MainLoop.new
loop.add_timeout(0.2) { puts 'Something' }
loop.add_once(3.0) { puts 'Quitting'; loop.quit }
loop.run
puts 'Done'
```

Sit idle and print the names of the signals it receives:
```rb
...
loop.add_unix_signal('HUP', 'USR1', 'USR2') { |signals|
  puts "Got signals: #{signals.map { |signo| Signal.signame(signo) } }"

}

puts "Kill me with PID #{Process.pid}, fx 'kill -HUP #{Process.pid}'"
loop.run
puts 'Done'
```

Spin off a child process and get a callback in the main loop when it terminates:
```rb
...
loop.spawn("sleep 10") { |status|
  puts "Child process terminated: #{status}"
}
```
(Note - ```loop.spawn``` accepts all the same parameters as convential Ruby ```Process.spawn```.
Also the _status_ argument is a ```Process::Status``` like ```$?```)

Do something on the main loop when a long running thread detects there is work to do:
```rb
require 'thread'
...

thr = Thread.new {
  sleep 5 # Working hard! Or hardly working, eh!?
  loop.add_once { puts 'Yay! Back on the main loop' }
  sleep 5
  loop.add_once { puts 'I quit!'; loop.quit }
}

loop.run
thr.join
puts 'All done'
```

Do something repeatedly on each loop iteration, 10 times:
```rb
...
i = 0
loop.add_idle {
    i += 1
    puts "Count #{i}"
    next false if i == 10
}
```

Do intense blocking computations on the mainloop, but allow the loop to run every once in a while by using fibers:
```rb
loop.add_fiber {
    # heavy data crunching here
    loop.yield
    # more data crunching
    loop.yield
    # even more crunching - ad lib!
}
```

Async Calls with Sync Calling Style
-----------------------------------
By leveraging standard Ruby Fibers EventCore allows you to call async functions in a synchronous style. Similarly to
the popular feature in C# et al:
```rb
loop.add_fiber {
  puts 'Waiting for slow result...'
  slow_result = loop.yield { |task|
    Thread.new { sleep 10; task.done('This took 10s') }
  }
  puts slow_result
}
# prints 'Waiting for slow result...' and then after 10s 'This took 10s'
```



Concepts and Architecture
-------------------------
TODO, mainloop, sources, triggers, idles, timeouts, select io, fibers

Caveats & Known Bugs
--------------------

 - If you use multiple main loops on different threads the reaping of child processes using the async spawn is currently broken
 - Unix signal handlers, for the same signal, between two main loops (in the same process) will clobber each other
 - Unlike GMainLoop, EventCore does not have a concept of priority. All sources on the main loop have equal priority.
 - MainLoop.spawn does not work in JRuby (other than 9k, which should be ok). This is not likely to be fixable; see https://github.com/jruby/jruby/issues/2684

FAQ
---
 - *Is it any good?*
   Yes
 - *Can I have several main loops in the same process*
   Yes, but see caveat above, wrt unix signals and loop.spawn()
 - Is this stable? Production ready?
   Yes. It's been running on production services for months now without a single issue.

