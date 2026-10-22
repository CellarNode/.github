# CEL-2768: build and dependency code run in `deploy-production`, the job that holds `id-token: write`.
#
# Two rules keep that job from handing its OIDC token to code it just installed:
#   1. In EVERY job that holds `id-token: write`, no step runs dependency lifecycle scripts: `--ignore-scripts` on the install is undone
#      by a later `pnpm|npm|yarn rebuild`, and an install without `--ignore-scripts` runs them. (The GitHub-hosted `build-preview`
#      holds no id-token and may rebuild.)
#   2. In `deploy-production`, every step except Authenticate sets ACTIONS_ID_TOKEN_REQUEST_URL and ACTIONS_ID_TOKEN_REQUEST_TOKEN to
#      empty, so build and dependency code cannot casually mint the job's token. This is defence in depth, not a hard boundary: a
#      process the build leaves running could read a later step's environment, which is why `dist` is re-checked before the upload.
#
# The test then mutates the workflow to prove each rule can fail.
#
# Run: ruby .github/tests/deploy-static-token-job.test.rb      (exit 0 = every rule holds)

require "yaml"

PATH_TO_WORKFLOW = File.expand_path("../workflows/deploy-static-website.yaml", __dir__)
OIDC_VARS = %w[ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN].freeze
REBUILD = /\b(?:pnpm|npm|yarn)\s+rebuild\b/
INSTALL = /\b(?:pnpm|npm|yarn)\s+(?:install|i|add|ci)\b/

def failures_for(workflow)
  out = []
  jobs = workflow.fetch("jobs")

  # Rule 1: every job that holds id-token: write
  jobs.each do |job_name, job|
    next unless job.fetch("permissions", {}).is_a?(Hash) && job.fetch("permissions", {}).fetch("id-token", nil) == "write"

    job.fetch("steps", []).each do |step|
      run = step.fetch("run", "")
      label = "#{job_name} / #{step.fetch('name', step.fetch('uses', 'a step'))}"
      out << "#{label}: a job holding id-token: write must not rebuild dependencies" if run.match?(REBUILD)
      out << "#{label}: a job holding id-token: write must install with --ignore-scripts" if run.match?(INSTALL) && !run.include?("--ignore-scripts")
    end
  end

  # Rule 2: deploy-production blanks the OIDC variables everywhere except Authenticate
  production = jobs.fetch("deploy-production")
  steps = production.fetch("steps")
  out << "deploy-production: must not have a Rebuild dependencies step" if steps.any? { |step| step.fetch("name", "") == "Rebuild dependencies" }
  auth_steps = steps.select { |step| step.fetch("uses", "").start_with?("google-github-actions/auth@") }
  out << "deploy-production: must authenticate exactly once (got #{auth_steps.length})" unless auth_steps.length == 1
  steps.each do |step|
    label = step.fetch("name", step.fetch("uses", "a step"))
    env = step.fetch("env", {})
    if step.fetch("uses", "").start_with?("google-github-actions/auth@")
      out << "deploy-production: the authenticate step must keep the OIDC variables" if OIDC_VARS.any? { |name| env.key?(name) }
    else
      OIDC_VARS.each { |name| out << "deploy-production: step #{label.inspect} must blank #{name}" unless env[name] == "" }
    end
  end
  out
end

def deep_copy(object)
  Marshal.load(Marshal.dump(object))
end

workflow = YAML.safe_load(File.read(PATH_TO_WORKFLOW), aliases: true)
failures = failures_for(workflow)

# Control: the hosted preview build holds no id-token, so its own rebuild must not be flagged by rule 1.
preview_rebuilds = workflow.fetch("jobs").fetch("build-preview").fetch("steps").any? { |step| step.fetch("run", "").match?(REBUILD) }
failures << "control: build-preview is expected to keep its rebuild (it holds no id-token); the rule must not flag it" unless preview_rebuilds
failures << "control: build-preview must hold no id-token" if workflow.fetch("jobs").fetch("build-preview").fetch("permissions", {}).key?("id-token")

