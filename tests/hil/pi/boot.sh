#!/bin/bash
# 시작 직후 15초 (SWR-34)
source "$(dirname "$0")/common.sh"
trap stop_all EXIT

start_app
sleep 15
