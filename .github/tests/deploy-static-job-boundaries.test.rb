require "yaml"
require "open3"
require "tmpdir"

workflow_path = File.expand_path("../workflows/deploy-static-website.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)
jobs = workflow.fetch("jobs")

cancel_in_progress = workflow.fetch("concurrency").fetch("cancel-in-progress")
expected_cancel_policy = "${{ github.event_name == 'pull_request' && github.event.action != 'closed' }}"
abort "Production deploys must never be cancelled in progress" unless cancel_in_progress == expected_cancel_policy

abort "Preview dependencies must not cross jobs through a package-store artifact" if jobs.key?("preview-dependencies")

preview_policy = jobs.fetch("preview-policy")
abort "Preview policy must use a GitHub-hosted runner" unless preview_policy.fetch("runs-on") == "ubuntu-latest"
abort "Preview policy must not receive secrets" unless preview_policy.fetch("permissions") == { "contents" => "read" }
abort "Preview policy must expose a trusted output" unless preview_policy.fetch("outputs", {}).fetch("trusted", nil) == "${{ steps.policy.outputs.trusted }}"
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

build_preview = jobs.fetch("build-preview")
abort "Preview build must use a GitHub-hosted runner" unless build_preview.fetch("runs-on") == "ubuntu-latest"
abort "Preview build must not use a self-hosted container" if build_preview.key?("container")
abort "Preview build must not receive NPM_TOKEN at job scope" if build_preview.fetch("env", {}).key?("NPM_TOKEN")
preview_install = build_preview.fetch("steps").find { |step| step.fetch("name", "") == "Install dependencies with scoped registry credential" }
abort "Preview install must receive only the scoped NPM_TOKEN" unless preview_install&.fetch("env", {})&.fetch("NPM_TOKEN", nil) == "${{ secrets.NPM_TOKEN }}"
untrusted_preview_names = ["Verify credential isolation", "Rebuild dependencies", "Type check", "Lint", "Build preview"]
untrusted_preview_steps = build_preview.fetch("steps").select { |step| untrusted_preview_names.include?(step.fetch("name", "")) }
abort "Preview rebuild/check/build steps must explicitly clear NPM_TOKEN" unless untrusted_preview_steps.length == 5 && untrusted_preview_steps.all? { |step| step.fetch("env", {}).fetch("NPM_TOKEN", nil) == "" }
abort "Preview build must depend on the trusted policy" unless Array(build_preview.fetch("needs")).include?("preview-policy")
abort "Preview build must require the trusted policy output" unless build_preview.fetch("if") == "needs.preview-policy.outputs.trusted == 'true'"

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

abort "Preview lifecycle must not bind an unavailable sender field" if File.read(workflow_path).include?("github.event.sender.login")
abort "Preview lifecycle must not trust stale author association" if File.read(workflow_path).include?("author_association")

build_production = jobs.fetch("build-production")
abort "Production build must use a GitHub-hosted runner" unless build_production.fetch("runs-on") == "ubuntu-latest"
abort "Production build must not use a self-hosted container" if build_production.key?("container")

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

cleanup_guard = jobs.fetch("cleanup").fetch("if")
abort "Preview cleanup must survive author offboarding" if cleanup_guard.include?("author_association")

validation_path = File.expand_path("../workflows/validate-static-deploy.yaml", __dir__)
validation = YAML.safe_load(File.read(validation_path), aliases: true)
validation_checkout = validation.fetch("jobs").fetch("lock-validator").fetch("steps").find { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
abort "Validation checkout must disable persisted credentials" unless validation_checkout&.fetch("with", {})&.fetch("persist-credentials", nil) == false

puts "Static deploy job boundaries passed"
