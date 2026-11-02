# CEL-2795: the backend deploy notification is the LAST STEP of the job that ends the run, not a separate job.
#
# A separate `discord-deploy` job queued for a runner of the 2-runner pool AFTER the deploy had finished, and the caller's concurrency
# group (deploy-<workflow>-<ref>) is held until every job of the run ends, so later main deploys waited behind it. This test pins:
#   1. the shape: no notify job left in a main-deploy run, a continue-on-error notify step LAST in `build` and in `deploy`;
#   2. when each step posts (truth tables over event x ref x job status x argocd_deploy), including "never for a cancelled run";
#   3. that the inlined script is a verbatim subset of discord-notify.yaml (so the wording cannot drift) AND that it behaves: it is
#      executed under node with a stubbed GitHub and Discord;
#   4. that the webhook secret reaches only those two steps;
# and then mutates all of it to prove each check can fail.
#
# Run: ruby .github/tests/discord-deploy-in-job.test.rb      (exit 0 = every contract holds)

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

DIR = File.expand_path("../workflows", __dir__)
FAILURES = []
MAIN = "refs/heads/main".freeze
BRANCH = "refs/heads/feature/x".freeze
GITHUB_SCRIPT = "actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b".freeze

def fail!(message)
  FAILURES << message
end

def load_yaml(name)
  YAML.safe_load(File.read(File.join(DIR, name)), aliases: true)
end

# --- a tiny evaluator for the step `if` expressions ------------------------------------------------------------------------
EXPR = /\A(?:\s+|always\(\)|!cancelled\(\)|github\.event_name|github\.ref|job\.status|inputs\.argocd_deploy|'[^']*'|&&|\|\||==|!=|!|\(|\)|true|false)+\z/

def evaluate(expression, event: "push", ref: MAIN, status: "success", argocd_deploy: true, step: true)
  source = expression.to_s.gsub(/\$\{\{|\}\}/, "").gsub(/\s+/, " ").strip
  return status == "success" if source.empty? # no `if` means the implicit success()

  abort "unsupported expression construct: #{source}" unless source.match?(EXPR)
  # GitHub prepends an implicit success() to an `if` with no status function (always(), !cancelled(), success(), failure()).
  # (Only for a STEP: a job-level `if` is evaluated before the job runs, so the job's own status does not apply.)
  implicit_success = !step || source.match?(/always\(\)|cancelled\(\)/) ? true : status == "success"
  ruby = source
         .gsub("always()", "true")
         .gsub("!cancelled()", "(#{status.inspect} != \"cancelled\")")
         .gsub("github.event_name", event.inspect)
         .gsub("github.ref", ref.inspect)
         .gsub("job.status", status.inspect)
         .gsub("inputs.argocd_deploy", argocd_deploy.inspect)
         .gsub("'", '"')
  implicit_success && eval(ruby) # rubocop:disable Security/Eval  -- tokens validated against EXPR above
end

