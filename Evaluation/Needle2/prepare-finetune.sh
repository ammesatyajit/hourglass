#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CASES="$SCRIPT_DIR/finetune-cases.jsonl"
TOOLS="$SCRIPT_DIR/hourglass-tools.json"
OUTPUT=${1:-"$SCRIPT_DIR/hourglass-finetune.jsonl"}

jq --slurpfile catalogue "$TOOLS" -c '
  def named($names):
    [$catalogue[0][]
      | select(.name as $name | $names | index($name))
      | {
          name: .name,
          parameters: {
            type: "object",
            properties: (.parameters.properties | with_entries(.value |= del(.description, .maxLength))),
            required: .parameters.required
          }
        }
    ];
  def training_tools($tool):
    if $tool == "search_messages" then named(["search_messages", "read_conversation", "count_messages"])
    elif $tool == "read_conversation" then named(["read_conversation", "search_messages"])
    elif $tool == "count_messages" then named(["count_messages", "search_messages", "first_message"])
    elif $tool == "first_message" then named(["first_message", "search_messages", "count_messages"])
    elif $tool == "top_contacts" then named(["top_contacts", "top_groups", "overview_stats"])
    elif $tool == "top_groups" then named(["top_groups", "top_contacts", "overview_stats"])
    elif $tool == "overview_stats" then named(["overview_stats", "count_messages", "top_contacts"])
    elif $tool == "friends_made_since" then named(["friends_made_since", "search_contacts", "first_message"])
    elif $tool == "plans_in_window" then named(["plans_in_window", "search_messages"])
    elif $tool == "search_contacts" then named(["search_contacts", "search_messages"])
    else named(["search_messages", "search_contacts", "overview_stats"])
    end;
  {
    query: .query,
    tools: training_tools(.tool),
    answers: (if .tool == null then [] else [{name: .tool, arguments: .args}] end),
    reasoning: .reasoning
  }
' "$CASES" > "$OUTPUT"

echo "Wrote $(wc -l < "$OUTPUT" | tr -d " ") Needle2 examples to $OUTPUT"
