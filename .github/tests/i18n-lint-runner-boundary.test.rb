require "yaml"

workflow = YAML.safe_load(
  File.read(File.expand_path("../workflows/i18n-lint.yaml", __dir__)),
  aliases: true
)
jobs = workflow.fetch("jobs")
abort "Keep the existing lint check identity" unless jobs.keys == ["lint"]
job = jobs.fetch("lint")
abort "Lint permissions changed" unless job.fetch("permissions") == { "contents" => "read" }

image = "europe-north1-docker.pkg.dev/festive-terrain-478011-h0/beveriq/ci-runner@sha256:b8ae250c5d7fae79dbbea1f62ca7613ecabd6f3efbd13b533cbdecb293cdf814"
contexts = [
  [true, "pull_request", "CellarNode/importer-dashboard", true],
  [true, "pull_request", "contributor/importer-dashboard", false],
  [false, "pull_request", "CellarNode/importer-dashboard", false],
  [false, "pull_request", "contributor/importer-dashboard", false],
  [nil, "pull_request", "CellarNode/importer-dashboard", false],
  [true, "pull_request", nil, false],
  [true, "pull_request_target", "CellarNode/importer-dashboard", false],
  [true, "push", "CellarNode/importer-dashboard", false],
  [true, "workflow_dispatch", "CellarNode/importer-dashboard", false],
  [true, "schedule", "CellarNode/importer-dashboard", false],
  [true, "unknown", "CellarNode/importer-dashboard", false]
]

# Evaluate only the boolean/string expression subset used by this trust boundary.
def evaluate(expression, private_repo, event, head)
  source = expression.gsub(/\$\{\{|\}\}/, "").gsub(/\s+/, " ").strip
  allowed = /\A(?:\s+|github\.event\.repository\.private|github\.event_name|github\.event\.pull_request\.head\.repo\.full_name|github\.repository|'[^']*'|&&|\|\||==|true|false)+\z/
  abort "Unsupported runner expression" unless source.match?(allowed)
  source = source
    .gsub("github.event.repository.private", private_repo.inspect)
    .gsub("github.event.pull_request.head.repo.full_name", head.inspect)
    .gsub("github.event_name", event.inspect)
    .gsub("github.repository", '"CellarNode/importer-dashboard"')
  eval(source) # Tokens above are limited to this workflow expression subset.
end

runner = job.fetch("runs-on")
container = job.fetch("container")
contexts.each do |private_repo, event, head, trusted|
  expected_runner = trusted ? "self-hosted-k8s" : "ubuntu-latest"
  expected_container = trusted ? image : ""
  abort "Wrong runner for #{[private_repo, event, head]}" unless evaluate(runner, private_repo, event, head) == expected_runner
  abort "Wrong container for #{[private_repo, event, head]}" unless evaluate(container, private_repo, event, head) == expected_container
end

# Each guard must matter independently; catch accidentally dropping one later.
[
  /github\.event\.repository\.private == true\s*&&\s*/,
  /github\.event_name == 'pull_request'\s*&&\s*/,
  /github\.event\.pull_request\.head\.repo\.full_name == github\.repository\s*&&\s*/
].each do |guard|
  [runner, container].each do |expression|
    mutated = expression.gsub(guard, "")
    abort "Guard mutation did not change expression" if mutated == expression
    unsafe = contexts.any? do |private_repo, event, head, trusted|
      next false if trusted
      result = evaluate(mutated, private_repo, event, head)
      result == "self-hosted-k8s" || result == image
    end
    abort "Routing scenarios failed to detect a removed trust guard" unless unsafe
  end
end

puts "PASS: 11 runner/container scenarios and 6 removed-guard mutations"
