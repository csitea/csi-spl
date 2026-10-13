#!/bin/bash
# Mock lane-map.sh --json output for testing
cat <<JSON
{
  "load": [
    {"box": "tnk", "live": true, "busy": 0, "mem_kb": 8192000},
    {"box": "sat", "live": true, "busy": 1, "mem_kb": 4096000},
    {"box": "lde", "live": true, "busy": 2, "mem_kb": 2048000}
  ]
}
JSON