# --- 1 + 2 + 4: the workflow contract ----------------------------------------------------------------------------------------
def workflow_failures(wf)
  out = []
  jobs = wf.fetch("jobs")
  out << "deploy-backend: the separate discord-deploy job must be gone (it holds the caller's concurrency group)" if jobs.key?("discord-deploy")

  # No remaining call of the reusable notifier may run for a push: the PR lifecycle jobs are PR-only.
  jobs.each do |name, job|
    next unless job["uses"].to_s.end_with?("discord-notify.yaml")

    out << "deploy-backend: #{name} still calls discord-notify and is not restricted to pull_request events" unless job["if"].to_s.include?("github.event_name == 'pull_request'")
    out << "deploy-backend: #{name} must not be the deploy notification (event: deploy)" if job.dig("with", "event") == "deploy"
  end

  build = jobs.fetch("build")
  deploy = jobs.fetch("deploy")
  build_step = build.fetch("steps").last
  deploy_step = deploy.fetch("steps").last
  out << "build: the notify step must be the LAST step (the run must end when the job ends)" unless build_step.fetch("name", "").start_with?("Discord deploy notification")
  out << "deploy: the notify step must be the LAST step (the run must end when the deploy ends)" unless deploy_step.fetch("name", "").start_with?("Discord deploy notification")

  [["build", build_step], ["deploy", deploy_step]].each do |label, step|
    out << "#{label}: the notify step must be continue-on-error: true (a notification problem must never fail the job)" unless step["continue-on-error"] == true
    out << "#{label}: the notify step must use the pinned github-script (got #{step['uses'].inspect})" unless step["uses"] == GITHUB_SCRIPT
    env = step.fetch("env", {})
    out << "#{label}: the notify step must send the deploy event" unless env["EVENT"] == "deploy"
    out << "#{label}: the notify step must read the status from job.status" unless env["STATUS"] == "${{ job.status }}"
    out << "#{label}: the webhook must come from the DISCORD_WEBHOOK_URL secret" unless env["WEBHOOK_URL"] == "${{ secrets.DISCORD_WEBHOOK_URL }}"
    out << "#{label}: the notify step must pass the Discord tags" unless env["TAGS"] == "${{ inputs.discord_tags }}"
  end
  out << "build: DEPLOY_MODE must be deployed unless argocd_deploy=false, then published" unless build_step.dig("env", "DEPLOY_MODE") == "${{ inputs.argocd_deploy && 'deployed' || 'published' }}"
  out << "deploy: DEPLOY_MODE must be deployed (the job only runs when argocd_deploy is true)" unless deploy_step.dig("env", "DEPLOY_MODE") == "deployed"
  out << "build: IMAGE_TAG must come from the build's own output" unless build_step.dig("env", "IMAGE_TAG") == "${{ steps.vars.outputs.image_tag }}"
  out << "deploy: IMAGE_TAG must come from needs.build" unless deploy_step.dig("env", "IMAGE_TAG") == "${{ needs.build.outputs.image_tag }}"
  out << "the two steps must run the same script (one YAML anchor)" unless build_step.dig("with", "script") == deploy_step.dig("with", "script")

  # build: runs the PR lookup the old job did, read-only
  out << "build: needs pull-requests: read for the merged-PR and thread lookup" unless build.dig("permissions", "pull-requests") == "read"
  out << "build: must not gain write permissions" if build.fetch("permissions", {}).any? { |scope, level| level == "write" && scope != "id-token" }
  out << "deploy: the 15 minute timeout must stay" unless deploy["timeout-minutes"] == 15

  # The webhook secret reaches ONLY those two steps: nothing at workflow or job level, no other step.
  out << "the webhook secret must not be set at workflow level" if wf.fetch("env", {}).to_s.include?("DISCORD_WEBHOOK_URL")
  jobs.each do |name, job|
    out << "#{name}: the webhook secret must not be set at job level" if job.fetch("env", {}).to_s.include?("DISCORD_WEBHOOK_URL")
    (job["steps"] || []).each do |step|
      next if step.equal?(build_step) || step.equal?(deploy_step)

      out << "#{name}: step #{step['name'].inspect} must not receive the webhook secret" if step.to_s.include?("DISCORD_WEBHOOK_URL")
    end
  end

  # When does each step post? Independent formulas over the whole table.
  events = %w[push workflow_dispatch pull_request schedule]
  [MAIN, BRANCH].product(events, %w[success failure cancelled], [true, false]).each do |ref, event, status, argocd|
    want_build = event == "push" && ref == MAIN && (status != "success" || !argocd)
    got_build = evaluate(build_step["if"], event: event, ref: ref, status: status, argocd_deploy: argocd)
    out << "build step on #{event} #{ref} status=#{status} argocd=#{argocd}: posts=#{got_build}, expected #{want_build}" if got_build != want_build

    # the deploy job only runs for main, push or dispatch, with argocd_deploy; the step adds push-only and not-cancelled
    runs = evaluate(deploy["if"], event: event, ref: ref, status: status, argocd_deploy: argocd, step: false)
    got_deploy = runs && evaluate(deploy_step["if"], event: event, ref: ref, status: status, argocd_deploy: argocd)
    want_deploy = argocd && ref == MAIN && event == "push"
    out << "deploy step on #{event} #{ref} status=#{status} argocd=#{argocd}: posts=#{got_deploy}, expected #{want_deploy}" if got_deploy != want_deploy
  end
  out
