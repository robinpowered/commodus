require 'sinatra'
require 'json'
require 'octokit'
require 'redis'

# Constants
ACCESS_TOKEN = ENV['DAS_TOKEN']
REDIS_URI = ENV["REDISTOGO_URL"] || 'redis://localhost:6379'
SECRET_TOKEN = ENV['SECRET_TOKEN']
NEEDED_PLOOS_ONES = 2
PLOOS_ONE_COMMENT = 'LGTM :+1:'

# Setup our clients
before do
  uri = URI.parse(REDIS_URI) 
  @redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
  @client ||= Octokit::Client.new(:access_token => ACCESS_TOKEN)
end

# Main index page
get '/' do
  "Welcome to the Robin CI server!"
end

# Webhook endpoint
# TODO persist data via postgres
post '/hooks' do
  # Grab our payload
  request.body.rewind
  payload_body = request.body.read

  # Verify our signature is coming from Github
  verify_signature(payload_body)

  @payload = JSON.parse(payload_body)

  # If $required_plus_ones has been specified, change the default
  if params['required_plus_ones']
    NEEDED_PLOOS_ONES ||= params['required_plus_ones']
  end

  # A webhook has been received from Github
  case request.env['HTTP_X_GITHUB_EVENT']
  when "pull_request"
    if @payload["action"] == "opened"
      process_opened_pull_request(@payload["pull_request"])
    elsif @payload["action"] == "closed"
      process_closed_pull_request(@payload["pull_request"])
    end
  when "issue_comment"
    if @payload["action"] == "created"
      process_created_issue_comment(@payload)
    end
  end
end

# Helper methods
helpers do

  # A pull request has been opened for a particular repo
  def process_opened_pull_request(pull_request)
    @redis.set(pull_request['base']['repo']['full_name'].to_s + ":" + pull_request['number'].to_s, 0)
    # Set the PR status to be pending
    @client.create_status(
      pull_request['base']['repo']['full_name'],
      pull_request['head']['sha'],
      'pending',
      {'description' => 'RobinCI: Required plus ones (' + plus_ones.to_s + '/' + NEEDED_PLOOS_ONES.to_s + ') has yet to be reached.'}
    )
    return 200
  end

  # A pull request has been closed
  def process_closed_pull_request(pull_request)
    # Delete the PR from the redis store
    @redis.del(pull_request['base']['repo']['full_name'].to_s + ":" + pull_request['number'].to_s)
    return 200
  end

  # An issue comment has been reported
  def process_created_issue_comment(issue_comment_payload)
    plus_ones = @redis.get(issue_comment_payload['repository']['full_name'].to_s + ":" + issue_comment_payload['issue']['number'].to_s)
    plus_ones = plus_ones.to_i + 1

    if plus_ones
      # The :+1: threshold still hasn't been reached, store the incremented value
      if plus_ones < NEEDED_PLOOS_ONES
        plus_ones_to_add = parse_comment_body(issue_comment_payload['comment']['body'])
        @redis.set(issue_comment_payload['repository']['full_name'].to_s + ":" + issue_comment_payload['issue']['number'].to_s, plus_ones)
        return 200
      else
        # Threshold has been reached
        pull_request = @client.pull_request(issue_comment_payload['repository']['full_name'], issue_comment_payload['issue']['number'])
        # Set commit status to sucessful
        @client.create_status(
          pull_request['base']['repo']['full_name'],
          pull_request['head']['sha'],
          'success',
          {'description' => 'RobinCI: Required plus ones (' + plus_ones.to_s + '/' + NEEDED_PLOOS_ONES.to_s + ') has been reached!'}
        )
        # Delete the lingering store
        @redis.del(issue_comment_payload['repository']['full_name'].to_s + ":" + issue_comment_payload['issue']['number'].to_s)
        return 200
      end
    end
  end

  # Simply parse the comment for plus ones
  def parse_comment_body(comment_body)
    if comment_body.include? PLOOS_ONE_COMMENT
      return 1
    end
    return 0
  end

  # Ensure the delivered webhook is from Github
  def verify_signature(payload_body)
    signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), SECRET_TOKEN, payload_body)
    return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
  end
end