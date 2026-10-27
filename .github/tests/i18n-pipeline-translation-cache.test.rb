require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

workflow_path = File.expand_path("../workflows/i18n-pipeline.yaml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)
job = workflow.fetch("jobs").fetch("sync-translate")
shell = job.fetch("defaults").fetch("run").fetch("shell")
abort "Translation job must select Bash for its run steps" unless shell == "bash"
SHELL = shell.freeze
steps = job.fetch("steps")
translate = steps.find { |step| step.fetch("name", "") == "Translate new/changed keys" }
abort "Translation step missing" unless translate

env = translate.fetch("env", {})
abort "Target languages must cross into the shell as data" unless env.fetch("TARGET_LANGUAGES", nil) == "${{ inputs.target_languages }}"
abort "Translation context must cross into the shell as data" unless env.fetch("TRANSLATION_CONTEXT", nil) == "${{ inputs.context }}"

script = translate.fetch("run")
SCRIPT = script.freeze
abort "Translation must snapshot the original cache" unless script.include?('cp .polyglot-cache.json "$BASE_CACHE"')
abort "Translation must initialize an empty cache" unless script.include?(%q{printf '{}\n' > "$BASE_CACHE"})
abort "Normalized duplicate languages must be rejected before translation" unless script.include?("Duplicate target language after normalization")
abort "Only verified package versions may invoke translation" unless script.include?("0.4.1|0.2.4")
abort "Each modern language must start from the same immutable snapshot" unless script.include?('cp "$BASE_CACHE" "$language_cache"')
abort "Original cache lookup must not inherit prototype properties" unless script.include?("own(base, namespace)") && script.include?("own(originalNamespace, key)")
abort "Base cache must be validated before the first translator invocation" unless script.index("Original translation cache is malformed") < script.index("pnpm exec polyglot-i18n translate")
abort "Provider context must stay an argument value" unless script.include?('--context "$TRANSLATION_CONTEXT"')

def json_bytes(value)
  "#{JSON.pretty_generate(value)}\n"
end

def modern_output(base, language, fresh_hashes:, marker_update: nil, remove_keys: [])
  output = JSON.parse(JSON.generate(base))
  common = output.fetch("common.json")
  remove_keys.each { |key| common.delete(key) }

  fresh_hashes.each do |key, new_hash|
    previous = common[key]
    default_hash = previous.is_a?(Hash) ? previous.fetch("hash", new_hash) : previous
    old_langs = previous.is_a?(Hash) ? previous.fetch("langs", {}) : {}
    langs = JSON.parse(JSON.generate(old_langs))
    if default_hash == new_hash
      langs.delete(language)
    else
      langs[language] = { "hash" => new_hash }
    end
    entry = { "langs" => langs }
    entry["hash"] = default_hash unless default_hash.nil?
    common[key] = entry
  end

  if marker_update
    previous = common.fetch("markers")
    langs = JSON.parse(JSON.generate(previous.fetch("langs")))
    if marker_update == :clear
      langs.delete(language)
    else
      langs[language] = marker_update
    end
    common["markers"] = { "hash" => previous.fetch("hash"), "langs" => langs }
  end
  output
end

def write_package(project, version)
  package_dir = File.join(project, "node_modules", "polyglot-i18n")
  FileUtils.mkdir_p(File.join(package_dir, "dist"))
  File.write(File.join(package_dir, "package.json"), JSON.generate({
    "name" => "polyglot-i18n",
    "version" => version,
    "type" => "module",
    "main" => "./dist/index.js",
    "exports" => {
      "." => {
        "types" => "./dist/index.d.ts",
        "default" => "./dist/index.js",
      },
    },
    "bin" => { "polyglot-i18n" => "./dist/cli.js" },
  }))
  File.write(File.join(package_dir, "dist", "package.json"), JSON.generate({
    "name" => "unrelated-nested-package",
    "version" => "9.9.9",
  }))
  File.write(File.join(package_dir, "dist", "index.js"), "export {};\n")
  File.write(File.join(package_dir, "dist", "index.d.ts"), "export {};\n")
  File.write(File.join(package_dir, "dist", "cli.js"), "#!/usr/bin/env node\n")
end

def run_translation(target_languages, version:, base_bytes:, outputs:, fail_language: nil, fail_status: "23", context: "synthetic context")
  Dir.mktmpdir("i18n-pipeline-test") do |workdir|
    bin_dir = File.join(workdir, "bin")
    result_dir = File.join(workdir, "results")
    FileUtils.mkdir_p(bin_dir)
    FileUtils.mkdir_p(result_dir)
    write_package(workdir, version)

    cache_path = File.join(workdir, ".polyglot-cache.json")
    File.binwrite(cache_path, base_bytes) if base_bytes

    outputs.each do |language, bytes|
      File.binwrite(File.join(result_dir, "#{language}.json"), bytes)
    end

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
      digest="$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$cache_file")"
      printf '%s\t%s\n' "$language" "$digest" >> "$PNPM_CALL_LOG"
      printf 'polyglot-i18n 0.2.3 (deliberately misleading banner)\n'
      cp "$MOCK_RESULT_DIR/$language.json" "$cache_file"
      if [ "$language" = "$FAIL_LANGUAGE" ]; then exit "$FAIL_STATUS"; fi
    BASH
    File.chmod(0o755, pnpm_path)

    env = {
      "FAIL_LANGUAGE" => fail_language.to_s,
      "FAIL_STATUS" => fail_status.to_s,
      "FORCE_TRANSLATE" => "false",
      "GOOGLE_API_KEY" => "synthetic-provider-key",
      "LOCALES_PATH" => "public/locales",
      "MOCK_RESULT_DIR" => result_dir,
      "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}",
      "PNPM_CALL_LOG" => call_log,
      "RUNNER_TEMP" => workdir,
      "TARGET_LANGUAGES" => target_languages,
      "TRANSLATION_CONTEXT" => context,
    }
    stdout, stderr, status = Open3.capture3(env, SHELL, "-c", SCRIPT, chdir: workdir)
    calls = File.exist?(call_log) ? File.readlines(call_log, chomp: true) : []
    tracked = File.exist?(cache_path) ? File.binread(cache_path) : nil
    executed_sentinel = File.exist?(File.join(workdir, "SHOULD_NOT_EXIST"))
    [stdout + stderr, status, calls, tracked, executed_sentinel]
  end
