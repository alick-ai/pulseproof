# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class LocalePortabilityTest < Minitest::Test
  def test_cli_suite_survives_unset_c_posix_and_utf8_locales
    locales = {
      "unset" => { "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil },
      "C" => { "LANG" => "C", "LC_ALL" => "C", "LC_CTYPE" => "C" },
      "POSIX" => { "LANG" => "POSIX", "LC_ALL" => "POSIX", "LC_CTYPE" => "POSIX" },
      "UTF-8" => { "LANG" => "en_US.UTF-8", "LC_ALL" => nil, "LC_CTYPE" => nil }
    }
    locales.each do |name, environment|
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby,
        "-Itest", "test/challenge_cli_test.rb", chdir: PulseProofTestData::ROOT, binmode: true)
      # Bound a failure message: a JSON equality failure can otherwise dump
      # a megabyte-long report and hide the useful locale diagnostic.
      detail = (stdout + stderr).force_encoding(Encoding::UTF_8).scrub[-2000, 2000] ||
        (stdout + stderr).force_encoding(Encoding::UTF_8).scrub
      assert status.success?, "CLI suite failed under #{name}:\n#{detail}"
      assert_includes stdout, "0 failures, 0 errors"
    end
  end
end
