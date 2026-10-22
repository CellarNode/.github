# CEL-2795 / CEL-2819: the static-site deploy notification is the LAST STEP of `deploy-production`, not a separate job.
#
# A separate `discord-deploy` job queued for a runner of the 2-runner pool after the deploy had finished, and this workflow's
# concurrency group (static-deploy-<slug>-<ref>) is held until every job of the run ends, so the next push to main for the same site
# waited behind it. This test pins the shape, when the step posts, that the webhook secret reaches only that step, that its script is a
# verbatim subset of discord-notify.yaml and behaves (executed under node, stubbed GitHub and Discord), and then mutates all of it.
#
# Run: ruby .github/tests/deploy-static-discord-in-job.test.rb      (exit 0 = every contract holds)

require_relative "support/discord_inline_script"

DIR = File.expand_path("../workflows", __dir__)
MAIN = "refs/heads/main".freeze
BRANCH = "refs/heads/feature/x".freeze
GITHUB_SCRIPT = "actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b".freeze
OIDC_VARS = %w[ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN].freeze

def load_yaml(name)
  YAML.safe_load(File.read(File.join(DIR, name)), aliases: true)
end

# --- a tiny evaluator for the step `if` expression ---------------------------------------------------------------------------
EXPR = /\A(?:\s+|always\(\)|!cancelled\(\)|github\.event_name|github\.ref|job\.status|'[^']*'|&&|\|\||==|!=|!|\(|\)|true|false)+\z/

def evaluate(expression, event: "push", ref: MAIN, status: "success")
  source = expression.to_s.gsub(/\$\{\{|\}\}/, "").gsub(/\s+/, " ").strip
  return status == "success" if source.empty? # no `if` means the implicit success()

  abort "unsupported expression construct: #{source}" unless source.match?(EXPR)
  # GitHub prepends an implicit success() to an `if` with no status function (always(), !cancelled(), success(), failure()).
  implicit_success = source.match?(/always\(\)|cancelled\(\)/) ? true : status == "success"
  ruby = source
         .gsub("always()", "true")
         .gsub("!cancelled()", "(#{status.inspect} != \"cancelled\")")
         .gsub("github.event_name", event.inspect)
         .gsub("github.ref", ref.inspect)
         .gsub("job.status", status.inspect)
         .gsub("'", '"')
  implicit_success && eval(ruby) # rubocop:disable Security/Eval  -- tokens validated against EXPR above
end

