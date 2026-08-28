require "open3"
require "tmpdir"
require "yaml"

workflow_path = File.expand_path("../workflows/i18n-pipeline.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)
steps = workflow.fetch("jobs").fetch("sync-translate").fetch("steps")
translate = steps.find { |step| step.fetch("name", "") == "Translate new/changed keys" }
abort "Translation step missing" unless translate

env = translate.fetch("env", {})
abort "Target languages must cross into the shell as data" unless env.fetch("TARGET_LANGUAGES", nil) == "${{ inputs.target_languages }}"
abort "Translation context must cross into the shell as data" unless env.fetch("TRANSLATION_CONTEXT", nil) == "${{ inputs.context }}"

script = translate.fetch("run")
abort "Translation must snapshot the original cache" unless script.include?('cp .polyglot-cache.json "$BASE_CACHE"')
abort "Translation must initialize an empty cache" unless script.include?(%q{printf '{}\n' > "$BASE_CACHE"})
abort "Translation must reject a trailing language delimiter" unless script.include?('if [[ "$TARGET_LANGUAGES" == *, ]]; then')
abort "Translation must process one target language at a time" unless script.include?('for language in "${languages[@]}"; do')
abort "Every language must start from the original cache" unless script.include?('cp "$BASE_CACHE" "$language_cache"')
abort "CLI must receive one target language per invocation" unless script.include?('--output-languages "$language"')
abort "Each language must receive its own cache copy" unless script.include?('--cache-file "$language_cache"')
abort "Updated source hashes must return to the tracked cache" unless script.include?('cp "$updated_cache" .polyglot-cache.json')

def run_translation(script, target_languages)
  Dir.mktmpdir("i18n-pipeline-test") do |workdir|
    bin_dir = File.join(workdir, "bin")
    Dir.mkdir(bin_dir)
    call_log = File.join(workdir, "pnpm-calls.log")
    pnpm_path = File.join(bin_dir, "pnpm")
    File.write(pnpm_path, <<~'BASH')
      #!/usr/bin/env bash
      set -euo pipefail
      language=""
      cache_file=""
      previous=""
      for argument in "$@"; do
        if [ "$previous" = "--output-languages" ]; then language="$argument"; fi
        if [ "$previous" = "--cache-file" ]; then cache_file="$argument"; fi
        previous="$argument"
      done
      printf '%s:%s\n' "$language" "$(tr -d '\n' < "$cache_file")" >> "$PNPM_CALL_LOG"
      printf '{"updated":"%s"}\n' "$language" > "$cache_file"
    BASH
    File.chmod(0o755, pnpm_path)

    env = {
      "FORCE_TRANSLATE" => "false",
      "GOOGLE_API_KEY" => "test-key",
      "LOCALES_PATH" => "public/locales",
      "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}",
      "PNPM_CALL_LOG" => call_log,
      "RUNNER_TEMP" => workdir,
      "TARGET_LANGUAGES" => target_languages,
      "TRANSLATION_CONTEXT" => "test",
    }
    stdout, stderr, status = Open3.capture3(env, "bash", "-c", script, chdir: workdir)
    calls = File.exist?(call_log) ? File.readlines(call_log, chomp: true) : []
    cache_path = File.join(workdir, ".polyglot-cache.json")
    cache = File.exist?(cache_path) ? File.read(cache_path) : nil
    [stdout + stderr, status, calls, cache]
  end
end

["", " ", ",sv", "sv,", "sv,,de", "sv, ,de"].each do |target_languages|
  output, status, calls, = run_translation(script, target_languages)
  abort "Invalid languages #{target_languages.inspect} must fail with validation" if status.success? || !output.include?("Target language code must not be empty")
  abort "Invalid languages #{target_languages.inspect} must fail before translation" unless calls.empty?
end

_output, status, calls, cache = run_translation(script, "sv, de")
abort "Valid languages must translate successfully" unless status.success?
abort "Every language must receive the untouched cache" unless calls == ["sv:{}", "de:{}"]
abort "Tracked cache must receive one updated language cache" unless cache == "{\"updated\":\"de\"}\n"

puts "i18n pipeline per-language cache isolation: PASS"
