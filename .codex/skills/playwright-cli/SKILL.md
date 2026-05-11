---
name: playwright-cli
description: Record browser proof videos with the Microsoft @playwright/cli global command. Use when a task needs a reviewable walkthrough video of a route or UI flow.
allowed-tools: Bash(playwright-cli:*)
---

# Playwright CLI Proof Video Recording

This skill only covers recording proof videos. It assumes the Microsoft `@playwright/cli` command is already available globally as `playwright-cli`.

Before recording, verify the command exposes the video API:

```bash
playwright-cli --version
playwright-cli video-start --help
```

## Basic proof video flow

Use a named session so concurrent agent runs do not collide:

```bash
SESSION="${PLAYWRIGHT_CLI_SESSION:-symphony-proof}"
VIDEO="proof-video.webm"
URL="http://127.0.0.1:4000/"

playwright-cli -s="$SESSION" close || true
playwright-cli -s="$SESSION" open "$URL"
playwright-cli -s="$SESSION" video-start "$VIDEO" --size 1280x720
playwright-cli -s="$SESSION" video-chapter "Loaded target route" --description="Verify the starting page" --duration=2000
playwright-cli -s="$SESSION" snapshot --filename="proof-start.yml"
# Drive the requested user flow here, for example:
# playwright-cli -s="$SESSION" click "getByRole('link', { name: 'Kanban' })"
playwright-cli -s="$SESSION" video-chapter "Verified expected state" --description="Show the final page" --duration=2000
playwright-cli -s="$SESSION" snapshot --filename="proof-finish.yml"
playwright-cli -s="$SESSION" video-stop
playwright-cli -s="$SESSION" close
```

Attach the resulting `.webm` proof video to the ticket or PR review context.

## Rich walkthroughs with `run-code`

For user-facing proof, prefer one small temporary script and `run-code` so the video has deliberate pauses, chapters, and visual callouts:

```js
async page => {
  await page.screencast.start({ path: 'proof-video.webm', size: { width: 1280, height: 720 } });
  await page.goto('http://127.0.0.1:4000/');

  await page.screencast.showChapter('Root route', {
    description: 'The route loads and displays the expected dashboard.',
    duration: 2000,
  });

  await page.getByRole('link', { name: 'Kanban' }).click();
  await page.waitForLoadState('networkidle');

  await page.screencast.showChapter('Kanban route', {
    description: 'The linked Kanban view is reachable and rendered.',
    duration: 2000,
  });

  await page.screencast.stop();
}
```

Run it with:

```bash
playwright-cli -s="$SESSION" open about:blank
playwright-cli -s="$SESSION" run-code --filename proof-script.js
playwright-cli -s="$SESSION" close
```

Temporary proof scripts, snapshots, and videos should not be committed unless the ticket explicitly asks for committed media.
