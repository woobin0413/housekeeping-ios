require 'minitest/autorun'
require 'open3'
require 'base64'
require 'json'

class PublicKeyValidationTest < Minitest::Test
  def run_validator(key)
    Open3.capture3({ 'HK_SUPABASE_PUBLISHABLE_KEY' => key, 'HK_SUPABASE_URL' => '' }, '/usr/bin/ruby',
                  File.join(__dir__, 'validate-public-key.rb'))
  end

  def test_accepts_missing_and_public_keys
    ['', 'sb_publishable_abcdefghijklmnopqrstuvwxyz', jwt('anon')].each do |key|
      stdout, stderr, status = run_validator(key)
      assert status.success?
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_rejects_privileged_and_malformed_keys_without_echoing_them
    ['sb_secret_synthetic-administrator', jwt('service_role'), 'placeholder',
     'sb_publishable_short', 'e30.W10.signature', 'e30.bnVsbA.signature'].each do |key|
      stdout, stderr, status = run_validator(key)
      refute status.success?
      assert_empty stdout
      assert_includes stderr, 'Configuration rejected'
      refute_includes stderr, key
    end
  end

  def jwt(role)
    'e30.' + Base64.urlsafe_encode64({ role: role }.to_json, padding: false) + '.signature'
  end

  def test_url_validation_rejects_embedded_credentials_and_release_local_http
    [ ['https://test.supabase.co', 'Release', true],
      ['http://127.0.0.1:55321', 'Debug', true],
      ['http://127.0.0.1:55321', 'Release', false],
      ['https://person:synthetic-password@test.supabase.co', 'Debug', false],
      ['https://test.supabase.co?token=synthetic', 'Debug', false],
      ['http://example.com', 'Debug', false],
      ['not a URL', 'Debug', false] ].each do |address, configuration, accepted|
      stdout, stderr, status = Open3.capture3(
        { 'HK_SUPABASE_URL' => address, 'HK_SUPABASE_PUBLISHABLE_KEY' => '', 'CONFIGURATION' => configuration },
        '/usr/bin/ruby', File.join(__dir__, 'validate-public-key.rb'))
      assert_equal accepted, status.success?
      assert_empty stdout
      refute_includes stderr, address
    end
  end
end