step = ->(wf, job, name) { wf["jobs"][job]["steps"].find { |s| s.fetch("name", s.fetch("uses", "")) == name } }
mutations = {
  "a Rebuild dependencies step returns to deploy-production" => ->(wf) { wf["jobs"]["deploy-production"]["steps"].insert(8, { "name" => "Rebuild dependencies", "env" => { "ACTIONS_ID_TOKEN_REQUEST_URL" => "", "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "" }, "run" => "pnpm rebuild" }) },
  "npm rebuild hidden in the Build step" => ->(wf) { step.call(wf, "deploy-production", "Build production")["run"] = "npm rebuild && pnpm build" },
  "yarn rebuild in the cleanup job (it holds id-token)" => ->(wf) { wf["jobs"]["cleanup"]["steps"].first["run"] = "yarn rebuild" },
  "an install without --ignore-scripts in deploy-preview (it holds id-token)" => ->(wf) { wf["jobs"]["deploy-preview"]["steps"].first["run"] = "pnpm install --frozen-lockfile" },
  "the production install drops --ignore-scripts" => ->(wf) { step.call(wf, "deploy-production", "Install dependencies")["run"] = step.call(wf, "deploy-production", "Install dependencies")["run"].gsub("--ignore-scripts", "") },
  "npm ci in a new production step" => ->(wf) { wf["jobs"]["deploy-production"]["steps"].insert(8, { "name" => "More deps", "env" => { "ACTIONS_ID_TOKEN_REQUEST_URL" => "", "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "" }, "run" => "npm ci" }) },
  "the URL is not blanked in Lint" => ->(wf) { step.call(wf, "deploy-production", "Lint")["env"].delete("ACTIONS_ID_TOKEN_REQUEST_URL") },
  "the token is not blanked in the install" => ->(wf) { step.call(wf, "deploy-production", "Install dependencies")["env"].delete("ACTIONS_ID_TOKEN_REQUEST_TOKEN") },
  "Build production does not blank them" => ->(wf) { step.call(wf, "deploy-production", "Build production")["env"].delete("ACTIONS_ID_TOKEN_REQUEST_URL"); step.call(wf, "deploy-production", "Build production")["env"].delete("ACTIONS_ID_TOKEN_REQUEST_TOKEN") },
  "a variable is passed through instead of blanked" => ->(wf) { step.call(wf, "deploy-production", "Type check")["env"]["ACTIONS_ID_TOKEN_REQUEST_URL"] = "${{ env.ACTIONS_ID_TOKEN_REQUEST_URL }}" },
  "the first step is not blanked" => ->(wf) { step.call(wf, "deploy-production", "Validate deploy service account")["env"].delete("ACTIONS_ID_TOKEN_REQUEST_TOKEN") },
  "the Cloud SDK step is not blanked" => ->(wf) { step.call(wf, "deploy-production", "Set up Cloud SDK")["env"].delete("ACTIONS_ID_TOKEN_REQUEST_URL") },
  "the deploy step is not blanked" => ->(wf) { step.call(wf, "deploy-production", "Deploy to production")["env"].delete("ACTIONS_ID_TOKEN_REQUEST_TOKEN") },
  "the authenticate step blanks the variables" => ->(wf) { step.call(wf, "deploy-production", "Authenticate to Google Cloud")["env"] = { "ACTIONS_ID_TOKEN_REQUEST_URL" => "" } },
  "an unblanked step is added" => ->(wf) { wf["jobs"]["deploy-production"]["steps"].insert(9, { "name" => "Extra", "run" => "echo hi" }) },
  "a second authenticate step is added" => ->(wf) { wf["jobs"]["deploy-production"]["steps"] << { "uses" => "google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093" } },
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
  puts "static deploy token job: OK (no rebuild or script-running install in any id-token job, OIDC variables blanked on every non-auth production step, #{mutations.length} mutations caught)"
else
  warn "static deploy token job FAILED:\n  - #{failures.join("\n  - ")}"
  exit 1
end
