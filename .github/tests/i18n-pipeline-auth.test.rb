require "open3"
require "tmpdir"
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

ensure_gh = steps.find { |step| step.fetch("name", "") == "Ensure GitHub CLI is available" }
abort "GitHub CLI setup must precede PR creation" unless ensure_gh && steps.index(ensure_gh) < steps.index(create_pr)
expected_gh_setup_if = "github.event.repository.private == true && (github.event_name == 'push' || github.event_name == 'workflow_dispatch') && steps.diff.outputs.changed == 'true'"
abort "GitHub CLI setup must run only for changed trusted private translation runs" unless ensure_gh.fetch("if", "") == expected_gh_setup_if
abort "GitHub CLI setup must not receive a token" if ensure_gh.fetch("env", {}).key?("GH_TOKEN")

gh_setup = ensure_gh.fetch("run")

def run_gh_setup(script, gh_available:)
  Dir.mktmpdir("i18n-gh-setup-test") do |workdir|
    bin_dir = File.join(workdir, "bin")
    Dir.mkdir(bin_dir)
    log = File.join(workdir, "apt-get.log")
    gh_path = File.join(bin_dir, "gh")
    apt_get_path = File.join(bin_dir, "apt-get")

    if gh_available
      File.write(gh_path, "#!/bin/bash\nprintf 'gh version fixture\\n'\n")
      File.chmod(0o755, gh_path)
    end
    File.write(apt_get_path, <<~'BASH')
      #!/bin/bash
      printf 'apt-get %s\n' "$*" >> "$GH_SETUP_LOG"
      if [ "$1" = "install" ]; then
        printf "#!/bin/bash\\nprintf 'gh version fixture\\n'\\n" > "$FAKE_BIN/gh"
        /bin/chmod +x "$FAKE_BIN/gh"
      fi
    BASH
    File.chmod(0o755, apt_get_path)

    env = { "FAKE_BIN" => bin_dir, "GH_SETUP_LOG" => log, "PATH" => bin_dir }
    stdout, stderr, status = Open3.capture3(env, "/bin/bash", "-c", script)
    calls = File.exist?(log) ? File.readlines(log, chomp: true) : []
    [stdout + stderr, status, calls]
  end
end

available_output, available_status, available_calls = run_gh_setup(gh_setup, gh_available: true)
abort "Existing GitHub CLI must skip package installation" unless available_status.success? && available_calls.empty? && available_output.include?("gh version fixture")
missing_output, missing_status, missing_calls = run_gh_setup(gh_setup, gh_available: false)
abort "Missing GitHub CLI setup failed (status=#{missing_status.exitstatus}, calls=#{missing_calls.inspect}, output=#{missing_output.inspect})" unless missing_status.success? &&
  missing_calls == ["apt-get update", "apt-get install -y --no-install-recommends gh"] &&
  missing_output.include?("gh version fixture")

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

Dir.mktmpdir("i18n-pr-rollback-test") do |workdir|
  bin_dir = File.join(workdir, "bin")
  Dir.mkdir(bin_dir)
  gh_log = File.join(workdir, "gh.log")
  git_log = File.join(workdir, "git.log")

  git_path = File.join(bin_dir, "git")
  File.write(git_path, <<~'BASH')
    #!/usr/bin/env bash
    printf 'git %s\n' "$*" >> "$GIT_CALL_LOG"
  BASH
  File.chmod(0o755, git_path)

  gh_path = File.join(bin_dir, "gh")
  File.write(gh_path, <<~'BASH')
    #!/usr/bin/env bash
    printf 'gh %s\n' "$*" >> "$GH_CALL_LOG"
    if [[ "$*" == *"repos/CellarNode/test/pulls"* ]]; then
      exit 1
    fi
  BASH
  File.chmod(0o755, gh_path)

  env = {
    "GH_CALL_LOG" => gh_log,
    "GH_TOKEN" => "test-token",
    "GITHUB_OUTPUT" => File.join(workdir, "github-output"),
    "GITHUB_REF_NAME" => "main",
    "GITHUB_REPOSITORY" => "CellarNode/test",
    "GIT_CALL_LOG" => git_log,
    "LOCALES_PATH" => "public/locales",
    "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}",
    "RUNNER_TEMP" => workdir,
  }
  _stdout, _stderr, status = Open3.capture3(env, "bash", "-c", script, chdir: workdir)
  gh_calls = File.exist?(gh_log) ? File.read(gh_log) : ""
  abort "PR creation failure must fail the step" if status.success?
  abort "PR creation failure must delete the pushed branch" unless gh_calls.include?("--method DELETE repos/CellarNode/test/git/refs/heads/chore/i18n-pipeline-")
end

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

puts "i18n pipeline authentication boundary and conditional gh setup: PASS"