end

# --- 3: the inlined script is a verbatim subset of discord-notify.yaml ------------------------------------------------------
def notify_script(notify)
  notify.fetch("jobs").fetch("notify").fetch("steps").first.fetch("with").fetch("script")
end

def subset_blocks(script)
  a = script[/const rawWebhook[\s\S]*?(?=\n\n\s*\/\/ --- Metadata stored)/]
  b = script[/const META_TAG[\s\S]*?function parseMetadata[\s\S]*?\n\}\n/]
  c = script[/async function discordPost[\s\S]*?\n\}\n/]
  marker = "} else if (event === 'deploy') {\n"
  d = script.include?(marker) ? script.split(marker, 2).last.sub(/\n\}\s*\z/, "") : nil
  [a, b, c, d]
end

def sync_failures(inline, notify_text)
  out = []
  names = %w[webhook/context preamble metadata\ parser discordPost deploy\ branch]
  blocks = subset_blocks(notify_text)
  [blocks[0], blocks[1], blocks[2], blocks[3]].each_with_index do |block, index|
    label = ["webhook and context preamble", "metadata parser", "discordPost", "deploy branch"][index]
    if block.nil? || block.strip.empty?
      out << "sync: could not extract the #{label} from discord-notify.yaml (did its layout change? update subset_blocks)"
    elsif !inline.include?(block)
      out << "sync: the inlined script no longer contains discord-notify.yaml's #{label} verbatim"
    end
  end
  out << "sync: the inlined script must only handle the deploy event" unless inline.include?("if (event === 'deploy') {")
  out << "sync: the inlined script must not carry thread helpers it never uses (getMetadata/setMetadata/discordPatch)" if inline.match?(/getMetadata|setMetadata|discordPatch/)
  _ = names
  out
end

# --- 3b: run the inlined script under node with a stubbed GitHub and Discord -------------------------------------------------
HARNESS = <<~'JAVASCRIPT'.freeze
  const fs = require('fs');
  const script = fs.readFileSync(process.argv[2], 'utf8');
  const scenario = JSON.parse(process.argv[3]);
  const posts = [];
  const warnings = [];
  global.fetch = async (url, init) => {
    posts.push({ url, body: JSON.parse(init.body) });
    return scenario.discordFails
      ? { ok: false, status: 500, json: async () => ({}) }
      : { ok: true, status: 200, json: async () => ({ id: '111111111111111111', channel_id: '222222222222222222' }) };
  };
  const core = { setSecret() {}, warning: m => warnings.push(m), notice() {}, info() {}, setFailed: m => { throw new Error(m); } };
  const context = {
    repo: { owner: 'CellarNode', repo: 'backend-v2' }, actor: 'marcus', sha: 'abcdef1234567890', ref: 'refs/heads/main',
    runId: 42, serverUrl: 'https://github.com', payload: { before: '1111111222222' }, workflow: 'Build and Deploy',
  };
  const github = {
    rest: {
      repos: {
        listPullRequestsAssociatedWithCommit: async () => ({ data: scenario.prs || [] }),
        getCommit: async () => ({ data: { commit: { message: 'direct push message' } } }),
      },
      issues: { listComments: Symbol('listComments') },
    },
    paginate: async () => scenario.comments || [],
  };
  const AsyncFunction = Object.getPrototypeOf(async () => null).constructor;
  new AsyncFunction('github', 'context', 'core', script)(github, context, core)
    .then(() => console.log(JSON.stringify({ posts, warnings })))
    .catch(error => { console.log(JSON.stringify({ posts, warnings, error: error.message })); process.exitCode = 2; });