end

invalid_languages = {
  "" => "Target language code must not be empty",
  " " => "Target language code must not be empty",
  ",sv" => "Target language code must not be empty",
  "sv," => "Target language code must not be empty",
  "sv,,de" => "Target language code must not be empty",
  "sv, ,de" => "Target language code must not be empty",
  "sv\nde" => "Target language code must not contain line breaks",
  "sv, sv" => "Duplicate target language after normalization",
}.freeze

invalid_languages.each do |target_languages, expected_error|
  output, status, calls, = run_translation(target_languages, version: "0.4.1", base_bytes: nil, outputs: {})
  abort "Invalid languages #{target_languages.inspect} must fail validation" if status.success? || !output.include?(expected_error)
  abort "Invalid languages #{target_languages.inspect} must fail before translation" unless calls.empty?
end

languages = %w[fr de es it pt zh ru].freeze
changed_keys = (0..6).map { |index| "changed#{index}" }.freeze
old_hashes = changed_keys.to_h { |key| [key, "old-#{key}"] }
fresh_hashes = changed_keys.to_h { |key| [key, "fresh-#{key}"] }
base = {
  "common.json" => old_hashes.merge(
    "unknown-default" => "known-default",
    "hashless-base" => { "langs" => { "sv" => { "hash" => "old-sv" } } },
    "markers" => {
      "hash" => "marker-default",
      "langs" => {
        "fr" => { "hash" => "fr-before", "state" => "stale" },
        "de" => { "hash" => "de-before", "state" => "accepted" },
        "es" => { "state" => "stale" },
        "it" => { "hash" => "it-before", "state" => "stale" },
        "pt" => { "hash" => "marker-default", "state" => "accepted" },
        "ru" => { "hash" => "ru-before", "state" => "stale" },
        "sv" => { "hash" => "sv-before", "state" => "accepted" },
      },
    },
    "__proto__" => "old-proto",
    "constructor" => "old-constructor",
    "prototype" => "old-prototype",
    "removedFromEnglish" => "removed-hash",
  ),
  "unrelated.json" => { "keep" => "unrelated-hash" },
  "empty-source.json" => { "keep-even-when-source-is-empty" => "empty-source-hash" },
}
base_bytes = json_bytes(base)
outputs = {}
languages.each do |language|
  marker_update = case language
                  when "fr" then :clear
                  when "de" then { "hash" => "de-current", "state" => "accepted" }
                  when "es" then {}
                  when "it" then "stale"
                  when "pt" then { "hash" => "marker-default" }
                  when "zh" then { "hash" => "zh-current", "state" => "stale" }
                  else nil
                  end
  special_hashes = { "__proto__" => "fresh-proto", "constructor" => "fresh-constructor", "prototype" => "fresh-prototype" }
  output = modern_output(base, language, fresh_hashes: fresh_hashes.merge(special_hashes, "hashless-base" => "fresh-hashless"), marker_update: marker_update, remove_keys: ["removedFromEnglish"])
  output.fetch("common.json")["unknown-default"] = { "langs" => {} }
  output.fetch("common.json")["toString"] = "fresh-to-string"
  output["__proto__"] = { "new-key" => "fresh-proto-namespace" }
  outputs[language] = json_bytes(output)
