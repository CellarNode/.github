require "yaml"
require "open3"
require "tmpdir"
require "json"

workflow_path = File.expand_path("../workflows/deploy-static-website.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)
jobs = workflow.fetch("jobs")

# CEL-1980: every @cellarnode/* package is public on npm and the org
# NPM_TOKEN secret has been retired. Guard against silent re-introduction.
workflow_call_secrets = workflow.dig("on", "workflow_call", "secrets") || {}
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

# CEL-2768: the GitHub-hosted Actions budget is exhausted, so the policy and production build jobs
# run on the existing self-hosted-k8s ARC pool inside the digest-pinned ci-runner image. That image
# carries Node 22, corepack pnpm and ruby (the deploy-production image does not carry ruby).
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

# CEL-2768: preview still hands off through an artifact; production hands off through the cache.
{
  "build-preview" => "Upload static site artifact",
  "build-production" => "Pack static site tarball",
}.each do |job_name, handoff_step|
  steps = jobs.fetch(job_name).fetch("steps")
  validation_index = steps.index { |step| step.fetch("name", "") == "Reject non-regular build outputs" }
  upload_index = steps.index { |step| step.fetch("name", "") == handoff_step }
  abort "#{job_name} must validate build outputs before upload" unless validation_index && upload_index && validation_index < upload_index

  validation = steps.fetch(validation_index).fetch("run")
  Dir.mktmpdir do |directory|
    dist = File.join(directory, "dist")
    Dir.mkdir(dist)
    File.write(File.join(dist, "index.html"), "safe")
    _stdout, stderr, status = Open3.capture3("bash", "-euo", "pipefail", "-c", validation, chdir: directory)
    abort "#{job_name} must accept regular build outputs: #{stderr}" unless status.success?

    File.symlink("/proc/self/environ", File.join(dist, "environment.txt"))
    _stdout, _stderr, status = Open3.capture3("bash", "-euo", "pipefail", "-c", validation, chdir: directory)
    abort "#{job_name} must reject symlinks before upload" if status.success?
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

build_production = jobs.fetch("build-production")
abort "Production build must use the self-hosted runner" unless build_production.fetch("runs-on") == "self-hosted-k8s"
abort "Production build must use the pinned ci-runner image" unless build_production.dig("container", "image") == CI_RUNNER_IMAGE
abort "Production build must not receive workload identity" if build_production.fetch("permissions", {}).key?("id-token")
abort "Production build must only run for pushes to main" unless build_production.fetch("if").include?("github.event_name == 'push'") && build_production.fetch("if").include?("github.ref == 'refs/heads/main'")
abort "Production build must depend on toolchain policy" unless Array(build_production.fetch("needs")).include?("preview-policy")
abort "Production build must require approved toolchain" unless build_production.fetch("if").include?("needs.preview-policy.outputs.toolchain_allowed == 'true'")

deploy_production = jobs.fetch("deploy-production")
abort "Production deploy must use the self-hosted runner" unless deploy_production.fetch("runs-on") == "self-hosted-k8s"

# CEL-2768: production hands the build to the deploy job through an exact-key Actions cache entry
# bound by a SHA-256 job output, because artifact storage is blocked org-wide.
CACHE_ACTION_SHA = "0057852bfaa89a56745cba8c7296529d2fc39830".freeze
deploy_steps = deploy_production.fetch("steps")
production_steps = build_production.fetch("steps") + deploy_steps
production_actions = production_steps.map { |step| step.fetch("uses", "") }
abort "Production path must not use upload-artifact or download-artifact (CEL-2768)" if production_actions.any? { |action| action.match?(%r{\Aactions/(upload|download)-artifact@}) }
abort "Production path must not reference an artifact action anywhere in its steps" if deep_string_values(production_steps).any? { |value| value.match?(%r{actions/(upload|download)-artifact}) }

build_steps = build_production.fetch("steps")
pack_index = build_steps.index { |step| step.fetch("id", "") == "pack" }
save_index = build_steps.index { |step| step.fetch("uses", "").start_with?("actions/cache/save@") }
abort "Production build must pack a tarball and then save it to the cache" unless pack_index && save_index && pack_index < save_index
pack_step = build_steps.fetch(pack_index)
save_step = build_steps.fetch(save_index)
deploy_restore_index = deploy_steps.index { |step| step.fetch("uses", "").start_with?("actions/cache/restore@") }
abort "Production deploy must restore the tarball from the cache" unless deploy_restore_index
restore_step = deploy_steps.fetch(deploy_restore_index)

[save_step, restore_step].each do |step|
  abort "Cache actions must be pinned to the reviewed full commit SHA: #{step.fetch("uses")}" unless step.fetch("uses").match?(/\Aactions\/cache\/(save|restore)@#{CACHE_ACTION_SHA}( #.*)?\z/)
  abort "Cache steps must not use restore-keys (exact key only)" if step.fetch("with").key?("restore-keys")
  abort "Cache steps must only cache the tarball" unless step.fetch("with").fetch("path") == "static-site.tar"
end

pack_script = pack_step.fetch("run")
abort "Pack step must key the entry on run_id and run_attempt" unless pack_step.fetch("env").values_at("RUN_ID", "RUN_ATTEMPT") == ["${{ github.run_id }}", "${{ github.run_attempt }}"]
abort "Cache key must combine slug, run id and run attempt" unless pack_script.include?('cache_key=static-site-${WEBSITE_SLUG}-${RUN_ID}-${RUN_ATTEMPT}')
abort "Pack step must create a deterministic tarball" unless pack_script.include?("tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner")
abort "Pack step must record the tarball SHA-256" unless pack_script.include?("sha256sum static-site.tar") && pack_script.include?('echo "tarball_sha256=${tarball_sha256}"') && pack_script.include?('>> "$GITHUB_OUTPUT"')
abort "Build job must expose the cache key and tarball hash as outputs" unless build_production.fetch("outputs") == {
  "cache_key" => "${{ steps.pack.outputs.cache_key }}",
  "tarball_sha256" => "${{ steps.pack.outputs.tarball_sha256 }}",
}
abort "Cache save must use the key computed by the pack step" unless save_step.fetch("with").fetch("key") == "${{ steps.pack.outputs.cache_key }}"
abort "Cache restore must use the exact key the build job published" unless restore_step.fetch("with").fetch("key") == "${{ needs.build-production.outputs.cache_key }}"
abort "Cache restore must fail on a miss" unless restore_step.fetch("with").fetch("fail-on-cache-miss") == true

verify_index = deploy_steps.index { |step| step.fetch("name", "") == "Verify static site tarball hash" }
extract_index = deploy_steps.index { |step| step.fetch("name", "") == "Extract static site tarball" }
reject_index = deploy_steps.index { |step| step.fetch("name", "") == "Reject non-regular artifact entries" }
oidc_index = deploy_steps.index { |step| step.fetch("name", "") == "Authenticate to Google Cloud" }
abort "Production deploy must restore, verify, extract, reject non-regular entries, then authenticate (in that order)" unless [deploy_restore_index, verify_index, extract_index, reject_index, oidc_index].all? && [deploy_restore_index, verify_index, extract_index, reject_index, oidc_index] == [deploy_restore_index, verify_index, extract_index, reject_index, oidc_index].sort
verify_step = deploy_steps.fetch(verify_index)
abort "Hash verification must compare against the build job output" unless verify_step.fetch("env").fetch("EXPECTED_SHA256") == "${{ needs.build-production.outputs.tarball_sha256 }}"
extract_step = deploy_steps.fetch(extract_index)
abort "Extraction must write to dist (the path the deploy step syncs)" unless extract_step.fetch("run").include?("tar -xf static-site.tar -C dist")

# Run the real verify step: matching hash passes, anything else fails closed.
Dir.mktmpdir do |directory|
  File.write(File.join(directory, "static-site.tar"), "tarball bytes")
  good = Open3.capture3("sha256sum", File.join(directory, "static-site.tar")).first.split.first
  {
    "matching hash" => [good, true],
    "different hash" => ["0" * 64, false],
    "empty hash" => ["", false],
    "malformed hash" => ["not-a-hash", false],
  }.each do |name, (expected, accepted)|
    _stdout, _stderr, status = Open3.capture3({ "EXPECTED_SHA256" => expected }, "bash", "-c", verify_step.fetch("run"), chdir: directory)
    abort "tarball verification #{name}: expected accepted=#{accepted}, got #{status.success?}" unless status.success? == accepted
  end
end

# Run the real pack step and prove the tarball is deterministic (GNU tar only; skipped on bsdtar).
Dir.mktmpdir do |directory|
  if system("tar --version 2>/dev/null | grep -q 'GNU tar'")
    Dir.mkdir(File.join(directory, "dist"))
    File.write(File.join(directory, "dist", "index.html"), "safe")
    hashes = 2.times.map do |attempt|
      output_file = File.join(directory, "output-#{attempt}")
      File.write(output_file, "")
      _stdout, stderr, status = Open3.capture3(
        { "GITHUB_OUTPUT" => output_file, "WEBSITE_SLUG" => "site", "RUN_ID" => "1", "RUN_ATTEMPT" => "1" },
        "bash", "-c", pack_script, chdir: directory
      )
      abort "pack step failed: #{stderr}" unless status.success?
      File.utime(Time.now + attempt * 3600, Time.now + attempt * 3600, File.join(directory, "dist", "index.html"))
      File.read(output_file)[/tarball_sha256=(\h{64})/, 1]
    end
    abort "pack step must be deterministic across mtime changes" unless hashes.compact.uniq.length == 1
  end
end

deploy_steps = deploy_production.fetch("steps")
abort "Production deploy must not check out source" if deploy_steps.any? { |step| step.fetch("uses", "").start_with?("actions/checkout@") }

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
