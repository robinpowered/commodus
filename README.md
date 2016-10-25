# Robinpowered Commodus

A Sinatra powered, heroku ready application that will track open GitHub pull requests, and search comments for the :+1:

![](http://3.bp.blogspot.com/-CmAKAZkYCtQ/UFHmbs36DXI/AAAAAAAAC4M/QCtrQRcmoBk/s1600/thumbs-up-gladiator.gif)

## Usage

Simply run `bundler install` and `ruby app.rb` to startup the Sinatra app locally.

Use `git push heroku master` after cloning to deploy to a heroku server.

Setup a [personal access token](https://help.github.com/articles/creating-an-access-token-for-command-line-use/) with `repo` scope with `export ACCESS_TOKEN=token` or `heroku config:set ACCESS_TOKEN=token`.

Setup a GitHub webhook on your repo/organization that points to `https://yourserver.herokuapp.com/hooks` with `pull_request`, `issue_comment`, `pull_request_review`, and `pull_request_review_comment` feeds. Make sure to set your `SECRET_TOKEN` env variable.

By default, Commodus will look for comments in the open PR for a `:+1:` or a `:-1:` and calculate the net change per comment.

If you want to change the default number of :+1:s needed for a repository set the `required_plus_ones` POST parameter in your webhook.


[![Deploy](https://www.herokucdn.com/deploy/button.png)](https://heroku.com/deploy)