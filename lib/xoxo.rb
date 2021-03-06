require 'gmail'
require 'yaml'
require 'ostruct'
require 'pry' # For debug purpose
require 'fileutils'
require 'tickle'
require 'erb'
require_relative 'service'

class PickCandy < Service
  class NoAvailableCandyError < StandardError
  end

  def initialize(files, exclude_list)
    @files = files
    @exclude_list = exclude_list
  end

  private

  def execute
    key = available_candies.keys.sample
    fail NoAvailableCandyError unless key
    Candy.new key, available_candies[key]
  end

  def available_candies
    @_available_candies ||= candies.delete_if { |k, _| @exclude_list.include?(k) }
  end

  def candies
    @_candies ||= @files.group_by do |file|
      File.basename(file).sub(/#{Regexp.escape(File.extname(file))}$/, '')
    end
  end
end

# A candy can have a quote and/or an attached file
class Candy
  attr_reader :name, :quote, :attachments

  def initialize(name, files)
    @name = name
    @quote = nil
    @attachments = []
    files.each do |file|
      case File.extname(file)
      when '.txt'
        @quote = File.read(file).chomp
      else
        @attachments << file
      end
    end
  end

  def to_s
    "Candy '#{name}', '#{quote}', #{attachments.join(', ')}"
  end
end

# Read emails
# gmail.inbox.emails(:unread).each do |email|
#   sender = email.sender.first
#   sender_email = sender.mailbox + '@' + sender.host
#   next unless sender_email == recipient
#   puts email.subject
#   email.read!
# end
#

class Context
  attr_reader :working_dir, :users_dir
  def initialize(working_dir)
    # TODO: Use constants
    @working_dir = File.expand_path(working_dir)
    @users_dir = File.join(@working_dir, 'users')
    @config_file_path = File.join(@working_dir, 'config.yml')
  end

  def config
    OpenStruct.new(YAML.load_file(@config_file_path))
  end
end

class CheckDeliveryForAllUsers < Service
  def initialize(users)
    @users = users
  end

  private

  def execute
    @users.each do |user|
      CheckDelivery.run!(user)
    end
  end
end

# TODO: Refactor
module GmailSession
  def self.get
    Gmail.connect(@config.username, @config.password)
  end

  def self.init(config)
    @config = config
  end
end

class DeliverCandy < Service
  def initialize(user, candy)
    @user = user
    @candy = candy
  end

  private

  def execute
    # TODO: Refactor
    gmail = GmailSession.get

    candy_email = CandyEmailPresenter.new(@user, @candy)

    email = gmail.compose do
      to candy_email.recipient
      subject candy_email.subject
      #text_part do
      #  body candy.quote
      #end
      html_part do
        content_type 'text/html; charset=UTF-8'
        body candy_email.body
      end
      candy_email.attachments.each do |attachment|
        add_file attachment
      end
    end

    email.deliver!
    gmail.logout
  end
end

class CandyEmailPresenter
  def initialize(user, candy)
    @user = user
    @candy = candy
  end

  def recipient
    @user.name
  end

  def attachments
    @candy.attachments
  end

  def subject
    'Your daily candy'
  end

  def body
    renderer = ERB.new(File.read(File.join('templates', 'candy.html.erb')))
    renderer.result(binding)
  end
end

class User
  attr_reader :dir, :name

  def initialize(user_dir)
    @dir = user_dir
    @name = File.basename(@dir)

    # TODO: Use constant
    @data_file_path = File.join(user_dir, 'data.yml')

    # TODO: This code doesn't belong here
    @data = { 'done' => [] }
    if File.exist?(@data_file_path)
      @data = YAML.load_file(@data_file_path)
    end
  end

  def candy_files
    # TODO: Use constant
    Dir.glob(File.join(@dir, 'candies', '**', '*.*'))
  end

  def excluded_candies
    @data['done'].map { |i| i['candy_name'] }
  end

  def candy_delivered(candy)
    exclude_candy(candy)
    @data['deliver_candy_at'] = next_delivery_date.to_s
  end

  def deliver_candy_at
    return Time.now unless @data['deliver_candy_at']
    Time.parse @data['deliver_candy_at']
  end

  def next_delivery_date
    now = Time.now.utc
    start = Time.utc(now.year, now.month, now.day, deliver_candy_at.hour, deliver_candy_at.min)
    Tickle.parse('everyday', start: start, next_only: true).utc
  end

  def exclude_candy(candy)
    @data['done'] << { 'candy_name' => candy.name, 'sent_at' => Time.now.utc }
  end

  def save!
    File.open(@data_file_path, 'w') { |f| f << @data.to_yaml }
  end
end

class CheckDelivery < Service
  def initialize(user)
    @user = user
  end

  private

  def execute
    return unless should_deliver_candy?
    begin
      candy = PickCandy.run!(@user.candy_files, @user.excluded_candies)
    rescue PickCandy::NoAvailableCandyError
      puts "No candy found for #{@user.name}"
      return
    end
    puts candy
    DeliverCandy.run!(@user, candy)
    @user.candy_delivered(candy)
    # TODO: This will be messy because the user is never reloaded
    @user.save!
  end

  def should_deliver_candy?
    return true unless @user.deliver_candy_at
    @user.deliver_candy_at <= Time.now.utc
  end
end

class Xoxo < Service
  def initialize(context)
    @context = context
  end

  private

  def execute
    # TODO: Manage interuptions
    while true
      run_once
      puts "Going to sleep for 10 minutes..."
      sleep 10 * 60 # 10 minutes
    end
    # TODO: Use a valid return value
  end

  def run_once
    # Check all users sequentially
    CheckDeliveryForAllUsers.run!(users)
    # TODO: Check the xoxo inbox
  end

  def users
    Dir.glob(File.join(@context.users_dir, '*')).map { |dir| User.new(dir) }
  end
end
