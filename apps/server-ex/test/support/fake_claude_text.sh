#!/bin/sh
# Fake `claude -p --output-format json` for text generation tests.
cat > /dev/null
printf '{"type":"result","structured_output":{"subject":"Add greeting file.","body":"- says hello","branch":"add greeting"}}\n'
