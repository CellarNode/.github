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
abort "Translation must process one target language at a time" unless script.include?('for language in "${languages[@]}"; do')
abort "Every language must start from the original cache" unless script.include?('cp "$BASE_CACHE" "$language_cache"')
abort "CLI must receive one target language per invocation" unless script.include?('--output-languages "$language"')
abort "Each language must receive its own cache copy" unless script.include?('--cache-file "$language_cache"')
abort "Updated source hashes must return to the tracked cache" unless script.include?('cp "$updated_cache" .polyglot-cache.json')

puts "i18n pipeline per-language cache isolation: PASS"
