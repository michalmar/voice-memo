import json
import os
import sys

os.environ["VOICEPROMPT_ENVIRONMENT"] = "test"
os.environ["VOICEPROMPT_ALLOW_DEVELOPMENT_AUTH"] = "true"
sys.path.insert(0, "backend/src")

from voiceprompt.app import app

with open("api/openapi.json", "w", encoding="utf-8") as output:
    json.dump(app.openapi(), output, indent=2)
    output.write("\n")

