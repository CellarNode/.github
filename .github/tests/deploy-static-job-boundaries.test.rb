require "yaml"

workflow_path = File.expand_path("../workflows/deploy-static-website.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)
jobs = workflow.fetch("jobs")

cancel_in_progress = workflow.fetch("concurrency").fetch("cancel-in-progress")
expected_cancel_policy = "${{ github.event_name == 'pull_request' && github.event.action != 'closed' }}"
abort "Production deploys must never be cancelled in progress" unless cancel_in_progress == expected_cancel_policy

abort "Preview dependencies must not cross jobs through a package-store artifact" if jobs.key?("preview-dependencies")

build_preview = jobs.fetch("build-preview")
abort "Preview build must use a GitHub-hosted runner" unless build_preview.fetch("runs-on") == "ubuntu-latest"
abort "Preview build must not use a self-hosted container" if build_preview.key?("container")
abort "Preview build must not receive NPM_TOKEN at job scope" if build_preview.fetch("env", {}).key?("NPM_TOKEN")
preview_install = build_preview.fetch("steps").find { |step| step.fetch("name", "") == "Install dependencies with scoped registry credential" }
abort "Preview install must receive only the scoped NPM_TOKEN" unless preview_install&.fetch("env", {})&.fetch("NPM_TOKEN", nil) == "${{ secrets.NPM_TOKEN }}"
untrusted_preview_names = ["Verify credential isolation", "Rebuild dependencies", "Type check", "Lint", "Build preview"]
untrusted_preview_steps = build_preview.fetch("steps").select { |step| untrusted_preview_names.include?(step.fetch("name", "")) }
abort "Preview rebuild/check/build steps must explicitly clear NPM_TOKEN" unless untrusted_preview_steps.length == 5 && untrusted_preview_steps.all? { |step| step.fetch("env", {}).fetch("NPM_TOKEN", nil) == "" }
preview_guard = build_preview.fetch("if")
abort "Preview build must bind the synchronizing actor to the member author" unless preview_guard.include?("github.event.sender.login == github.event.pull_request.user.login")

build_production = jobs.fetch("build-production")
abort "Production build must use a GitHub-hosted runner" unless build_production.fetch("runs-on") == "ubuntu-latest"
abort "Production build must not use a self-hosted container" if build_production.key?("container")

deploy_production = jobs.fetch("deploy-production")
abort "Production deploy must use the self-hosted runner" unless deploy_production.fetch("runs-on") == "self-hosted-k8s"

deploy_steps = deploy_production.fetch("steps")
abort "Production deploy must not check out source" if deploy_steps.any? { |step| step.fetch("uses", "").start_with?("actions/checkout@") }

cleanup_guard = jobs.fetch("cleanup").fetch("if")
abort "Preview cleanup must survive author offboarding" if cleanup_guard.include?("author_association")

validation_path = File.expand_path("../workflows/validate-static-deploy.yaml", __dir__)
validation = YAML.safe_load(File.read(validation_path), aliases: true)
validation_checkout = validation.fetch("jobs").fetch("lock-validator").fetch("steps").find { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
abort "Validation checkout must disable persisted credentials" unless validation_checkout&.fetch("with", {})&.fetch("persist-credentials", nil) == false

puts "Static deploy job boundaries passed"
