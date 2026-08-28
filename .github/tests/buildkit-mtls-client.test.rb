# Client half of the buildkitd mutual-TLS invariant (CEL-1513).
#
# The server half lives in CellarNode/crossplane-gcloud
# (scripts/verify_buildkit_mtls.py). That one proves buildkitd demands a client
# certificate; this one proves the only caller actually presents one, over the
# exact contract documented in crossplane-gcloud docs/buildkit-mtls.md:
#
#   docker buildx create --name k8s-buildkit --driver remote \
#     --driver-opt cacert=/run/buildkit/certs/ca.crt \
#     --driver-opt cert=/run/buildkit/certs/tls.crt \
#     --driver-opt key=/run/buildkit/certs/tls.key \
#     tcp://buildkitd.buildkit.svc.cluster.local:1234 --use
#
# The regression it exists for is a silent downgrade. Dropping the --driver-opt
# flags, or letting the fallback swallow a failed handshake once the server is
# TLS-only, leaves every build green while the connection goes back to
# unauthenticated plaintext. Nothing else in CI notices.

require "yaml"

# Merge-order gate. The rollout is three steps and this constant is which one
# we are on:
#
#   true  - step 1 of 3. This repo lands FIRST, before crossplane-gcloud#78.
#           The certificate does not exist in the cluster yet, so the step must
#           still be able to reach a plaintext buildkitd.
#   false - step 3 of 3. #78 has soaked; the fallback is deleted so a
#           server-side TLS regression fails the build instead of downgrading
#           it. Flip this in the same commit that deletes the branch.
PLAINTEXT_FALLBACK_EXPECTED = true

CERT_DIR = "/run/buildkit/certs".freeze
BUILDKITD_ADDR = "tcp://buildkitd.buildkit.svc.cluster.local:1234".freeze

workflow_path = File.expand_path("../workflows/deploy-backend.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)

build = workflow.fetch("jobs").fetch("build")
connect = build.fetch("steps").find { |step| step.fetch("name", "") == "Connect to in-cluster buildkitd" }
abort "deploy-backend must have a 'Connect to in-cluster buildkitd' step" if connect.nil?

run = connect.fetch("run", "")
env = connect.fetch("env", {})

# --- endpoint and certificate paths are data, not inlined literals -----------

abort "buildkitd address must be passed as env data" unless env.fetch("BUILDKITD_ADDR", nil) == BUILDKITD_ADDR
abort "buildkitd certificate directory must be passed as env data" unless env.fetch("BUILDKITD_CERT_DIR", nil) == CERT_DIR
abort "buildkitd endpoint must not be inlined in the script" if run.include?(BUILDKITD_ADDR)

# --- the mTLS invocation itself ---------------------------------------------

abort "buildkitd connection must use the remote driver" unless run.include?("--driver remote")

{
  "cacert" => "ca.crt",
  "cert" => "tls.crt",
  "key" => "tls.key",
}.each do |opt, file|
  # cert-manager's key names, absolute paths. buildx rejects relative ones and
  # renaming a key silently produces a builder that cannot handshake.
  abort "buildkitd client must pass --driver-opt #{opt}=<certdir>/#{file}" unless
    run.include?(%(--driver-opt "#{opt}=${BUILDKITD_CERT_DIR}/#{file}"))
end

# All three files, or none. A partial mount must not select the TLS path and
# then fail the handshake on a missing key.
["ca.crt", "tls.crt", "tls.key"].each do |file|
  abort "buildkitd client must require #{file} to be readable before choosing TLS" unless
    run.include?(%([ -r "${BUILDKITD_CERT_DIR}/#{file}" ]))
end

# The condition is pinned whole, not just scanned for its parts. Certificate
# presence must be the ONLY thing gating the TLS branch: an extra conjunct
# (`if false && [ -r ... ]`, `... && [ "$SOMETHING" = 1 ]`) leaves every string
# this file greps for intact while making the branch unreachable, and the
# fallback below then quietly carries every build over plaintext. Reformatting
# the guard is expected to fail here — re-read it, then update this regex.
tls_guard = /
  ^[ ]*if[ ]\[[ ]-r[ ]"\$\{BUILDKITD_CERT_DIR\}\/ca\.crt"[ ]\][ ]\\\n
  [ ]*&&[ ]\[[ ]-r[ ]"\$\{BUILDKITD_CERT_DIR\}\/tls\.crt"[ ]\][ ]\\\n
  [ ]*&&[ ]\[[ ]-r[ ]"\$\{BUILDKITD_CERT_DIR\}\/tls\.key"[ ]\];[ ]then$
/x
abort "the TLS branch must be gated on certificate presence and nothing else" unless run.match?(tls_guard)

# `docker buildx create` records an endpoint without dialling it, so create
# exiting 0 proves nothing. Only bootstrap performs the handshake.
abort "buildkitd connection must be proven with 'inspect --bootstrap'" unless run.include?("docker buildx inspect --bootstrap k8s-buildkit")

# --- merge-order gate --------------------------------------------------------

fallback_markers = [
  "connected=false",
  %(if [ "$connected" != true ]; then),
]

if PLAINTEXT_FALLBACK_EXPECTED
  fallback_markers.each do |marker|
    abort "step 1 of 3 must keep the plaintext fallback (missing: #{marker})" unless run.include?(marker)
  end

  # The fallback exists so a plaintext server still works. It must never be
  # the only path: the TLS attempt has to come first.
  tls_at = run.index("--driver-opt")
  fallback_at = run.index(%(if [ "$connected" != true ]; then))
  abort "the mTLS attempt must precede the plaintext fallback" unless tls_at && fallback_at && tls_at < fallback_at

  # An unbootstrapped fallback would defer a total connection failure to the
  # first `docker buildx build`, where it reads as a build error.
  abort "the plaintext fallback must bootstrap too, so a dead endpoint fails here" unless
    run.match?(/if \[ "\$connected" != true \]; then\s+recreate\s+docker buildx inspect --bootstrap/)
else
  # Step 3 of 3: no branch may reach buildkitd without the client credential.
  fallback_markers.each do |marker|
    abort "step 3 of 3 must delete the plaintext fallback (still present: #{marker})" if run.include?(marker)
  end
  abort "step 3 of 3 must not leave a bare plaintext create" if
    run.match?(/recreate\s*$/) || run.include?("recreate\n")
end

# --- fork PRs must never see a client certificate ---------------------------

# The credential is mounted by ARC into job pods in the cluster. Fork PRs are
# untrusted and build on GitHub-hosted runners, which have no cluster access
# and therefore no certificate; if that job ever moved to self-hosted it would
# hand arbitrary PR code a working buildkitd credential.
build_fork = workflow.fetch("jobs").fetch("build-fork")
abort "fork builds must stay on GitHub-hosted runners" unless build_fork.fetch("runs-on") == "ubuntu-latest"
abort "fork builds must not connect to in-cluster buildkitd" if
  build_fork.fetch("steps").any? { |step| step.fetch("run", "").include?("--driver remote") }

puts "BuildKit mTLS client contract passed (plaintext fallback: #{PLAINTEXT_FALLBACK_EXPECTED})"
