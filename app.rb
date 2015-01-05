require 'sinatra'
require 'json'
require 'octokit'
require 'redis'

# Constants
ACCESS_TOKEN = ENV['ACCESS_TOKEN']
REDIS_URI = ENV["REDISTOGO_URL"] || 'redis://localhost:6379'
SECRET_TOKEN = ENV['SECRET_TOKEN']
NEEDED_PLUS_ONES = 2
PLUS_ONE_COMMENT = ':+1:'
NEG_ONE_COMMENT = ':-1:'

# Setup our clients
before do
  uri = URI.parse(REDIS_URI) 
  @redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
  @client ||= Octokit::Client.new(:access_token => ACCESS_TOKEN)
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
    NEEDED_PLUS_ONES ||= params['required_plus_ones']
  end

  # A webhook has been received from Github
  case request.env['HTTP_X_GITHUB_EVENT']
  when "pull_request"
    if @payload["action"] == "opened" || @payload["action"] == "synchronize"
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
    pr_name = pull_request['base']['repo']['full_name'].to_s
    pr_number = pull_request['number'].to_s
    commit_hash = pull_request['head']['sha'].to_s

    @redis.hset(pr_name + ":" + pr_number, commit_hash, 0)

    # Set the PR status to be pending
    @client.create_status(
      pr_name,
      commit_hash,
      'pending',
      {
        'description' => 'Commodus: Required plus ones (0/' + NEEDED_PLUS_ONES.to_s + ') has yet to be reached.',
        'context' => 'robinpowered/commodus'
      }
    )
    return 200
  end

  # A pull request has been closed
  def process_closed_pull_request(pull_request)
    pr_name = pull_request['base']['repo']['full_name'].to_s
    pr_number = pull_request['number'].to_s
    current_commit_hash = pull_request['head']['sha'].to_s

    # Delete the PR from the redis store
    @redis.del(pr_name + ":" + pr_number)
    return 200
  end

  # An issue comment has been reported
  def process_created_issue_comment(issue_comment_payload)
    pr_name = issue_comment_payload['repository']['full_name'].to_s
    pr_number = issue_comment_payload['issue']['number'].to_s

    pull_request = @client.pull_request(pr_name, pr_number)
    current_commit_hash = pull_request['head']['sha'].to_s

    plus_ones = @redis.hget(pr_name + ":" + pr_number, current_commit_hash)

    # Ensure that a key actually exists
    if !plus_ones.nil?
      plus_ones_to_add = parse_comment_body(issue_comment_payload['comment']['body'])

      # If there is no net change
      if plus_ones_to_add === 0
        return 200
      end

      plus_ones = plus_ones.to_i + plus_ones_to_add

      # Ensure the count isn't negative
      if plus_ones < 0
        plus_ones = 0
      end

      @redis.hset(pr_name + ":" + pr_number, current_commit_hash, plus_ones)

      if plus_ones >= NEEDED_PLUS_ONES
        # Set commit status to sucessful
        @client.create_status(
          pr_name,
          current_commit_hash,
          'success',
          {
            'description' => 'Commodus: Required plus ones (' + plus_ones.to_s + '/' + NEEDED_PLUS_ONES.to_s + ') has been reached!',
            'context' => 'robinpowered/commodus'
          }
        )
      else
        @client.create_status(
          pr_name,
          current_commit_hash,
          'pending',
          {
            'description' => 'Commodus: Required plus ones (' + plus_ones.to_s + '/' + NEEDED_PLUS_ONES.to_s + ') has yet to be reached.',
            'context' => 'robinpowered/commodus'
          }
        )
      end
    end

    return 200
  end

  # Simply parse the comment for plus ones
  def parse_comment_body(comment_body)
    net_pluses = comment_body.scan(PLUS_ONE_COMMENT).count
    net_pluses = net_pluses - comment_body.scan(NEG_ONE_COMMENT).count

    if net_pluses > 0
      net_pluses = 1
    elsif net_pluses < 0
      net_pluses = -1
    end

    return net_pluses
  end

  # Ensure the delivered webhook is from Github
  def verify_signature(payload_body)
    signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), SECRET_TOKEN, payload_body)
    return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
  end
end