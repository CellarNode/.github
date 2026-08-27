require "open3"
require "rbconfig"
require "tempfile"
require "tmpdir"
require "yaml"

workflow = File.read(File.expand_path("../workflows/deploy-static-website.yaml", __dir__))
match = workflow.match(/cat > "\$LOCK_VALIDATOR" <<'RUBY'\n(?<body>.*?)^\s+RUBY$/m)
abort "Lock validator heredoc not found" unless match

validator = match[:body].gsub(/^ {10}/, "")
fixtures = {
  "registry resolution" => [<<~YAML, true],
    lockfileVersion: '9.0'
    packages:
      '@scope/package@1.0.0':
        resolution:
          integrity: sha512-safe
  YAML
  "empty resolution" => [<<~YAML, false],
    lockfileVersion: '9.0'
    packages:
      '@scope/package@1.0.0':
        resolution: {}
  YAML
  "missing integrity value" => [<<~YAML, false],
    lockfileVersion: '9.0'
    packages:
      '@scope/package@1.0.0':
        resolution:
          integrity:
  YAML
  "structured integrity value" => [<<~YAML, false],
    lockfileVersion: '9.0'
    packages:
      '@scope/package@1.0.0':
        resolution:
          integrity:
            digest: sha512-safe
  YAML
  "array integrity value" => [<<~YAML, false],
    lockfileVersion: '9.0'
    packages:
      '@scope/package@1.0.0':
        resolution:
          integrity:
            - sha512-safe
  YAML
  "unknown integrity algorithm" => [<<~YAML, false],
    lockfileVersion: '9.0'
    packages:
      '@scope/package@1.0.0':
        resolution:
          integrity: sha999-safe
  YAML
  "workspace importer reference" => [<<~YAML, true],
    lockfileVersion: '9.0'
    importers:
      .:
        dependencies:
          local-package:
            specifier: workspace:*
            version: link:../local-package
  YAML
  "raw git protocol" => [<<~YAML, false],
    lockfileVersion: '9.0'
    packages:
      git-package@1.0.0:
        resolution:
          type: git
          repo: git://evil.example/repo.git
  YAML
  "structured git resolution" => [<<~YAML, false],
    lockfileVersion: '9.0'
    packages:
      git-package@1.0.0:
        resolution:
          type: git
          repo: registry.example.invalid/repo
  YAML
  "unknown resolution shape" => [<<~YAML, false],
    lockfileVersion: '9.0'
    packages:
      external-package@1.0.0:
        resolution:
          path: external-package
  YAML
  "tarball resolution" => [<<~YAML, false],
    lockfileVersion: '9.0'
    packages:
      external-package@1.0.0:
        resolution:
          tarball: https://evil.example/package.tgz
  YAML
  "directory resolution" => [<<~YAML, false],
    lockfileVersion: '9.0'
    packages:
      external-package@1.0.0:
        resolution:
          directory: ../external-package
  YAML
  "allowed private package" => [<<~YAML, true],
    lockfileVersion: '9.0'
    packages:
      '@cellarnode/ui@0.154.0':
        resolution:
          integrity: sha512-safe
  YAML
  "unknown private package" => [<<~YAML, false],
    lockfileVersion: '9.0'
    packages:
      '@cellarnode/internal-secrets@1.0.0':
        resolution:
          integrity: sha512-safe
  YAML
  "aliased unknown private package" => [<<~YAML, false],
    lockfileVersion: '9.0'
    importers:
      .:
        dependencies:
          hidden-package:
            specifier: npm:@cellarnode/internal-secrets@1.0.0
            version: '@cellarnode/internal-secrets@1.0.0'
    packages:
      '@cellarnode/internal-secrets@1.0.0':
        resolution:
          integrity: sha512-safe
  YAML
}

fixtures.each do |name, (lock, expected)|
  Tempfile.create(["pnpm-lock", ".yaml"]) do |file|
    file.write(lock)
    file.flush
    _stdout, _stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-",
      file.path,
      stdin_data: validator,
    )
    actual = status.success?
    abort "#{name}: expected accepted=#{expected}, got accepted=#{actual}" unless actual == expected
  end
