#!/usr/bin/env bash
# summary: Run a shell thing
# group: Greeting
# flag: label short=l repeatable -- A label
# flag: level kind=number default=2 -- A level
# arg: target required -- What to hit
# requires: workspace
# remote: false
echo "$DEV_FLAG_LEVEL" "$1"
