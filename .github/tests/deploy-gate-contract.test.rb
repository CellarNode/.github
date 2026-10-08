# CEL-2322: contract test for the PRODUCTION deploy gate of the shared deploy workflows.
#
# Marcus's rule: production deploys only from main. A non-main workflow_dispatch still builds and pushes its
# `branch-<slug>-<sha7>` image (kept for a future preview environment) but must NEVER deploy, and must say so. This
# parses deploy-backend.yaml and deploy-cloudrun.yaml, evaluates the `deploy` job's `if:` (and the notice job's) over the
# full event x ref x input truth table, pins the branch-tag slug, and then MUTATES the expressions in memory to prove the
# table would catch a dropped ref check, an inverted event check, or a dropped argocd_deploy check.
#
# Run: ruby .github/tests/deploy-gate-contract.test.rb      (exit 0 = every contract holds)

require "yaml"
require "open3"

WORKFLOWS = %w[deploy-backend.yaml deploy-cloudrun.yaml].freeze
DIR = File.expand_path("../workflows", __dir__)
FAILURES = []

def fail!(msg)
  FAILURES << msg
end

# Evaluate the tiny subset of the GitHub expression language these gates use. Anything outside the allowed token set
# aborts: a new construct must be taught to this test deliberately.
ALLOWED = /\A(?:\s+|'[^']*'|github\.ref_name|github\.ref|github\.event_name|inputs\.argocd_deploy|&&|\|\||==|!=|\(|\)|true|false)+\z/

def evaluate(expr, event:, ref:, argocd_deploy:)
  src = expr.to_s.gsub(/\$\{\{|\}\}/, "").gsub(/\s+/, " ").strip
  abort "gate expression uses an unsupported construct: #{src}" unless src.match?(ALLOWED)
  ruby = src
         .gsub("github.event_name", event.inspect)
         .gsub("github.ref_name", ref.sub(%r{\Arefs/(heads|tags)/}, "").inspect)
         .gsub("github.ref", ref.inspect)
         .gsub("inputs.argocd_deploy", argocd_deploy.inspect)
         .gsub("'", '"')
  eval(ruby) # rubocop:disable Security/Eval  -- tokens validated against ALLOWED above
end

# [event, ref, argocd_deploy (:default = the declared default), deploys?, notice?]
MAIN = "refs/heads/main".freeze
BRANCH = "refs/heads/feature/x".freeze
SCENARIOS = [
  ["push", MAIN, :default, true, false],
  ["workflow_dispatch", MAIN, :default, true, false],
  ["workflow_dispatch", BRANCH, :default, false, true],
  ["workflow_dispatch", "refs/tags/v1", :default, false, true],
  ["pull_request", "refs/pull/7/merge", :default, false, false],
  ["pull_request_target", MAIN, :default, false, false],
  # the event gate must hold on its own, independent of the ref (defence in depth)
  ["pull_request", MAIN, :default, false, false],
  ["schedule", MAIN, :default, false, false],
  ["workflow_run", MAIN, :default, false, false],
  ["push", BRANCH, :default, false, false],
  # argocd_deploy (pull-model callers): only meaningful when the workflow declares the input
  ["push", MAIN, true, true, false],
  ["workflow_dispatch", MAIN, true, true, false],
  ["push", MAIN, false, false, false],
  ["workflow_dispatch", MAIN, false, false, false],
  ["workflow_dispatch", BRANCH, false, false, true]
].freeze

def table_failures(name, deploy_if, notice_if, declared_default)
  out = []
  SCENARIOS.each do |event, ref, input, deploys, notice|
    value = input == :default ? declared_default : input
    next if declared_default.nil? && input != :default # input not declared in this workflow (stacked-PR tolerance)
    got = evaluate(deploy_if, event: event, ref: ref, argocd_deploy: value.nil? ? true : value)
    out << "#{name}: deploy `#{event}` on #{ref} (argocd_deploy=#{value.inspect}) => #{got}, expected #{deploys}" if got != deploys
    got_notice = evaluate(notice_if, event: event, ref: ref, argocd_deploy: true)
    out << "#{name}: notice `#{event}` on #{ref} => #{got_notice}, expected #{notice}" if input == :default && got_notice != notice
  end
  out
end

