#!/usr/bin/env python3
"""Disposable protocol peer that deliberately stops reading its input pipe."""
import json
import sys
import time

request = json.loads(sys.stdin.readline())
print(json.dumps({"id": request["id"], "result": {}}), flush=True)
time.sleep(30)
