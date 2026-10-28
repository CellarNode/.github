# CEL-2768: build and dependency code run in `deploy-production`, the job that holds `id-token: write`.
#
# Two rules keep that job from handing its OIDC token to code it just installed:
#   1. In EVERY job that may hold `id-token: write`, no step runs dependency lifecycle scripts: `--ignore-scripts` on the install is undone
#      by a later `pnpm|npm|yarn|bun rebuild`, and an install without `--ignore-scripts` runs them. Each install command is checked on its
#      own (an appended `npm ci`, or `&& npm install` after the pnpm install, is caught). A job "may hold" the token when its effective
#      permissions (its own, else the workflow's) are absent, `write-all`, or a mapping with `id-token: write`, and such a job must declare
#      `permissions:` itself: a called job inherits the caller's id-token. (The GitHub-hosted `build-preview` holds no id-token and may
#      rebuild.)
#   2. In `deploy-production`, every `run:` script starts with `unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN`, so code
#      those steps run cannot casually mint the job's token from its own environment. A step-level `env:` blank would be INERT (the runner sets
#      both variables after it applies the step env: actions/runner ScriptHandler / NodeScriptActionHandler / ContainerActionHandler), so none
#      may be used. `uses:` steps cannot be stripped (pinned actions). Not a hard boundary: code could still read the values from its parent
#      shell's /proc/<pid>/environ. The only boundary is the IAM bindings (per-site deploy service account, pipelines exclusion); this rule,
#      build-before-auth ordering and the `dist` re-check are defence in depth.
#   3. The deploy notification is a separate `discord-deploy` job with no id-token, and `deploy-production` never sees the webhook secret.
#
# The test then mutates the workflow to prove each rule can fail.
#
# Run: ruby .github/tests/deploy-static-token-job.test.rb      (exit 0 = every rule holds)

require "open3"
require "yaml"

PATH_TO_WORKFLOW = File.expand_path("../workflows/deploy-static-website.yaml", __dir__)
OIDC_VARS = %w[ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN].freeze
UNSET_LINE = "unset #{OIDC_VARS.join(' ')}".freeze
REBUILD = /\b(?:pnpm|npm|yarn|bun)\s+(?:\S+\s+)*?rebuild\b/
INSTALL = /\b(?:pnpm|npm|yarn|bun)\b(?!\s+(?:exec|dlx)\b).*?\s(?:install|i|add|ci)\b/

# A job may hold an id-token unless its effective permissions are an explicit mapping without `id-token: write`.
def may_hold_id_token?(permissions)
  permissions.nil? || permissions == "write-all" || (permissions.is_a?(Hash) && permissions["id-token"] == "write")
end

# Split a run script into commands: join line continuations, blank `${{ }}` expressions (their && and || are not shell operators).
def commands_of(run)
  run.gsub(/\$\{\{.*?\}\}/m, "EXPR").gsub(/\\\n/, " ").split(/&&|\|\||[;|\n]/)
end

