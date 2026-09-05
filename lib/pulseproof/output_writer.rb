# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"

module PulseProof
  class OutputWriter
    def self.json(path, payload)
      directory = File.dirname(File.expand_path(path))
      FileUtils.mkdir_p(directory)
      tempfile = Tempfile.new(["pulseproof", ".json"], directory)
      tempfile.write(JSON.pretty_generate(payload))
      tempfile.write("\n")
      tempfile.flush
      tempfile.fsync
      tempfile.close
      File.rename(tempfile.path, path)
      File.chmod(0o644, path)
      path
    ensure
      tempfile.close! if tempfile && !tempfile.closed?
    end
  end
end
