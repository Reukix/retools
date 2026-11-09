#!/usr/bin/env python3
"""Prepare synthetic attachments only in the dedicated Retools Review simulator."""
from pathlib import Path
import subprocess, json, uuid, datetime, shutil, argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--simulator", default="3E16A60D-76BA-463E-AD21-3B8E5E4169D4")
parser.add_argument("--empty-workspace", action="store_true", help="Allow a newly created simulator with no workspace data")
arguments = parser.parse_args()
simulator = arguments.simulator
repo = Path(__file__).resolve().parents[1]
root = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", simulator, "dev.retools.ios", "data"], text=True).strip())
support = root / "Library/Application Support/Retools"
state_file = support / "workspace.json"
workspace = json.loads(state_file.read_text()) if state_file.exists() else {}
if arguments.empty_workspace:
    assert not any(workspace.get(key) for key in ["packages", "identities", "containerApps", "plugins"]), "Use a new empty review simulator"
else:
    assert workspace.get("packages") and all(p["name"] == "测试应用" for p in workspace["packages"]), "Use the dedicated synthetic workspace"
subprocess.run(["xcrun", "simctl", "terminate", simulator, "dev.retools.ios"], capture_output=True)
folder = support / "AI"
folder.mkdir(parents=True, exist_ok=True)
for name in ["configuration.json", "conversations.json"]:
    if (folder / name).exists(): shutil.copy2(folder / name, folder / (name + ".review-backup"))
identifier = "44444444-4444-4444-8444-444444444444"
files = folder / "Attachments"
files.mkdir(exist_ok=True)
app = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", simulator, "dev.retools.ios", "app"], text=True).strip())
image = app / "AppIcon60x60@2x.png"
assert image.exists(), "Build and install the review app before seeding"
destination = files / (identifier + ".png")
shutil.copy2(image, destination)
model_id = "gpt-image-2.6-sunburst"
review_models = [
    {"id": model_id, "name": "GPT Image · 界面示例", "outputModalities": ["image"]},
    {"id": "anthropic/claude-sonnet-4-5", "name": "Claude · 界面示例"},
    {"id": "google/gemini-2.5-pro", "name": "Gemini · 界面示例"},
    {"id": "deepseek/deepseek-chat", "name": "DeepSeek · 界面示例"},
    {"id": "qwen/Qwen3-235B-A22B", "name": "Qwen · 界面示例"},
    {"id": "x-ai/grok-4", "name": "Grok · 界面示例"},
    {"id": "meta-llama/Llama-3.3-70B-Instruct", "name": "Llama · 界面示例"},
    {"id": "mistralai/codestral-latest", "name": "Mistral · 界面示例"}
]
endpoint = {"address": "https://example.test/v1", "model": model_id, "systemPrompt": "", "maxTokens": 4096, "anthropicVersion": "2023-06-01", "availableModels": review_models}
(folder / "configuration.json").write_text(json.dumps({"provider": "openAI", "openAI": endpoint, "anthropic": endpoint}))
attachment = {"id": identifier, "fileName": destination.name, "name": "生成图片.png", "kind": "image", "mediaType": "image/png", "byteCount": destination.stat().st_size}
now = (datetime.datetime.now(datetime.UTC) - datetime.datetime(2001, 1, 1, tzinfo=datetime.UTC)).total_seconds()
conversation_id = str(uuid.uuid4())
conversation = {"id": conversation_id, "title": "模拟器附件示例", "connection": {"provider": "openAI", "url": "https://example.test/v1/images/generations", "model": model_id, "systemPrompt": "", "maxTokens": 4096, "anthropicVersion": "2023-06-01"}, "updatedAt": now, "messages": [
    {"id": str(uuid.uuid4()), "role": "user", "content": "查看这张示例图片。", "status": "complete"},
    {"id": str(uuid.uuid4()), "role": "assistant", "content": "这张图片仅用于模拟器界面验证。", "status": "complete", "modelLabel": model_id, "attachments": [attachment]}
]}
(folder / "conversations.json").write_text(json.dumps({"currentID": conversation_id, "conversations": [conversation]}))
(root / "Documents/AI Review Notes.txt").write_text("仅用于模拟器导入回归的示例文件。\n")
print("Seeded synthetic AI conversation and attachment; no API request or credential used.")
