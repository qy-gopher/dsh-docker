"""Exercise the image's browser without downloading or visiting external pages."""

import os
from pathlib import Path
import subprocess
from urllib.parse import quote


environment = dict(os.environ, AGENT_BROWSER_SESSION="dsh-docker-browser-smoke")


def browser(*arguments):
    result = subprocess.run(
        ["agent-browser", *arguments],
        env=environment,
        capture_output=True,
        text=True,
        timeout=45,
    )
    if result.returncode:
        raise RuntimeError(f"agent-browser {arguments[0]} failed: {result.stdout}{result.stderr}")
    return result.stdout.strip()


html = """<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<title>DSH Browser Smoke</title>
<button id="confirm" onclick="document.getElementById('status').textContent='浏览器可用'">确认</button>
<p id="status">等待</p></html>"""
screenshot = Path(os.environ["HOME"]) / "workspaces/default/docker-browser-smoke.png"

try:
    browser("open", "data:text/html;charset=utf-8," + quote(html))
    assert browser("get", "title") == "DSH Browser Smoke"
    assert 'button "确认"' in browser("snapshot", "-i")
    browser("click", "#confirm")
    assert browser("get", "text", "#status") == "浏览器可用"
    browser("screenshot", str(screenshot))
    assert screenshot.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
    print("Browser navigation, Chinese snapshot, interaction and screenshot passed.")
finally:
    browser("close")
