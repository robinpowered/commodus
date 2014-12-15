require 'sinatra'
require 'json'
require 'octokit'
require 'redis'

ACCESS_TOKEN = ENV['DAS_TOKEN']
REDIS_URI = ENV["REDISTOGO_URL"] || 'redis://localhost:6379'
NEEDED_PLOOS_ONES = 2
PLOOS_ONE_COMMENT = 'LGTM :+1:'

before do
  uri = URI.parse(REDIS_URI) 
  @redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
  @client ||= Octokit::Client.new(:access_token => ACCESS_TOKEN)
end

get '/' do
  "Welcome to the Robin CI server!"
end

post '/hooks' do
  request.body.rewind
  payload_body = request.body.read
  verify_signature(payload_body)

  @payload = JSON.parse(payload_body)

  if params['required_plus_ones']
    NEEDED_PLOOS_ONES ||= params['required_plus_ones']
  end

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

helpers do
  def process_opened_pull_request(pull_request)
    @redis.set(pull_request['base']['repo']['full_name'].to_s + ":" + pull_request['number'].to_s, 0)
    @client.create_status(
      pull_request['base']['repo']['full_name'],
      pull_request['head']['sha'],
      'pending',
      {'description' => 'RobinCI: Required plus ones (' + NEEDED_PLOOS_ONES.to_s + ') has yet to be reached.'}
    )
    return 200
  end

  def process_closed_pull_request(pull_request)
    @redis.del(pull_request['base']['repo']['full_name'].to_s + ":" + pull_request['number'].to_s)
    return 200
  end

  def process_created_issue_comment(issue_comment_payload)
    plus_ones = @redis.get(issue_comment_payload['repository']['full_name'].to_s + ":" + issue_comment_payload['issue']['number'].to_s)
    plus_ones = plus_ones.to_i + 1
    if plus_ones
      if plus_ones < NEEDED_PLOOS_ONES
        plus_ones_to_add = parse_comment_body(issue_comment_payload['comment']['body'])
        @redis.set(issue_comment_payload['repository']['full_name'].to_s + ":" + issue_comment_payload['issue']['number'].to_s, plus_ones)
        return 200
      else
        pull_request = @client.pull_request(issue_comment_payload['repository']['full_name'], issue_comment_payload['issue']['number'])
        @client.create_status(
          pull_request['base']['repo']['full_name'],
          pull_request['head']['sha'],
          'success',
          {'description' => 'RobinCI: Required plus ones (' + NEEDED_PLOOS_ONES.to_s + ') has been reached!'}
        )
        @redis.del(issue_comment_payload['repository']['full_name'].to_s + ":" + issue_comment_payload['issue']['number'].to_s)
        return 200
      end
    end
  end

  def parse_comment_body(comment_body)
    if comment_body.include? PLOOS_ONE_COMMENT
      return 1
    end
    return 0
  end
  def verify_signature(payload_body)
    signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), ENV['SECRET_TOKEN'], payload_body)
    return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
  end
end