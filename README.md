# Windows PS1 Media Player CLI

Most of us don’t like clicking buttons over and over again, especially on Windows when listening to music; sometimes we just want that Linux-like experience. This CLI application serves that purpose.

Get your playlist shuffled and switch tracks with ease... enjoy your favorite music - uninterrupted and ad-free.

Best suited for those who have a regular music playlist/library and prefer the flexibility to change songs on the fly.

**Originally built as a CLI music player, it now also supports video playback, bringing both music and video under one interface.**

> [!WARNING]
> This repository does not encourage playing songs in corporate environments. Use at your own risk.

## Setup

Drop the script in your media directory.

## Usage

```powershell

powershell -ep bypass -f .\play.ps1              
powershell -ep bypass -f .\play.ps1 <filename.ext>  
powershell -ep bypass -f .\play.ps1 <path to filename.ext>  
```

## Features

### Audio 

- **Track Navigation:** Browse your library and select tracks using the arrow keys.
- **Pause/Resume:** Pause and resume playback.
- **Shuffle Queue:** Shuffle the playback queue.
- **Search:** Search for tracks by name.
- **Repeat/Replay:** Automatically replay the current track after it finishes or replay a previously searched track.
- **Notifications:** Playback notifications as and when tracks are played.
- **Loop Mode:** Enable continuous playback.
- **Auto Exit:** Automatically exit after a directly searched track finishes.
- **Queue Management:** Search for tracks and add them to the queue without interrupting current playback while in Navigator View.
- **Single Song Play/Lazy Play:** Pass a track name as an argument to play it directly. Partial name matching is supported.
- **Seeking:** Seek forward and backward by 5 seconds using the Left/Right arrow keys, whether playback is active or paused.

### Video 

- **Video Playback:** Play supported video formats.
- **Playback Controls:** Control video playback through the player interface.
- **Seeking:** Seek forward and backward within the current video using the arrow keys.

## New Features/Updates

* 05-04-2026 [FEAT]: Queue now opens in a separate view with arrow key navigation to select and play a song; current song continues playing during navigation and auto-advance to the next song is suspended until the queue is closed.

* 07-04-2026 [FEAT]: Search, pause and endless scrolling have been added to the navigator view. The last played song is now highlighted, and search mode combined with the navigator enables custom queue creation.

* 27-04-2026 [FEAT]: Songs can now be added to the queue via navigator view without interrupting playback.

* 31-05-2026 [FEAT]: The single song play/lazy play feature has been added. Song names can now be passed as arguments to directly play a specific song. Partial name matching is supported, so an exact name is not required. Also, the script now defaults to the directory it is placed in.

* 05-06-2026 [FIX]: The last played track now gets highlighted correctly for all shuffle cases.

* 04-11-2026 [FIX]: Single-song folder broke the queue (one-item result was unwrapped into a string). Queue is now forced to be an array with @().

* 05-11-2026 [FIX]: Audio files are now discovered correctly in directories containing wildcard characters. Directories with audio file extensions are now excluded.

* 06-11-2026 [FIX]: Playback now handles extraneous bytes before the actual audio data in both MP3 and WAV files without modifying the original files.

* 06-11-2026 [FIX]: The player now converts IEEE float WAV files to PCM format before playback, without modifying the original files.

* 07-11-2026 [FIX]: Volume control now uses Windows Core Audio, allowing volume adjustment to work correctly during WAV playback.

* 14-11-2026 [FEAT]: Left/Right arrow keys now seek ±5 seconds within the current track, whether it's playing or paused.

* 15-11-2026 [FEAT]: Major rewrite: The music player has been extended into a media player, while retaining all existing music playback functionality and controls. The menu has also been reorganized into separate music and video sections. Windows Core Audio volume control has been dropped.

* 18-11-2026 [FEAT]: Playback support has been added for OGG Vorbis and AIFF/AIF files. Playback compatibility may vary depending on the file's encoding and audio format. Supported audio is decoded into PCM in memory for direct playback, without creating converted audio files or modifying the original files. Temporary copies may be created only to remove extraneous data before the actual audio content.
