# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"

module PulseProof
  class OutputWriter
    def self.json(path, payload, pretty: true, verify: false)
      directory = File.dirname(File.expand_path(path))
      FileUtils.mkdir_p(directory)
      tempfile = Tempfile.new(["pulseproof", ".json"], directory)
      tempfile.write(pretty ? JSON.pretty_generate(payload) : JSON.generate(payload))
      tempfile.write("\n")
      tempfile.flush
      tempfile.fsync
      tempfile.close
      File.rename(tempfile.path, path)
      File.chmod(0o644, path)
      if verify
        restored = JSON.parse(File.read(path, encoding: "UTF-8"))
        raise InvariantError, "persisted JSON differs from the validated in-memory artifact: #{path}" unless restored == payload
      end
      path
    rescue JSON::ParserError => error
      raise InvariantError, "persisted JSON cannot be read back: #{path} (#{error.message})"
    ensure
      tempfile.close! if tempfile && !tempfile.closed?
    end
  end
end
