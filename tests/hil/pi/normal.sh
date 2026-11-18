#!/bin/bash
# 정상 동작 60초 (SWR-04 · 11 · 31 · 34)
source "$(dirname "$0")/common.sh"
trap stop_all EXIT

start_app
sleep 60
