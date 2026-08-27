workflow_path = File.expand_path("../workflows/discord-notify.yaml", __dir__)
workflow = File.read(workflow_path)

abort "Discord metadata must ignore non-bot comments" unless workflow.include?("c.user?.login !== 'github-actions[bot]'")
abort "Discord metadata must validate allowed keys" unless workflow.include?("allowedMetadataKeys")
abort "Discord metadata must validate Discord snowflake IDs" unless workflow.include?("discordSnowflake")
abort "Trusted GitHub comment ID must override parsed metadata" unless workflow.include?("return { ...metadata, commentId: c.id };")
abort "Parsed metadata must never override trusted comment ID" if workflow.include?("return { commentId: c.id, ...JSON.parse(json) };")

deploy_metadata = workflow[/listPullRequestsAssociatedWithCommit[\s\S]*?\/\/ Get commit message/]
abort "Deploy metadata must ignore non-bot comments" unless deploy_metadata&.include?("c.user?.login !== 'github-actions[bot]'")
abort "Deploy metadata must use the shared parser" unless deploy_metadata&.include?("const metadata = parseMetadata(c.body ?? '');")
abort "Deploy metadata must continue past invalid or incomplete comments" unless deploy_metadata&.include?("if (metadata?.threadId) {")
abort "Deploy metadata must not parse marker fragments directly" if deploy_metadata&.include?("split(META_TAG)")

puts "Discord metadata boundary passed"
