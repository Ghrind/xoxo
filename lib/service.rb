class Service
  attr_reader :result

  def self.run(*args)
    new(*args).run
  end

  def self.run!(*args)
    new(*args).run!
  end

  def initialize
  end

  def run!
    run
    result
  end

  def run
    @result = execute
    executed!
    self
  end

  def executed?
    @executed.present?
  end

  private

  def execute
    # Your service logic goes here
  end

  def executed!
    @executed = true
  end
end