# --- the workflow contract ---------------------------------------------------------------------------------------------------
def workflow_failures(wf)
  out = []
  jobs = wf.fetch("jobs")
  out << "the separate discord-deploy job must be gone (it holds the workflow's concurrency group)" if jobs.key?("discord-deploy")

  # Every remaining call of the reusable notifier must be a PR lifecycle job: none may run for a push to main.
  jobs.each do |name, job|
    next unless job["uses"].to_s.end_with?("discord-notify.yaml")

    guard = job["if"].to_s
    out << "#{name}: still calls discord-notify and is not restricted to pull_request_target / the trusted-preview policy" unless guard.include?("github.event_name == 'pull_request_target'") || guard.include?("needs.preview-policy.outputs.trusted == 'true'")
    out << "#{name}: must not be the deploy notification (event: deploy)" if job.dig("with", "event") == "deploy"
  end

  production = jobs.fetch("deploy-production")
  steps = production.fetch("steps")
  notify = steps.last
  out << "deploy-production: the notify step must be the LAST step (the run must end when the deploy ends)" unless notify.fetch("name", "") == "Discord deploy notification"
  out << "deploy-production: the notify step must be continue-on-error: true (a notification problem must never fail the deploy)" unless notify["continue-on-error"] == true
  out << "deploy-production: the notify step must use the pinned github-script (got #{notify['uses'].inspect})" unless notify["uses"] == GITHUB_SCRIPT
  env = notify.fetch("env", {})
  out << "deploy-production: the notify step must send the deploy event" unless env["EVENT"] == "deploy"
  out << "deploy-production: the notify step must read the status from job.status" unless env["STATUS"] == "${{ job.status }}"
  out << "deploy-production: DEPLOY_MODE must be deployed" unless env["DEPLOY_MODE"] == "deployed"
  out << "deploy-production: the notify step must pass the Discord tags" unless env["TAGS"] == "${{ inputs.discord_tags }}"
  out << "deploy-production: the webhook must come from the DISCORD_WEBHOOK_URL secret" unless env["WEBHOOK_URL"] == "${{ secrets.DISCORD_WEBHOOK_URL }}"
  OIDC_VARS.each { |name| out << "deploy-production: the notify step must blank #{name}" unless env[name] == "" }

  # The webhook secret reaches ONLY the notify step: nothing at workflow or job level, no other step of any job.
  out << "the webhook secret must not be set at workflow level" if wf.fetch("env", {}).to_s.include?("DISCORD_WEBHOOK_URL")
  out << "deploy-production: the webhook secret must not be set at job level" if production.fetch("env", {}).to_s.include?("DISCORD_WEBHOOK_URL")
  steps[0...-1].each { |step| out << "deploy-production: step #{step['name'].inspect} must not receive the webhook secret" if step.to_s.include?("DISCORD_WEBHOOK_URL") }
  jobs.each do |name, job|
    next if name == "deploy-production" || job.key?("uses")

    (job["steps"] || []).each { |step| out << "#{name}: step #{step['name'].inspect} must not receive the webhook secret" if step.to_s.include?("DISCORD_WEBHOOK_URL") }
  end

  # The job token stays minimal: no pull-requests scope (that is why the merged-PR lookup degrades to the commit message).
  out << "deploy-production: permissions must stay exactly contents: read and id-token: write" unless production["permissions"] == { "contents" => "read", "id-token" => "write" }

  # When does the step post? It must post for a push to main whatever the job status, and never for anything else.
  [MAIN, BRANCH].product(%w[push workflow_dispatch pull_request_target schedule], %w[success failure cancelled]).each do |ref, event, status|
    want = event == "push" && ref == MAIN
    got = evaluate(notify["if"], event: event, ref: ref, status: status)
    out << "notify step on #{event} #{ref} status=#{status}: posts=#{got}, expected #{want}" if got != want
  end
  out
end

# --- run it ------------------------------------------------------------------------------------------------------------------
FAILURES = []
workflow = load_yaml("deploy-static-website.yaml")
notify = load_yaml("discord-notify.yaml")
inline = workflow.fetch("jobs").fetch("deploy-production").fetch("steps").last.dig("with", "script").to_s
notify_text = notify_script(notify)

FAILURES.concat(workflow_failures(workflow))
FAILURES.concat(sync_failures(inline, notify_text))
FAILURES.concat(behavior_failures(inline))

# --- the checks must themselves be able to fail ------------------------------------------------------------------------------
def deep_copy(object)
  Marshal.load(Marshal.dump(object))
end

def last_step(wf)
  wf["jobs"]["deploy-production"]["steps"].last
end

