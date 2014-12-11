require 'sinatra'
require 'json'

post '/hooks' do
  payload = JSON.parse(params[:payload])
  "Well, it worked!"
end
