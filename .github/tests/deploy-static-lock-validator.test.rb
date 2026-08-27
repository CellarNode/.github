require "open3"
require "rbconfig"
require "tempfile"

workflow = File.read(File.expand_path("../workflows/deploy-static-website.yaml", __dir__))
match = workflow.match(/ruby - "\$1" <<'RUBY'\n(?<body>.*?)^\s+RUBY$/m)
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

puts "Lock validator fixtures passed: #{fixtures.length}"