def failures_for(workflow)
  out = []
  jobs = workflow.fetch("jobs")

  # Rule 1: every job that may hold id-token: write
  jobs.each do |job_name, job|
    perms = job.key?("permissions") ? job["permissions"] : workflow["permissions"]
    next unless may_hold_id_token?(perms)

    out << "#{job_name}: must declare permissions (a called job inherits the caller's id-token)" unless job.key?("permissions")
    job.fetch("steps", []).each do |step|
      run = step.fetch("run", "")
      label = "#{job_name} / #{step.fetch('name', step.fetch('uses', 'a step'))}"
      commands_of(run).each do |cmd|
        out << "#{label}: a job holding id-token: write must not rebuild dependencies: #{cmd.strip}" if cmd.match?(REBUILD)
        next unless cmd.match?(INSTALL) || cmd.strip.match?(/\Ayarn\s*\z/)

        out << "#{label}: every install in an id-token job needs --ignore-scripts: #{cmd.strip}" unless cmd.split.include?("--ignore-scripts")
      end
    end
  end

  # Rule 3: the notification is a separate job without id-token; deploy-production never sees the webhook
  notify = jobs["discord-deploy"]
  out << "discord-deploy: the deploy notification must be a separate job" unless notify
  if notify
    out << "discord-deploy: must need deploy-production" unless Array(notify["needs"]).include?("deploy-production")
    out << "discord-deploy: must declare permissions without id-token (got #{notify['permissions'].inspect})" unless notify["permissions"].is_a?(Hash) && !notify["permissions"].key?("id-token") && notify["permissions"].values.none? { |level| level == "write" }
    out << "discord-deploy: must not have steps that run build code" if notify.key?("steps")
  end
  # Rule 4: the stale-deploy freshness check sits before the rsync and fails closed
  deploy_run = (jobs.fetch("deploy-production").fetch("steps").find { |step| step.fetch("name", "") == "Deploy to production" } || {}).fetch("run", "")
  fresh = deploy_run.index("commits/${GITHUB_REF_NAME}")
  rsync = deploy_run.index("gcloud storage rsync")
  out << "deploy-production: the freshness check (branch head lookup) must come before the rsync" unless fresh && rsync && fresh < rsync
  out << "deploy-production: the freshness check must fail closed when the lookup fails" unless deploy_run.match?(/commits\/\$\{GITHUB_REF_NAME\}"\) \|\| exit 1/)
  out << "deploy-production: a superseded run must skip the deploy and exit 0" unless deploy_run.match?(/if \[ "\$head" != "\$GITHUB_SHA" \]; then\n[^\n]*[Ss]uperseded[^\n]*\n\s*exit 0/)
  webhook_hit = lambda do |value|
    case value
    when Hash then value.any? { |key, inner| webhook_hit.call(key) || webhook_hit.call(inner) }
    when Array then value.any? { |inner| webhook_hit.call(inner) }
    else value.to_s.include?("DISCORD_WEBHOOK_URL")
    end
  end
  out << "deploy-production: must not reference DISCORD_WEBHOOK_URL anywhere" if webhook_hit.call(jobs.fetch("deploy-production"))

  # Rule 2: every run script of deploy-production starts with the unset line; no step relies on an (inert) env blank
  production = jobs.fetch("deploy-production")
  steps = production.fetch("steps")
  out << "deploy-production: must not have a Rebuild dependencies step" if steps.any? { |step| step.fetch("name", "") == "Rebuild dependencies" }
  auth_steps = steps.select { |step| step.fetch("uses", "").start_with?("google-github-actions/auth@") }
  out << "deploy-production: must authenticate exactly once (got #{auth_steps.length})" unless auth_steps.length == 1
  steps.each do |step|
    label = step.fetch("name", step.fetch("uses", "a step"))
    out << "deploy-production: step #{label.inspect} must not set the OIDC variables in env (the runner overwrites them, so the blank is inert)" if OIDC_VARS.any? { |name| step.fetch("env", {}).key?(name) }
    next unless step.key?("run")

    first = step.fetch("run").lines.map(&:strip).reject(&:empty?).first
    out << "deploy-production: step #{label.inspect} must start its script with: #{UNSET_LINE}" unless first == UNSET_LINE
  end
  # The anchored dependency script the job aliases is defined in the hosted preview job; it must carry the line too.
  anchored = workflow.fetch("jobs").fetch("build-preview").fetch("steps").find { |step| step.fetch("name", "") == "Validate preview dependency inputs" }
  out << "the anchored dependency validation script must start with the unset line" unless anchored && anchored.fetch("run").lines.map(&:strip).reject(&:empty?).first == UNSET_LINE
  out
end

def deep_copy(object)
  Marshal.load(Marshal.dump(object))
end

workflow = YAML.safe_load(File.read(PATH_TO_WORKFLOW), aliases: true)
failures = failures_for(workflow)

# The line must really remove both variables for the shells the runner uses (bash, and sh for steps without `shell:`).
%w[bash sh].each do |shell|
  stdout, _stderr, status = Open3.capture3({ "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.example", "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "secret" }, shell, "-e", "-c", "#{UNSET_LINE}\nenv")
  failures << "#{UNSET_LINE} must succeed under #{shell}" unless status.success?
  failures << "#{UNSET_LINE} must remove both variables under #{shell}" if stdout.include?("ACTIONS_ID_TOKEN_REQUEST")
end

# Control: the hosted preview build holds no id-token, so its own rebuild must not be flagged by rule 1.
preview_rebuilds = workflow.fetch("jobs").fetch("build-preview").fetch("steps").any? { |step| step.fetch("run", "").match?(REBUILD) }
failures << "control: build-preview is expected to keep its rebuild (it holds no id-token); the rule must not flag it" unless preview_rebuilds
failures << "control: build-preview must hold no id-token" if workflow.fetch("jobs").fetch("build-preview").fetch("permissions", {}).key?("id-token")

step = ->(wf, job, name) { wf["jobs"][job]["steps"].find { |s| s.fetch("name", s.fetch("uses", "")) == name } }
strip_unset = ->(wf, name) { s = step.call(wf, "deploy-production", name); s["run"] = s["run"].lines.reject { |line| line.strip == UNSET_LINE }.join }
with_unset = ->(command) { "#{UNSET_LINE}\n#{command}" }
mutations = {
  "a Rebuild dependencies step returns to deploy-production" => ->(wf) { wf["jobs"]["deploy-production"]["steps"].insert(8, { "name" => "Rebuild dependencies", "run" => with_unset.call("pnpm rebuild") }) },
  "npm rebuild hidden in the Build step" => ->(wf) { step.call(wf, "deploy-production", "Build production")["run"] = with_unset.call("npm rebuild && pnpm build") },
  "yarn rebuild in the cleanup job (it holds id-token)" => ->(wf) { wf["jobs"]["cleanup"]["steps"].first["run"] = "yarn rebuild" },
  "an install without --ignore-scripts in deploy-preview (it holds id-token)" => ->(wf) { wf["jobs"]["deploy-preview"]["steps"].first["run"] = "pnpm install --frozen-lockfile" },
  "an `npm ci` line appended to the production install step" => ->(wf) { s = step.call(wf, "deploy-production", "Install dependencies"); s["run"] = "#{s['run']}\nnpm ci\n" },
  "`&& npm install` after the pnpm install" => ->(wf) { s = step.call(wf, "deploy-production", "Install dependencies"); s["run"] = s["run"].sub("--ignore-pnpmfile", "--ignore-pnpmfile && npm install") },
  "`pnpm --dir . install` without --ignore-scripts" => ->(wf) { wf["jobs"]["cleanup"]["steps"].first["run"] = "pnpm --dir . install" },
  "`bun install` in the cleanup job" => ->(wf) { wf["jobs"]["cleanup"]["steps"].first["run"] = "bun install" },
  "bare `yarn` in the cleanup job" => ->(wf) { wf["jobs"]["cleanup"]["steps"].first["run"] = "yarn" },
  "`bun rebuild` in the cleanup job" => ->(wf) { wf["jobs"]["cleanup"]["steps"].first["run"] = "bun rebuild" },
  "a second install with --ignore-scripts only on the first" => ->(wf) { wf["jobs"]["deploy-preview"]["steps"].first["run"] = "pnpm install --ignore-scripts\npnpm add left-pad" },
  "an id-token job without its own permissions (workflow level absent)" => ->(wf) { wf["jobs"]["cleanup"].delete("permissions"); wf["jobs"]["cleanup"]["steps"].first["run"] = "pnpm install --ignore-scripts" },
  "write-all permissions with a bare install" => ->(wf) { wf["jobs"]["cleanup"]["permissions"] = "write-all"; wf["jobs"]["cleanup"]["steps"].first["run"] = "pnpm install" },
  "workflow-level id-token write and a job without permissions" => ->(wf) { wf["permissions"] = { "id-token" => "write" }; wf["jobs"]["build-preview"].delete("permissions") },
  "discord-deploy gains id-token" => ->(wf) { wf["jobs"]["discord-deploy"]["permissions"]["id-token"] = "write" },
  "discord-deploy is removed" => ->(wf) { wf["jobs"].delete("discord-deploy") },
  "the webhook secret returns to deploy-production" => ->(wf) { (step.call(wf, "deploy-production", "Lint")["env"] ||= {})["WEBHOOK_URL"] = "${{ secrets.DISCORD_WEBHOOK_URL }}" },
  "the freshness check is removed" => ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub(/head=\$\(curl.*?\nfi\n/m, "") },
  "the freshness check moves after the rsync" => ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = "#{s['run']}\n# commits/${GITHUB_REF_NAME}\n"; s["run"] = s["run"].sub("commits/${GITHUB_REF_NAME}\")", "x\")") },
  "the freshness lookup no longer fails closed" => ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub('commits/${GITHUB_REF_NAME}") || exit 1', 'commits/${GITHUB_REF_NAME}") || true') },
  "a stale run no longer exits 0" => ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub("skipping stale deploy of ${GITHUB_SHA}\"\n  exit 0", "skipping stale deploy of ${GITHUB_SHA}\"\n  exit 1") },
  "the production install drops --ignore-scripts" => ->(wf) { s = step.call(wf, "deploy-production", "Install dependencies"); s["run"] = s["run"].gsub("--ignore-scripts", "") },
  "npm ci in a new production step" => ->(wf) { wf["jobs"]["deploy-production"]["steps"].insert(8, { "name" => "More deps", "run" => with_unset.call("npm ci") }) },
  "the unset is removed from Lint" => ->(wf) { strip_unset.call(wf, "Lint") },
  "the unset is removed from the install" => ->(wf) { strip_unset.call(wf, "Install dependencies") },
  "the unset is removed from Build production" => ->(wf) { strip_unset.call(wf, "Build production") },
  "the unset is removed from Type check" => ->(wf) { strip_unset.call(wf, "Type check") },
  "the unset is removed from the first step" => ->(wf) { strip_unset.call(wf, "Validate deploy service account") },
  "the unset is removed from the deploy step" => ->(wf) { strip_unset.call(wf, "Deploy to production") },
  "the unset is not the first command in Build" => ->(wf) { s = step.call(wf, "deploy-production", "Build production"); s["run"] = "echo before\n#{s['run']}" },
  "only one variable is unset" => ->(wf) { s = step.call(wf, "deploy-production", "Lint"); s["run"] = s["run"].sub(UNSET_LINE, "unset ACTIONS_ID_TOKEN_REQUEST_URL") },
  "an inert env blank is added to a step" => ->(wf) { (step.call(wf, "deploy-production", "Lint")["env"] ||= {})["ACTIONS_ID_TOKEN_REQUEST_URL"] = "" },
  "an inert env blank is added to the authenticate step" => ->(wf) { (step.call(wf, "deploy-production", "Authenticate to Google Cloud")["env"] ||= {})["ACTIONS_ID_TOKEN_REQUEST_TOKEN"] = "" },
  "a new run step without the unset is added" => ->(wf) { wf["jobs"]["deploy-production"]["steps"].insert(9, { "name" => "Extra", "run" => "echo hi" }) },
  "a second authenticate step is added" => ->(wf) { wf["jobs"]["deploy-production"]["steps"] << { "uses" => "google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093" } },
  "the anchored validation script loses the unset" => ->(wf) { s = wf["jobs"]["build-preview"]["steps"].find { |x| x.fetch("name", "") == "Validate preview dependency inputs" }; s["run"] = s["run"].lines.reject { |line| line.strip == UNSET_LINE }.join },
}
mutations.each do |label, mutate|
  mutated = deep_copy(workflow)
  begin
    mutate.call(mutated)
  rescue NoMethodError
    failures << "mutation `#{label}` could not be applied (a step it targets is missing or renamed): update the mutation"
    next
  end
  failures << "mutation `#{label}` was NOT caught" if failures_for(mutated).empty?
end

if failures.empty?
  puts "static deploy token job: OK (no rebuild or script-running install in any id-token job, the OIDC variables unset first in every production run script, #{mutations.length} mutations caught)"
else
  warn "static deploy token job FAILED:\n  - #{failures.join("\n  - ")}"
  exit 1
end