end

output, status, calls, tracked = run_translation(languages.join(","), version: "0.4.1", base_bytes: base_bytes, outputs: outputs)
abort "Seven 0.4.1 language runs must succeed" unless status.success?
abort "All seven languages must be invoked once" unless calls.map { |call| call.split("\t", 2).first } == languages
expected_digest = Digest::SHA256.hexdigest(base_bytes)
abort "Every 0.4.1 invocation must start from identical original bytes" unless calls.all? { |call| call.split("\t", 2).last == expected_digest }
merged = JSON.parse(tracked)
changed_keys.each do |key|
  record = merged.fetch("common.json").fetch(key)
  abort "Default provenance must remain old for #{key}" unless record.fetch("hash") == old_hashes.fetch(key)
  languages.each do |language|
    abort "Fresh per-language provenance missing for #{language}/#{key}" unless record.fetch("langs").fetch(language).fetch("hash") == fresh_hashes.fetch(key)
  end
  abort "Untouched language must retain old provenance for #{key}" unless record.fetch("hash") == old_hashes.fetch(key)
end
abort "Removed English keys must be pruned" if merged.fetch("common.json").key?("removedFromEnglish")
abort "Unrelated namespaces must be preserved" unless merged.fetch("unrelated.json") == base.fetch("unrelated.json")
abort "An empty English namespace must retain the CLI's original cache" unless merged.fetch("empty-source.json") == base.fetch("empty-source.json")
unknown_default = merged.fetch("common.json").fetch("unknown-default")
abort "Unknown active provenance must override, not fall back to, the old default" unless unknown_default.fetch("hash") == "known-default" && languages.all? { |language| unknown_default.fetch("langs").fetch(language).empty? }
hashless_base = merged.fetch("common.json").fetch("hashless-base")
abort "A pre-existing hashless base must remain absent while preserving untouched sv" unless !hashless_base.key?("hash") && hashless_base.fetch("langs").fetch("sv") == { "hash" => "old-sv" } && languages.all? { |language| hashless_base.fetch("langs").fetch(language).fetch("hash") == "fresh-hashless" }
absent_special_key = merged.fetch("common.json").fetch("toString")
abort "An absent inherited-name key must be treated as new data" unless !absent_special_key.key?("hash") && languages.all? { |language| absent_special_key.fetch("langs").fetch(language).fetch("hash") == "fresh-to-string" }
absent_special_namespace = merged.fetch("__proto__").fetch("new-key")
abort "An absent inherited-name namespace must be treated as new data" unless !absent_special_namespace.key?("hash") && languages.all? { |language| absent_special_namespace.fetch("langs").fetch(language).fetch("hash") == "fresh-proto-namespace" }
markers = merged.fetch("common.json").fetch("markers")
abort "The active successful stale marker must clear" if markers.fetch("langs").key?("fr")
abort "Accepted state must survive the active language result" unless markers.fetch("langs").fetch("de") == { "hash" => "de-current", "state" => "accepted" }
abort "Hashless state must remain an explicit override" unless markers.fetch("langs").fetch("es").empty?
it_state = markers.fetch("langs").fetch("it")
abort "Legacy shorthand stale state must survive" unless it_state == "stale" || it_state == { "state" => "stale" }
abort "A record equal to the original default must be omitted" if markers.fetch("langs").key?("pt")
abort "Other languages' stale and accepted markers must remain unchanged" unless markers.fetch("langs").fetch("ru") == base.fetch("common.json").fetch("markers").fetch("langs").fetch("ru") && markers.fetch("langs").fetch("sv") == base.fetch("common.json").fetch("markers").fetch("langs").fetch("sv")
%w[__proto__ constructor prototype].each do |key|
  record = merged.fetch("common.json").fetch(key)
  abort "Special cache key #{key} must remain data" unless record.fetch("hash") == base.fetch("common.json").fetch(key) && languages.all? { |language| record.fetch("langs").fetch(language).fetch("hash") == "fresh-#{key == "__proto__" ? "proto" : key}" }
