# CEL-2795: behavioural contract for the single-job backend deploy loop in deploy-backend.yaml.
#
# Extracts the `deploy` job's step script from the YAML and EXECUTES it under bash with a stub `argocd` on PATH (a temp-dir
# script that logs its args). Hermetic: no network, no real argocd. Asserts:
#   * the deploy step declares `shell: bash` (ARC k8s-mode otherwise runs `sh -e`/dash, where `set -o pipefail` is illegal),
#   * order: non-worker flavors first (input order), then worker-* flavors,
#   * the first failed flavor stops the loop with a non-zero exit and nothing after it is upserted,
#   * a flavor that fails once then succeeds is retried and the run still succeeds,
#   * a flavor that fails every attempt is retried 3 times and then fails the run,
#   * a non-argocd error (malformed docker_targets) fails the run before any upsert.
#
# Run: ruby .github/tests/deploy-backend-loop.test.rb      (exit 0 = every contract holds)

require "yaml"
require "open3"
require "tmpdir"
require "fileutils"

WORKFLOW = File.expand_path("../workflows/deploy-backend.yaml", __dir__)
FAILURES = []

def fail!(msg)
  FAILURES << msg
end

deploy = YAML.safe_load(File.read(WORKFLOW), aliases: true).fetch("jobs").fetch("deploy")
step = deploy.fetch("steps").find { |s| s["name"].to_s.start_with?("Deploy flavors to ArgoCD") } or abort("deploy step not found")
script = step.fetch("run")

fail!("the deploy step must declare `shell: bash` (ARC k8s-mode runs run: steps with plain sh -e, where pipefail is illegal)") unless step["shell"] == "bash"
fail!("the deploy job must keep a timeout-minutes (CEL-2795)") unless deploy["timeout-minutes"].is_a?(Integer) && deploy["timeout-minutes"] <= 15
fail!("the deploy job id/needs contract changed (discord-deploy reads needs.deploy.result)") unless deploy["needs"] == "build"

FLAVORS = '["admin","public","worker-extraction","worker-matching","worker-lifecycle","elabel"]'.freeze

def run_script(script, interpreter: %w[bash -e], env: {})
  Dir.mktmpdir("cel2795-loop") do |dir|
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    log = File.join(dir, "calls.log")
    stub = File.join(bin, "argocd")
    File.write(stub, <<~'STUB')
      #!/bin/bash
      # args: app create --upsert <name> ...
      name="$4"
      echo "$name" >> "$STUB_LOG"
      if [ "$name" = "${FAIL_ALWAYS:-}" ]; then exit 3; fi
      if [ "$name" = "${FAIL_ONCE:-}" ]; then
        marker="$STUB_LOG.once"
        if [ ! -e "$marker" ]; then : > "$marker"; exit 4; fi
      fi
      exit 0
    STUB
    FileUtils.chmod(0o755, stub)
    path = File.join(dir, "script.sh")
    File.write(path, script)
    base = {
      "PATH" => "#{bin}:#{ENV['PATH']}", "STUB_LOG" => log, "ARGOCD_AUTH_TOKEN" => "dummy", "ARGOCD_URL" => "stub",
      "APP" => "cellarnode", "WORKER_PREFIX" => "worker", "ARGOCD_PROJECT" => "p", "DEPLOY_PATH" => "d", "REGISTRY" => "reg",
      "TAG" => "t1", "DOCKER_TARGETS" => '["admin","worker","elabel"]', "FLAVORS" => FLAVORS,
      "RETRY_DELAY_1" => "0", "RETRY_DELAY_2" => "0"
    }
    out, status = Open3.capture2e(base.merge(env), *interpreter, path)
    calls = File.exist?(log) ? File.read(log).split : []
    [status, calls, out]
  end
end

ORDER = %w[cellarnode-admin cellarnode-public cellarnode-elabel cellarnode-worker-extraction cellarnode-worker-matching cellarnode-worker-lifecycle].freeze

status, calls, out = run_script(script)
fail!("happy path must exit 0, got #{status.exitstatus}: #{out}") unless status.success?
fail!("order must be non-workers first then workers, got #{calls.inspect}") unless calls == ORDER

status, calls, = run_script(script, env: { "FAIL_ALWAYS" => "cellarnode-worker-matching" })
fail!("a failing flavor must fail the run") if status.success?
fail!("a failing flavor must be tried 3 times and stop the loop, got #{calls.inspect}") unless calls == ORDER[0..3] + ["cellarnode-worker-matching"] * 3

status, calls, = run_script(script, env: { "FAIL_ALWAYS" => "cellarnode-admin" })
fail!("failing admin must fail the run") if status.success?
fail!("nothing may run after a failed first flavor, got #{calls.inspect}") unless calls == ["cellarnode-admin"] * 3

status, calls, out = run_script(script, env: { "FAIL_ONCE" => "cellarnode-public" })
fail!("a flavor failing once must be retried and the run succeed, got #{status.exitstatus}: #{out}") unless status.success?
fail!("a flaky flavor must be retried exactly once, got #{calls.inspect}") unless calls == ["cellarnode-admin", "cellarnode-public", "cellarnode-public"] + ORDER[2..]
fail!("a retry must be logged with ::warning::") unless out.include?("::warning")

# An error OUTSIDE argocd (here: the jq image mapping on malformed docker_targets) must fail the run, not be swallowed.
# This guards the per-flavor `set -eo pipefail` subshell.
status, calls, out = run_script(script, env: { "DOCKER_TARGETS" => "not-json" })
fail!("a non-argocd error in the deploy function must fail the run, got exit #{status.exitstatus}") if status.success?
fail!("argocd must not be called for a flavor whose image mapping failed, got #{calls.inspect}") unless calls.empty?
fail!("the failure must name the first flavor (loop stops there): #{out}") unless out.include?("cellarnode-admin failed") && !out.include?("cellarnode-public")

if FAILURES.empty?
  puts "deploy backend loop: OK (shell: bash, order, stop at first failure, retry)"
else
  warn "deploy backend loop FAILED:"
  FAILURES.each { |f| warn "  - #{f}" }
  exit 1
end
