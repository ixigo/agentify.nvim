#!/bin/sh
# Fake `claude` CLI used by the test suite. Replays recorded stream-json shapes.
#
# Environment knobs:
#   FAKE_CLAUDE_AUTH=apikey|loggedout   auth status variants (default: subscription)
#   FAKE_CLAUDE_MODE=hang               never finish a turn until interrupted
#   FAKE_CLAUDE_ARGS_FILE=<path>        write argv to this file for assertions

if [ -n "$FAKE_CLAUDE_ARGS_FILE" ]; then
  printf '%s\n' "$@" > "$FAKE_CLAUDE_ARGS_FILE"
fi

case "$1" in
  --version)
    echo "2.1.273 (Claude Code)"
    exit 0
    ;;
  auth)
    case "$FAKE_CLAUDE_AUTH" in
      apikey)
        echo '{"loggedIn":true,"authMethod":"apiKey","apiProvider":"firstParty"}'
        ;;
      loggedout)
        echo '{"loggedIn":false}'
        exit 1
        ;;
      *)
        echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"dev@example.com","subscriptionType":"team"}'
        ;;
    esac
    exit 0
    ;;
esac

INIT=""
while IFS= read -r line; do
  case "$line" in
    *'"subtype":"interrupt"'*)
      echo '{"type":"control_response","response":{"subtype":"success","request_id":"x","response":{"still_queued":[]}}}'
      echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":null,"usage":{"input_tokens":5,"output_tokens":0}}'
      ;;
    *'"type":"user"'*)
      if [ -z "$INIT" ]; then
        echo '{"type":"system","subtype":"init","model":"claude-haiku-4-5-20251001","tools":[]}'
        INIT=1
      fi
      echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"return "}}}'
      if [ "$FAKE_CLAUDE_MODE" != "hang" ]; then
        echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"value"}}}'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"return value","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.0001}'
      fi
      ;;
  esac
done
