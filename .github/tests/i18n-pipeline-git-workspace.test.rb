require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

# CEL-2768: a self-hosted container job runs as root in a workspace owned by the
# runner user. Git then refuses the checkout unless it is marked safe, and the
# pipeline used to read that refusal as "files changed". This test runs the
# workflow's own step scripts against a repository git considers foreign
# (GIT_TEST_ASSUME_DIFFERENT_OWNER) so the container condition is reproduced
# without a container.

workflow_path = File.expand_path("../workflows/i18n-pipeline.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)
job = workflow.fetch("jobs").fetch("sync-translate")
shell = job.fetch("defaults").fetch("run").fetch("shell")
abort "Translation job must select Bash for its run steps" unless shell == "bash"
steps = job.fetch("steps")

def step_named(steps, name)
  steps.find { |step| step.fetch("name", "") == name } || abort("Step missing: #{name}")
end

checkout = steps.find { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
trust = step_named(steps, "Trust the workspace for git")
verify_git = step_named(steps, "Verify git can read the workspace")
verify_token = step_named(steps, "Verify I18N_PIPELINE_TOKEN is present")
setup_node = step_named(steps, "Setup Node")
diff = step_named(steps, "Check for changes")
create_pr = steps.find { |step| step.fetch("id", "") == "create_pr" } || abort("Create PR step missing")

index = ->(step) { steps.index(step) }
abort "Git trust must follow checkout and precede every other git use" unless index[checkout] < index[trust] && index[trust] < index[verify_git]
abort "Git and token pre-flights must run before the install and translation steps" unless index[verify_git] < index[setup_node] && index[verify_token] < index[setup_node]
abort "Change detection must follow the git trust step" unless index[trust] < index[diff] && index[diff] < index[create_pr]
abort "Pre-flight steps must not be conditional" if [trust, verify_git, verify_token].any? { |step| step.key?("if") }
abort "The token pre-flight must receive only I18N_PIPELINE_TOKEN" unless verify_token.fetch("env") == { "I18N_PIPELINE_TOKEN" => "${{ secrets.I18N_PIPELINE_TOKEN }}" }
abort "The token pre-flight must not print the token" if verify_token.fetch("run").match?(/echo[^\n]*\$\{?I18N_PIPELINE_TOKEN(?!\/\/)/)

BASE_ENV = {
  "GIT_CONFIG_NOSYSTEM" => "1",
  "GIT_CONFIG_GLOBAL" => File::NULL,
  "GIT_TERMINAL_PROMPT" => "0",
  "LC_ALL" => "C",
}.freeze

def run_step(script, shell, env, chdir)
  Open3.capture3(BASE_ENV.merge(env), shell, "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script, chdir: chdir)
end

def parse_env_file(path)
  File.readlines(path, chomp: true).to_h { |line| line.split("=", 2) }
end

Dir.mktmpdir("i18n-git-workspace-test") do |root|
  home = File.join(root, "home")
  workspace = File.join(root, "workspace")
  FileUtils.mkdir_p([home, workspace])
  git_env = { "HOME" => home }
  system(git_env.merge(BASE_ENV), "git", "init", "-q", workspace, exception: true)
  File.write(File.join(workspace, "en.json"), "{}\n")
  system(git_env.merge(BASE_ENV), "git", "-C", workspace, "add", "en.json", exception: true)
  system(git_env.merge(BASE_ENV), "git", "-C", workspace, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init", exception: true)

  # A checkout owned by another user, as the runner user's workspace is to root in the container.
  foreign = git_env.merge("GIT_TEST_ASSUME_DIFFERENT_OWNER" => "1")

  _out, err, status = run_step("git rev-parse --is-inside-work-tree", shell, foreign, workspace)
  abort "Simulation is ineffective: git trusted a foreign checkout (#{err})" if status.success?

  # Run the trust step the way the runner does: it appends to $GITHUB_ENV, and the
  # following steps see those variables.
  github_env = File.join(root, "github_env")
  File.write(github_env, "")
  _out, err, status = run_step(trust.fetch("run"), shell, foreign.merge("GITHUB_ENV" => github_env, "GITHUB_WORKSPACE" => workspace), workspace)
  abort "Trust step failed: #{err}" unless status.success?
  trusted = foreign.merge(parse_env_file(github_env))
  abort "Trust step must export a safe.directory entry for the workspace" unless trusted.values_at("GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0") == ["1", "safe.directory", workspace]

  # Pre-flight: refuses an untrusted checkout, accepts a trusted one.
  out, _err, status = run_step(verify_git.fetch("run"), shell, foreign, workspace)
  abort "Git pre-flight must fail on an untrusted checkout" if status.success?
  abort "Git pre-flight must annotate the failure" unless out.include?("::error title=Workspace not readable by git")
  _out, err, status = run_step(verify_git.fetch("run"), shell, trusted, workspace)
  abort "Git pre-flight must pass on a trusted checkout: #{err}" unless status.success?

  # Change detection: a clean tree, a modified tree, and a git failure are three different answers.
  detect = diff.fetch("run")
  output = File.join(root, "github_output")
  detect_env = ->(base) { base.merge("GITHUB_OUTPUT" => output) }

  File.write(output, "")
  _out, err, status = run_step(detect, shell, detect_env[trusted], workspace)
  abort "Clean tree must succeed: #{err}" unless status.success? && File.read(output) == "changed=false\n"

  File.write(File.join(workspace, "en.json"), "{\"a\":1}\n")
  File.write(output, "")
  _out, err, status = run_step(detect, shell, detect_env[trusted], workspace)
  abort "Modified tree must report a change: #{err}" unless status.success? && File.read(output) == "changed=true\n"

  File.write(output, "")
  out, _err, status = run_step(detect, shell, detect_env[foreign], workspace)
  abort "A git failure must fail the step instead of reporting a change" if status.success?
  abort "A git failure must not write a changed= output" unless File.read(output).empty?
  abort "A git failure must be annotated with git's exit status" unless out.include?("::error title=Change detection failed::git diff exited 129")

  # The run observed on the self-hosted runner: the legacy chain reports a change
  # when git cannot read the checkout, which is what this test must keep catching.
  legacy = 'git diff --exit-code && echo "changed=false" >> $GITHUB_OUTPUT || echo "changed=true" >> $GITHUB_OUTPUT'
  File.write(output, "")
  _out, _err, status = run_step(legacy, shell, detect_env[foreign], workspace)
  abort "Legacy chain scenario drifted: it must report a false change" unless status.success? && File.read(output) == "changed=true\n"

  # Create PR starts with `git config user.name`; it died here with "not in a git directory".
  first_git = create_pr.fetch("run")[/^\s*git config user\.name .*$/] || abort("Create PR no longer configures git first")
  _out, _err, status = run_step(first_git.strip, shell, foreign, workspace)
  abort "Simulation is ineffective for git config" if status.success?
  _out, err, status = run_step(first_git.strip, shell, trusted, workspace)
  abort "Create PR's first git command must work on a trusted checkout: #{err}" unless status.success?
end

# Token pre-flight: an empty or blank secret fails by name, a real one passes silently.
Dir.mktmpdir("i18n-token-preflight-test") do |workdir|
  script = verify_token.fetch("run")
  ["", " ", "\n", " \t\n"].each do |blank|
    out, _err, status = run_step(script, shell, { "I18N_PIPELINE_TOKEN" => blank }, workdir)
    abort "Blank token #{blank.inspect} must fail" if status.success?
    abort "Blank token failure must name the secret and its likely causes" unless out.include?("::error title=I18N_PIPELINE_TOKEN empty") && out.include?("repository-level secret") && out.include?("secrets: inherit")
  end

  secret = "ghp_fixture_secret_value"
  out, err, status = run_step(script, shell, { "I18N_PIPELINE_TOKEN" => secret }, workdir)
  abort "A present token must pass: #{err}" unless status.success?
  abort "The pre-flight must not print the token" if (out + err).include?(secret)
end

puts "i18n pipeline git workspace trust, loud change detection and token pre-flight: PASS"
