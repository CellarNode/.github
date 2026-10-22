# CEL-2795 / CEL-2819: shared checks for a workflow that posts the deploy notification from a STEP instead of a separate job.
#
# The step's script is the deploy-only subset of discord-notify.yaml's script (webhook handling, tag map, metadata parser, discordPost and
# the `deploy` branch), copied verbatim. This file keeps the copy honest: `sync_failures` fails when it drifts from the notifier, and
# `behavior_failures` EXECUTES it under node with a stubbed GitHub and Discord.

require "json"
require "open3"
require "tmpdir"
require "yaml"

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