end

repeat_outputs = languages.to_h { |language| [language, tracked] }
_repeat_output, repeat_status, repeat_calls, repeated_cache = run_translation(languages.join(","), version: "0.4.1", base_bytes: tracked, outputs: repeat_outputs)
abort "A repeat run over current per-language provenance must remain stable" unless repeat_status.success? && JSON.parse(repeated_cache) == merged
abort "A repeat run must pass the accumulated cache unchanged to each language" unless repeat_calls.all? { |call| call.split("\t", 2).last == Digest::SHA256.hexdigest(tracked) }

new_key_outputs = languages.to_h do |language|
  [language, json_bytes({ "common.json" => { "newKey" => "new-key-hash" } })]
end
_output, status, calls, tracked = run_translation(languages.join(","), version: "0.4.1", base_bytes: nil, outputs: new_key_outputs)
abort "An empty baseline must run every language" unless status.success? && calls.length == languages.length
new_key_record = JSON.parse(tracked).fetch("common.json").fetch("newKey")
abort "A new key must not mint a default hash for unrun locales" unless !new_key_record.key?("hash") && languages.all? { |language| new_key_record.fetch("langs").fetch(language).fetch("hash") == "new-key-hash" }
abort "An empty baseline must be passed unchanged to every language" unless calls.all? { |call| call.split("\t", 2).last == Digest::SHA256.hexdigest("{}\n") }

legacy_base = { "common.json" => { "old" => "old-hash" }, "unrelated.json" => { "keep" => "keep-hash" } }
legacy_outputs = languages.to_h do |language|
  result = { "common.json" => { "old" => "new-hash" }, "unrelated.json" => { "keep" => "keep-hash" } }
  result = { "unrelated.json" => result.fetch("unrelated.json"), "common.json" => result.fetch("common.json") } if language == "de"
  [language, json_bytes(result)]
