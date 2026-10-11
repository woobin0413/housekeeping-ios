require 'base64'
require 'json'
require 'uri'

address = ENV.fetch('HK_SUPABASE_URL', '').strip
unless address.empty?
  begin
    uri = URI.parse(address)
    local = ENV['CONFIGURATION'] == 'Debug' && uri.scheme == 'http' && uri.host == '127.0.0.1' && uri.port == 55321
    valid_url = uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? &&
      (uri.scheme == 'https' || local) && uri.userinfo.nil? && uri.query.nil? &&
      uri.fragment.nil? && ['', '/'].include?(uri.path)
  rescue URI::InvalidURIError
    valid_url = false
  end
  unless valid_url
    warn 'error: HouseKeeping project URL rejected. Use a public HTTPS origin or the Debug localhost endpoint.'
    exit 1
  end
end

# Reject privileged credentials before packaging. Never print the supplied value.
key = ENV.fetch('HK_SUPABASE_PUBLISHABLE_KEY', '').strip
valid = key.empty? || /\Asb_publishable_[A-Za-z0-9_-]{20,}\z/.match?(key)
unless valid
  begin
    parts = key.split('.', -1)
    if parts.length == 3 && parts.all? { |part| /\A[A-Za-z0-9_-]+\z/.match?(part) }
      claims = JSON.parse(Base64.urlsafe_decode64(parts[1]))
      valid = claims.is_a?(Hash) && claims['role'] == 'anon'
    end
  rescue ArgumentError, JSON::ParserError, TypeError
    valid = false
  end
end
unless valid
  warn 'error: HouseKeeping requires a public publishable or legacy anon key. Configuration rejected.'
  exit 1
end
