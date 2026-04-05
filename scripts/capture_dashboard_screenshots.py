#!/usr/bin/env python3
"""
Drive the local dashboard in a headless browser (Playwright) and save PNGs under docs/screenshots/.

Prerequisites (once per machine):
  pip3 install --user "playwright>=1.40"
  python3 -m playwright install chromium

Usage (from repo root):
  ./scripts/capture-dashboard-screenshots.sh

Or with an already-running dashboard on 127.0.0.1:PORT:
  CURSOR_DASH_SCREENSHOT_BASE=http://127.0.0.1:58741 ./scripts/capture-dashboard-screenshots.sh
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "docs" / "screenshots"
SETUP = REPO / "setup"


def _wait_http(url: str, timeout: float = 180.0) -> None:
    """Poll until dashboard responds with HTTP 200 or timeout."""
    deadline = time.time() + timeout
    last_err: Exception | None = None
    while time.time() < deadline:
        try:
            with urlopen(url, timeout=10) as r:
                code = getattr(r, "status", None)
                if code is None:
                    code = r.getcode()
                if code == 200:
                    return
                last_err = RuntimeError(f"Unexpected HTTP status from {url}: {code}")
        except (URLError, OSError) as e:
            last_err = e
        time.sleep(1.0)
    if last_err is not None:
        raise RuntimeError(f"Dashboard not reachable at {url}: {last_err}") from last_err
    raise RuntimeError(f"Dashboard not reachable at {url}")


def _free_port(port: int) -> None:
    subprocess.run(
        [
            "bash",
            "-c",
            f"lsof -nP -iTCP:{port} -sTCP:LISTEN -t 2>/dev/null | xargs kill -9 2>/dev/null; true",
        ],
        check=False,
    )
    time.sleep(0.4)


def _start_dashboard(port: int) -> subprocess.Popen[bytes]:
    _free_port(port)
    env = os.environ.copy()
    env["CURSOR_DASH_OPEN_BROWSER"] = "0"
    env["CURSOR_DASH_HOST"] = "127.0.0.1"
    env["CURSOR_DASH_PORT"] = str(port)
    env["PYTHONUNBUFFERED"] = "1"
    # English-first README assets
    env["CURSOR_DASH_LANG"] = "en"
    return subprocess.Popen(
        ["/bin/bash", str(SETUP)],
        cwd=str(REPO),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def _stop_process_group(proc: subprocess.Popen[bytes]) -> None:
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main() -> int:
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print(
            "Playwright is not installed. Run:\n"
            '  pip3 install --user "playwright>=1.40"\n'
            "  python3 -m playwright install chromium",
            file=sys.stderr,
        )
        return 1

    preset = os.environ.get("CURSOR_DASH_SCREENSHOT_BASE", "").strip().rstrip("/")
    proc: subprocess.Popen[bytes] | None = None
    port = 58741

    if preset:
        base = preset
    else:
        if not SETUP.is_file():
            print(f"Missing {SETUP}", file=sys.stderr)
            return 1
        proc = _start_dashboard(port)
        base = f"http://127.0.0.1:{port}"

    try:
        _wait_http(f"{base}/")
    except RuntimeError as e:
        print(e, file=sys.stderr)
        if proc:
            _stop_process_group(proc)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)

    def snap(page, name: str, full: bool = False) -> None:
        path = OUT / name
        page.screenshot(path=str(path), full_page=full)
        print(path)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            viewport={"width": 1440, "height": 900},
            device_scale_factor=1,
        )
        page = context.new_page()

        # Cookie + redirect: show English UI in one navigation chain
        page.goto(
            f"{base}/?lang=en",
            wait_until="domcontentloaded",
            timeout=180_000,
        )
        page.wait_for_timeout(900)
        snap(page, "01-dashboard-overview-en.png")
        snap(page, "dashboard-en-full.png", full=True)

        # Quick check → global status cards
        qc = page.locator("details.quick-check summary").first
        try:
            qc.click(timeout=5000)
            page.wait_for_timeout(450)
        except Exception:
            pass
        snap(page, "02-quick-check-expanded.png")

        # “Other projects” / all workspaces fold
        fold = page.locator("details#ws-all-fold summary.ws-section-fold-sum").first
        try:
            fold.click(timeout=5000)
            page.wait_for_timeout(450)
        except Exception:
            pass
        snap(page, "03-other-projects-expanded.png")

        # Workspace actions fold (single D screen only; no secondary detail screen)
        rf = page.locator("details.repo-fold summary.repo-fold-summary").first
        try:
            rf.click(timeout=5000)
            page.wait_for_timeout(500)
        except Exception:
            pass
        snap(page, "04-workspace-actions-expanded.png")

        browser.close()

    if proc:
        _stop_process_group(proc)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