end
legacy_bytes = json_bytes(legacy_base)
banner_output, status, calls, tracked = run_translation(languages.join(","), version: "0.2.4", base_bytes: legacy_bytes, outputs: legacy_outputs)
abort "The legacy 0.2.4 cache path must succeed" unless status.success?
abort "The misleading CLI banner must not determine cache mode" unless banner_output.include?("0.2.3") && JSON.parse(tracked) == JSON.parse(legacy_outputs.fetch(languages.last))
abort "Legacy output must remain bare-string compatible" unless JSON.parse(tracked).fetch("common.json").values.all? { |entry| entry.is_a?(String) }

[
  ["0.4.1", json_bytes({ "common.json" => { "partial" => { "hash" => "old", "langs" => { "fr" => { "hash" => "new" } } } } })],
  ["0.2.4", json_bytes({ "common.json" => { "partial" => "falsely-fresh-even-on-failure" } })],
].each do |version, failed_output|
  original = json_bytes({ "common.json" => { "partial" => "old-hash" } })
  failure_results = { "fr" => failed_output, "de" => failed_output }
  _failure_output, failed_status, failed_calls, failed_tracked = run_translation("fr,de", version: version, base_bytes: original, outputs: failure_results, fail_language: "fr", fail_status: "29")
  abort "A failed #{version} translation must preserve its exit status" unless failed_status.exitstatus == 29
  abort "A failed #{version} translation must stop before later languages" unless failed_calls.map { |call| call.split("\t", 2).first } == ["fr"]
  abort "A failed #{version} translation must preserve tracked cache bytes" unless failed_tracked == original
end

[
  ["0.4.1", json_bytes({ "common.json" => { "partial" => { "hash" => "old", "langs" => { "fr" => { "hash" => "fr-fresh" } } } } })],
  ["0.2.4", json_bytes({ "common.json" => { "partial" => "fr-fresh" } })],
].each do |version, first_success|
  original = json_bytes({ "common.json" => { "partial" => "old-hash" } })
  failure_results = {
    "fr" => first_success,
    "de" => json_bytes({ "common.json" => { "partial" => version == "0.4.1" ? { "hash" => "old-hash", "langs" => { "de" => { "state" => "stale" } } } : "false-fresh-on-failure" } }),
    "es" => first_success,
  }
  _failure_output, failed_status, failed_calls, failed_tracked = run_translation("fr,de,es", version: version, base_bytes: original, outputs: failure_results, fail_language: "de", fail_status: "31")
  abort "A second-language #{version} failure must preserve its exit status" unless failed_status.exitstatus == 31
  abort "A second-language #{version} failure must stop before third language" unless failed_calls.map { |call| call.split("\t", 2).first } == %w[fr de]
  abort "A second-language #{version} failure must preserve exact tracked bytes" unless failed_tracked == original
end

_failure_output, failed_status, failed_calls, absent_tracked, = run_translation(
  "fr,de",
  version: "0.4.1",
  base_bytes: nil,
  outputs: {
    "fr" => json_bytes({ "common.json" => { "partial" => "unsafe-current-hash" } }),
    "de" => json_bytes({ "common.json" => { "partial" => "unsafe-current-hash" } }),
  },
  fail_language: "fr",
  fail_status: "29",
)
abort "A failed first translation must preserve cache absence" unless failed_status.exitstatus == 29 && failed_calls.length == 1 && absent_tracked.nil?

original = json_bytes({ "common.json" => { "unchanged" => "original-hash" } })
malformed_outputs = { "fr" => "{broken", "de" => json_bytes({ "common.json" => { "unchanged" => "original-hash" } }) }
_failure_output, status, calls, tracked = run_translation("fr,de", version: "0.4.1", base_bytes: original, outputs: malformed_outputs)
abort "Malformed cache output must fail after successful language calls" if status.success? || calls.length != 2
abort "Malformed cache output must not replace tracked bytes" unless tracked == original