workflow_mutations = {
  "the separate discord-deploy job comes back" => ->(wf) { wf["jobs"]["discord-deploy"] = { "needs" => "deploy-production", "uses" => "./.github/workflows/discord-notify.yaml", "with" => { "event" => "deploy" } } },
  "a PR notify job loses its guard" => ->(wf) { wf["jobs"]["discord-thread-close"]["if"] = "true" },
  "the notify step loses always()" => ->(wf) { last_step(wf)["if"] = last_step(wf)["if"].sub("always() && ", "") },
  "the notify step drops its if entirely" => ->(wf) { last_step(wf).delete("if") },
  "the notify step also posts on a manual dispatch" => ->(wf) { last_step(wf)["if"] = "${{ always() }}" },
  "the notify step posts for a branch" => ->(wf) { last_step(wf)["if"] = last_step(wf)["if"].sub(" && github.ref == 'refs/heads/main'", "") },
  "the notify step stops being continue-on-error" => ->(wf) { last_step(wf).delete("continue-on-error") },
  "the notify step is no longer last" => ->(wf) { wf["jobs"]["deploy-production"]["steps"].push({ "name" => "Later step", "run" => "true" }) },
  "status is hard-coded" => ->(wf) { last_step(wf)["env"]["STATUS"] = "success" },
  "unpinned github-script" => ->(wf) { last_step(wf)["uses"] = "actions/github-script@v7" },
  "the notify step keeps the OIDC token variable" => ->(wf) { last_step(wf)["env"].delete("ACTIONS_ID_TOKEN_REQUEST_TOKEN") },
  "the webhook secret moves to the job env" => ->(wf) { wf["jobs"]["deploy-production"]["env"] = { "DISCORD_WEBHOOK_URL" => "${{ secrets.DISCORD_WEBHOOK_URL }}" } },
  "the webhook secret leaks into the build step" => ->(wf) { wf["jobs"]["deploy-production"]["steps"].find { |s| s["name"] == "Build production" }["env"]["DISCORD_WEBHOOK_URL"] = "${{ secrets.DISCORD_WEBHOOK_URL }}" },
  "the webhook secret leaks into a preview step" => ->(wf) { wf["jobs"]["deploy-preview"]["steps"].first["env"] = { "DISCORD_WEBHOOK_URL" => "${{ secrets.DISCORD_WEBHOOK_URL }}" } },
  "the job gains pull-requests: read" => ->(wf) { wf["jobs"]["deploy-production"]["permissions"]["pull-requests"] = "read" },
}
workflow_mutations.each do |label, mutate|
  mutated = deep_copy(workflow)
  caught = begin
    mutate.call(mutated)
    !workflow_failures(mutated).empty?
  rescue SystemExit, KeyError, NoMethodError
    true
  end
  FAILURES << "mutation `#{label}` was NOT caught (the workflow contract is too weak)" unless caught
end

sync_mutations = {
  "the deployed wording drifts in the notifier" => ->(inl, nt) { [inl, nt.sub("'Deployed to production'", "'Shipped'")] },
  "the inlined deploy branch drifts" => ->(inl, nt) { [inl.sub("Compare Changes", "Compare"), nt] },
  "the metadata parser is dropped from the inline script" => ->(inl, nt) { [inl.sub("function parseMetadata", "function parseMetadataX"), nt] },
  "discordPost drifts" => ->(inl, nt) { [inl.sub("wait: 'true'", "wait: 'false'"), nt] },
  "the tag map drifts" => ->(inl, nt) { [inl.sub("1484207128288694443", "1"), nt] },
}
sync_mutations.each do |label, mutate|
  inl2, nt2 = mutate.call(inline, notify_text)
  FAILURES << "mutation `#{label}` was NOT caught by the sync check" if sync_failures(inl2, nt2).empty?
end

behavior_mutations = {
  "the bot-author check is dropped" => ->(inl) { inl.sub("c.user?.login !== 'github-actions[bot]'", "false") },
  "the status colour is wrong" => ->(inl) { inl.sub("3066993", "1") },
  "the webhook guard is dropped" => ->(inl) { inl.sub("if (!webhook) {", "if (false) {") },
  "a Discord outage throws" => ->(inl) { inl.sub("core.warning(`Discord POST failed: ${res.status}`);", "throw new Error('x');") },
}
behavior_mutations.each do |label, mutate|
  FAILURES << "mutation `#{label}` was NOT caught by the behaviour scenarios" if behavior_failures(mutate.call(inline)).empty?
end

if FAILURES.empty?
  puts "static deploy discord in job: OK (shape, secret confined to the last step, #{2 * 4 * 3} step-condition cases, sync with discord-notify, " \
       "#{SCENARIOS.length} node scenarios, #{workflow_mutations.length + sync_mutations.length + behavior_mutations.length} mutations caught)"
else
  warn "static deploy discord in job FAILED:\n  - #{FAILURES.join("\n  - ")}"
  exit 1
end
