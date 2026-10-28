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
      # pnpm/action-setup can run `pnpm install` itself (with lifecycle scripts) when run_install is set; it must be an explicit false.
      if step.fetch("uses", "").start_with?("pnpm/action-setup@") && step.fetch("with", {})["run_install"] != false
        out << "#{label}: pnpm/action-setup in an id-token job must set with.run_install: false (got #{step.fetch('with', {})['run_install'].inspect}), or it installs with lifecycle scripts"
      end
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
    out << "discord-deploy: must grant pull-requests: read (the notice looks up the merged pull request)" unless notify["permissions"].is_a?(Hash) && notify["permissions"]["pull-requests"] == "read"
    out << "discord-deploy: must not have steps that run build code" if notify.key?("steps")
  end
  # Rule 4: the stale-deploy guard is a last-deployed marker plus an ancestry check, not a branch-head lookup
  production_steps = jobs.fetch("deploy-production").fetch("steps")
  deploy_run = (production_steps.find { |step| step.fetch("name", "") == "Deploy to production" } || {}).fetch("run", "")
  marker_read = deploy_run.index('gcloud storage cat "$marker"')
  rsync = deploy_run.index("gcloud storage rsync")
  marker_defs = deploy_run.scan("gcloud storage cp --cache-control=no-store -")
  out << "deploy-production: the marker write must be defined once (a write_marker function around gcloud storage cp)" unless marker_defs.length == 1 && deploy_run.include?('write_marker() { printf \'%s\\n\' "$GITHUB_SHA" | gcloud storage cp --cache-control=no-store - "$marker"; }')
  pre_write = deploy_run.index(/^ *write_marker \|\| \{[^\n]*exit 1/)
  post_write = rsync && deploy_run.index("for i in 1 2 3; do", rsync)
  out << "deploy-production: the marker read must come before the rsync" unless marker_read && rsync && marker_read < rsync
  out << "deploy-production: the marker must be written BEFORE the rsync as an intent record, and the failure must stop the step" unless pre_write && rsync && marker_read && marker_read < pre_write && pre_write < rsync
  out << "deploy-production: the marker must be written again after the rsync, with 3 attempts" unless post_write && deploy_run[post_write..].match?(/for i in 1 2 3; do\s+if write_marker; then written=1; break; fi/) && deploy_run.include?('[ "$written" = 1 ] ||')
  deployed_out = deploy_run.index('echo "deployed=true" >> "$GITHUB_OUTPUT"')
  out << "deploy-production: deployed=true may only be emitted after the rsync and the retried marker write" unless deployed_out && post_write && deployed_out > deploy_run.index('[ "$written" = 1 ] ||').to_i && deploy_run.scan("deployed=true").length == 1
  out << "deploy-production: a stale skip must emit deployed=false" unless deploy_run.match?(/stale deploy skipped[^\n]*\n\s*echo "deployed=false" >> "\$GITHUB_OUTPUT"\n\s*exit 0/)
  out << "deploy-production: a missing marker is recognised only by gcloud's 'matched no objects' wording (no 404 arm)" unless deploy_run.include?('*"matched no objects"*) ;;') && !deploy_run.include?("*404*") && !deploy_run.include?("No URLs matched")
  out << "deploy-production: the unknown-commit and malformed-marker errors must name the operator recovery (gcloud storage rm of the marker) and the runbook section" unless deploy_run.include?('recovery="Operator recovery: gcloud storage rm ${marker} (see the runbook section \'Deploy marker\' in ci-identities.md)"') && deploy_run.scan('${recovery}').length == 3
  out << "deploy-production: the rsync must exclude .deploy/ so --delete-unmatched never removes the marker" unless deploy_run.match?(/gcloud storage rsync [^\n]*--delete-unmatched-destination-objects[^\n]*-x '\^\\\.deploy\/'/)
  out << "deploy-production: the skip path must emit ::warning::stale deploy skipped" unless deploy_run.include?('echo "::warning::stale deploy skipped:')
  out << "deploy-production: an unknown marker commit must fail closed" unless deploy_run.match?(/git cat-file -e "\$\{last\}\^\{commit\}"[^\n]*exit 1/)
  out << "deploy-production: the guard must use an ancestry check" unless deploy_run.include?('git merge-base --is-ancestor "$GITHUB_SHA" "$last"')
  out << "deploy-production: the guard must not look up the branch head (it fails open)" if deploy_run.include?("api.github.com") || deploy_run.include?("ls-remote")
  checkout = production_steps.find { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
  out << "deploy-production: the checkout needs fetch-depth: 0 for the ancestry check" unless checkout && checkout.fetch("with", {})["fetch-depth"] == 0
  out << "deploy-production: the checkout needs filter: blob:none so full history stays cheap" unless checkout && checkout.fetch("with", {})["filter"] == "blob:none"
  # F1: the liveness warning lives in its own job: no build code, no git, no checkout, and deploy-production holds no GitHub token at all
  check = jobs["check-newer-head"] || {}
  check_script = check.fetch("steps", []).map { |step| step.dig("with", "script").to_s }.join("\n")
  out << "check-newer-head: must exist and need deploy-production" unless check["needs"] == "deploy-production"
  out << "check-newer-head: must run only after a real deploy (deployed output == 'true')" unless check["if"].to_s.include?("needs.deploy-production.outputs.deployed == 'true'")
  out << "check-newer-head: must hold only contents: read (got #{check['permissions'].inspect})" unless check["permissions"] == { "contents" => "read" }
  out << "check-newer-head: must use the REST API, with no checkout, run script or git" if check.fetch("steps", []).any? { |step| step.fetch("uses", "").start_with?("actions/checkout@") || step.key?("run") } || check_script.include?("git ")
  out << "check-newer-head: must warn with ::warning::newer commit (core.warning) and export newer_head" unless check_script.include?("core.warning(`newer commit ${head.sha} on ${process.env.BRANCH} is not deployed yet; if its production run was cancelled, re-run it`)") && check_script.include?("core.setOutput('newer_head', head.sha)")
  out << "check-newer-head: must compare through the REST API and treat only status ahead as newer" unless check_script.include?("compareCommitsWithBasehead") && check_script.include?("cmp.status === 'ahead'") && check_script.include?("repos.getCommit")
  out << "check-newer-head: must never fail the deploy (continue-on-error and a catch that only warns)" unless check.fetch("steps", []).all? { |step| step["continue-on-error"] == true } && check_script.include?("catch (error)") && !check_script.include?("setFailed") && !check_script.match?(/\bthrow\b/)
  out << "check-newer-head: must export the newer_head job output" unless check.dig("outputs", "newer_head") == "${{ steps.newer.outputs.newer_head }}"
  out << "deploy-production: must not have the newer-commit step (it runs build code, so no GitHub token may live there)" if production_steps.any? { |step| step.fetch("name", "") == "Warn when a newer commit is not deployed" }
  token_hit = lambda do |value|
    case value
    when Hash then value.any? { |key, inner| token_hit.call(key) || token_hit.call(inner) }
    when Array then value.any? { |inner| token_hit.call(inner) }
    else value.to_s.match?(/github\.token|GITHUB_TOKEN|GH_TOKEN|secrets\.GITHUB_TOKEN/)
    end
  end
  out << "deploy-production: must never reference github.token, GITHUB_TOKEN or GH_TOKEN in any step" if token_hit.call(jobs.fetch("deploy-production"))
  outputs = jobs.fetch("deploy-production").fetch("outputs", {})
  out << "deploy-production: must export a deployed job output from the deploy step" unless outputs["deployed"] == "${{ steps.deploy.outputs.deployed }}"
  out << "deploy-production: the deploy step needs id: deploy" unless (production_steps.find { |step| step.fetch("name", "") == "Deploy to production" } || {})["id"] == "deploy"
  out << "discord-deploy: must report not-deployed outcomes separately from a deploy (uses deploy_title and the deployed output)" unless notify && notify.dig("with", "deploy_title").to_s.include?("outputs.deployed") && notify.dig("with", "status").to_s.include?("outputs.deployed") && notify.dig("with", "deploy_note").to_s.include?("needs.check-newer-head.outputs.newer_head") && Array(notify["needs"]).include?("check-newer-head")
  webhook_hit = lambda do |value|
    case value
    when Hash then value.any? { |key, inner| webhook_hit.call(key) || webhook_hit.call(inner) }
    when Array then value.any? { |inner| webhook_hit.call(inner) }
    else value.to_s.include?("DISCORD_WEBHOOK_URL") || value.to_s.match?(/toJSON\(\s*secrets\s*\)/i) || value.to_s.match?(/\bsecrets\s*\[/)
    end
  end
  out << "deploy-production: must not reference DISCORD_WEBHOOK_URL anywhere (nor toJSON(secrets) or secrets[...])" if webhook_hit.call(jobs.fetch("deploy-production"))

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
  "a Rebuild dependencies step returns to deploy-production" => ["must not have a Rebuild dependencies step", ->(wf) { wf["jobs"]["deploy-production"]["steps"].insert(8, { "name" => "Rebuild dependencies", "run" => with_unset.call("pnpm rebuild") }) }],
  "npm rebuild hidden in the Build step" => ["must not rebuild dependencies", ->(wf) { step.call(wf, "deploy-production", "Build production")["run"] = with_unset.call("npm rebuild && pnpm build") }],
  "yarn rebuild in the cleanup job (it holds id-token)" => ["must not rebuild dependencies", ->(wf) { wf["jobs"]["cleanup"]["steps"].first["run"] = "yarn rebuild" }],
  "an install without --ignore-scripts in deploy-preview (it holds id-token)" => ["every install in an id-token job needs --ignore-scripts", ->(wf) { wf["jobs"]["deploy-preview"]["steps"].first["run"] = "pnpm install --frozen-lockfile" }],
  "an `npm ci` line appended to the production install step" => ["every install in an id-token job needs --ignore-scripts", ->(wf) { s = step.call(wf, "deploy-production", "Install dependencies"); s["run"] = "#{s['run']}\nnpm ci\n" }],
  "`&& npm install` after the pnpm install" => ["every install in an id-token job needs --ignore-scripts", ->(wf) { s = step.call(wf, "deploy-production", "Install dependencies"); s["run"] = s["run"].sub("--ignore-pnpmfile", "--ignore-pnpmfile && npm install") }],
  "`pnpm --dir . install` without --ignore-scripts" => ["every install in an id-token job needs --ignore-scripts", ->(wf) { wf["jobs"]["cleanup"]["steps"].first["run"] = "pnpm --dir . install" }],
  "`bun install` in the cleanup job" => ["every install in an id-token job needs --ignore-scripts", ->(wf) { wf["jobs"]["cleanup"]["steps"].first["run"] = "bun install" }],
  "bare `yarn` in the cleanup job" => ["every install in an id-token job needs --ignore-scripts", ->(wf) { wf["jobs"]["cleanup"]["steps"].first["run"] = "yarn" }],
  "`bun rebuild` in the cleanup job" => ["must not rebuild dependencies", ->(wf) { wf["jobs"]["cleanup"]["steps"].first["run"] = "bun rebuild" }],
  "a second install with --ignore-scripts only on the first" => ["every install in an id-token job needs --ignore-scripts", ->(wf) { wf["jobs"]["deploy-preview"]["steps"].first["run"] = "pnpm install --ignore-scripts\npnpm add left-pad" }],
  "an id-token job without its own permissions (workflow level absent)" => ["must declare permissions (a called job inherits the caller's id-token)", ->(wf) { wf["jobs"]["cleanup"].delete("permissions"); wf["jobs"]["cleanup"]["steps"].first["run"] = "pnpm install --ignore-scripts" }],
  "write-all permissions with a bare install" => ["every install in an id-token job needs --ignore-scripts", ->(wf) { wf["jobs"]["cleanup"]["permissions"] = "write-all"; wf["jobs"]["cleanup"]["steps"].first["run"] = "pnpm install" }],
  "workflow-level id-token write and a job without permissions" => ["must declare permissions (a called job inherits the caller's id-token)", ->(wf) { wf["permissions"] = { "id-token" => "write" }; wf["jobs"]["build-preview"].delete("permissions") }],
  "discord-deploy gains id-token" => ["discord-deploy: must declare permissions without id-token", ->(wf) { wf["jobs"]["discord-deploy"]["permissions"]["id-token"] = "write" }],
  "discord-deploy is removed" => ["discord-deploy: the deploy notification must be a separate job", ->(wf) { wf["jobs"].delete("discord-deploy") }],
  "toJSON(secrets) in deploy-production" => ["must not reference DISCORD_WEBHOOK_URL anywhere", ->(wf) { (step.call(wf, "deploy-production", "Lint")["env"] ||= {})["ALL"] = "${{ toJSON(secrets) }}" }],
  "secrets index syntax in deploy-production" => ["must not reference DISCORD_WEBHOOK_URL anywhere", ->(wf) { (step.call(wf, "deploy-production", "Lint")["env"] ||= {})["HOOK"] = "${{ secrets['DISCORD_' + 'WEBHOOK'] }}" }],
  "pnpm/action-setup runs an install in deploy-production" => ["run_install", ->(wf) { step.call(wf, "deploy-production", "Set up pnpm")["with"]["run_install"] = true }],
  "pnpm/action-setup loses run_install in deploy-production" => ["run_install", ->(wf) { step.call(wf, "deploy-production", "Set up pnpm")["with"].delete("run_install") }],
  "pnpm/action-setup run_install is a mapping in deploy-production" => ["run_install", ->(wf) { step.call(wf, "deploy-production", "Set up pnpm")["with"]["run_install"] = [{ "args" => ["--frozen-lockfile"] }] }],
  "discord-deploy loses pull-requests: read" => ["must grant pull-requests: read", ->(wf) { wf["jobs"]["discord-deploy"]["permissions"].delete("pull-requests") }],
  "the checkout loses filter: blob:none" => ["needs filter: blob:none", ->(wf) { wf["jobs"]["deploy-production"]["steps"].find { |x| x.fetch("uses", "").start_with?("actions/checkout@") }["with"].delete("filter") }],
  "the marker is not retried after the rsync" => ["must be written again after the rsync, with 3 attempts", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub("for i in 1 2 3; do", "for i in 1; do") }],
  "deployed=true is emitted before the rsync" => ["deployed=true may only be emitted after", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub('echo "deployed=true" >> "$GITHUB_OUTPUT"', "").sub("gcloud storage rsync", "echo \"deployed=true\" >> \"$GITHUB_OUTPUT\"\n          gcloud storage rsync") }],
  "a stale skip stops emitting deployed=false" => ["a stale skip must emit deployed=false", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub(%(echo "deployed=false" >> "$GITHUB_OUTPUT"\n), "") }],
  "the missing-marker arm accepts a 404" => ["no 404 arm", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub('*"matched no objects"*) ;;', '*"matched no objects"* | *404*) ;;') }],
  "the malformed-marker error loses the recovery" => ["must name the operator recovery", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub("Live marker is not a commit sha: ${last}. ${recovery}", "Live marker is not a commit sha: ${last}") }],
  "the newer-commit job is removed" => ["check-newer-head: must exist", ->(wf) { wf["jobs"].delete("check-newer-head") }],
  "the newer-commit job runs on a deploy that did not happen" => ["must run only after a real deploy", ->(wf) { wf["jobs"]["check-newer-head"]["if"] = "${{ !cancelled() }}" }],
  "the newer-commit job gains a write permission" => ["must hold only contents: read", ->(wf) { wf["jobs"]["check-newer-head"]["permissions"]["pull-requests"] = "write" }],
  "the newer-commit job checks out and runs git" => ["must use the REST API, with no checkout, run script or git", ->(wf) { wf["jobs"]["check-newer-head"]["steps"].unshift({ "uses" => "actions/checkout@11d5960a326750d5838078e36cf38b85af677262" }) }],
  "the newer-commit job can fail the deploy" => ["must never fail the deploy", ->(wf) { wf["jobs"]["check-newer-head"]["steps"].first.delete("continue-on-error") }],
  "the newer-commit job loses its warning" => ["must warn with ::warning::newer commit", ->(wf) { s = wf["jobs"]["check-newer-head"]["steps"].first["with"]; s["script"] = s["script"].sub("core.warning(`newer commit", "console.log(`newer commit") }],
  "the newer-commit job treats any compare status as newer" => ["treat only status ahead as newer", ->(wf) { s = wf["jobs"]["check-newer-head"]["steps"].first["with"]; s["script"] = s["script"].sub("cmp.status === 'ahead'", "true") }],
  "the newer-commit step returns to deploy-production" => ["must not have the newer-commit step", ->(wf) { wf["jobs"]["deploy-production"]["steps"] << { "name" => "Warn when a newer commit is not deployed", "run" => with_unset.call("true") } }],
  "deploy-production gets GH_TOKEN" => ["must never reference github.token, GITHUB_TOKEN or GH_TOKEN", ->(wf) { (step.call(wf, "deploy-production", "Lint")["env"] ||= {})["GH_TOKEN"] = "x" }],
  "deploy-production reads github.token" => ["must never reference github.token, GITHUB_TOKEN or GH_TOKEN", ->(wf) { (step.call(wf, "deploy-production", "Lint")["env"] ||= {})["T"] = "${{ github.token }}" }],
  "deploy-production reads secrets.GITHUB_TOKEN" => ["must never reference github.token, GITHUB_TOKEN or GH_TOKEN", ->(wf) { (step.call(wf, "deploy-production", "Lint")["env"] ||= {})["T"] = "${{ secrets.GITHUB_TOKEN }}" }],
  "the deployed job output is removed" => ["must export a deployed job output", ->(wf) { wf["jobs"]["deploy-production"]["outputs"].delete("deployed") }],
  "discord-deploy stops waiting for the newer-commit job" => ["must report not-deployed outcomes separately", ->(wf) { wf["jobs"]["discord-deploy"]["needs"] = "deploy-production" }],
  "discord-deploy reports the raw job result again" => ["must report not-deployed outcomes separately", ->(wf) { wf["jobs"]["discord-deploy"]["with"].delete("deploy_title") }],
  "the webhook secret returns to deploy-production" => ["must not reference DISCORD_WEBHOOK_URL anywhere", ->(wf) { (step.call(wf, "deploy-production", "Lint")["env"] ||= {})["WEBHOOK_URL"] = "${{ secrets.DISCORD_WEBHOOK_URL }}" }],
  "the marker read is removed" => ["the marker read must come before the rsync", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub('gcloud storage cat "$marker"', "true") }],
  "the marker is only written after the rsync (no intent record)" => ["must be written BEFORE the rsync", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub(/^ *write_marker \|\| [^\n]*\n/, "") }],
  "the marker write is removed" => ["the marker write must be defined once", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].lines.reject { |l| l.include?("gcloud storage cp --cache-control") }.join }],
  "the .deploy/ exclusion is removed" => ["the rsync must exclude .deploy/", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub(" -x '^\\.deploy/'", "") }],
  "the stale warning is removed" => ["the skip path must emit ::warning::stale deploy skipped", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub("::warning::stale deploy skipped:", "stale deploy skipped:") }],
  "an unknown marker commit no longer fails closed" => ["an unknown marker commit must fail closed", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = s["run"].sub(/(git cat-file -e [^\n]*?)exit 1/, '\1true') }],
  "the guard falls back to a branch-head lookup" => ["the guard must not look up the branch head", ->(wf) { s = step.call(wf, "deploy-production", "Deploy to production"); s["run"] = "#{s['run']}\ncurl https://api.github.com/repos/x/commits/main\n" }],
  "the checkout loses fetch-depth: 0" => ["the checkout needs fetch-depth: 0", ->(wf) { wf["jobs"]["deploy-production"]["steps"].find { |x| x.fetch("uses", "").start_with?("actions/checkout@") }["with"].delete("fetch-depth") }],
  "the production install drops --ignore-scripts" => ["every install in an id-token job needs --ignore-scripts", ->(wf) { s = step.call(wf, "deploy-production", "Install dependencies"); s["run"] = s["run"].gsub("--ignore-scripts", "") }],
  "npm ci in a new production step" => ["every install in an id-token job needs --ignore-scripts", ->(wf) { wf["jobs"]["deploy-production"]["steps"].insert(8, { "name" => "More deps", "run" => with_unset.call("npm ci") }) }],
  "the unset is removed from Lint" => ["step \"Lint\" must start its script with", ->(wf) { strip_unset.call(wf, "Lint") }],
  "the unset is removed from the install" => ["step \"Install dependencies\" must start its script with", ->(wf) { strip_unset.call(wf, "Install dependencies") }],
  "the unset is removed from Build production" => ["step \"Build production\" must start its script with", ->(wf) { strip_unset.call(wf, "Build production") }],
  "the unset is removed from Type check" => ["step \"Type check\" must start its script with", ->(wf) { strip_unset.call(wf, "Type check") }],
  "the unset is removed from the first step" => ["step \"Validate deploy service account\" must start its script with", ->(wf) { strip_unset.call(wf, "Validate deploy service account") }],
  "the unset is removed from the deploy step" => ["step \"Deploy to production\" must start its script with", ->(wf) { strip_unset.call(wf, "Deploy to production") }],
  "the unset is not the first command in Build" => ["step \"Build production\" must start its script with", ->(wf) { s = step.call(wf, "deploy-production", "Build production"); s["run"] = "echo before\n#{s['run']}" }],
  "only one variable is unset" => ["step \"Lint\" must start its script with", ->(wf) { s = step.call(wf, "deploy-production", "Lint"); s["run"] = s["run"].sub(UNSET_LINE, "unset ACTIONS_ID_TOKEN_REQUEST_URL") }],
  "an inert env blank is added to a step" => ["step \"Lint\" must not set the OIDC variables in env", ->(wf) { (step.call(wf, "deploy-production", "Lint")["env"] ||= {})["ACTIONS_ID_TOKEN_REQUEST_URL"] = "" }],
  "an inert env blank is added to the authenticate step" => ["step \"Authenticate to Google Cloud\" must not set the OIDC variables in env", ->(wf) { (step.call(wf, "deploy-production", "Authenticate to Google Cloud")["env"] ||= {})["ACTIONS_ID_TOKEN_REQUEST_TOKEN"] = "" }],
  "a new run step without the unset is added" => ["step \"Extra\" must start its script with", ->(wf) { wf["jobs"]["deploy-production"]["steps"].insert(9, { "name" => "Extra", "run" => "echo hi" }) }],
  "a second authenticate step is added" => ["must authenticate exactly once", ->(wf) { wf["jobs"]["deploy-production"]["steps"] << { "uses" => "google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093" } }],
  "the anchored validation script loses the unset" => ["the anchored dependency validation script must start with the unset line", ->(wf) { s = wf["jobs"]["build-preview"]["steps"].find { |x| x.fetch("name", "") == "Validate preview dependency inputs" }; s["run"] = s["run"].lines.reject { |line| line.strip == UNSET_LINE }.join }],
}
# Each mutation must trip ITS rule: the expected message has to appear, so a mutation cannot pass on an unrelated failure.
mutations.each do |label, (expected, mutate)|
  mutated = deep_copy(workflow)
  begin
    mutate.call(mutated)
  rescue NoMethodError
    failures << "mutation `#{label}` could not be applied (a step it targets is missing or renamed): update the mutation"
    next
  end
  caught = failures_for(mutated)
  failures << "mutation `#{label}` was NOT caught" if caught.empty?
  failures << "mutation `#{label}` was caught by the wrong rule: expected a message containing #{expected.inspect}, got #{caught.inspect}" if !caught.empty? && caught.none? { |message| message.include?(expected) }
end

if failures.empty?
  puts "static deploy token job: OK (no rebuild or script-running install in any id-token job, the OIDC variables unset first in every production run script, #{mutations.length} mutations caught, each by its own rule)"
else
  warn "static deploy token job FAILED:\n  - #{failures.join("\n  - ")}"
  exit 1
end