end

parsed_workflow = YAML.safe_load(workflow, aliases: true)
validation_step = parsed_workflow
  .fetch("jobs")
  .fetch("build-preview")
  .fetch("steps")
  .find { |step| step["name"] == "Validate preview dependency inputs" }
abort "Credential-free dependency validation step not found" unless validation_step

install_step = parsed_workflow
  .fetch("jobs")
  .fetch("build-preview")
  .fetch("steps")
  .find { |step| step["name"] == "Install dependencies with scoped registry credential" }
abort "Credentialed install step not found" unless install_step

validation_script = validation_step.fetch("run")
non_frozen_script = install_step.fetch("run").sub(
  "${{ inputs.frozen_lockfile && '--frozen-lockfile' || '--no-frozen-lockfile' }}",
  "--no-frozen-lockfile",
)

manifest_fixtures = {
  "unknown private manifest package" => ["@cellarnode/internal-secrets", "1.0.0", false],
  "aliased unknown private manifest package" => ["hidden-package", "npm:@cellarnode/internal-secrets@1.0.0", false],
  "allowed private manifest package" => ["@cellarnode/ui", "1.0.0", true],
}

manifest_fixtures.each do |name, (package, version, expected_install)|
  Dir.mktmpdir("cel1328-manifest-boundary") do |directory|
    File.write(
      File.join(directory, "package.json"),
      <<~JSON,
        {
          "dependencies": {
            "#{package}": "#{version}"
          }
        }
      JSON
    )
    File.write(
      File.join(directory, "pnpm-lock.yaml"),
      <<~YAML,
        lockfileVersion: '9.0'
        packages:
          '@scope/package@1.0.0':
            resolution:
              integrity: sha512-safe
      YAML
    )

    bin_directory = File.join(directory, "bin")
    Dir.mkdir(bin_directory)
    marker = File.join(directory, "pnpm-invoked")
    manifest_validator = File.join(directory, "manifest-validator.rb")
    lock_validator = File.join(directory, "lock-validator.rb")
    pnpm = File.join(bin_directory, "pnpm")
    File.write(pnpm, <<~SH)
      #!/bin/sh
      : > "$PNPM_MARKER"
    SH
    File.chmod(0o755, pnpm)

    validator_env = {
      "MANIFEST_VALIDATOR" => manifest_validator,
      "LOCK_VALIDATOR" => lock_validator,
    }
    _stdout, validation_stderr, validation_status = Open3.capture3(
      validator_env,
      "bash",
      "-euo",
      "pipefail",
      "-c",
      validation_script,
      chdir: directory,
    )

    if expected_install
      abort "#{name}: credential-free validation failed: #{validation_stderr}" unless validation_status.success?
    else
      abort "#{name}: credential-free validation unexpectedly succeeded" if validation_status.success?
      abort "#{name}: package manager ran before manifest rejection" if File.exist?(marker)
      abort "#{name}: wrong rejection: #{validation_stderr}" unless validation_stderr.include?("manifest contains a disallowed private package")
      next
    end

    _stdout, stderr, status = Open3.capture3(
      {
        "NPM_CONFIG_USERCONFIG" => File.join(directory, "preview-npmrc"),
        "NPM_TOKEN" => "test-token",
        "PATH" => "#{bin_directory}:#{ENV.fetch("PATH")}",
        "PNPM_MARKER" => marker,
        "MANIFEST_VALIDATOR" => manifest_validator,
        "LOCK_VALIDATOR" => lock_validator,
      },
      "bash",
      "-euo",
      "pipefail",
      "-c",
      non_frozen_script,
      chdir: directory,
    )

    abort "#{name}: install did not run successfully: #{stderr}" unless status.success? && File.exist?(marker)
  end
end

puts "Lock validator fixtures passed: #{fixtures.length}; manifest fixtures passed: #{manifest_fixtures.length}"
