#!/usr/bin/env bash
# Stand-in for "the replica boots itself": a spawned HOST process drops a marker proving it ran.
echo "replicated at $(date -u +%FT%TZ) pid $$" > BOOT_OK
