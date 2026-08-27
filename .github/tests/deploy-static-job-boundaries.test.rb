require "yaml"

workflow_path = File.expand_path("../workflows/deploy-static-website.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)
jobs = workflow.fetch("jobs")

build_production = jobs.fetch("build-production")
abort "Production build must use a GitHub-hosted runner" unless build_production.fetch("runs-on") == "ubuntu-latest"
abort "Production build must not use a self-hosted container" if build_production.key?("container")

deploy_production = jobs.fetch("deploy-production")
abort "Production deploy must use the self-hosted runner" unless deploy_production.fetch("runs-on") == "self-hosted-k8s"

deploy_steps = deploy_production.fetch("steps")
abort "Production deploy must not check out source" if deploy_steps.any? { |step| step.fetch("uses", "").start_with?("actions/checkout@") }

puts "Static deploy job boundaries passed"
