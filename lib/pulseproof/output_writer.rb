# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "tempfile"

module PulseProof
  class OutputWriter
    def self.json(path, payload, pretty: true, verify: false)
      directory = File.dirname(File.expand_path(path))
      FileUtils.mkdir_p(directory)
      tempfile = Tempfile.new(["pulseproof", ".json"], directory)
      encoded = "#{pretty ? JSON.pretty_generate(payload) : JSON.generate(payload)}\n"
      expected_digest = Digest::SHA256.hexdigest(encoded) if verify
      tempfile.write(encoded)
      tempfile.flush
      tempfile.fsync
      tempfile.close
      File.rename(tempfile.path, path)
      File.chmod(0o644, path)
      if verify
        actual_digest = Digest::SHA256.file(path).hexdigest
        raise InvariantError, "persisted JSON bytes differ from the validated serialization: #{path}" unless actual_digest == expected_digest
      end
      path
    ensure
      tempfile.close! if tempfile && !tempfile.closed?
    end
  end
end
