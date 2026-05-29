require "../spec_helper"

describe Mystral::CompileWorker do
  it "processes a settled URI through the injected processor (debounce 0)" do
    received = [] of {String, String?}
    worker = Mystral::CompileWorker.new(IO::Memory.new, async: false, debounce: Time::Span.zero,
      processor: ->(uri : String, text : String?) { received << {uri, text}; nil })
    worker.enqueue("file:///a.cr", "code")
    worker.drain_now
    received.should eq([{"file:///a.cr", "code"}])
  end

  it "does NOT process a URI that hasn't settled yet" do
    received = [] of String
    worker = Mystral::CompileWorker.new(IO::Memory.new, async: false, debounce: 10.seconds,
      processor: ->(uri : String, _t : String?) { received << uri; nil })
    worker.enqueue("file:///a.cr", "code")
    worker.drain_now # nothing is older than 10s
    received.should be_empty
  end

  it "keeps only the last text snapshot per URI (last edit wins)" do
    received = [] of String?
    worker = Mystral::CompileWorker.new(IO::Memory.new, async: false, debounce: Time::Span.zero,
      processor: ->(_u : String, text : String?) { received << text; nil })
    worker.enqueue("file:///a.cr", "first")
    worker.enqueue("file:///a.cr", "second")
    worker.drain_now
    received.should eq(["second"])
  end

  it "swaps in a processor via use_processor" do
    hits = 0
    worker = Mystral::CompileWorker.new(IO::Memory.new, async: false, debounce: Time::Span.zero)
    worker.use_processor(->(_u : String, _t : String?) { hits += 1; nil })
    worker.enqueue("file:///a.cr")
    worker.drain_now
    hits.should eq(1)
  end
end
