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
# CEL-2795: the Discord webhook never reaches the job that runs build code and holds id-token. The deploy notification is a separate
# `discord-deploy` job that calls the reusable notifier. No step of deploy-production may read a secret or the job token.
secret_pattern = /secrets\.|github\.token|GITHUB_TOKEN|GH_TOKEN/
# No exception: the newer-commit liveness check lives in the separate check-newer-head job, so deploy-production never holds a GitHub token.
abort "Production job must not read a repository secret or the job token (the webhook belongs to discord-deploy; the token belongs to no build job)" if deep_string_values(deploy_production).any? { |value| value.match?(secret_pattern) }
abort "Production job must not mention DISCORD_WEBHOOK_URL anywhere" if deep_string_values(deploy_production).any? { |value| value.include?("DISCORD_WEBHOOK_URL") }
abort "Production job must carry its own non-cancelling lock" unless deploy_production["concurrency"] == { "group" => "static-deploy-prod-${{ inputs.website_slug }}", "cancel-in-progress" => false }
abort "The workflow-level group must be unique per push run (run_id), so no notify job holds a deploy lock" unless workflow.fetch("concurrency").fetch("group") == "static-deploy-${{ inputs.website_slug }}-${{ github.event.pull_request.number || github.run_id }}"

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
build_index = step_index.call("Build production")
outputs_index = step_index.call("Reject non-regular build outputs")
auth_index = step_index.call("Authenticate to Google Cloud")
sdk_index = step_index.call("Set up Cloud SDK")
warm_index = step_index.call("Warm gcloud credential cache")
publish_index = step_index.call("Deploy to production")
abort "Deploy service account must be validated before source is fetched" unless account_index < checkout_index
abort "Production must not rebuild dependencies (the install runs with --ignore-scripts in the job that holds id-token: write)" if deploy_steps.any? { |step| step.fetch("name", "") == "Rebuild dependencies" }
abort "Production steps are out of order" unless checkout_index < dependency_index && dependency_index < install_index && install_index < build_index && build_index < outputs_index
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
good_account = "site-deploy-admin@#{project_id}.iam.gserviceaccount.com"
account_cases = {
  "per-site account" => [good_account, true],
  "site-deploy naming (publicsite)" => ["site-deploy-publicsite@#{project_id}.iam.gserviceaccount.com", true],
  "site-deploy naming (digits and hyphens)" => ["site-deploy-admin-2@#{project_id}.iam.gserviceaccount.com", true],
  "empty" => ["", false],
  "shared pipelines account" => ["pipelines@#{project_id}.iam.gserviceaccount.com", false],
  "other per-site-looking name without the prefix" => ["site-admin@#{project_id}.iam.gserviceaccount.com", false],
  "arbitrary service account" => ["abcdef@#{project_id}.iam.gserviceaccount.com", false],
  "nothing after the prefix" => ["site-deploy-@#{project_id}.iam.gserviceaccount.com", false],
  "prefix with nothing before the at sign" => ["site-deploy@#{project_id}.iam.gserviceaccount.com", false],
  "uppercase" => ["Site-Deploy-Admin@#{project_id}.iam.gserviceaccount.com", false],
  "other project" => ["site-deploy-admin@other-project-123456.iam.gserviceaccount.com", false],
  "other domain" => ["site-deploy-admin@#{project_id}.iam.example.com", false],
  "dots are literal" => ["site-deploy-admin@#{project_id}.iamXgserviceaccount.com", false],
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
site_prefix = /\Ags:\/\/\$\{GCS_BUCKET\}\/\$\{WEBSITE\}\/\z/
# The one `recovery=` assignment is an operator-facing message that names `gcloud storage rm`; it is checked on its own below and never executed.
RECOVERY_LINE = 'recovery="Operator recovery: gcloud storage rm ${marker} (see the runbook section \'Deploy marker\' in ci-identities.md)"'.freeze
deploy_runs = deploy_steps.map { |step| [step.fetch("name", step.fetch("uses", "")), step.fetch("run", "").lines.reject { |line| line.lstrip.start_with?("#") || line.strip == RECOVERY_LINE }.join] }.reject { |_name, run| run.empty? }
abort "The deploy step must carry the recovery message exactly once" unless deploy_steps.fetch(publish_index).fetch("run").lines.count { |line| line.strip == RECOVERY_LINE } == 1
production_gcloud_calls = deploy_runs.flat_map { |_name, run| run.scan(/(?<![\w-])gcloud\s+(?!warm-up)(?:\S+)\s+(?:\S+)/) }
abort "Production path must run gcloud storage ls, cat, cp and rsync once each, got #{production_gcloud_calls.inspect}" unless production_gcloud_calls.length == 4
abort "Production path may only run gcloud storage ls, cat, rsync and the marker cp" unless production_gcloud_calls.map { |call| call.split.values_at(1, 2).join(" ") }.sort == ["storage cat", "storage cp", "storage ls", "storage rsync"]
abort "Production path must not use gsutil or gcloud storage rm/mv/buckets" if deploy_runs.any? { |_name, run| run.match?(/gsutil|gcloud storage (?:rm|mv|buckets|objects)/) }
abort "The only gcloud storage cp must write the .deploy/sha marker from stdin" unless deploy_runs.flat_map { |_name, run| run.scan(/gcloud storage cp[^\n]*/) } == ['gcloud storage cp --cache-control=no-store - "$marker"; }']
abort "The marker variable must be exactly the site's .deploy/sha object" unless deploy_runs.flat_map { |_name, run| run.scan(/^\s*marker=.*$/) }.map(&:strip) == ['marker="gs://${GCS_BUCKET}/${WEBSITE}/.deploy/sha"']
bucket_urls = deploy_runs.flat_map { |_name, run| run.scan(%r{gs://[^\s"']*}) }
abort "Production path must reference the bucket by URL" if bucket_urls.empty?
marker_url = "gs://${GCS_BUCKET}/${WEBSITE}/.deploy/sha"
abort "Production gcloud targets must be exactly gs://${GCS_BUCKET}/${WEBSITE}/ (or its .deploy/sha marker), got #{bucket_urls.reject { |url| url.match?(site_prefix) || url == marker_url }.inspect}" unless bucket_urls.all? { |url| url.match?(site_prefix) || url == marker_url }
abort "Production workflow comments must not claim deploys of one site 'still queue, never cancel'" if File.read(workflow_path).include?("queue, never cancel")
abort "Production workflow must explain the one-pending-job concurrency semantics" unless File.read(workflow_path).include?("at most ONE pending job per concurrency group")
abort "Production path must not hard-code a bucket or prefix" if deploy_runs.any? { |_name, run| run.include?(bucket) || run.include?("preview/") }

# Parallel composite uploads write temporary objects outside the site prefix, so they must stay off.
production_publish_env = deploy_steps.fetch(publish_index).fetch("env", {})
abort "Production rsync must disable parallel composite uploads (they write outside the site prefix)" unless production_publish_env.fetch("CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED", nil) == "False"
abort "Production path must not re-enable composite uploads through gcloud config" if deploy_runs.any? { |_name, run| run.match?(/parallel_composite_upload/i) }

# The security comment must not overstate the boundary (CEL-2768 review): the per-site account plus the
# pipelines exclusion in crossplane-gcloud#160, and the shared-buildkitd exposure named, not hidden.
workflow_text = File.read(workflow_path)
abort "The production job comment must not claim the worst case equals the poisoned-dist baseline" if workflow_text.match?(/worst case equals/i)
abort "The production job comment must name the pipelines exclusion in crossplane-gcloud#160" unless workflow_text.include?("crossplane-gcloud#160") && workflow_text.include?("pipelines exclusion")
abort "The production job comment must name the shared buildkitd exposure" unless workflow_text.match?(/shared buildkitd client certificate/)

# The rsync never follows symlinks, and the output check is repeated in the same step right before it
# (a process left running by the build could recreate a symlink after the earlier check).
publish_run = deploy_steps.fetch(publish_index).fetch("run")
abort "Production rsync must pass --ignore-symlinks" unless publish_run.match?(/gcloud storage rsync\b[^\n]*--ignore-symlinks/)
abort "Production rsync must not re-enable symlink following" if publish_run.include?("--no-ignore-symlinks")
publish_check_index = publish_run.index("bad=$(find dist \\( -type l")
publish_rsync_index = publish_run.index("gcloud storage rsync")
abort "Production deploy step must repeat the non-regular output check before the rsync" unless publish_check_index && publish_check_index < publish_rsync_index
build_output_check_line = deploy_steps.fetch(outputs_index).fetch("run").lines.map(&:strip).find { |line| line.start_with?("bad=$(find dist") }
abort "Production deploy step check must match the build-output check" unless build_output_check_line && publish_run.include?(build_output_check_line)

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
  # A gcloud stub for the Deploy step: `storage cat` returns the live marker (or fails), `storage cp -` records the marker written,
  # `storage rsync` can be made to fail; every call is logged.
  marker_out = File.join(directory, "marker-written")
  step_output = File.join(directory, "github-output")
  deploy_gcloud = <<~SH
    #!/bin/sh
    printf '%s\\n' "$*" >> "$STUB_LOG"
    case "$1 $2" in
      "storage cat")
        if [ "${MARKER_RC:-0}" != 0 ]; then echo "$MARKER_ERR" >&2; exit "$MARKER_RC"; fi
        printf '%s\\n' "$MARKER"; exit 0 ;;
      "storage cp")
        # PRE_CP_FAIL=1 fails the write before the rsync; POST_CP_FAILS=N fails the first N writes after it.
        if [ ! -f "$STUB_DIR/rsynced" ]; then
          if [ "${PRE_CP_FAIL:-0}" = 1 ]; then cat > /dev/null; exit 1; fi
        else
          n=$(cat "$STUB_DIR/post-cp-count" 2>/dev/null || echo 0)
          echo $((n + 1)) > "$STUB_DIR/post-cp-count"
          if [ "$n" -lt "${POST_CP_FAILS:-0}" ]; then cat > /dev/null; exit 1; fi
        fi
        cat > "$MARKER_OUT"; exit 0 ;;
      "storage rsync") touch "$STUB_DIR/rsynced"; exit "${RSYNC_RC:-0}" ;;
    esac
    exit 0
  SH
  run_step = lambda do |name, runner, extra_env = {}|
    step = deploy_steps.fetch(step_index.call(name))
    env = {
      "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
      "STUB_LOG" => log,
      "GCS_BUCKET" => bucket,
      "WEBSITE" => "admin.cellarnode.com",
      "GITHUB_SHA" => "a" * 40,
      "MARKER_OUT" => marker_out,
      "STUB_DIR" => directory,
      "GITHUB_OUTPUT" => step_output,
    }.merge(extra_env)
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
  File.symlink("/proc/self/environ", File.join(directory, "dist", "environment.txt"))
  _out, _err, status = run_step.call("Deploy to production", posix)
  abort "Deploy step must refuse a symlink that appears after the earlier check" if status.success?
  abort "Deploy step must not call gcloud when dist holds a non-regular entry, got #{File.read(log).inspect}" unless File.read(log).empty?
  File.delete(File.join(directory, "dist", "environment.txt"))

  # The stale-deploy guard runs against a real git history: c1 <- c2, and d1 diverged from c1.
  git = ->(*args) { Open3.capture3("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: directory).tap { |_o, e, st| abort "git #{args.join(' ')} failed: #{e}" unless st.success? }[0].strip }
  git.call("init", "-q")
  git.call("commit", "-q", "--allow-empty", "-m", "c1"); c1 = git.call("rev-parse", "HEAD")
  git.call("commit", "-q", "--allow-empty", "-m", "c2"); c2 = git.call("rev-parse", "HEAD")
  git.call("checkout", "-q", "-b", "other", c1)
  git.call("commit", "-q", "--allow-empty", "-m", "d1"); d1 = git.call("rev-parse", "HEAD")
  unknown = "c" * 40
  # gcloud's real message for a missing object (not "No URLs matched", not a 404).
  missing = { "MARKER_RC" => "1", "MARKER_ERR" => "ERROR: (gcloud.storage.cat) The following URLs matched no objects or files:\n-gs://#{bucket}/admin.cellarnode.com/.deploy/sha" }
  deploy = lambda do |sha, extra|
    File.write(File.join(directory, "gcloud"), deploy_gcloud)
    File.chmod(0o755, File.join(directory, "gcloud"))
    File.write(log, "")
    [marker_out, File.join(directory, "rsynced"), File.join(directory, "post-cp-count")].each { |path| File.delete(path) if File.exist?(path) }
    File.write(step_output, "")
    out, err, status = run_step.call("Deploy to production", posix, { "GITHUB_SHA" => sha }.merge(extra))
    [out, err, status, File.read(log).lines.map(&:strip)]
  end
  rsync_pattern = %r{\Astorage rsync .*--delete-unmatched-destination-objects -x \^\\\.deploy/ \./dist gs://#{Regexp.escape(bucket)}/admin\.cellarnode\.com/\z}
  marker_url = "gs://#{bucket}/admin.cellarnode.com/.deploy/sha"
  cp_call = "storage cp --cache-control=no-store - #{marker_url}"
  deployed_output = -> { File.read(step_output) }
  # Deployed: cat, the intent marker, the rsync, the final marker; deployed=true only at the end.
  assert_deployed = lambda do |label, sha, extra|
    _out, err, status, calls = deploy.call(sha, extra)
    abort "#{label}: the step must succeed: #{err}" unless status.success?
    abort "#{label}: calls must be cat, cp (intent), rsync (excluding .deploy/), cp, got #{calls.inspect}" unless calls.length == 4 && calls[0] == "storage cat #{marker_url}" && calls[1] == cp_call && calls[2].match?(rsync_pattern) && calls[3] == cp_call
    abort "#{label}: the marker written must be the deployed sha" unless File.exist?(marker_out) && File.read(marker_out).strip == sha
    abort "#{label}: must emit deployed=true, got #{deployed_output.call.inspect}" unless deployed_output.call == "deployed=true\n"
  end
  assert_not_deployed = lambda do |label, sha, extra, recovery_hint: false|
    _out, err, status, calls = deploy.call(sha, extra)
    abort "#{label}: the step must fail closed" if status.success?
    abort "#{label}: nothing may be uploaded or marked, got #{calls.inspect}" unless calls.none? { |call| call.start_with?("storage rsync", "storage cp") }
    abort "#{label}: must not emit deployed=true" if deployed_output.call.include?("deployed=true")
    next unless recovery_hint

    abort "#{label}: the error must name the operator recovery, got #{err.inspect}" unless err.include?("gcloud storage rm #{marker_url}") && err.include?("Deploy marker")
  end

  assert_deployed.call("no marker (first deploy)", c2, missing)
  assert_deployed.call("equal sha (redeploy)", c2, { "MARKER" => c2 })
  assert_deployed.call("a descendant of the live commit", c2, { "MARKER" => c1 })
  out, err, status, calls = deploy.call(d1, { "MARKER" => c2 })
  abort "Diverged history must still deploy: #{err}" unless status.success? && calls.length == 4
  abort "Diverged history must warn, got #{out.inspect}" unless out.include?("::warning::live #{c2} and #{d1} have diverged, deploying")
  out, _err, status, calls = deploy.call(c1, { "MARKER" => c2 })
  abort "A stale run (ancestor of the live commit) must exit 0" unless status.success?
  abort "A stale run must emit the warning, got #{out.inspect}" unless out.include?("::warning::stale deploy skipped: #{c1} is an ancestor of live #{c2}")
  abort "A stale run must only read the marker, got #{calls.inspect}" unless calls.length == 1 && calls[0].start_with?("storage cat")
  abort "A stale skip must emit deployed=false and never deployed=true, got #{deployed_output.call.inspect}" unless deployed_output.call == "deployed=false\n"
  assert_not_deployed.call("a marker commit this checkout does not have", c2, { "MARKER" => unknown }, recovery_hint: true)
  # CEL-3080: the container job runs as root in a runner-owned workspace, which git treats as foreign (dubious ownership). The guard
  # must still read history there, and a git failure must surface git's own message instead of "not in this checkout" alone.
  foreign = { "GIT_TEST_ASSUME_DIFFERENT_OWNER" => "1" }
  assert_deployed.call("a descendant in a foreign-owned workspace", c2, { "MARKER" => c1 }.merge(foreign))
  out, _err, status, calls = deploy.call(c1, { "MARKER" => c2 }.merge(foreign))
  abort "A stale run in a foreign-owned workspace must skip, got #{calls.inspect}" unless status.success? && calls.length == 1 && out.include?("stale deploy skipped")
  _out, err, status, calls = deploy.call(c2, { "MARKER" => unknown })
  abort "An unknown marker commit must surface git's error, got #{err.inspect}" if status.success? || !err.include?("fatal:") || calls.any? { |call| call.start_with?("storage rsync") }
  broken = File.join(directory, "not-a-repo")
  Dir.mkdir(broken) unless Dir.exist?(broken)
  _out, err, status, calls = deploy.call(c2, { "MARKER" => c1, "GIT_DIR" => broken })
  abort "A git that cannot open the checkout must fail closed with git's error, got #{err.inspect}" if status.success? || !err.include?("fatal:") || calls.any? { |call| call.start_with?("storage rsync") }
  assert_not_deployed.call("a marker that is not a sha", c2, { "MARKER" => "not-a-sha" }, recovery_hint: true)
  assert_not_deployed.call("an unreadable marker (403)", c2, { "MARKER_RC" => "1", "MARKER_ERR" => "ERROR: (gcloud.storage.cat) HTTPError 403: denied" })
  assert_not_deployed.call("a 404 is not 'no marker' (only gcloud's matched-no-objects wording is)", c2, { "MARKER_RC" => "1", "MARKER_ERR" => "ERROR: (gcloud.storage.cat) HTTPError 404: Not Found" })
  assert_not_deployed.call("the old 'No URLs matched' wording is not accepted", c2, { "MARKER_RC" => "1", "MARKER_ERR" => "ERROR: (gcloud.storage.cat) No URLs matched: #{marker_url}" })

  # F3: a failed rsync leaves the INTENT marker (the commit whose files may be live) and posts no deployed.
  _out, _err, status, calls = deploy.call(c2, { "MARKER" => c1, "RSYNC_RC" => "1" })
  abort "A failed rsync must fail the step" if status.success?
  abort "A failed rsync must leave exactly the intent marker write before it, got #{calls.inspect}" unless calls.length == 3 && calls[1] == cp_call && calls[2].start_with?("storage rsync")
  abort "A failed rsync must leave the intent marker naming the deployed sha" unless File.exist?(marker_out) && File.read(marker_out).strip == c2
  abort "A failed rsync must not claim deployed, got #{deployed_output.call.inspect}" unless deployed_output.call.empty?
  # The intent marker keeps an older run out afterwards: the marker now names c2, so a run of c1 is a stale skip.
  _out, _err, status, calls = deploy.call(c1, { "MARKER" => c2, "RSYNC_RC" => "1" })
  abort "An older run after a failed newer deploy must still be a stale skip" unless status.success? && calls.length == 1
  # A failed intent write stops before the rsync.
  _out, err, status, calls = deploy.call(c2, { "MARKER" => c1, "PRE_CP_FAIL" => "1" })
  abort "A failed intent write must fail the step before the rsync, got #{calls.inspect}" if status.success? || calls.any? { |call| call.start_with?("storage rsync") }
  abort "A failed intent write must say nothing was deployed, got #{err.inspect}" unless err.include?("nothing was deployed") && deployed_output.call.empty?
  # The post-rsync write is retried 3 times: two failures still succeed, three fail the step and post no deployed.
  _out, err, status, calls = deploy.call(c2, { "MARKER" => c1, "POST_CP_FAILS" => "2" })
  abort "Two failed marker writes after the rsync must be retried to success: #{err}" unless status.success? && calls.count { |call| call == cp_call } == 4 && deployed_output.call == "deployed=true\n"
  _out, err, status, calls = deploy.call(c2, { "MARKER" => c1, "POST_CP_FAILS" => "3" })
  abort "Three failed marker writes after the rsync must fail the step" if status.success?
  abort "The post-rsync marker write must be attempted exactly 3 times (plus the intent write), got #{calls.inspect}" unless calls.count { |call| call == cp_call } == 4
  abort "A step whose final marker write failed must not claim deployed, got #{deployed_output.call.inspect}" unless deployed_output.call.empty?
end

# F1: the newer-commit check runs the real github-script body against a mocked REST API (no checkout, no git, no token in deploy-production).
check_job = jobs.fetch("check-newer-head")
check_script = check_job.fetch("steps").first.fetch("with").fetch("script")
run_newer_check = lambda do |deployed, head, compare_status, lookup_error: false|
  Open3.capture3(
    { "DEPLOYED_SHA" => deployed, "BRANCH" => "main", "HEAD_SHA" => head, "COMPARE_STATUS" => compare_status, "LOOKUP_ERROR" => lookup_error ? "1" : "", "SCRIPT" => check_script },
    "node", "-e", <<~'JAVASCRIPT'
      const AsyncFunction = Object.getPrototypeOf(async () => null).constructor;
      const outputs = {};
      const github = { rest: { repos: {
        getCommit: async ({ ref }) => { if (process.env.LOOKUP_ERROR) throw new Error('boom'); if (ref !== 'main') throw new Error('wrong ref ' + ref); return { data: { sha: process.env.HEAD_SHA } }; },
        compareCommitsWithBasehead: async ({ basehead }) => { if (basehead !== `${process.env.DEPLOYED_SHA}...${process.env.HEAD_SHA}`) throw new Error('wrong basehead ' + basehead); return { data: { status: process.env.COMPARE_STATUS } }; },
      } } };
      const core = { warning: m => console.log(`::warning::${m}`), setOutput: (k, v) => { outputs[k] = v; }, setFailed: m => { throw new Error(m); } };
      new AsyncFunction('github', 'context', 'core', process.env.SCRIPT)(github, { repo: { owner: 'CellarNode', repo: 'site' } }, core)
        .then(() => console.log('OUTPUTS ' + JSON.stringify(outputs)))
        .catch(error => { console.error(error.message); process.exitCode = 1; });
    JAVASCRIPT
  )
end
deployed_sha = "a" * 40
newer_sha = "b" * 40
out, err, status = run_newer_check.call(deployed_sha, deployed_sha, "identical")
abort "No newer commit: the check must succeed quietly: #{err}" unless status.success? && !out.include?("::warning::") && out.include?("OUTPUTS {}")
out, err, status = run_newer_check.call(deployed_sha, newer_sha, "ahead")
abort "A newer descendant on main must warn and export newer_head: #{err} #{out}" unless status.success? && out.include?("::warning::newer commit #{newer_sha} on main is not deployed yet; if its production run was cancelled, re-run it") && out.include?(%(OUTPUTS {"newer_head":"#{newer_sha}"}))
out, err, status = run_newer_check.call(deployed_sha, newer_sha, "behind")
abort "A behind head must stay quiet: #{err} #{out}" unless status.success? && !out.include?("::warning::") && out.include?("OUTPUTS {}")
out, err, status = run_newer_check.call(deployed_sha, newer_sha, "diverged")
abort "A diverged head must warn about the divergence and not export newer_head: #{err} #{out}" unless status.success? && out.include?("::warning::main head #{newer_sha} has diverged from the deployed commit #{deployed_sha} (force-push?); deploy it or see the runbook Deploy marker section") && out.include?("OUTPUTS {}")
out, err, status = run_newer_check.call(deployed_sha, newer_sha, "weird")
abort "An unknown compare status must warn and not export newer_head: #{err} #{out}" unless status.success? && out.include?("::warning::unexpected compare status weird") && out.include?("OUTPUTS {}")
out, err, status = run_newer_check.call(deployed_sha, newer_sha, "ahead", lookup_error: true)
abort "A failed lookup must warn and never fail the check: #{err} #{out}" unless status.success? && out.include?("::warning::could not check whether a newer commit on main is deployed") && out.include?("OUTPUTS {}")

# Previews are untouched by CEL-2768: they keep the artifact hand-off and their existing identity.
abort "Preview build must keep its artifact upload" unless jobs.fetch("build-preview").fetch("steps").any? { |step| step.fetch("uses", "").start_with?("actions/upload-artifact@") }
%w[deploy-preview cleanup].each do |job_name|
  job_steps = jobs.fetch(job_name).fetch("steps")
  preview_auth = job_steps.find { |step| step.fetch("uses", "").start_with?("google-github-actions/auth@") }
  abort "#{job_name} must keep its existing pipelines identity (previews unchanged by CEL-2768)" unless preview_auth&.fetch("with", {})&.fetch("service_account", nil) == "pipelines@${{ env.PROJECT_ID }}.iam.gserviceaccount.com"
end
abort "Preview deploy must keep its artifact download" unless jobs.fetch("deploy-preview").fetch("steps").any? { |step| step.fetch("uses", "").start_with?("actions/download-artifact@") }

# CEL-2795: the deploy notification is a separate job on its own runner, after deploy-production, with no id-token. The production lock is
# on deploy-production and the workflow group is unique per push run, so the notify job holds nothing the next deploy waits for.
discord_deploy = jobs["discord-deploy"]
abort "discord-deploy job must exist" unless discord_deploy
abort "discord-deploy must need deploy-production and check-newer-head" unless discord_deploy["needs"] == ["deploy-production", "check-newer-head"]
abort "discord-deploy must run on !cancelled()" unless discord_deploy["if"].to_s.include?("!cancelled()") && !discord_deploy["if"].to_s.include?("always()")
abort "discord-deploy must not hold id-token (got #{discord_deploy['permissions'].inspect})" unless discord_deploy["permissions"] == { "contents" => "read", "pull-requests" => "read" }
abort "discord-deploy must call discord-notify.yaml with the deploy event" unless discord_deploy["uses"] == "./.github/workflows/discord-notify.yaml" && discord_deploy.dig("with", "event") == "deploy"

# F2: evaluate the real discord-deploy expressions over the outcome matrix. Only a real deploy may say "Deployed to production".
def evaluate_notice_expression(expression, result:, deployed:, newer_head:)
  source = expression.strip.sub(/\A\$\{\{/, "").sub(/\}\}\z/, "").gsub(/\s+/, " ").strip
  tokens = source.scan(/'(?:[^']|'')*'|&&|\|\||==|!=|[(),]|[A-Za-z_][\w.-]*/)
  abort "Unsupported discord-deploy expression: #{source}" unless source.gsub(/'(?:[^']|'')*'|&&|\|\||==|!=|[(),]|[A-Za-z_][\w.-]*|\s+/, "").empty?
  vars = { "needs.deploy-production.result" => result, "needs.deploy-production.outputs.deployed" => deployed, "needs.check-newer-head.outputs.newer_head" => newer_head }
  position = 0
  truthy = ->(value) { !(value.nil? || value == "" || value == false) }
  peek = -> { tokens[position] }
  take = -> { tokens[position].tap { position += 1 } }
  parse_or = nil
  parse_primary = lambda do
    token = take.call
    if token == "("
      value = parse_or.call
      abort "expected )" unless take.call == ")"
      value
    elsif token == "format"
      take.call
      args = [parse_or.call]
      args << parse_or.call while peek.call == "," && take.call
      abort "expected )" unless take.call == ")"
      args.first.gsub(/\{(\d)\}/) { args[Regexp.last_match(1).to_i + 1].to_s }
    elsif token.start_with?("'")
      token[1..-2].gsub("''", "'")
    else
      vars.fetch(token) { abort "Unknown variable in discord-deploy expression: #{token}" }
    end
  end
  parse_equality = lambda do
    left = parse_primary.call
    if ["==", "!="].include?(peek.call)
      operator = take.call
      right = parse_primary.call
      return operator == "==" ? left == right : left != right
    end
    left
  end
  parse_and = lambda do
    value = parse_equality.call
    while peek.call == "&&"
      take.call
      right = parse_equality.call
      value = truthy.call(value) ? right : value
    end
    value
  end
  parse_or = lambda do
    value = parse_and.call
    while peek.call == "||"
      take.call
      right = parse_and.call
      value = truthy.call(value) ? value : right
    end
    value
  end
  parse_or.call.tap { abort "Trailing tokens in discord-deploy expression: #{tokens[position..].inspect}" if position < tokens.length }
end
notice = ->(result, deployed, newer_head = "") do
  %w[status deploy_title deploy_note].to_h { |key| [key, evaluate_notice_expression(discord_deploy.dig("with", key).to_s, result: result, deployed: deployed, newer_head: newer_head)] }
end
real = notice.call("success", "true")
abort "A real deploy must say Deployed to production with status success, got #{real.inspect}" unless real == { "status" => "success", "deploy_title" => "Deployed to production", "deploy_note" => "" }
warned = notice.call("success", "true", c3_placeholder = "b" * 40)
abort "A real deploy with a newer head must carry the newer-head warning, got #{warned.inspect}" unless warned["deploy_title"] == "Deployed to production" && warned["deploy_note"].include?(c3_placeholder) && warned["deploy_note"].include?("Re-run its production run")
stale = notice.call("success", "false")
abort "A stale skip must not say Deployed, got #{stale.inspect}" if stale["deploy_title"].start_with?("Deployed") || stale["status"] == "success" || !stale["deploy_title"].include?("stale run skipped")
abort "An unset deployed output on a successful job must not say Deployed, got #{notice.call('success', '').inspect}" if notice.call("success", "")["deploy_title"].start_with?("Deployed")
cancelled = notice.call("cancelled", "")
abort "A cancelled deploy must say not deployed and to re-run the newest main run, got #{cancelled.inspect}" unless cancelled["status"] == "cancelled" && cancelled["deploy_title"] == "Not deployed: the production deploy was cancelled, re-run the newest main run"
skipped = notice.call("skipped", "")
abort "A skipped deploy must say not deployed, got #{skipped.inspect}" unless skipped["status"] == "skipped" && skipped["deploy_title"] == "Not deployed: the production deploy was skipped"
failed = notice.call("failure", "")
abort "A failed deploy must say it failed, not Deployed, got #{failed.inspect}" unless failed["status"] == "failure" && failed["deploy_title"] == "Production deploy failed"
titles = [real, stale, cancelled, skipped, failed].map { |entry| entry["deploy_title"] }
abort "Each outcome needs its own message, got #{titles.inspect}" unless titles.uniq.length == titles.length


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
