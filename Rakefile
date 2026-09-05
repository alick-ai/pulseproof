# frozen_string_literal: true

require "rake/testtask"
require_relative "lib/pulseproof"

ROOT = File.expand_path(__dir__)
PUBLIC_QUEUE = File.join(ROOT, "data/operations_queue_10.json")

def selected_queue
  PulseProof::InputLocator.queue(root: ROOT)
end

Rake::TestTask.new do |task|
  task.libs << "lib"
  task.pattern = "test/**/*_test.rb"
end

task default: :test

desc "Generate artifacts from the currently selected queue"
task :route do
  sh "bin/pulseproof run"
end

desc "Generate browser replay data"
task demo: :route do
  sh "bin/pulseproof demo --queue data/operations_queue_10.json"
end

desc "Run strict and official public validators"
task validate: :route do
  sh "bin/pulseproof validate"
  if File.expand_path(selected_queue) == PUBLIC_QUEUE
    sh "ruby scripts/validate_10.rb routing_decisions_test.json"
  else
    puts "official public validator skipped: stopcode queue is selected; strict validator passed"
  end
end

desc "Lint and build the frontend"
task :frontend do
  Dir.chdir("web") do
    sh "npm run lint"
    sh "npm run build"
  end
end

desc "Verify that no queue phone is present in generated artifacts"
task pii: [:route, :demo] do
  queues = [selected_queue, PUBLIC_QUEUE].uniq.map { |path| PulseProof::InputLoader.json(path) }
  phones = queues.flatten.map { |operation| operation.dig("payout_requisite", "sbp", "phone") }.compact
  artifacts = %w[routing_decisions_test.json routing_report_test.json web/public/demo-data.json]
  leaks = artifacts.flat_map do |path|
    text = File.read(path)
    phones.select { |phone| text.include?(phone) }.map { |phone| [path, phone] }
  end
  abort "PII gate failed: #{leaks.map(&:first).uniq.join(', ')}" if leaks.any?
  puts "PII gate passed: #{phones.length} sensitive values absent from #{artifacts.length} artifacts"
end

desc "Verify LOCAL artifact layout on main (not commit or publication)"
task submission_layout: :route do
  branch = `git branch --show-current`.strip
  actual = branch.empty? ? "no branch" : branch
  abort "submission layout failed: expected Git branch main, got #{actual}" unless branch == "main"
  required = %w[routing_decisions_test.json routing_report_test.json]
  missing = required.reject { |path| File.file?(File.join(ROOT, path)) }
  abort "submission layout failed: missing #{missing.join(', ')}" if missing.any?
  puts "LOCAL_LAYOUT_PASS: #{required.join(' + ')} in repository root; commit and publication NOT verified"
end

desc "Run executable public requirements evidence and save an isolated report"
task :evidence do
  sh "bin/pulseproof evidence --human --evidence-output outputs/requirements-evidence.json"
end

desc "Rehearse stopcode generation, commit, push and Git verification in a disposable local clone"
task :rehearse_submission do
  sh "ruby scripts/rehearse_submission.rb"
end

desc "Fail unless the organizer stopcode queue is present"
task :require_stopcode do
  path = selected_queue
  unless PulseProof::InputLocator.test_queue?(path)
    abort "stopcode gate stopped: operations_queue_test.json is not present; public sample outputs must not be submitted"
  end
  puts "Stopcode queue selected: #{path}"
end

desc "Generate organizer-queue artifacts locally: tests, validation and privacy (commit/publish separately)"
task submit: [:require_stopcode, :test, :validate, :pii, :ruby_majority, :submission_layout] do
  puts "PulseProof stopcode gate: GENERATED_LOCALLY — not proof of commit or publication"
  puts "Commit the reviewed code and both JSON files to main, then run rake submission_git; verify publication separately"
end

desc "Read-only check: required JSON committed on main and valid for the selected organizer queue; remote NOT verified"
task :submission_git do
  begin
    result = PulseProof::SubmissionGitCheck.new(root: ROOT).verify!
    path = selected_queue
    abort "submission Git check stopped: operations_queue_test.json is missing; organizer input remains required" unless PulseProof::InputLocator.test_queue?(path)
    sh "bin/pulseproof", "validate", "--queue", path
    puts "#{result.fetch('status')}: #{result.fetch('commit')} on main; both committed JSON match local files and passed queue validation"
    puts "REMOTE_UNVERIFIED: no push performed, no remote publication checked; organizer input authenticity is the operator's responsibility"
  rescue PulseProof::InputError => error
    abort error.message
  end
end

desc "Verify the written Ruby-majority requirement"
task :ruby_majority do
  ruby_files = Dir["{bin,lib}/**/*"].select { |path| File.file?(path) && (path.end_with?(".rb") || path == "bin/pulseproof") }
  frontend_files = (Dir["web/src/**/*.{js,jsx,ts,tsx,css,html}"] + Dir["web/*.{js,ts,html}"]).select { |path| File.file?(path) }
  ruby_lines = ruby_files.inject(0) { |sum, path| sum + File.readlines(path).length }
  frontend_lines = frontend_files.inject(0) { |sum, path| sum + File.readlines(path).length }
  ratio = ruby_lines.to_f / [ruby_lines + frontend_lines, 1].max * 100
  abort "Ruby-majority gate failed: #{ratio.round(2)}%" unless ratio > 50
  puts "Ruby-majority source-line estimate: #{ratio.round(2)}% (#{ruby_lines} production Ruby / #{frontend_lines} frontend incl. CSS, HTML and config; excludes tests, organizer scripts, generated data and dependencies)"
end

desc "Full LOCAL deterministic release gate (not a Git delivery check)"
task release: [:test, :validate, :pii, :ruby_majority, :submission_layout, :evidence, :frontend] do
  puts "PulseProof release gate: LOCAL_CHECKS_PASS — Git commit and remote publication NOT verified"
end

desc "Public jury walkthrough: cascade alternatives, inverse policy and hard-rule boundary"
task jury: :test do
  puts "PUBLIC SIMULATION ONLY: isolated outputs, no real payouts and no stopcode submission"
  sh "bin/pulseproof run --policy config/planner.json --queue data/operations_queue_10.json --decisions outputs/planner-decisions.json --report outputs/planner-report.json"
  sh "bin/pulseproof explain op_101 --decisions outputs/planner-decisions.json --report outputs/planner-report.json"
  sh "bin/pulseproof challenge op_101 --prefer vipay --factor count_potential_change --report outputs/planner-report.json --challenge-output outputs/challenge-op101.json"
  sh "bin/pulseproof challenge op_103 --prefer vipay --report outputs/planner-report.json --challenge-output outputs/challenge-hard-boundary.json"
  sh "bin/pulseproof run --policy config/planner.json --queue data/operations_queue_10.json --simulation-mode approve --decisions outputs/planner-public-decisions.json --report outputs/planner-public-report.json"
  sh "ruby scripts/validate_10.rb outputs/planner-public-decisions.json"
end
