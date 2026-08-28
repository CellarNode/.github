require "open3"
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
checkout = steps.find { |step| step.fetch("uses", "") == "actions/checkout@11d5960a326750d5838078e36cf38b85af677262" }
abort "Checkout must use the audited v4.4.0 commit" unless checkout
abort "Checkout must disable persisted credentials" unless checkout&.fetch("with", {})&.fetch("persist-credentials", nil) == false
abort "setup-node must use an audited commit" unless steps.any? { |step| step.fetch("uses", "") == "actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020" }
abort "pnpm setup must use an audited commit" unless steps.any? { |step| step.fetch("uses", "") == "pnpm/action-setup@b906affcce14559ad1aafd4ab0e942779e9f58b1" }

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

ruleset_check_filter = 'if type == "array" then [.[] | select(type == "object") | select(.type? == "required_status_checks") | .parameters? | select(type == "object") | .required_status_checks? | select(type == "array") | .[] | select(type == "object") | select((.context? | type) == "string" and (.context | length) > 0)] | length else 0 end'
abort "Ruleset probe must count configured checks, not rule objects" unless auto_merge_script.include?("--jq '#{ruleset_check_filter}'")

ruleset_fixtures = {
  "no rules" => ["[]", "0"],
  "empty required-check rule" => ['[{"type":"required_status_checks","parameters":{"required_status_checks":[]}}]', "0"],
  "malformed required check" => ['[{"type":"required_status_checks","parameters":{"required_status_checks":[{}]}}]', "0"],
  "malformed rule beside valid check" => ['[{"type":"required_status_checks","parameters":1},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"lint"}]}}]', "1"],
  "one configured check" => ['[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"lint"}]}}]', "1"],
  "two rules with three checks" => ['[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"lint"},{"context":"test"}]}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]', "3"],
}.freeze

ruleset_fixtures.each do |name, (payload, expected)|
  output, status = Open3.capture2e("jq", "-r", ruleset_check_filter, stdin_data: payload)
  abort "Ruleset fixture #{name} failed: #{output}" unless status.success? && output.strip == expected
end

classic_check_filter = 'if (.checks? | type) == "array" then [.checks[] | select((.context? | type) == "string" and (.context | length) > 0)] | length else 0 end'
abort "Classic probe must count valid configured checks" unless auto_merge_script.include?("--jq '#{classic_check_filter}'")

classic_fixtures = {
  "missing checks" => ["{}", "0"],
  "string checks" => ['{"checks":"oops"}', "0"],
  "numeric checks" => ['{"checks":1}', "0"],
  "empty checks" => ['{"checks":[]}', "0"],
  "malformed check" => ['{"checks":[{}]}', "0"],
  "one configured check" => ['{"checks":[{"context":"lint","app_id":1}]}', "1"],
  "mixed checks" => ['{"checks":[{}, {"context":""}, {"context":"test"}]}', "1"],
}.freeze

classic_fixtures.each do |name, (payload, expected)|
  output, status = Open3.capture2e("jq", "-r", classic_check_filter, stdin_data: payload)
  abort "Classic fixture #{name} failed: #{output}" unless status.success? && output.strip == expected
end

puts "i18n pipeline authentication boundary: PASS"
