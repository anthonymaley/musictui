---
name: ceol
description: "Control Apple Music playback, AirPlay speakers, AirPods, catalog search, library management, playlists, and music discovery on macOS. Use this skill whenever the user wants to play music, control playback (play, pause, skip, volume, shuffle), manage playlists, play an album or artist, search the Apple Music catalog (100M+ tracks), add tracks to their library, get music recommendations, route audio to AirPlay speakers or AirPods, add or remove speakers from a group, adjust per-speaker volume, switch between headphones and speakers, or check what's currently playing. Trigger on any mention of: Apple Music, AirPlay, speakers, playlist, play a song, what's playing, music volume, now playing, queue, HomePod, AirPods, headphones, Bluetooth audio, album, artist, search for music, add to library, recommendations, similar tracks, new releases, or any request to control audio playback on their Mac — even casual ones like 'put on some music', 'find me something like this', 'switch to my AirPods', 'add the bedroom to the group', or 'turn down the kitchen'."
---

# Ceol — Apple Music Controller

Control Apple Music from the terminal via the `ceol` CLI. All commands run as bash — use `ceol` for structured operations, with `--json` for machine-readable output.

## Architecture

Ceol has two backends:
- **AppleScript** — playback, speakers, volume, now playing (no auth needed)
- **REST API** — catalog search, library writes, playlists via API, discovery (needs auth)

## Playback (no auth)

```bash
ceol play                                    # resume
ceol play --playlist "Working Vibes"         # play a playlist (with shuffle)
ceol play --song "Get It Done" --artist "Fouk"  # play specific track from library
ceol pause
ceol skip                                    # next track
ceol back                                    # previous track
ceol stop
ceol now                                     # what's playing + speakers
ceol now --json                              # structured: track, artist, album, speakers, state
ceol shuffle on|off
ceol repeat off|one|all
```

## Speakers (no auth)

```bash
ceol speaker list                            # all AirPlay devices + status
ceol speaker list --json                     # structured device list
ceol speaker set "Kitchen"                   # switch to single speaker
ceol speaker add "Bedroom"                   # add to current group
ceol speaker remove "Bedroom"                # remove from group
```

## Volume (no auth)

```bash
ceol vol                                     # show current volume per speaker
ceol vol 60                                  # set all active speakers to 60
ceol vol up                                  # +10 on all active speakers
ceol vol down                                # -10 on all active speakers
ceol vol Kitchen 80                          # set Kitchen to 80
```

## Catalog Search (developer token only)

```bash
ceol search "Bohemian Rhapsody Queen"        # search songs
ceol search "Fouk" --limit 20               # control result count
ceol search --artist "Radiohead"             # filter by artist
ceol search --album "OK Computer"            # filter by album
ceol search "query" --json                   # structured results with catalog IDs
```

## Add to Library (requires user token)

```bash
ceol add "Get It Done" "Fouk"                # search + add top result
ceol add --id 1844648631                     # add by catalog ID
```

## Playlists (requires user token for API, AppleScript fallback for local)

```bash
ceol playlist list                           # list all playlists
ceol playlist tracks "Working Vibes"         # list tracks in playlist
ceol playlist create "New Playlist"          # create empty playlist
ceol playlist delete "Old Playlist"          # delete (via AppleScript)
ceol playlist add "Working Vibes" "Song" "Artist"  # add track to playlist
ceol playlist add "P1,P2" "Song" "Artist"    # add to multiple playlists
ceol playlist remove "Playlist" "Song"       # remove track
ceol playlist share "Playlist" --imessage "+1234567890"  # share via iMessage
ceol playlist share "Playlist" --email "a@b.com"         # share via email
ceol playlist temp "Song1" "Artist1" "Song2" "Artist2"   # temp playlist, play, cleanup later
ceol playlist create-from "Song1" "Artist1" "Song2" "Artist2" --name "My Mix"  # create + populate
ceol playlist cleanup                        # delete all __temp__ playlists
```

## Discovery (requires user token)

```bash
ceol similar                                 # similar to now playing
ceol similar "Song" "Artist"                 # similar to specific track
ceol suggest 10                              # suggest tracks from now playing
ceol suggest 10 --from "Working Vibes"       # suggest from playlist vibe
ceol new-releases --like-current             # new releases from current artist
ceol new-releases --artist "Fouk"            # new releases from specific artist
ceol mix --artists "Fouk,Floating Points" --count 20 --name "Friday Mix"  # mixed playlist
```

## Auth Management

```bash
ceol auth status                             # check config + token status
ceol auth setup                              # guided setup (key ID, team ID, .p8 key)
ceol auth                                    # open browser for user token
ceol auth set-token <TOKEN>                  # save user token from browser
```

## Auth Tiers

| Tier | What works | What doesn't |
|------|-----------|--------------|
| No auth | play, pause, skip, back, stop, now, shuffle, repeat, speaker, vol | search, add, playlist (API), similar, suggest, new-releases, mix |
| Developer token only | Above + search | add, playlist (API), similar, suggest, new-releases, mix |
| Both tokens | Everything | — |

## Workflow: Complex Requests

For multi-step requests like "play Fouk on the kitchen speaker at 60%", compose commands:

```bash
ceol speaker set "Kitchen"
ceol vol Kitchen 60
ceol play --playlist "Working Vibes"
```

For "find me something like what's playing and make a playlist":

```bash
ceol similar --json                          # get similar tracks
ceol playlist create "Discovered"
# For each track: ceol playlist add "Discovered" "Title" "Artist"
```

## Output Modes

- **Default:** Human-readable text for terminal
- **`--json`:** Structured JSON for scripting and Claude

Always use `--json` when you need to parse the output programmatically.

## Error Handling

- **"Config not found"** — Run `ceol auth setup`
- **"User token required"** — Run `ceol auth`
- **"API request failed with status 401/403"** — Token expired, run `ceol auth` again
- **"No tracks found"** — Try a broader search query
- **Speaker commands fail** — Check exact speaker name with `ceol speaker list`
