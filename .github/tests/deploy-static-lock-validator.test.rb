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
dependency_scripts = %w[build-preview build-production].to_h do |job_name|
  steps = parsed_workflow.fetch("jobs").fetch(job_name).fetch("steps")
  validation_index = steps.index do |step|
    env = step.fetch("env", {})
    env.key?("MANIFEST_VALIDATOR") && env.key?("LOCK_VALIDATOR") && !env.key?("NPM_TOKEN")
  end
  install_index = steps.index { |step| step["name"] == "Install dependencies with scoped registry credential" }
  abort "#{job_name}: credential-free dependency validation step not found" unless validation_index
  abort "#{job_name}: credentialed install step not found" unless install_index
  abort "#{job_name}: dependency validation must run before credentialed install" unless validation_index < install_index

  validation_step = steps.fetch(validation_index)
  abort "#{job_name}: dependency validation must not receive NPM_TOKEN" if validation_step.fetch("env", {}).key?("NPM_TOKEN")

  install_script = steps.fetch(install_index).fetch("run").sub(
    "${{ inputs.frozen_lockfile && '--frozen-lockfile' || '--no-frozen-lockfile' }}",
    "--no-frozen-lockfile",
  )
  [job_name, [validation_step.fetch("run"), install_script]]
end

abort "Preview and production dependency validation must use the same trusted script" unless dependency_scripts.values.map(&:first).uniq.one?

manifest_fixtures = {
  "unknown private manifest package" => ["@cellarnode/internal-secrets", "1.0.0", false],
  "aliased unknown private manifest package" => ["hidden-package", "npm:@cellarnode/internal-secrets@1.0.0", false],
  "allowed private manifest package" => ["@cellarnode/ui", "1.0.0", true],
  "allowed public registry range" => ["public-package", "^1.0.0", true],
  "aliased public manifest package" => ["@cellarnode/ui", "npm:evil-package@1.0.0", false],
  "git manifest package" => ["public-package", "git+https://evil.example/package.git", false],
  "file manifest package" => ["public-package", "file:../package", false],
  "workspace manifest package" => ["public-package", "workspace:*", false],
  "github shorthand manifest package" => ["public-package", "attacker/package", false],
  "tarball manifest package" => ["public-package", "package.tgz", false],
}

dependency_scripts.each do |job_name, (validation_script, non_frozen_script)|
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
        abort "#{job_name} #{name}: credential-free validation failed: #{validation_stderr}" unless validation_status.success?
      else
        abort "#{job_name} #{name}: credential-free validation unexpectedly succeeded" if validation_status.success?
        abort "#{job_name} #{name}: package manager ran before manifest rejection" if File.exist?(marker)
        abort "#{job_name} #{name}: wrong rejection: #{validation_stderr}" unless validation_stderr.include?("manifest contains a disallowed package or source")
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

      abort "#{job_name} #{name}: install did not run successfully: #{stderr}" unless status.success? && File.exist?(marker)
    end
  end
end

puts "Lock validator fixtures passed: #{fixtures.length}; manifest fixtures passed: #{manifest_fixtures.length * dependency_scripts.length}"
