# Peace

macOS front end for Apple Music with album art visualizers and synced lyrics.

Controls Music.app over Apple Events, so no developer token is needed.

## Modes

- Turntable: record or cover, mesh background, scrolling lyrics.
- Stage: current lyric in full-window type, with the art showing through the letters.
- Halftone: the art as a dot field that reacts to the audio.
- Orbit: the art ringed by spinning spectrum bars, with bass hits rippling out and a swarm that speeds up with the music.
- Constellation: a turning night sky with no lyrics. Stars twinkle with the spectrum, the sky swells gently on the bass, and the vocals draw new constellations syllable by syllable. Track info and controls sit in the bottom corner.

## Menu bar

Peace runs from the menu bar, with no Dock icon. The menu has playback controls, the full player, the mini player and Quit. Frame Rate sets how often Halftone, Orbit and Constellation redraw (30 fps by default); Halve on Battery slows them further on battery or in Low Power Mode.

## Mini player

Floats above other windows, on every Space and over full screen apps. Hover to expand, drag to move. It shrinks toward the nearest screen corner. `OPEN` or the menu bar icon returns to the full player.

Mini Player Style in the menu picks Disc (a spinning record with a spectrum ring) or Sleeve (the cover over its own blurred art, with spectrum bars that fill in as the song plays).

## Themes

Liquid Glass or Mono, in every mode.

## Install

Needs macOS 26 and Xcode 26. Builds from source and installs to `/Applications`, or `~/Applications` if that isn't writable.

```sh
curl -fsSL https://gitlab.com/q_welpl/peacemusic/-/raw/main/install.sh | bash
```

To remove it:

```sh
curl -fsSL https://gitlab.com/q_welpl/peacemusic/-/raw/main/install.sh | bash -s -- --uninstall
```

## Develop

```sh
./scripts/build.sh --run
```

The app lands in `build/Peace.app`. On first launch, allow Peace to control Music. If you miss the prompt, go to System Settings > Privacy & Security > Automation.

`open build/Peace.app --args --demo` runs with a sample track and no Music connection.

## Keys

| Key | Action |
| --- | --- |
| Space | Play / pause |
| Left / Right | Previous / next |
| M | Switch mode (Turntable / Stage / Halftone / Orbit / Constellation) |
| T | Switch theme (Liquid Glass / Mono) |
| L | Show or hide lyrics (Turntable) |
| V | Switch between vinyl and cover (Turntable) |
| [ / ] | Shift this song's lyrics 0.1s later / earlier |
| \ | Reset this song's lyric timing |
| F | Full screen |
| P or Cmd-Shift-M | Mini player |

## Audio

Halftone, Orbit, Constellation and the mini player tap Music's audio with a Core Audio process tap, which needs System Audio Recording permission. Audio is analyzed locally and never recorded or sent anywhere. Without permission, Halftone, Orbit and Constellation follow the lyric timing instead.

`open build/Peace.app --args --demo-instrumental` uses a generated drum loop.

## Network use

Track title and artist go to [LRCLIB](https://lrclib.net) and NetEase Cloud Music to find lyrics, and the best match is cached on disk. NetEase's API is unofficial, so it may stop working; Peace then falls back to LRCLIB. Artist and title go to the iTunes Search API only when Music has no artwork for a track.
