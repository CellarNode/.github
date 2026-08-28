require "yaml"

workflow_path = File.expand_path("../workflows/i18n-pipeline.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)

pipeline_token = workflow
  .fetch("on") { workflow.fetch(true) }
  .fetch("workflow_call")
  .fetch("secrets")
  .fetch("I18N_PIPELINE_TOKEN")
abort "I18N pipeline token must be required" unless pipeline_token.fetch("required") == true

steps = workflow.fetch("jobs").fetch("sync-translate").fetch("steps")
checkout = steps.find { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
abort "Checkout must disable persisted credentials" unless checkout&.fetch("with", {})&.fetch("persist-credentials", nil) == false

create_pr = steps.find { |step| step.fetch("id", "") == "create_pr" }
abort "Create PR must use only I18N_PIPELINE_TOKEN" unless create_pr&.fetch("env", {})&.fetch("GH_TOKEN", nil) == "${{ secrets.I18N_PIPELINE_TOKEN }}"

script = create_pr.fetch("run")
abort "Push must not place GH_TOKEN in its URL" if script.include?('x-access-token:${GH_TOKEN}@')
abort "Push must use an ephemeral credential file" unless script.include?('GIT_CREDENTIAL_FILE="$RUNNER_TEMP/i18n-git-credentials"')
abort "Credential file must be removed on exit" unless script.include?('trap \'rm -f "$GIT_CREDENTIAL_FILE"\' EXIT')
abort "Push must use the credential-free repository URL" unless script.include?('git push "https://github.com/${GITHUB_REPOSITORY}.git" "$BRANCH"')

puts "i18n pipeline authentication boundary: PASS"
