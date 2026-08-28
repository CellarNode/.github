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
abort "Credential file creation must use a restrictive umask" unless script.include?("umask 077")
abort "Push must use an atomic ephemeral credential file" unless script.include?('GIT_CREDENTIAL_FILE=$(mktemp "$RUNNER_TEMP/i18n-git-credentials.XXXXXX")')
abort "Credential cleanup must cover failure paths" unless script.include?("trap cleanup_git_credentials EXIT")
abort "Failure cleanup must unset the helper" unless script.include?("git config --local --unset-all credential.helper >/dev/null 2>&1 || true")
abort "Push must use the credential-free repository URL" unless script.include?('git push "https://github.com/${GITHUB_REPOSITORY}.git" "$BRANCH"')
push_index = script.index('git push "https://github.com/${GITHUB_REPOSITORY}.git" "$BRANCH"')
cleanup_index = script.index("cleanup_git_credentials\n", push_index)
clear_trap_index = script.index("trap - EXIT", push_index)
abort "Credentials must be cleaned immediately after push" unless cleanup_index && cleanup_index > push_index
abort "Credential cleanup trap must be cleared after success" unless clear_trap_index && clear_trap_index > cleanup_index

auto_merge = steps.find { |step| step.fetch("name", "") == "Enable auto-merge on the new PR" }
auto_merge_script = auto_merge.fetch("run")
abort "Branch-rule API failures must not append response JSON to zero" if auto_merge_script.include?("|| echo 0")
abort "Ruleset count must default before the API probe" unless auto_merge_script.include?("RULES=0")
abort "Classic protection count must default before the API probe" unless auto_merge_script.include?("CLASSIC=0")

puts "i18n pipeline authentication boundary: PASS"
