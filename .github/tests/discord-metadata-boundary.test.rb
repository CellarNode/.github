workflow_path = File.expand_path("../workflows/discord-notify.yaml", __dir__)
workflow = File.read(workflow_path)

abort "Discord metadata must ignore non-bot comments" unless workflow.include?("c.user?.login !== 'github-actions[bot]'")
abort "Discord metadata must validate allowed keys" unless workflow.include?("allowedMetadataKeys")
abort "Discord metadata must validate Discord snowflake IDs" unless workflow.include?("discordSnowflake")
abort "Trusted GitHub comment ID must override parsed metadata" unless workflow.include?("return { ...metadata, commentId: c.id };")
abort "Parsed metadata must never override trusted comment ID" if workflow.include?("return { commentId: c.id, ...JSON.parse(json) };")

puts "Discord metadata boundary passed"
