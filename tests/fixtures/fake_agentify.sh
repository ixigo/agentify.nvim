#!/bin/sh
# Fake `agentify` CLI for tests. Answers `query def|refs --symbol X --json --root R`.
#   FAKE_AGENTIFY_DELAY=<seconds>  sleep before answering
#   FAKE_AGENTIFY_ARGS_FILE=<path> append argv for assertions
if [ -n "$FAKE_AGENTIFY_ARGS_FILE" ]; then
  printf '%s\n' "$*" >> "$FAKE_AGENTIFY_ARGS_FILE"
fi
if [ -n "$FAKE_AGENTIFY_DELAY" ]; then
  sleep "$FAKE_AGENTIFY_DELAY"
fi

sub="$2"
symbol=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--symbol" ]; then symbol="$arg"; fi
  prev="$arg"
done

case "$symbol" in
  formatPrice)
    case "$sub" in
      def)
        echo '{"symbol":"formatPrice","ambiguous":false,"definitions":[{"module_id":"util","file_path":"src/util.ts","name":"formatPrice","kind":"function","exported":1,"start_line":2,"end_line":4}]}'
        ;;
      refs)
        echo '{"symbol":"formatPrice","references":[{"kind":"reference","file_path":"src/app.ts","line":1},{"kind":"call","file_path":"src/app.ts","line":3},{"kind":"call","file_path":"src/current.ts","line":9}]}'
        ;;
    esac
    ;;
  *)
    echo '{"symbol":"'"$symbol"'","ambiguous":false,"definitions":[],"references":[]}'
    ;;
esac
