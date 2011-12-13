require 'oauth'
require 'twitter'
require 'json'

module Lokka
  module TweetFeed
    CONSUMER_KEY    = "iBhYRxPYM89O0jjzYOgYEA"
    CONSUMER_SECRET = "lxfRU4srZqfP7JEIEkFj8UywCeJuXCOooETF1xtl11g"

    def self.registered(app)
      app.get '/admin/plugins/tweet_feed' do
        haml :"plugin/lokka-tweet_feed/views/index", :layout => :"admin/layout"
      end

      app.put '/admin/plugins/tweet_feed' do
        params.each {|k, v| Option.send("#{k}=", v) }
        flash[:notice] = 'Updated.'
        redirect '/admin/plugins/tweet_feed'
      end

      app.get '/admin/plugins/tweet_feed/request_token' do
        callback_url = tweet_feed_url + "/admin/plugins/tweet_feed/oauth_callback"
        request_token = Lokka::TweetFeed.consumer.get_request_token(:oauth_callback => callback_url)
        session[:request_token]        = request_token.token
        session[:request_token_secret] = request_token.secret
        redirect request_token.authorize_url
      end

      app.get '/admin/plugins/tweet_feed/oauth_callback' do
        request_token = OAuth::RequestToken.new(
          Lokka::TweetFeed.consumer,
          session[:request_token],
          session[:request_token_secret]
        )

        begin
          access_token = request_token.get_access_token(
            {},
            :oauth_token    => params[:oauth_token],
            :oauth_verifier => params[:oauth_verifier]
          )
        rescue OAuth::Unauthorized
          flash[:error] = "It failed in the attestation."
          redirect '/admin/plugins/tweet_feed'
        end

        Option.tweet_feed_token  = access_token.token
        Option.tweet_feed_secret = access_token.secret

        redirect '/admin/plugins/tweet_feed'
      end

      app.delete '/admin/posts/:id' do |id|
        post = Post.get(id)
        Lokka::TweetFeed.reject(post.id) #add_line
        post.destroy
        flash[:notice] = t('post_was_successfully_deleted')
        if post.draft
          redirect '/admin/posts?draft=true'
        else
          redirect '/admin/posts'
        end
      end

      app.helpers do
        def tweet_feed_url
          "#{request.env['rack.url_scheme']}://#{request.env['HTTP_HOST']}"
        end

        def post_admin_entry(entry_class)
          @name = entry_class.name.downcase
          @entry = entry_class.new(params[@name])
          if params['preview']
            render_preview @entry
          else
            @entry.user = current_user
            if @entry.save
              Lokka::TweetFeed.when_register(@entry, tweet_feed_url) #add_line
              flash[:notice] = t("#{@name}_was_successfully_created")
              redirect_after_edit(@entry)
            else
#              @field_names = FieldName.all(:order => :name.asc)
              @categories = Category.all.map {|c| [c.id, c.title] }.unshift([nil, t('not_select')])
              render_any :'entries/new'
            end
          end
        end

        def put_admin_entry(entry_class, id)
          @name = entry_class.name.downcase
          @entry = entry_class.get(id)
          if params['preview']
            render_preview entry_class.new(params[@name])
          else
            if @entry.update(params[@name])
              Lokka::TweetFeed.when_update(@entry, tweet_feed_url) #add_line
              flash[:notice] = t("#{@name}_was_successfully_updated")
              redirect_after_edit(@entry)
            else
              @categories = Category.all.map {|c| [c.id, c.title] }.unshift([nil, t('not_select')])
              render_any :'entries/edit'
            end
          end
        end
      end
    end

    class << self
      def consumer
        OAuth::Consumer.new(CONSUMER_KEY, CONSUMER_SECRET, :site => "http://twitter.com")
      end

      def configure
        Twitter.configure do |config|
          config.consumer_key       = CONSUMER_KEY
          config.consumer_secret    = CONSUMER_SECRET
          config.oauth_token        = Option.tweet_feed_token
          config.oauth_token_secret = Option.tweet_feed_secret
        end
      end

      def when_register(post, url)
        validation Lokka::TweetFeed.auth? do
          post.reload
          if post.draft
            Lokka::TweetFeed.check_draft(post.id)
          else
            Lokka::TweetFeed.tweet(post, url)
          end
        end
      end

      def when_update(post, url)
        validation Lokka::TweetFeed.unregistered?(post.id) do
          unless post.draft
            Lokka::TweetFeed.tweet(post,url)
          end
        end
      end

      def tweet(post, long_url)
        site, url = Site.first, long_url + "/#{post.id}"
        short_url = Lokka::TweetFeed.short_url(url)
        Lokka::TweetFeed.configure
        Twitter.update("#{Option.tweet_feed_post_message}: #{post.title} - #{site.title} #{short_url}")
        Lokka::TweetFeed.reject(post.id)
      end

      def short_url(long_url)
        case Option.tweet_feed_short_url
        when  "bitly"
          Lokka::TweetFeed.bitly_short_url(long_url)
        when "tiny"
          Lokka::TweetFeed.tiny_short_url(long_url)
        else
          long_url
        end
      end

      def bitly_short_url(long_url)
        user_id, api_key = Option.tweet_feed_bitly_user_id, Option.tweet_feed_bitly_api_key
        query   = "version=2.0.1&longUrl=#{long_url}&login=#{user_id}&apiKey=#{api_key}"
        results = JSON.parse(Net::HTTP.get("api.bit.ly", "/shorten?#{query}"))
        results["results"][long_url]["shortUrl"]
      rescue
        long_url
      end

      def tiny_short_url(long_url)
        query = "url=#{URI.encode(long_url)}"
        Net::HTTP.get("tinyurl.com", "/api-create.php?#{query}")
      rescue
        long_url
      end

      def check_draft(id)
        if Option.tweet_feed_unregistered
          Option.tweet_feed_unregistered = Lokka::TweetFeed.unregistered << id
        else
          Option.tweet_feed_unregistered = [id]
        end
      end

      def validation(obj = nil, &block)
        return nil unless obj
        block.call
      end

      def auth?
        Option.tweet_feed_token && Option.tweet_feed_secret
      end

      def unregistered
        eval Option.tweet_feed_unregistered
      end

      def unregistered?(id)
        if Option.tweet_feed_unregistered
          Lokka::TweetFeed.unregistered.include?(id)
        else
          false
        end
      end

      def reject(id)
        if Lokka::TweetFeed.auth? && Lokka::TweetFeed.unregistered?(id)
          Option.tweet_feed_unregistered = Lokka::TweetFeed.unregistered.reject{|i| i == id}
        end
      end
    end
  end
end