JAVASCRIPT

THREAD_ID = "333333333333333333".freeze
BOT_COMMENT = { "user" => { "login" => "github-actions[bot]" }, "body" => "<!-- discord-metadata:{\"threadId\":\"#{THREAD_ID}\"}-->" }.freeze
MERGED_PR = [{ "merged_at" => "2026-10-22T10:00:00Z", "number" => 7, "title" => "Add the thing", "html_url" => "https://github.com/x/y/pull/7", "body" => "Changelog line one" }].freeze

SCENARIOS = [
  ["deployed success in the PR's thread", { env: { "STATUS" => "success", "DEPLOY_MODE" => "deployed" }, prs: MERGED_PR, comments: [BOT_COMMENT] },
   ->(r) { p = r["posts"]; p.length == 1 && p[0]["url"].include?("thread_id=#{THREAD_ID}") && p[0]["url"].include?("wait=true") &&
     p[0]["body"]["embeds"][0]["title"] == "✅ Deployed to production" && p[0]["body"]["embeds"][0]["color"] == 3066993 &&
     p[0]["body"]["embeds"][0]["description"].include?("Changelog line one") && !p[0]["body"].key?("thread_name") }],
  ["deployed failure with no PR opens a deploy thread", { env: { "STATUS" => "failure", "DEPLOY_MODE" => "deployed" } },
   ->(r) { p = r["posts"]; p.length == 1 && !p[0]["url"].include?("thread_id") && p[0]["body"]["embeds"][0]["title"] == "❌ Deployed to production — backend-v2" &&
     p[0]["body"]["embeds"][0]["color"] == 15158332 && p[0]["body"]["embeds"][0]["description"].include?("direct push message") &&
     p[0]["body"]["thread_name"].include?("backend-v2 deploy") && p[0]["body"]["applied_tags"] == ["1484207128288694443"] }],
  ["published success", { env: { "STATUS" => "success", "DEPLOY_MODE" => "published", "IMAGE_TAG" => "abc1234" } },
   ->(r) { t = r["posts"][0]["body"]["embeds"][0]; r["posts"].length == 1 && t["title"].start_with?("📦 Image published (`abc1234`)") && t["color"] == 3447003 }],
  ["published failure is a build failure", { env: { "STATUS" => "failure", "DEPLOY_MODE" => "published", "IMAGE_TAG" => "abc1234" } },
   ->(r) { t = r["posts"][0]["body"]["embeds"][0]; t["title"].start_with?("❌ Image build failed") && t["color"] == 15158332 }],
  ["no webhook posts nothing and warns", { env: { "STATUS" => "success", "DEPLOY_MODE" => "deployed", "WEBHOOK_URL" => "" } },
   ->(r) { r["posts"].empty? && r["warnings"].any? { |w| w.include?("DISCORD_WEBHOOK_URL not set") } && !r.key?("error") }],
  ["a Discord outage warns and does not throw", { env: { "STATUS" => "success", "DEPLOY_MODE" => "deployed" }, discordFails: true },
   ->(r) { r["warnings"].any? { |w| w.include?("Discord POST failed: 500") } && !r.key?("error") }],
  ["a forged thread comment from a non-bot is ignored", { env: { "STATUS" => "success", "DEPLOY_MODE" => "deployed" }, prs: MERGED_PR,
                                                           comments: [BOT_COMMENT.merge("user" => { "login" => "someone-else" })] },
   ->(r) { !r["posts"][0]["url"].include?("thread_id") && r["posts"][0]["body"].key?("thread_name") }],
  ["another event posts nothing", { env: { "STATUS" => "success", "EVENT" => "thread_open" } },
   ->(r) { r["posts"].empty? && !r.key?("error") }],
].freeze

