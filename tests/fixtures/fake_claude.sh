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
        printf '%s\n' '{"loggedIn":true,"authMethod":"apiKey","apiProvider":"firstParty"}'
        ;;
      loggedout)
        printf '%s\n' '{"loggedIn":false}'
        exit 1
        ;;
      *)
        printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"dev@example.com","subscriptionType":"team"}'
        ;;
    esac
    exit 0
    ;;
esac

# One-shot agent mode: `claude -p <prompt>` without --input-format. Replays a short
# tool-using transcript and exits.
case " $* " in
  *" --input-format "*) ;;
  *)
    if [ "$FAKE_CLAUDE_MODE" = "agent-fail" ]; then
      printf '%s\n' '{"type":"system","subtype":"init","model":"claude-sonnet-5","tools":["Read"]}'
      printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Reached max turns","num_turns":12}'
      exit 0
    fi
    printf '%s\n' '{"type":"system","subtype":"init","model":"claude-sonnet-5","tools":["Read","Edit","Grep","Glob"]}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking at the diagnostic."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"src/app.ts"}}]}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"..."}]}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"src/app.ts","old_string":"user.name","new_string":"user?.name"}}]}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Added optional chaining so `user` can be undefined.\nNo other lines changed."}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"Added optional chaining so `user` can be undefined.\nNo other lines changed.","usage":{"input_tokens":50,"output_tokens":20},"total_cost_usd":0.001,"num_turns":3}'
    exit 0
    ;;
esac

INIT=""
while IFS= read -r line; do
  case "$line" in
    *'"subtype":"interrupt"'*)
      printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"x","response":{"still_queued":[]}}}'
      printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":null,"usage":{"input_tokens":5,"output_tokens":0}}'
      ;;
    *'"type":"user"'*)
      if [ -z "$INIT" ]; then
        printf '%s\n' '{"type":"system","subtype":"init","model":"claude-haiku-4-5-20251001","tools":[]}'
        INIT=1
      fi
      printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"return "}}}'
      if [ "$FAKE_CLAUDE_MODE" != "hang" ]; then
        printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"value"}}}'
        printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"return value","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.0001}'
      fi
      ;;
  esac
done
