# frozen_string_literal: true
require 'net/http'
require 'uri'
require 'json'

module AegisRelease
  # No implicit retries: a lost response to a mutation must be reconciled first.
  class AscApi
    ORIGIN = 'https://api.appstoreconnect.apple.com'

    def initialize(token:, transport: nil, before_mutation: nil)
      @token, @before_mutation = token, before_mutation
      @transport = transport || lambda do |uri, request|
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 90,
                        max_retries: 0) do |http|
          result = http.request(request)
          { status: result.code.to_i, body: result.body.to_s }
        end
      end
    end

    def uri_for(path, query = {})
      uri = URI.parse(path.start_with?('https://') ? path : "#{ORIGIN}/v1/#{path}")
      AegisRelease.require!(uri.scheme == 'https' && uri.host == 'api.appstoreconnect.apple.com' &&
                            uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil? &&
                            uri.path.start_with?('/v1/') && !uri.path.include?('..'), 'Unsafe ASC API URL')
      uri.query = URI.encode_www_form(query) unless query.empty?
      uri
    end

    def call(method, path, body = nil, query = {})
      uri = uri_for(path, query)
      @token.refresh! if @token.expired?
      request = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method).new(uri)
      request['Authorization'] = "Bearer #{@token.text}"
      request['Content-Type'] = request['Accept'] = 'application/json'
      request.body = JSON.generate(body) if body
      @before_mutation&.call unless method == :get
      result = @transport.call(uri, request)
      status = result.fetch(:status).to_i
      AegisRelease.require!((200..299).cover?(status), "ASC #{method.to_s.upcase} failed (HTTP #{status}); inspect store state before retrying")
      result.fetch(:body).empty? ? {} : JSON.parse(result.fetch(:body))
    rescue IOError, SystemCallError, Timeout::Error, JSON::ParserError, OpenSSL::SSL::SSLError
      raise Error, 'ASC response unavailable; outcome may be unknown. Read status before any retry'
    end

    def get(path, query = {}) = call(:get, path, nil, query)
    def post(path, body) = call(:post, path, body)
    def patch(path, body) = call(:patch, path, body)

    def collection(path, query = {})
      result = { 'data' => [], 'included' => [] }
      visited = {}
      loop do
        uri = uri_for(path, query).to_s
        AegisRelease.require!(!visited[uri] && visited.length < 100, 'ASC pagination cycle or limit exceeded')
        visited[uri] = true
        page = get(uri)
        AegisRelease.require!(page['data'].is_a?(Array), 'ASC collection response is invalid')
        result['data'].concat(page.fetch('data'))
        result['included'].concat(page.fetch('included', []))
        path = page.dig('links', 'next')
        break unless path
        query = {}
      end
      result
    end
  end
end
