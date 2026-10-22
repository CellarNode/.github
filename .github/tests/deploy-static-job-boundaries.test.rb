require "yaml"
require "open3"
require "tmpdir"
require "json"

workflow_path = File.expand_path("../workflows/deploy-static-website.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)
jobs = workflow.fetch("jobs")

# CEL-1980: every @cellarnode/* package is public on npm and the org
# NPM_TOKEN secret has been retired. Guard against silent re-introduction.
# YAML 1.1 (Psych) parses the bare `on:` key as boolean true, so look it up by either key.
workflow_triggers = workflow["on"] || workflow[true] || abort("deploy-static-website.yaml has no on: block")
workflow_call_secrets = workflow_triggers.dig("workflow_call", "secrets") || {}
abort "deploy-static-website.yaml must not declare NPM_TOKEN as a secret input (CEL-1980)" if workflow_call_secrets.key?("NPM_TOKEN")

def deep_string_values(node)
  case node
  when Hash
    node.values.flat_map { |value| deep_string_values(value) }
  when Array
    node.flat_map { |value| deep_string_values(value) }
  when String
    [node]
  else
    []
  end
end

abort "No job may reference the retired NPM_TOKEN secret (CEL-1980)" if deep_string_values(jobs).any? { |value| value.match?(/secrets(\.|\[['"])NPM_TOKEN/) }

cancel_in_progress = workflow.fetch("concurrency").fetch("cancel-in-progress")
expected_cancel_policy = "${{ github.event_name == 'pull_request_target' }}"
abort "Production deploys must never be cancelled in progress" unless cancel_in_progress == expected_cancel_policy

abort "Preview dependencies must not cross jobs through a package-store artifact" if jobs.key?("preview-dependencies")

# CEL-2768: the GitHub-hosted Actions budget is exhausted, so the policy job and the single
# production build-and-deploy job run on the existing self-hosted-k8s ARC pool inside the
# digest-pinned ci-runner image. That image carries Node 22, corepack pnpm, ruby and gcloud, so
# one job can validate, build, authenticate and deploy without an artifact or cache hand-off.
# Preview builds deliberately stay GitHub-hosted: they run unmerged pull-request lifecycle scripts
# and every pool pod carries the buildkitd client certificate.
CI_RUNNER_IMAGE = "europe-north1-docker.pkg.dev/festive-terrain-478011-h0/beveriq/ci-runner@sha256:b8ae250c5d7fae79dbbea1f62ca7613ecabd6f3efbd13b533cbdecb293cdf814".freeze

# Evaluate only the boolean/string expression subset used by the preview-policy trust boundary.
def evaluate_policy_routing(expression, private_repo, event, head)
  source = expression.gsub(/\$\{\{|\}\}/, "").gsub(/\s+/, " ").strip
  allowed = /\A(?:\s+|github\.event\.repository\.private|github\.event_name|github\.event\.pull_request\.head\.repo\.full_name|github\.repository|'[^']*'|true|&&|\|\||==|\(|\))+\z/
  abort "Unsupported preview-policy routing expression: #{source}" unless source.match?(allowed)
  source = source
    .gsub("github.event.repository.private", private_repo.inspect)
    .gsub("github.event.pull_request.head.repo.full_name", head.inspect)
    .gsub("github.event_name", event.inspect)
    .gsub("github.repository", '"CellarNode/site"')
  eval(source) # rubocop:disable Security/Eval -- tokens are restricted by the allowlist above
end

preview_policy = jobs.fetch("preview-policy")
policy_runner = preview_policy.fetch("runs-on")
policy_container = preview_policy.fetch("container")
policy_routes = [
  [true, "push", nil, true],
  [true, "pull_request_target", "CellarNode/site", true],
  [true, "pull_request_target", "attacker/site", false],
  [true, "pull_request_target", nil, false],
  [true, "pull_request", "CellarNode/site", false],
  [true, "workflow_dispatch", nil, false],
  [true, "schedule", nil, false],
  [true, "unknown", "CellarNode/site", false],
  [false, "push", nil, false],
  [false, "pull_request_target", "CellarNode/site", false],
  [nil, "push", nil, false],
  [nil, "pull_request_target", "CellarNode/site", false],
]
policy_routes.each do |private_repo, event, head, self_hosted|
  runner = evaluate_policy_routing(policy_runner, private_repo, event, head)
  container = evaluate_policy_routing(policy_container, private_repo, event, head)
  abort "Preview policy runner for #{[private_repo, event, head]} must be #{self_hosted ? "self-hosted-k8s" : "ubuntu-latest"}, got #{runner.inspect}" unless runner == (self_hosted ? "self-hosted-k8s" : "ubuntu-latest")
  abort "Preview policy container for #{[private_repo, event, head]} must be #{self_hosted ? "the pinned ci-runner" : "empty"}, got #{container.inspect}" unless container == (self_hosted ? CI_RUNNER_IMAGE : "")
end
# Each trust guard must matter on its own: neutralising it has to let a non-trusted context onto the pool.
private_guard = "github.event.repository.private == true"
head_guard = "github.event.pull_request.head.repo.full_name == github.repository"
event_guard = "github.event_name == 'pull_request_target'"
[private_guard, head_guard, event_guard].each do |guard|
  [policy_runner, policy_container].each do |expression|
    mutated = expression.sub(guard, "true")
    abort "Guard mutation did not change the preview-policy expression" if mutated == expression
    leaks = policy_routes.any? do |private_repo, event, head, self_hosted|
      result = evaluate_policy_routing(mutated, private_repo, event, head)
      !self_hosted && (result == "self-hosted-k8s" || result == CI_RUNNER_IMAGE)
    end
    abort "Routing scenarios failed to detect a neutralised preview-policy trust guard: #{guard}" unless leaks
  end
end

abort "Preview policy must not receive secrets" unless preview_policy.fetch("permissions") == { "contents" => "read" }
abort "Preview policy must expose a trusted output" unless preview_policy.fetch("outputs", {}).fetch("trusted", nil) == "${{ steps.policy.outputs.trusted }}"
abort "Preview policy must expose a trusted toolchain output" unless preview_policy.fetch("outputs", {}).fetch("toolchain_allowed", nil) == "${{ steps.policy.outputs.toolchain_allowed }}"
policy_step = preview_policy.fetch("steps").find { |step| step.fetch("id", "") == "policy" }
abort "Preview policy must compare actor and author inside the trusted shell" unless policy_step&.fetch("run", "")&.include?('[ "$ACTOR" = "$AUTHOR" ]')
abort "Preview policy must receive actor and author as data" unless policy_step&.fetch("env", {})&.slice("ACTOR", "AUTHOR") == {
  "ACTOR" => "${{ github.actor }}",
  "AUTHOR" => "${{ github.event.pull_request.user.login }}",
}
abort "Preview policy must authenticate its current permission lookup" unless policy_step&.fetch("env", {})&.fetch("GH_TOKEN", nil) == "${{ github.token }}"
abort "Preview policy must query current repository permission" unless policy_step&.fetch("run", "")&.include?('"https://api.github.com/repos/${REPOSITORY}/collaborators/${ACTOR}/permission"')
abort "Preview policy must not depend on the gh CLI (absent from the ci-runner image)" if policy_step&.fetch("run", "")&.match?(/^\s*[^#\n]*\bgh\s+api\b/)
abort "Preview policy must fail closed when the permission lookup fails" unless policy_step&.fetch("run", "")&.include?("set -euo pipefail") && policy_step.fetch("run").include?("--fail")
abort "Preview policy must not check out or run pull-request code" if preview_policy.fetch("steps").any? { |step| step.key?("uses") }
abort "Preview policy must run its single metadata step through bash" unless policy_step&.fetch("shell", nil) == "bash"
abort "Preview policy must require write-capable permission" unless policy_step&.fetch("run", "")&.include?("admin|maintain|write)")
abort "Preview policy must not trust stale author association" if policy_step&.fetch("env", {})&.key?("AUTHOR_ASSOCIATION")
abort "Preview policy must require the trusted pull-request event" unless policy_step&.fetch("run", "")&.include?('[ "$EVENT_NAME" = "pull_request_target" ]')
abort "Preview policy must receive toolchain inputs as data" unless policy_step&.fetch("env", {})&.slice("NODE_VERSION", "PNPM_VERSION") == {
  "NODE_VERSION" => "${{ inputs.node_version }}",
  "PNPM_VERSION" => "${{ inputs.pnpm_version }}",
}
abort "Preview policy must allow only Node.js 22" unless policy_step&.fetch("run", "")&.include?('[ "$NODE_VERSION" = "22" ]')
abort "Preview policy must allow only reviewed pnpm versions" unless policy_step&.fetch("run", "")&.include?("10.28.2|10.32.1")

# Execute the real policy script with a stubbed curl so the permission lookup (curl | jq) is
# exercised end to end: trusted only for write-capable same-repository authors, a failed lookup
# must abort the step instead of producing a trusted output, and non-pull-request events must not
# look anything up at all.
POLICY_TOKEN = "ghs_policy_test_secret".freeze
Dir.mktmpdir do |directory|
  stub_bin = File.join(directory, "bin")
  Dir.mkdir(stub_bin)
  File.write(File.join(stub_bin, "curl"), <<~'STUB')
    #!/usr/bin/env bash
    # Record every invocation (argv and stdin) so tests can prove when curl is not called and
    # that the token never travels in argv.
    printf '%s\n' "$*" >> "$STUB_LOG"
    cat >> "$STUB_LOG.stdin"
    [ "${STUB_CURL_FAIL:-}" = "1" ] && exit 22
    printf '{"permission":"%s"}\n' "$STUB_PERMISSION"
  STUB
  File.chmod(0o755, File.join(stub_bin, "curl"))
  policy_script = policy_step.fetch("run")
  abort "Preview policy lookup must bound the request and retry transient failures" unless policy_script.include?("--max-time 30") && policy_script.include?("--retry 2")
  abort "Preview policy must not put the token in curl arguments" if policy_script.match?(/^[^#\n]*curl[^\n]*GH_TOKEN/) || policy_script.match?(/-H\s+"Authorization/)
  # [env overrides, step succeeds, trusted output, curl expected to be called]
  policy_cases = {
    "same-repository write author" => [{ "STUB_PERMISSION" => "write" }, true, "true", true],
    "same-repository read author" => [{ "STUB_PERMISSION" => "read" }, true, "false", true],
    "permission lookup failure" => [{ "STUB_CURL_FAIL" => "1" }, false, nil, true],
    "different actor and author" => [{ "STUB_PERMISSION" => "admin", "ACTOR" => "someone-else" }, true, "false", false],
    "fork head" => [{ "STUB_PERMISSION" => "admin", "HEAD_REPOSITORY" => "attacker/site" }, true, "false", false],
    "closed action" => [{ "STUB_PERMISSION" => "admin", "EVENT_ACTION" => "closed" }, true, "false", true],
    "unreviewed pnpm" => [{ "STUB_PERMISSION" => "admin", "PNPM_VERSION" => "9.0.0" }, true, "false", true],
    # A push to main has no pull request: even with a broken lookup the step must succeed,
    # keep the toolchain verdict (build-production depends on it) and never call the API.
    "push with failing lookup" => [
      { "STUB_CURL_FAIL" => "1", "EVENT_NAME" => "push", "EVENT_ACTION" => "", "HEAD_REPOSITORY" => "", "AUTHOR" => "" },
      true, "false", false
    ],
  }
  policy_cases.each do |name, (overrides, succeeds, trusted, curl_called)|
    slug = name.tr(" ", "-")
    output_file = File.join(directory, "output-#{slug}")
    log_file = File.join(directory, "curl-#{slug}")
    File.write(output_file, "")
    environment = {
      "PATH" => "#{stub_bin}:#{ENV.fetch("PATH")}",
      "GITHUB_OUTPUT" => output_file,
      "STUB_LOG" => log_file,
      "EVENT_NAME" => "pull_request_target",
      "EVENT_ACTION" => "synchronize",
      "HEAD_REPOSITORY" => "CellarNode/site",
      "REPOSITORY" => "CellarNode/site",
      "ACTOR" => "maintainer",
      "AUTHOR" => "maintainer",
      "NODE_VERSION" => "22",
      "PNPM_VERSION" => "10.32.1",
      "GH_TOKEN" => POLICY_TOKEN,
    }.merge(overrides)
    _stdout, stderr, status = Open3.capture3(environment, "bash", "-c", policy_script)
    abort "preview policy #{name}: expected success=#{succeeds}, got #{status.success?} (#{stderr})" unless status.success? == succeeds
    abort "preview policy #{name}: expected curl called=#{curl_called}" unless File.exist?(log_file) == curl_called
    if curl_called
      abort "preview policy #{name}: token must not appear in curl arguments" if File.read(log_file).include?(POLICY_TOKEN)
      abort "preview policy #{name}: token must reach curl on stdin" unless File.read("#{log_file}.stdin").include?("Bearer #{POLICY_TOKEN}")
    end
    next unless succeeds
    outputs = File.read(output_file)
    abort "preview policy #{name}: expected trusted=#{trusted}" unless outputs.include?("trusted=#{trusted}\n")
    abort "preview policy #{name}: toolchain_allowed must stay true for the approved toolchain" if name == "push with failing lookup" && !outputs.include?("toolchain_allowed=true\n")
  end
end

build_preview = jobs.fetch("build-preview")
abort "Preview build must use a GitHub-hosted runner (CEL-2768: unmerged PR scripts stay off the cluster pool)" unless build_preview.fetch("runs-on") == "ubuntu-latest"
abort "Preview build must not use a self-hosted container" if build_preview.key?("container")
abort "Preview build must not receive workload identity" if build_preview.fetch("permissions", {}).key?("id-token")
abort "Preview build must not receive NPM_TOKEN at job scope" if build_preview.fetch("env", {}).key?("NPM_TOKEN")
abort "Preview build must allow live pull-request authorization lookup" unless build_preview.fetch("permissions", {}).fetch("pull-requests", nil) == "read"
preview_install = build_preview.fetch("steps").find { |step| step.fetch("name", "") == "Install dependencies" }
abort "Preview install must not receive NPM_TOKEN (packages are public on npm; CEL-1980)" if preview_install&.fetch("env", {})&.key?("NPM_TOKEN")
untrusted_preview_names = ["Verify credential isolation", "Rebuild dependencies", "Type check", "Lint", "Build preview"]
untrusted_preview_steps = build_preview.fetch("steps").select { |step| untrusted_preview_names.include?(step.fetch("name", "")) }
abort "Preview rebuild/check/build steps must explicitly clear NPM_TOKEN" unless untrusted_preview_steps.length == 5 && untrusted_preview_steps.all? { |step| step.fetch("env", {}).fetch("NPM_TOKEN", nil) == "" }
abort "Preview build must depend on the trusted policy" unless Array(build_preview.fetch("needs")).include?("preview-policy")
abort "Preview build must require the trusted policy output" unless build_preview.fetch("if") == "needs.preview-policy.outputs.trusted == 'true'"

preview_steps = build_preview.fetch("steps")
dependency_validation_index = preview_steps.index { |step| step.fetch("name", "") == "Validate preview dependency inputs" }
authorization_index = preview_steps.index { |step| step.fetch("name", "") == "Revalidate preview authorization" }
credentialed_install_index = preview_steps.index { |step| step.fetch("name", "") == "Install dependencies" }
abort "Preview dependency inputs must be validated before credentialed install" unless dependency_validation_index && credentialed_install_index && dependency_validation_index < credentialed_install_index
abort "Preview authorization must be revalidated immediately before credentialed install" unless authorization_index && authorization_index + 1 == credentialed_install_index
dependency_validation = preview_steps.fetch(dependency_validation_index)
abort "Preview dependency validation must not receive NPM_TOKEN" if dependency_validation.fetch("env", {}).key?("NPM_TOKEN")
preview_authorization = preview_steps.fetch(authorization_index)
abort "Preview authorization recheck must not receive NPM_TOKEN" if preview_authorization.fetch("env", {}).key?("NPM_TOKEN")
abort "Preview authorization recheck must use pinned GitHub Script" unless preview_authorization.fetch("uses", "").match?(/\Aactions\/github-script@[0-9a-f]{40}\z/)
abort "Preview authorization recheck must use the job token" unless preview_authorization.fetch("with", {}).fetch("github-token", nil) == "${{ github.token }}"

%w[build-preview deploy-production].each do |job_name|
  steps = jobs.fetch(job_name).fetch("steps")
  validation_index = steps.index { |step| step.fetch("name", "") == "Reject non-regular build outputs" }
  abort "#{job_name} must validate build outputs" unless validation_index
  if job_name == "build-preview"
    upload_index = steps.index { |step| step.fetch("name", "") == "Upload static site artifact" }
    abort "#{job_name} must validate build outputs before upload" unless upload_index && validation_index < upload_index
  end

  validation = steps.fetch(validation_index).fetch("run")
  Dir.mktmpdir do |directory|
    dist = File.join(directory, "dist")
    Dir.mkdir(dist)
    File.write(File.join(dist, "index.html"), "safe")
    _stdout, stderr, status = Open3.capture3("bash", "-euo", "pipefail", "-c", validation, chdir: directory)
    abort "#{job_name} must accept regular build outputs: #{stderr}" unless status.success?

    File.symlink("/proc/self/environ", File.join(dist, "environment.txt"))
    _stdout, _stderr, status = Open3.capture3("bash", "-euo", "pipefail", "-c", validation, chdir: directory)
    abort "#{job_name} must reject symlinks before upload or deploy" if status.success?
  end
end

%w[deploy-preview discord-thread-open discord-build-update].each do |job_name|
  job = jobs.fetch(job_name)
  abort "#{job_name} must depend on the trusted policy" unless Array(job.fetch("needs")).include?("preview-policy")
  abort "#{job_name} must require the trusted policy output" unless job.fetch("if").include?("needs.preview-policy.outputs.trusted == 'true'")
end

deploy_preview_steps = jobs.fetch("deploy-preview").fetch("steps")
deploy_authorization_index = deploy_preview_steps.index { |step| step.fetch("name", "") == "Revalidate preview authorization" }
deploy_oidc_index = deploy_preview_steps.index { |step| step.fetch("name", "") == "Authenticate to Google Cloud" }
abort "Preview authorization must be revalidated immediately before OIDC" unless deploy_authorization_index && deploy_authorization_index + 1 == deploy_oidc_index
deploy_authorization = deploy_preview_steps.fetch(deploy_authorization_index)
abort "Build and deploy must execute the same authorization recheck" unless preview_authorization.fetch("with").fetch("script") == deploy_authorization.fetch("with").fetch("script")

authorization_script = preview_authorization.fetch("with").fetch("script")
  base_pull_request = {
    "state" => "open",
    "user" => { "login" => "maintainer" },
    "head" => {
      "sha" => "trusted-head",
      "repo" => { "full_name" => "CellarNode/site" },
    },
  }
  cases = {
    "current trusted author" => [base_pull_request, "write", true],
    "closed pull request" => [base_pull_request.merge("state" => "closed"), "write", false],
    "changed head" => [base_pull_request.merge("head" => base_pull_request.fetch("head").merge("sha" => "changed-head")), "write", false],
    "forked head" => [base_pull_request.merge("head" => base_pull_request.fetch("head").merge("repo" => { "full_name" => "attacker/site" })), "write", false],
    "different author" => [base_pull_request.merge("user" => { "login" => "other-user" }), "write", false],
    "revoked permission" => [base_pull_request, "read", false],
  }

  cases.each do |name, (pull_request, permission, expected)|
    _stdout, _stderr, status = Open3.capture3(
      {
        "ACTOR" => "maintainer",
        "AUTHORIZATION_SCRIPT" => authorization_script,
        "CURRENT_PERMISSION" => permission,
        "EXPECTED_HEAD" => "trusted-head",
        "PR_JSON" => JSON.generate(pull_request),
        "PR_NUMBER" => "42",
        "REPOSITORY" => "CellarNode/site",
      },
      "node", "-e", <<~'JAVASCRIPT',
        const AsyncFunction = Object.getPrototypeOf(async () => null).constructor;
        const pullRequest = JSON.parse(process.env.PR_JSON);
        const github = {
          rest: {
            pulls: { get: async () => ({ data: pullRequest }) },
            repos: {
              getCollaboratorPermissionLevel: async () => ({
                data: { permission: process.env.CURRENT_PERMISSION },
              }),
            },
          },
        };
        const context = { repo: { owner: 'CellarNode', repo: 'site' } };
        const core = { setFailed: message => { throw new Error(message); } };
        new AsyncFunction('github', 'context', 'core', process.env.AUTHORIZATION_SCRIPT)(github, context, core)
          .catch(error => { console.error(error.message); process.exitCode = 1; });
      JAVASCRIPT
    )
    abort "#{name}: expected accepted=#{expected}, got accepted=#{status.success?}" unless status.success? == expected
  end

abort "Preview lifecycle must not bind an unavailable sender field" if File.read(workflow_path).include?("github.event.sender.login")
abort "Preview lifecycle must not trust stale author association" if File.read(workflow_path).include?("author_association")

# CEL-2768: production is ONE job. A separate build job would need an artifact (storage quota is
# exhausted) or a cache (actions/cache restore extracts with tar -P before any of our checks, so a
# compromised build could overwrite the action code of a credentialed job). See
# CellarNode/.github#42 for the cache analysis.
abort "Production must not keep a separate build-production job (CEL-2768)" if jobs.key?("build-production")
deploy_production = jobs.fetch("deploy-production")
abort "Production deploy must use the self-hosted runner" unless deploy_production.fetch("runs-on") == "self-hosted-k8s"
abort "Production deploy must use the pinned ci-runner image" unless deploy_production.dig("container", "image") == CI_RUNNER_IMAGE
abort "Production deploy must only run for pushes to main" unless deploy_production.fetch("if").include?("github.event_name == 'push'") && deploy_production.fetch("if").include?("github.ref == 'refs/heads/main'")
abort "Production deploy must depend only on the toolchain policy" unless Array(deploy_production.fetch("needs")) == ["preview-policy"]
abort "Production deploy must require approved toolchain" unless deploy_production.fetch("if").include?("needs.preview-policy.outputs.toolchain_allowed == 'true'")
abort "Production deploy permissions must be exactly contents: read and id-token: write" unless deploy_production["permissions"] == { "contents" => "read", "id-token" => "write" }
# Build code runs in this job, so it must not be able to start another run (workflow_dispatch needs
# actions: write; repository_dispatch or a workflow-triggering push needs contents: write) and so
# escape the per-site identity. The job block replaces, not extends, any workflow-level permissions.
forbidden_scopes = %w[actions checks deployments discussions issues packages pages pull-requests repository-projects security-events statuses attestations models]
production_permissions = deploy_production["permissions"]
abort "Production job permissions must be an explicit mapping, not a shorthand" unless production_permissions.is_a?(Hash)
abort "Production job must hold only contents: read and id-token: write, got #{production_permissions.inspect}" unless production_permissions.keys.sort == %w[contents id-token] && production_permissions.fetch("contents") == "read" && production_permissions.fetch("id-token") == "write"
abort "Production job must not grant #{forbidden_scopes & production_permissions.keys}" unless (forbidden_scopes & production_permissions.keys).empty?
workflow_permissions = workflow["permissions"]
abort "Workflow-level permissions must not grant write access (got #{workflow_permissions.inspect})" if workflow_permissions.is_a?(String) ? workflow_permissions.match?(/write/) : Array(workflow_permissions&.values).any? { |level| level == "write" }
abort "Production job must not read a repository secret or the job token itself" if deep_string_values(deploy_production).any? { |value| value.match?(/secrets\.|github\.token|GITHUB_TOKEN/) }

deploy_steps = deploy_production.fetch("steps")
artifact_or_cache = /\A(?:actions\/(?:upload-artifact|download-artifact|cache(?:\/[a-z-]+)?)|[^@]*\/(?:upload-artifact|download-artifact))@/
abort "Production path must not use artifact or cache actions (CEL-2768)" if deploy_steps.any? { |step| step.fetch("uses", "").match?(artifact_or_cache) }
abort "Production path must not reference artifacts or caches anywhere in the job" if deep_string_values(deploy_production).any? { |value| value.match?(/upload-artifact|download-artifact|actions\/cache|static-site-/) }
abort "Production job must check out source in the same job" unless deploy_steps.any? { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
production_checkout = deploy_steps.find { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
abort "Production checkout must disable persisted credentials" unless production_checkout.fetch("with", {}).fetch("persist-credentials", nil) == false

step_index = lambda do |name|
  deploy_steps.index { |step| step.fetch("name", "") == name } || abort("Production job is missing step: #{name}")
end
checkout_index = deploy_steps.index { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
account_index = step_index.call("Validate deploy service account")
dependency_index = step_index.call("Validate production dependency inputs")
install_index = step_index.call("Install dependencies")
rebuild_index = step_index.call("Rebuild dependencies")
build_index = step_index.call("Build production")
outputs_index = step_index.call("Reject non-regular build outputs")
auth_index = step_index.call("Authenticate to Google Cloud")
sdk_index = step_index.call("Set up Cloud SDK")
warm_index = step_index.call("Warm gcloud credential cache")
publish_index = step_index.call("Deploy to production")
abort "Deploy service account must be validated before source is fetched" unless account_index < checkout_index
abort "Production steps are out of order" unless checkout_index < dependency_index && dependency_index < install_index && install_index < rebuild_index && rebuild_index < build_index && build_index < outputs_index
abort "Google Cloud authentication must come after build and output validation" unless outputs_index < auth_index && auth_index < sdk_index && sdk_index < warm_index && warm_index < publish_index
google_steps = deploy_steps.each_index.select { |index| deploy_steps.fetch(index).fetch("uses", "").start_with?("google-github-actions/") }
abort "No Google action may run before output validation has finished" unless google_steps.all? { |index| index > outputs_index }
abort "Production must authenticate exactly once" unless deploy_steps.count { |step| step.fetch("uses", "").start_with?("google-github-actions/auth@") } == 1

production_auth = deploy_steps.fetch(auth_index)
abort "Production auth must use the pinned auth action" unless production_auth.fetch("uses") == "google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093"
abort "Production auth must impersonate the caller's deploy_service_account" unless production_auth.fetch("with").fetch("service_account") == "${{ inputs.deploy_service_account }}"
abort "Production path must never reference the shared pipelines service account" if deep_string_values(deploy_production).any? { |value| value.include?("pipelines@") }

# The deploy_service_account input is required and is validated by regex before anything uses it.
account_input = workflow_triggers.dig("workflow_call", "inputs", "deploy_service_account") || {}
abort "deploy_service_account must be a required string input" unless account_input["required"] == true && account_input["type"] == "string"
abort "deploy_service_account must not default to any account" if account_input.key?("default")
account_step = deploy_steps.fetch(account_index)
abort "Service account validation must read the input as data" unless account_step.fetch("env", {}).fetch("DEPLOY_SERVICE_ACCOUNT", nil) == "${{ inputs.deploy_service_account }}"
abort "Service account validation must not interpolate the input into the script" if account_step.fetch("run").include?("inputs.")
abort "Service account validation must run under bash" unless account_step.fetch("shell", nil) == "bash"
project_id = workflow.fetch("env").fetch("PROJECT_ID")
good_account = "site-admin@#{project_id}.iam.gserviceaccount.com"
account_cases = {
  "per-site account" => [good_account, true],
  "site-deploy naming (admin)" => ["site-deploy-admin@#{project_id}.iam.gserviceaccount.com", true],
  "site-deploy naming (publicsite)" => ["site-deploy-publicsite@#{project_id}.iam.gserviceaccount.com", true],
  "shortest allowed name" => ["abcdef@#{project_id}.iam.gserviceaccount.com", true],
  "longest allowed name" => ["#{"a" * 30}@#{project_id}.iam.gserviceaccount.com", true],
  "empty" => ["", false],
  "shared pipelines account" => ["pipelines@#{project_id}.iam.gserviceaccount.com", false],
  "name too short" => ["abcde@#{project_id}.iam.gserviceaccount.com", false],
  "name too long" => ["#{"a" * 31}@#{project_id}.iam.gserviceaccount.com", false],
  "leading digit" => ["1site-admin@#{project_id}.iam.gserviceaccount.com", false],
  "trailing hyphen" => ["site-admin-@#{project_id}.iam.gserviceaccount.com", false],
  "uppercase" => ["Site-Admin@#{project_id}.iam.gserviceaccount.com", false],
  "other project" => ["site-admin@other-project-123456.iam.gserviceaccount.com", false],
  "other domain" => ["site-admin@#{project_id}.iam.example.com", false],
  "dots are literal" => ["site-admin@#{project_id}.iamXgserviceaccount.com", false],
  "suffix smuggling" => ["#{good_account}.evil.example", false],
  "prefix smuggling" => ["evil #{good_account}", false],
  "trailing newline" => ["#{good_account}\n", false],
  "second line" => ["#{good_account}\nattacker@#{project_id}.iam.gserviceaccount.com", false],
  "user email" => ["someone@gmail.com", false],
}
account_cases.each do |name, (account, expected)|
  _stdout, stderr, status = Open3.capture3({ "PROJECT_ID" => project_id, "DEPLOY_SERVICE_ACCOUNT" => account, "WEBSITE" => "admin.cellarnode.com" }, "bash", "-euo", "pipefail", "-c", account_step.fetch("run"))
  abort "deploy_service_account #{name}: expected accepted=#{expected}, got accepted=#{status.success?} (#{stderr.strip})" unless status.success? == expected
end

# The production gcloud commands are confined to gs://<bucket>/<hostname>/, the only prefix a per-site
# service account is granted (object operations plus objectListPrefix, no bucket-root listing). The
# hostname is validated first, so an empty value, slash, dot-segment or glob cannot widen the target.
website_cases = {
  "admin host" => ["admin.cellarnode.com", true],
  "hyphenated host" => ["e-label.cellarnode.com", true],
  "empty" => ["", false],
  "bucket root slash" => ["/", false],
  "path" => ["admin.cellarnode.com/preview", false],
  "other prefix" => ["preview/admin", false],
  "slash in first label" => ["preview/admin.cellarnode.com", false],
  "slash in middle label" => ["admin.cellar/node.com", false],
  "preview prefix trick" => ["preview/site/123.cellarnode.com", false],
  "dot-dot segment" => ["..", false],
  "glob" => ["*.cellarnode.com", false],
  "uppercase" => ["Admin.cellarnode.com", false],
  "trailing dot" => ["admin.cellarnode.com.", false],
  "leading dot" => [".cellarnode.com", false],
  "single label" => ["admin", false],
  "space" => ["admin.cellarnode.com evil", false],
  "trailing newline" => ["admin.cellarnode.com\n", false],
}
website_cases.each do |name, (website, expected)|
  _stdout, stderr, status = Open3.capture3({ "PROJECT_ID" => project_id, "DEPLOY_SERVICE_ACCOUNT" => good_account, "WEBSITE" => website }, "bash", "-euo", "pipefail", "-c", account_step.fetch("run"))
  abort "website #{name}: expected accepted=#{expected}, got accepted=#{status.success?} (#{stderr.strip})" unless status.success? == expected
end

bucket = workflow.fetch("env").fetch("GCS_BUCKET")
site_prefix = /\Ags:\/\/\$\{GCS_BUCKET\}\/\$\{WEBSITE\}\/?\z/
deploy_runs = deploy_steps.map { |step| [step.fetch("name", step.fetch("uses", "")), step.fetch("run", "").lines.reject { |line| line.lstrip.start_with?("#") }.join] }.reject { |_name, run| run.empty? }
production_gcloud_calls = deploy_runs.flat_map { |_name, run| run.scan(/(?<![\w-])gcloud\s+(?!warm-up)(?:\S+)\s+(?:\S+)/) }
abort "Production path must run gcloud storage ls and rsync, got #{production_gcloud_calls.inspect}" unless production_gcloud_calls.length == 2
abort "Production path may only run gcloud storage ls and rsync" unless production_gcloud_calls.map { |call| call.split.values_at(1, 2).join(" ") }.sort == ["storage ls", "storage rsync"]
abort "Production path must not use gsutil or gcloud storage cp/rm/mv/buckets" if deploy_runs.any? { |_name, run| run.match?(/gsutil|gcloud storage (?:cp|rm|mv|buckets|objects)/) }
bucket_urls = deploy_runs.flat_map { |_name, run| run.scan(%r{gs://[^\s"']*}) }
abort "Production path must reference the bucket by URL" if bucket_urls.empty?
abort "Production gcloud commands must stay within gs://${GCS_BUCKET}/${WEBSITE}/, got #{bucket_urls.reject { |url| url.match?(site_prefix) }.inspect}" unless bucket_urls.all? { |url| url.match?(site_prefix) }
abort "Production path must not hard-code a bucket or prefix" if deploy_runs.any? { |_name, run| run.include?(bucket) || run.include?("preview/") }

# Parallel composite uploads write temporary objects outside the site prefix, so they must stay off.
production_publish_env = deploy_steps.fetch(publish_index).fetch("env", {})
abort "Production rsync must disable parallel composite uploads (they write outside the site prefix)" unless production_publish_env.fetch("CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED", nil) == "False"
abort "Production path must not re-enable composite uploads through gcloud config" if deploy_runs.any? { |_name, run| run.match?(/parallel_composite_upload/i) }

# Execute the warm-up and deploy steps against a recording gcloud to prove the real targets.
Dir.mktmpdir do |directory|
  File.write(File.join(directory, "sleep"), "#!/bin/sh\nexit 0\n")
  File.chmod(0o755, File.join(directory, "sleep"))
  log = File.join(directory, "calls.log")
  stub_gcloud = lambda do |exit_code, message|
    File.write(File.join(directory, "gcloud"), "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$STUB_LOG\"\necho \"#{message}\" >&2\nexit #{exit_code}\n")
    File.chmod(0o755, File.join(directory, "gcloud"))
    File.write(log, "")
  end
  run_step = lambda do |name, runner|
    step = deploy_steps.fetch(step_index.call(name))
    env = {
      "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
      "STUB_LOG" => log,
      "GCS_BUCKET" => bucket,
      "WEBSITE" => "admin.cellarnode.com",
    }
    Dir.mkdir(File.join(directory, "dist")) unless Dir.exist?(File.join(directory, "dist"))
    Open3.capture3(env, *runner, step.fetch("run"), chdir: directory)
  end
  # Production steps without `shell:` run under the runner default (sh -e), not bash.
  posix = [File.exist?("/bin/dash") || File.exist?("/usr/bin/dash") ? "dash" : "sh", "-e", "-c"]

  stub_gcloud.call(0, "")
  _out, err, status = run_step.call("Warm gcloud credential cache", posix)
  abort "Warm-up must succeed when the prefix lists: #{err}" unless status.success?
  abort "Warm-up must list only the site prefix, got #{File.read(log).inspect}" unless File.read(log) == "storage ls gs://#{bucket}/admin.cellarnode.com/\n"

  stub_gcloud.call(1, "ERROR: (gcloud.storage.ls) One or more URLs matched no objects.")
  _out, err, status = run_step.call("Warm gcloud credential cache", posix)
  abort "Warm-up must accept an empty site prefix on a first deploy: #{err}" unless status.success?
  abort "Warm-up must not retry an empty prefix" unless File.read(log).lines.length == 1

  stub_gcloud.call(1, "ERROR: (gcloud.storage.ls) HTTPError 403: caller does not have storage.objects.list access")
  _out, _err, status = run_step.call("Warm gcloud credential cache", posix)
  abort "Warm-up must fail closed when listing the site prefix is denied" if status.success?
  abort "Warm-up must retry five times before failing" unless File.read(log).lines.length == 5

  stub_gcloud.call(0, "")
  _out, err, status = run_step.call("Deploy to production", posix)
  abort "Deploy step must succeed with a working gcloud: #{err}" unless status.success?
  abort "Deploy must rsync ./dist into the site prefix only, got #{File.read(log).inspect}" unless File.read(log).match?(%r{\Astorage rsync .* \./dist gs://#{Regexp.escape(bucket)}/admin\.cellarnode\.com\n\z})
end

# Previews are untouched by CEL-2768: they keep the artifact hand-off and their existing identity.
abort "Preview build must keep its artifact upload" unless jobs.fetch("build-preview").fetch("steps").any? { |step| step.fetch("uses", "").start_with?("actions/upload-artifact@") }
%w[deploy-preview cleanup].each do |job_name|
  job_steps = jobs.fetch(job_name).fetch("steps")
  preview_auth = job_steps.find { |step| step.fetch("uses", "").start_with?("google-github-actions/auth@") }
  abort "#{job_name} must keep its existing pipelines identity (previews unchanged by CEL-2768)" unless preview_auth&.fetch("with", {})&.fetch("service_account", nil) == "pipelines@${{ env.PROJECT_ID }}.iam.gserviceaccount.com"
end
abort "Preview deploy must keep its artifact download" unless jobs.fetch("deploy-preview").fetch("steps").any? { |step| step.fetch("uses", "").start_with?("actions/download-artifact@") }

discord_deploy = jobs.fetch("discord-deploy")
abort "Deploy notification must follow the single production job" unless Array(discord_deploy.fetch("needs")) == ["deploy-production"]
abort "Deploy notification must report the production job result" unless discord_deploy.fetch("with").fetch("status") == "${{ needs.deploy-production.result }}"
abort "Deploy notification must survive failure but not cancellation" unless discord_deploy.fetch("if").include?("!cancelled()") && !discord_deploy.fetch("if").include?("always()")

{
  "deploy-production" => "Deploy to production",
  "deploy-preview" => "Deploy preview",
}.each do |job_name, step_name|
  deploy_step = jobs.fetch(job_name).fetch("steps").find { |step| step.fetch("name", "") == step_name }
  storage_parallelism = deploy_step&.fetch("env", {})&.slice(
    "CLOUDSDK_STORAGE_PROCESS_COUNT",
    "CLOUDSDK_STORAGE_THREAD_COUNT",
  )
  expected_serial_execution = {
    "CLOUDSDK_STORAGE_PROCESS_COUNT" => "1",
    "CLOUDSDK_STORAGE_THREAD_COUNT" => "1",
  }
  abort "#{step_name} must serialize gcloud storage workers" unless storage_parallelism == expected_serial_execution
end

cleanup = jobs.fetch("cleanup")
cleanup_guard = cleanup.fetch("if")
abort "Preview cleanup must survive author offboarding" if cleanup_guard.include?("author_association")

cleanup_steps = cleanup.fetch("steps")
cleanup_authorization_index = cleanup_steps.index { |step| step.fetch("name", "") == "Revalidate cleanup authorization" }
cleanup_oidc_index = cleanup_steps.index { |step| step.fetch("name", "") == "Authenticate to Google Cloud" }
abort "Cleanup authorization must be revalidated immediately before OIDC" unless cleanup_authorization_index && cleanup_authorization_index + 1 == cleanup_oidc_index
cleanup_authorization = cleanup_steps.fetch(cleanup_authorization_index)
abort "Cleanup authorization recheck must use pinned GitHub Script" unless cleanup_authorization.fetch("uses", "").match?(/\Aactions\/github-script@[0-9a-f]{40}\z/)
abort "Cleanup authorization recheck must use the job token" unless cleanup_authorization.fetch("with", {}).fetch("github-token", nil) == "${{ github.token }}"
cleanup_script = cleanup_authorization.fetch("with").fetch("script")
abort "Cleanup authorization must require a closed pull request" unless cleanup_script.include?("pullRequest.state === 'closed'")
abort "Cleanup authorization must allow a write-capable closer who is not the pull-request author" if cleanup_script.include?("pullRequest.user?.login === actor")
abort "Cleanup authorization must require current write permission" unless cleanup_script.include?("['admin', 'maintain', 'write'].includes(access.permission)")

cleanup_base_pull_request = {
  "state" => "closed",
  "user" => { "login" => "author" },
  "head" => { "repo" => { "full_name" => "CellarNode/site" } },
}
cleanup_cases = {
  "write-capable maintainer closes another author's pull request" => [cleanup_base_pull_request, "write", true],
  "write-capable author closes own pull request" => [cleanup_base_pull_request.merge("user" => { "login" => "maintainer" }), "write", true],
  "open pull request" => [cleanup_base_pull_request.merge("state" => "open"), "write", false],
  "forked head" => [cleanup_base_pull_request.merge("head" => { "repo" => { "full_name" => "attacker/site" } }), "write", false],
  "revoked permission" => [cleanup_base_pull_request, "read", false],
}
cleanup_cases.each do |name, (pull_request, permission, expected)|
  _stdout, _stderr, status = Open3.capture3(
    {
      "ACTOR" => "maintainer",
      "AUTHORIZATION_SCRIPT" => cleanup_script,
      "CURRENT_PERMISSION" => permission,
      "PR_JSON" => JSON.generate(pull_request),
      "PR_NUMBER" => "42",
      "REPOSITORY" => "CellarNode/site",
    },
    "node", "-e", <<~'JAVASCRIPT',
      const AsyncFunction = Object.getPrototypeOf(async () => null).constructor;
      const pullRequest = JSON.parse(process.env.PR_JSON);
      const github = {
        rest: {
          pulls: { get: async () => ({ data: pullRequest }) },
          repos: {
            getCollaboratorPermissionLevel: async ({ username }) => {
              if (username !== process.env.ACTOR) throw new Error(`unexpected permission subject: ${username}`);
              return { data: { permission: process.env.CURRENT_PERMISSION } };
            },
          },
        },
      };
      const context = { repo: { owner: 'CellarNode', repo: 'site' } };
      const core = { setFailed: message => { throw new Error(message); } };
      new AsyncFunction('github', 'context', 'core', process.env.AUTHORIZATION_SCRIPT)(github, context, core)
        .catch(error => { console.error(error.message); process.exitCode = 1; });
    JAVASCRIPT
  )
  abort "cleanup #{name}: expected accepted=#{expected}, got accepted=#{status.success?}" unless status.success? == expected
end

delete_preview = cleanup_steps.find { |step| step.fetch("name", "") == "Delete preview" }
cleanup_parallelism = delete_preview&.fetch("env", {})&.slice(
  "CLOUDSDK_STORAGE_PROCESS_COUNT",
  "CLOUDSDK_STORAGE_THREAD_COUNT",
)
abort "Preview cleanup must serialize gcloud storage workers" unless cleanup_parallelism == {
  "CLOUDSDK_STORAGE_PROCESS_COUNT" => "1",
  "CLOUDSDK_STORAGE_THREAD_COUNT" => "1",
}

validation_path = File.expand_path("../workflows/validate-static-deploy.yaml", __dir__)
validation = YAML.safe_load(File.read(validation_path), aliases: true)
validation_checkout = validation.fetch("jobs").fetch("lock-validator").fetch("steps").find { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
abort "Validation checkout must disable persisted credentials" unless validation_checkout&.fetch("with", {})&.fetch("persist-credentials", nil) == false

puts "Static deploy job boundaries passed"