invalid_schema = json_bytes({ "common.json" => { "key" => { "hash" => "h", "langs" => "not-an-object" } } })
_failure_output, status, _calls, tracked = run_translation("fr", version: "0.4.1", base_bytes: original, outputs: { "fr" => invalid_schema })
abort "Malformed cache schema must be rejected" if status.success?
abort "Malformed cache schema must not replace tracked bytes" unless tracked == original

malformed_base = "{broken-original-cache"
_failure_output, status, calls, tracked = run_translation("fr,de", version: "0.4.1", base_bytes: malformed_base, outputs: {})
abort "Malformed modern base must fail before provider calls" if status.success? || !calls.empty?
abort "Malformed modern base bytes must remain unchanged" unless tracked == malformed_base

rich_legacy_base = json_bytes({ "common.json" => { "rich" => { "hash" => "h", "langs" => {} } } })
_failure_output, status, calls, tracked = run_translation("fr,de", version: "0.2.4", base_bytes: rich_legacy_base, outputs: {})
abort "Legacy 0.2.4 must reject a rich base before provider calls" if status.success? || !calls.empty?
abort "Legacy rich-base rejection must preserve tracked bytes" unless tracked == rich_legacy_base

inconsistent_outputs = {
  "fr" => json_bytes({ "common.json" => { "one" => "hash" } }),
  "de" => json_bytes({ "common.json" => { "two" => "hash" } }),
}
_failure_output, status, _calls, tracked = run_translation("fr,de", version: "0.4.1", base_bytes: original, outputs: inconsistent_outputs)
abort "Inconsistent cache keys must be rejected" if status.success?
abort "Inconsistent cache keys must not replace tracked bytes" unless tracked == original

legacy_rich_outputs = {
  "fr" => json_bytes({ "common.json" => { "key" => { "hash" => "h", "langs" => {} } } }),
  "de" => json_bytes({ "common.json" => { "key" => { "hash" => "h", "langs" => {} } } }),
}
_failure_output, status, _calls, tracked = run_translation("fr,de", version: "0.2.4", base_bytes: original, outputs: legacy_rich_outputs)
abort "Legacy 0.2.4 must reject rich outputs" if status.success?
abort "Legacy rich-output rejection must preserve tracked bytes" unless tracked == original

legacy_inconsistent_outputs = {
  "fr" => json_bytes({ "common.json" => { "key" => "fr-hash" } }),
  "de" => json_bytes({ "common.json" => { "key" => "de-hash" } }),
}
_failure_output, status, _calls, tracked = run_translation("fr,de", version: "0.2.4", base_bytes: original, outputs: legacy_inconsistent_outputs)
abort "Legacy 0.2.4 must reject inconsistent all-bare outputs" if status.success?
abort "Legacy inconsistency must preserve tracked bytes" unless tracked == original

_output, status, calls, tracked = run_translation("fr", version: "0.5.0", base_bytes: original, outputs: {})
abort "Unknown package versions must fail before translation" if status.success? || !calls.empty?
abort "Unknown package versions must leave tracked bytes unchanged" unless tracked == original

sentinel = "safe context\n$(touch SHOULD_NOT_EXIST)\n::add-mask::do-not-log"
single_output = { "fr" => json_bytes({ "common.json" => { "key" => "hash" } }) }
output, status, calls, _cache, executed_sentinel = run_translation("fr", version: "0.4.1", base_bytes: nil, outputs: single_output, context: sentinel)
abort "Multiline context must remain one argument without execution" unless status.success? && calls.length == 1
abort "Context or provider-key sentinels must not appear or execute" if output.include?(sentinel) || output.include?("do-not-log") || output.include?("synthetic-provider-key") || executed_sentinel

puts "i18n pipeline cache aggregation: PASS (#{languages.length} modern locales, legacy format, provenance, empty-cache isolation, failure atomicity)"