def behavior_failures(inline)
  out = []
  node, = Open3.capture2("sh", "-c", "command -v node")
  return ["node is required to run the behaviour scenarios"] if node.strip.empty?

  Dir.mktmpdir do |directory|
    harness = File.join(directory, "harness.js")
    script_path = File.join(directory, "script.js")
    File.write(harness, HARNESS)
    File.write(script_path, inline)
    SCENARIOS.each do |label, scenario, check|
      env = { "WEBHOOK_URL" => "https://discord.example/api/webhooks/1/token", "EVENT" => "deploy", "TAGS" => "backend", "IMAGE_TAG" => "" }.merge(scenario[:env])
      stdout, stderr, status = Open3.capture3(env, "node", harness, script_path, JSON.generate(scenario.reject { |k, _| k == :env }))
      begin
        result = JSON.parse(stdout.lines.last.to_s)
      rescue JSON::ParserError
        out << "behaviour: #{label}: the script did not run (#{status.exitstatus}): #{stderr.lines.first(2).join.strip}"
        next
      end
      out << "behaviour: #{label}: unexpected result #{result.inspect[0, 300]}" unless check.call(result)
    end
  end
  out
end

# --- run it ------------------------------------------------------------------------------------------------------------------
workflow = load_yaml("deploy-backend.yaml")
notify = load_yaml("discord-notify.yaml")
inline = workflow.fetch("jobs").fetch("build").fetch("steps").last.dig("with", "script").to_s
notify_text = notify_script(notify)

FAILURES.concat(workflow_failures(workflow))
FAILURES.concat(sync_failures(inline, notify_text))
FAILURES.concat(behavior_failures(inline))

# --- the checks must themselves be able to fail ------------------------------------------------------------------------------
def deep_copy(object)
  Marshal.load(Marshal.dump(object))
end

def last_step(wf, job)
  wf["jobs"][job]["steps"].last
end

workflow_mutations = {
  "the separate discord-deploy job comes back" => ->(wf) { wf["jobs"]["discord-deploy"] = { "needs" => %w[build deploy], "uses" => "./.github/workflows/discord-notify.yaml", "with" => { "event" => "deploy" } } },
  "a PR notify job loses its pull_request restriction" => ->(wf) { wf["jobs"]["discord-thread-close"]["if"] = "true" },
  "build step loses always() (so it never reports a failed or timed-out build)" => ->(wf) { last_step(wf, "build")["if"] = last_step(wf, "build")["if"].sub("always() && ", "") },
  "deploy step loses always() (so it never reports a failed or timed-out deploy)" => ->(wf) { last_step(wf, "deploy")["if"] = last_step(wf, "deploy")["if"].sub("always() && ", "") },
  "deploy step drops its if entirely" => ->(wf) { last_step(wf, "deploy").delete("if") },
  "build step posts on a successful deployed build" => ->(wf) { last_step(wf, "build")["if"] = "${{ always() && github.event_name == 'push' && github.ref == 'refs/heads/main' }}" },
  "build step loses the main check" => ->(wf) { last_step(wf, "build")["if"] = last_step(wf, "build")["if"].sub("github.ref == 'refs/heads/main' && ", "") },
  "deploy step posts for dispatches" => ->(wf) { last_step(wf, "deploy")["if"] = "${{ always() }}" },
  "build step stops being continue-on-error" => ->(wf) { last_step(wf, "build").delete("continue-on-error") },
  "deploy step stops being continue-on-error" => ->(wf) { last_step(wf, "deploy")["continue-on-error"] = false },
  "deploy notify step is no longer last" => ->(wf) { wf["jobs"]["deploy"]["steps"].push({ "name" => "Later step", "run" => "true" }) },
  "build notify step is no longer last" => ->(wf) { wf["jobs"]["build"]["steps"].push({ "name" => "Later step", "run" => "true" }) },
  "status is hard-coded" => ->(wf) { last_step(wf, "deploy")["env"]["STATUS"] = "success" },
  "build reports deployed in published mode" => ->(wf) { last_step(wf, "build")["env"]["DEPLOY_MODE"] = "deployed" },
  "unpinned github-script" => ->(wf) { last_step(wf, "build")["uses"] = "actions/github-script@v7" },
  "the webhook secret moves to the deploy job env" => ->(wf) { wf["jobs"]["deploy"]["env"] = { "DISCORD_WEBHOOK_URL" => "${{ secrets.DISCORD_WEBHOOK_URL }}" } },
  "the webhook secret leaks into another step" => ->(wf) { wf["jobs"]["deploy"]["steps"].first["env"]["DISCORD_WEBHOOK_URL"] = "${{ secrets.DISCORD_WEBHOOK_URL }}" },
  "build loses pull-requests read" => ->(wf) { wf["jobs"]["build"]["permissions"].delete("pull-requests") },
  "build gains write access" => ->(wf) { wf["jobs"]["build"]["permissions"]["contents"] = "write" },
  "deploy timeout is dropped" => ->(wf) { wf["jobs"]["deploy"].delete("timeout-minutes") },
  "the two steps run different scripts" => ->(wf) { last_step(wf, "deploy")["with"]["script"] = "core.info('x');" },
}
workflow_mutations.each do |label, mutate|
  mutated = deep_copy(workflow)
  mutate.call(mutated)
  caught = begin
    !workflow_failures(mutated).empty?
  rescue SystemExit, KeyError, NoMethodError
    true
  end
  fail!("mutation `#{label}` was NOT caught (the workflow contract is too weak)") unless caught
