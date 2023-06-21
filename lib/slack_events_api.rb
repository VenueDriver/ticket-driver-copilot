require 'logger'
require 'net/http'
require 'uri'
require 'aws-sdk-ssm'
require 'awesome_print'
require_relative 'gpt'

class SlackEventsAPIHandler
  def initialize(event)
    @logger = Logger.new(STDOUT)
    @event = JSON.parse(event)
    @logger.info("Slack event: #{@event}")
    
    ssm_client = Aws::SSM::Client.new(region: ENV['AWS_REGION'] || 'us-east-1')
    environment = ENV['ENV'] || 'development'

    param_name = "slack_app_id-#{environment}"
    @app_id = ssm_client.get_parameter(
      name: param_name, with_decryption: true
    ).parameter.value

    param_name = "slack_app_access_token-#{environment}"
    @access_token = ssm_client.get_parameter(
      name: param_name, with_decryption: true
    ).parameter.value
  end

  def dispatch
    case @event['type']
    when 'url_verification'
      url_confirmation
    when 'event_callback'
      handle_event_callback
    else
      # Handle unrecognized event types if necessary
    end
  end

  def url_confirmation
    @event['challenge']
  end

  def handle_event_callback
    case @event['event']['type']
    when 'message'
      message
    else
      # Handle other event types if necessary
    end
  end

  def message
    message_text = @event['event']['text']
    @logger.info("Slack message event with text: \"#{message_text}\"")
  
    unless is_event_from_me?
      conversation_history = get_conversation_history(
        @event['event']['channel'])
      conversation_history_string =
        if conversation_history.nil?
          "Error getting conversation history"
        else
          conversation_history.slice(0,3).reverse.map do |message|
            "#{message['user_profile']['real_name']} said: #{message['message'][0..140]}"
          end.join("\n\n")
        end
      
      send_message(
        @event['event']['channel'], conversation_history_string)
    end
  end
  
  def send_message(channel, text)
    uri = URI.parse("https://slack.com/api/chat.postMessage")
  
    request = Net::HTTP::Post.new(uri)
    request.content_type = "application/x-www-form-urlencoded"
    request["Authorization"] = "Bearer #{@access_token}"
    request.set_form_data(
      "channel" => channel,
      "text" => text,
    )
  
    req_options = {
      use_ssl: uri.scheme == "https",
    }
  
    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end.tap do |response|
      @logger.info("Sent message to Slack: #{response.body}")
    end
  end

  def is_event_from_me?
    @event['event']['app_id'] == @app_id
  end

  def get_conversation_history(channel_id)
    uri = URI("https://slack.com/api/conversations.history?channel=#{channel_id}")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{@access_token}"
  
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    response = http.request(request)
    response_body = JSON.parse(response.body)
  
    if response_body['ok']
      messages = response_body['messages']
      messages.map do |message|
        {
          'user_id' => message['user'],
          'user_profile' => get_user_profile(message['user']),
          'message' => message['text']
        }
      end.tap do |response|
        @logger.info("Conversation history:\n#{response.to_json}")
      end
    else
      @logger.error("Error getting conversation history: #{response_body['error']}")
      nil
    end
  end

  def get_user_profile(user_id)
    @profile_cache ||= {}
    if @profile_cache[user_id] && Time.now - @profile_cache[user_id][:timestamp] < 3600
      # Return the cached result if it's less than an hour old
      return @profile_cache[user_id][:data]
    end

    uri = URI("https://slack.com/api/users.profile.get?user=#{user_id}")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{@access_token}"
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    response = http.request(request)
    response_body = JSON.parse(response.body)
    
    if response_body['ok']
      profile = response_body['profile']
      @logger.info("User profile: #{profile}")
      
      # Cache the result with a timestamp
      @profile_cache[user_id] = { data: profile, timestamp: Time.now }
      
      profile
    else
      @logger.error("Error getting user profile: #{response_body['error']}")
      nil
    end
  end
  
end