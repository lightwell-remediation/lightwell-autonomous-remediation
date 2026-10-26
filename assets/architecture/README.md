# Architecture Diagram — Milestone 2

Target architecture with Milestone 2 done: the components, where they run and
how they integrate. The order of the steps is not here — that is the sequence
diagram of Act 3 ([demo-narrative.md](../../docs/demo-narrative.md)).

## Files

- [`../architecture-m2.png`](../architecture-m2.png) — the exported diagram (Act 2).
- `lightwell-architecture-diagram.drawio` — the source. Self-contained: every
  icon is embedded, so it opens anywhere.
- `assets/icons/` — the icons embedded in the source, kept for future edits.

## Editing

Open the `.drawio` in [app.diagrams.net](https://app.diagrams.net) or draw.io
Desktop, then export:

```bash
xvfb-run -a drawio.AppImage -x -f png --width 2400 \
  -o ../architecture-m2.png lightwell-architecture-diagram.drawio
```

## Known gaps

- The sandbox icon is OpenShift sandboxed containers'; the sandbox drawn is
  OpenShell. Replace it if an OpenShell or Agent Sandbox icon is published.
- TPA has no documented Developer Hub plugin; it sits inside the Developer Hub
  box because Red Hat Advanced Developer Suite ships them together.
- TPA's vulnerability lookup against Lightwell is not yet in a spec.
