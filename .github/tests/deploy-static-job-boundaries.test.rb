require "yaml"
require "open3"
require "tmpdir"
require "json"

workflow_path = File.expand_path("../workflows/deploy-static-website.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)
jobs = workflow.fetch("jobs")

cancel_in_progress = workflow.fetch("concurrency").fetch("cancel-in-progress")
expected_cancel_policy = "${{ github.event_name == 'pull_request_target' }}"
abort "Production deploys must never be cancelled in progress" unless cancel_in_progress == expected_cancel_policy

abort "Preview dependencies must not cross jobs through a package-store artifact" if jobs.key?("preview-dependencies")

preview_policy = jobs.fetch("preview-policy")
abort "Preview policy must use a GitHub-hosted runner" unless preview_policy.fetch("runs-on") == "ubuntu-latest"
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
abort "Preview policy must query current repository permission" unless policy_step&.fetch("run", "")&.include?('gh api "repos/${REPOSITORY}/collaborators/${ACTOR}/permission"')
abort "Preview policy must require write-capable permission" unless policy_step&.fetch("run", "")&.include?("admin|maintain|write)")
abort "Preview policy must not trust stale author association" if policy_step&.fetch("env", {})&.key?("AUTHOR_ASSOCIATION")
abort "Preview policy must require the trusted pull-request event" unless policy_step&.fetch("run", "")&.include?('[ "$EVENT_NAME" = "pull_request_target" ]')
abort "Preview policy must receive toolchain inputs as data" unless policy_step&.fetch("env", {})&.slice("NODE_VERSION", "PNPM_VERSION") == {
  "NODE_VERSION" => "${{ inputs.node_version }}",
  "PNPM_VERSION" => "${{ inputs.pnpm_version }}",
}
abort "Preview policy must allow only Node.js 22" unless policy_step&.fetch("run", "")&.include?('[ "$NODE_VERSION" = "22" ]')
abort "Preview policy must allow only reviewed pnpm versions" unless policy_step&.fetch("run", "")&.include?("10.28.2|10.32.1")

build_preview = jobs.fetch("build-preview")
abort "Preview build must use a GitHub-hosted runner" unless build_preview.fetch("runs-on") == "ubuntu-latest"
abort "Preview build must not use a self-hosted container" if build_preview.key?("container")
abort "Preview build must not receive NPM_TOKEN at job scope" if build_preview.fetch("env", {}).key?("NPM_TOKEN")
abort "Preview build must allow live pull-request authorization lookup" unless build_preview.fetch("permissions", {}).fetch("pull-requests", nil) == "read"
preview_install = build_preview.fetch("steps").find { |step| step.fetch("name", "") == "Install dependencies with scoped registry credential" }
abort "Preview install must receive only the scoped NPM_TOKEN" unless preview_install&.fetch("env", {})&.fetch("NPM_TOKEN", nil) == "${{ secrets.NPM_TOKEN }}"
untrusted_preview_names = ["Verify credential isolation", "Rebuild dependencies", "Type check", "Lint", "Build preview"]
untrusted_preview_steps = build_preview.fetch("steps").select { |step| untrusted_preview_names.include?(step.fetch("name", "")) }
abort "Preview rebuild/check/build steps must explicitly clear NPM_TOKEN" unless untrusted_preview_steps.length == 5 && untrusted_preview_steps.all? { |step| step.fetch("env", {}).fetch("NPM_TOKEN", nil) == "" }
abort "Preview build must depend on the trusted policy" unless Array(build_preview.fetch("needs")).include?("preview-policy")
abort "Preview build must require the trusted policy output" unless build_preview.fetch("if") == "needs.preview-policy.outputs.trusted == 'true'"

preview_steps = build_preview.fetch("steps")
dependency_validation_index = preview_steps.index { |step| step.fetch("name", "") == "Validate preview dependency inputs" }
authorization_index = preview_steps.index { |step| step.fetch("name", "") == "Revalidate preview authorization" }
credentialed_install_index = preview_steps.index { |step| step.fetch("name", "") == "Install dependencies with scoped registry credential" }
abort "Preview dependency inputs must be validated before credentialed install" unless dependency_validation_index && credentialed_install_index && dependency_validation_index < credentialed_install_index
abort "Preview authorization must be revalidated immediately before credentialed install" unless authorization_index && authorization_index + 1 == credentialed_install_index
dependency_validation = preview_steps.fetch(dependency_validation_index)
abort "Preview dependency validation must not receive NPM_TOKEN" if dependency_validation.fetch("env", {}).key?("NPM_TOKEN")
preview_authorization = preview_steps.fetch(authorization_index)
abort "Preview authorization recheck must not receive NPM_TOKEN" if preview_authorization.fetch("env", {}).key?("NPM_TOKEN")
abort "Preview authorization recheck must use pinned GitHub Script" unless preview_authorization.fetch("uses", "").match?(/\Aactions\/github-script@[0-9a-f]{40}\z/)
abort "Preview authorization recheck must use the job token" unless preview_authorization.fetch("with", {}).fetch("github-token", nil) == "${{ github.token }}"

%w[build-preview build-production].each do |job_name|
  steps = jobs.fetch(job_name).fetch("steps")
  validation_index = steps.index { |step| step.fetch("name", "") == "Reject non-regular build outputs" }
  upload_index = steps.index { |step| step.fetch("name", "") == "Upload static site artifact" }
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
abort "Production build must use a GitHub-hosted runner" unless build_production.fetch("runs-on") == "ubuntu-latest"
abort "Production build must not use a self-hosted container" if build_production.key?("container")
abort "Production build must depend on toolchain policy" unless Array(build_production.fetch("needs")).include?("preview-policy")
abort "Production build must require approved toolchain" unless build_production.fetch("if").include?("needs.preview-policy.outputs.toolchain_allowed == 'true'")

deploy_production = jobs.fetch("deploy-production")
abort "Production deploy must use the self-hosted runner" unless deploy_production.fetch("runs-on") == "self-hosted-k8s"

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
