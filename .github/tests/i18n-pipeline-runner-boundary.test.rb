require "yaml"

workflow_path = File.expand_path("../workflows/i18n-pipeline.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)
job = workflow.fetch("jobs").fetch("sync-translate")

image = "europe-north1-docker.pkg.dev/festive-terrain-478011-h0/beveriq/ci-runner@sha256:b8ae250c5d7fae79dbbea1f62ca7613ecabd6f3efbd13b533cbdecb293cdf814"
contexts = [
  ["private push", true, "push", "CellarNode/consumer", nil, "self-hosted-k8s"],
  ["private dispatch", true, "workflow_dispatch", "CellarNode/consumer", nil, "self-hosted-k8s"],
  ["public push", false, "push", "public/consumer", nil, "ubuntu-latest"],
  ["public dispatch", false, "workflow_dispatch", "public/consumer", nil, "ubuntu-latest"],
  ["private same-repo pull request", true, "pull_request", "CellarNode/consumer", "CellarNode/consumer", "ubuntu-latest"],
  ["private fork pull request", true, "pull_request", "CellarNode/consumer", "contributor/consumer", "ubuntu-latest"],
  ["public fork pull request", false, "pull_request", "public/consumer", "contributor/consumer", "ubuntu-latest"],
  ["private schedule", true, "schedule", "CellarNode/consumer", nil, "ubuntu-latest"],
  ["private unknown event", true, "unknown", "CellarNode/consumer", nil, "ubuntu-latest"],
  ["missing repository visibility", nil, "push", "CellarNode/consumer", nil, "ubuntu-latest"]
].freeze

def evaluate(expression, private_repo, event, repository, head_repository)
  source = expression.gsub(/\$\{\{|\}\}/, "").gsub(/\s+/, " ").strip
  allowed = /\A(?:\s+|github\.event\.repository\.private|github\.event_name|github\.repository|github\.event\.pull_request\.head\.repo\.full_name|'[^']*'|&&|\|\||==|true|false|\(|\))+\z/
  abort "Unsupported runner expression" unless source.match?(allowed)
  source = source
    .gsub("github.event.repository.private", private_repo.inspect)
    .gsub("github.event_name", event.inspect)
    .gsub("github.repository", repository.inspect)
    .gsub("github.event.pull_request.head.repo.full_name", head_repository.inspect)
  eval(source)
end

runner = job.fetch("runs-on")
container = job.fetch("container")
contexts.each do |name, private_repo, event, repository, head_repository, expected_runner|
  expected_container = expected_runner == "self-hosted-k8s" ? image : ""
  actual_runner = evaluate(runner, private_repo, event, repository, head_repository)
  actual_container = evaluate(container, private_repo, event, repository, head_repository)
  abort "Wrong runner for #{name}: #{actual_runner}" unless actual_runner == expected_runner
  abort "Wrong container for #{name}" unless actual_container == expected_container
end

puts "PASS: #{contexts.length} translation runner/container scenarios"