def mutations(deploy_if, declared_default)
  m = {
    "drop the main ref check" => deploy_if.gsub(/github\.ref == 'refs\/heads\/main'\s*&&\s*/, ""),
    "invert the event check" => deploy_if.gsub("github.event_name == 'push'", "github.event_name != 'push'"),
    "allow pull_request" => deploy_if.gsub("github.event_name == 'workflow_dispatch'", "github.event_name == 'pull_request'")
  }
  m["drop the argocd_deploy check"] = deploy_if.gsub(/inputs\.argocd_deploy\s*&&\s*/, "") unless declared_default.nil?
  m
end

WORKFLOWS.each do |file|
  wf = YAML.safe_load(File.read(File.join(DIR, file)), aliases: true)
  jobs = wf.fetch("jobs")
  deploy_if = jobs.fetch("deploy").fetch("if").to_s
  notice = jobs["deploy-skipped-notice"] || abort("#{file}: the deploy-skipped-notice job is missing")
  notice_if = notice.fetch("if").to_s
  input = (wf["on"] || wf[true]).fetch("workflow_call").fetch("inputs", {})["argocd_deploy"]
  declared_default = input.nil? ? nil : input.fetch("default")
  if input.nil?
    fail!("#{file}: must declare the argocd_deploy workflow_call input (pull-model apps skip the ArgoCD deploy with it)")
  elsif input["type"] != "boolean" || declared_default != true
    fail!("#{file}: argocd_deploy must be a boolean defaulting to true (existing callers must keep deploying)")
  end
  dd = jobs["discord-deploy"]
  unless dd && Array(dd["needs"]).sort == %w[build deploy] && dd.dig("with", "status").to_s.include?("needs.build.result")
    fail!("#{file}: discord-deploy must need [build, deploy] and report the build result when the deploy is skipped by design")
  end

  FAILURES.concat(table_failures(file, deploy_if, notice_if, declared_default))
  unless notice.fetch("steps").map(&:to_s).join.include?("Production deploys only from main")
    fail!("#{file}: the notice job must say that production deploys only from main")
  end

  # The gate test must itself be able to fail: every mutation of the real expression has to be caught by the table.
  mutations(deploy_if, declared_default).each do |label, mutated|
    caught = begin
      !table_failures(file, mutated, notice_if, declared_default).empty?
    rescue SystemExit
      true
    end
    fail!("#{file}: mutation `#{label}` was NOT caught by the truth table (the gate test is too weak)") unless caught
  end
end

# --- branch-tag slug (CEL-2322): `branch-<slug>-<sha7>` must never look like a bare sha7, runs collapse, no edge hyphens.
def slug_command(file)
  line = File.read(File.join(DIR, file)).lines.find { |l| l.include?("SLUG=$(") } or abort("#{file}: SLUG pipeline not found")
  line.strip
end

SLUG_CASES = {
  "main" => "main",
  "Feature/My_Branch.v2" => "feature-my-branch-v2",
  "foo___bar" => "foo-bar",
  "foo///bar..baz" => "foo-bar-baz",
  "release/2026-10" => "release-2026-10",
  "---lead-and-trail---" => "lead-and-trail",
  "///" => "",
  # truncation at 30 chars must not leave a trailing hyphen: 29 x's + '_' + 'tail'
  ("x" * 29) + "_tail" => "x" * 29
}.freeze

WORKFLOWS.each do |file|
  cmd = slug_command(file)
  SLUG_CASES.each do |ref, want|
    script = "set -eu; GITHUB_REF_NAME=#{ref.inspect}; #{cmd}; printf '%s' \"$SLUG\""
    out, status = Open3.capture2("bash", "-c", script)
    fail!("#{file}: slug command failed for #{ref.inspect}") unless status.success?
    fail!("#{file}: slug for #{ref.inspect} => #{out.inspect}, expected #{want.inspect}") unless out == want
    tag = "branch-#{out.empty? ? 'ref' : out}-abc1234"
    fail!("#{file}: tag #{tag} matches the pull-model sha7 allow-regex") if tag.match?(/\A[0-9a-f]{7}\z/)
    fail!("#{file}: tag #{tag} has a doubled or edge hyphen artifact") if tag.include?("--")
  end
end

if FAILURES.empty?
  puts "deploy gate contract: OK (#{WORKFLOWS.join(', ')}: truth table, notice, argocd_deploy default, mutations caught, slug cases)"
else
  warn "deploy gate contract FAILED:\n  - #{FAILURES.join("\n  - ")}"
  exit 1
end