end

sync_mutations = {
  "the deployed wording drifts in the notifier" => ->(inl, nt) { [inl, nt.sub("'Deployed to production'", "'Shipped'")] },
  "the inlined deploy branch drifts" => ->(inl, nt) { [inl.sub("Compare Changes", "Compare"), nt] },
  "the metadata parser is dropped from the inline script" => ->(inl, nt) { [inl.sub("function parseMetadata", "function parseMetadataX"), nt] },
  "discordPost drifts" => ->(inl, nt) { [inl.sub("wait: 'true'", "wait: 'false'"), nt] },
  "the tag map drifts" => ->(inl, nt) { [inl.sub("1484207128288694443", "1"), nt] },
  "thread helpers are pulled in" => ->(inl, nt) { [inl + "\nasync function getMetadata() {}\n", nt] },
}
sync_mutations.each do |label, mutate|
  inl2, nt2 = mutate.call(inline, notify_text)
  fail!("mutation `#{label}` was NOT caught by the sync check") if sync_failures(inl2, nt2).empty?
end

behavior_mutations = {
  "the bot-author check is dropped" => ->(inl) { inl.sub("c.user?.login !== 'github-actions[bot]'", "false") },
  "the status colour is wrong" => ->(inl) { inl.sub("3066993", "1") },
  "the webhook guard is dropped" => ->(inl) { inl.sub("if (!webhook) {", "if (false) {") },
  "a Discord outage throws" => ->(inl) { inl.sub("core.warning(`Discord POST failed: ${res.status}`);", "throw new Error('x');") },
}
behavior_mutations.each do |label, mutate|
  fail!("mutation `#{label}` was NOT caught by the behaviour scenarios") if behavior_failures(mutate.call(inline)).empty?
end

if FAILURES.empty?
  puts "discord deploy in job: OK (shape, #{2 * 2 * 2 * 3 * 2 * 2} step-condition cases, sync with discord-notify, #{SCENARIOS.length} node scenarios, " \
       "#{workflow_mutations.length + sync_mutations.length + behavior_mutations.length} mutations caught)"
else
  warn "discord deploy in job FAILED:\n  - #{FAILURES.join("\n  - ")}"
  exit 1
end
