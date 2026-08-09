#!/usr/bin/env python3
import json
import sys
import urllib.request


output_path = sys.argv[1]
payload = {
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "Reply with only OK."}],
    "temperature": 0,
    "max_tokens": 8,
    "stream": False,
}
request = urllib.request.Request(
    "http://127.0.0.1:17353/v1/chat/completions",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(request, timeout=120) as response:
    body = json.load(response)
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(body, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(body["choices"][0]["message"]["content"])
