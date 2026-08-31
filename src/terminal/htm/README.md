# HTM in Ghostty

Ghostty maps native tabs and splits onto Eternal Terminal's headless multiplexer (`htmd`) when a surface prints the HTM init sequence `ESC[###q`.

## Use

1. Put `htm` and `htmd` on `PATH`, or set `htm-bin-dir` in Ghostty config to the Eternal Terminal build directory.
2. In a Ghostty terminal, run `htm`.
3. Ghostty creates tabs and splits for existing `htmd` panes. New tabs/splits (the usual keybinds) create HTM panes. Closing a split closes that pane.

The original surface stays as the HTM control/debug view:

- Escape — disconnect from `htmd` (daemon keeps running)
- `x` — shut down `htmd`
- `d` — dump multiplexer state to the daemon log

## Config

```
htm-integration = true
htm-bin-dir = /path/to/EternalTerminal/build
```

Set `htm-integration = false` to ignore the init sequence.
