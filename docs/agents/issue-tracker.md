# Issue tracker: Linear

Issues and specs for this repo live in Linear. Use the Linear MCP server (`linear-server`, tools prefixed `mcp__linear-server__`) for all operations.

If the Linear MCP tools are unavailable or return an authentication error, tell the user to log in via `/mcp` and stop. Do not fall back to another tracker.

## Location

- **Team**: TBD. On first use, run `list_teams`, ask the user which team to use, and record it here (name and key).
- **Project**: `interview-recorder`. If it doesn't exist yet, propose creating it with `save_project` and create it only after the user approves.

## Conventions

- **Create an issue**: `save_issue` without `id`, with the team and the `interview-recorder` project set.
- **Update an issue**: `save_issue` with `id`.
- **Read an issue**: `get_issue` with the identifier (e.g. `ABC-123`) or URL.
- **List issues**: `list_issues` filtered by the `interview-recorder` project, and by label/state as needed.
- **Comment on an issue**: `save_comment`.
- **Apply / remove labels**: `save_issue` with the updated label set. Check existing labels with `list_issue_labels` first; use existing labels rather than creating duplicates.
- **Sub-issues**: set the parent via `save_issue` (`parentId`).
- **Blocking**: Linear's native "blocked by" relation. A ticket is startable when it has no open (not Done / Canceled) blockers.
- **Close**: post the explanation with `save_comment` first, then move the issue to Done (completed) or Canceled (not actioned).
- **Titles and descriptions**: follow the `linear-issue` skill (start with a verb, keep it short, no user-story format).

## When a skill says "publish to the issue tracker"

Create a Linear issue in the `interview-recorder` project.

## When a skill says "fetch the relevant ticket"

Read it with `get_issue`. The user will normally pass the identifier (e.g. `ABC-123`) or the URL.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single parent issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: a sub-issue of the map. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`).
- **Blocking**: see **Blocking** under Conventions.
- **Frontier query**: list the map's open sub-issues, drop any with an open blocker or an assignee; first in map order wins.
- **Claim**: assign the issue to the user (`save_issue` with the assignee), the session's first write.
- **Resolve**: `save_comment` with the answer, move the issue to Done, then append a context pointer (gist + link) to the map's Decisions-so-far.
