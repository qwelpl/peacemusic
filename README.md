# Peace

A good-looking macOS front end for Apple Music: spinning vinyl, liquid backgrounds drawn from the album art, and karaoke-style synced lyrics.

Peace controls the Music app over Apple Events, so Music does the playing and your account stays there. No Apple developer token needed.

## Run

Needs macOS 26 and Xcode 26.

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
| L | Show or hide lyrics |
| V | Switch between vinyl and cover |
| F | Full screen |

## Network use

Track title, artist, album and duration go to [LRCLIB](https://lrclib.net) to find lyrics, which are then cached on disk. Artist and title go to the iTunes Search API only when Music has no artwork for a track.
