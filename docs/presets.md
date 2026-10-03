# Presets

What a preset file holds, how one builds on another, and where presets are
looked for. Split out of the [README](../README.md), which lists the ones that
ship.

`base-vhs` is also on the list but is not a look: it is the shared tape chain
with the damage dialled low, for other presets to `extends` rather than
restate. `--list-presets` shows it; picking it gives a very mild result, which
is what it is for.

A preset is a YAML file naming effects and their parameters:

```yaml
name: vhs-decay
title: Third-generation dub
extends: base-vhs          # optional; merged underneath this file
output:
  max_dim: 1600
effects:
  tracking:  { bands: 6, displacement: 55 }
  scanlines: { opacity: 0.3, spacing: 3 }
  vignette:  { enabled: 0 }        # switch off something inherited
order: [downsample, tracking, scanlines]   # optional
```

`extends` merges per effect, so a child overrides only the parameters it
mentions. `--set` always wins over the file, so a preset is a starting point
rather than a commitment:

```bash
glitchvape -p vhs-decay --set tracking.bands=12 --set grain.amount=0.2 in.heic
```

Presets are looked for in `$GLITCHVAPE_PRESETS` if it is set, then in
`~/.local/share/glitchvape/presets` — which is where the window's **Save as
preset…** puts one, so a preset of yours shadows a shipped one of the same
name without replacing it — then `./presets`, then the presets that shipped,
and last any a plug-in brought.

In the window a preset is one of the two things **+** offers on the Image
page. It is the only thing there that *replaces* what is already in the
pipeline, which the chooser says before you press Load, and the name is
recorded — so `Copy command line` still comes back as `-p vhs-decay` with
whatever you changed on top.
