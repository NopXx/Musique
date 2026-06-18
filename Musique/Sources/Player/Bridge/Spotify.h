/*
 * Spotify.h
 *
 * ScriptingBridge header for the Spotify desktop app (com.spotify.client).
 * Hand-written from the Spotify scripting definition. Note: SpotifyTrack.duration
 * is in *milliseconds* (Apple Music's MusicTrack.duration is in seconds).
 */

#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>


@class SpotifyApplication, SpotifyTrack;

enum SpotifyEPlS {
	SpotifyEPlSStopped = 'kPSS',
	SpotifyEPlSPlaying = 'kPSP',
	SpotifyEPlSPaused = 'kPSp'
};
typedef enum SpotifyEPlS SpotifyEPlS;


@interface SpotifyApplication : SBApplication

@property (copy, readonly) SpotifyTrack *currentTrack;  // the current playing track
@property double playerPosition;  // the player's position within the currently playing track in seconds
@property (readonly) SpotifyEPlS playerState;  // is Spotify stopped, paused, or playing?
@property NSInteger soundVolume;  // the sound output volume (0 = minimum, 100 = maximum)
@property BOOL repeatingEnabled;  // is repeating enabled in the current playback context?
@property BOOL repeating;  // is repeating on or off?
@property BOOL shufflingEnabled;  // is shuffling enabled in the current playback context?
@property BOOL shuffling;  // is shuffling on or off?
@property (copy, readonly) NSString *name;  // the name of the application
@property (readonly) BOOL frontmost;  // is this the frontmost (active) application?
@property (copy, readonly) NSString *version;  // the version of the application

- (void) nextTrack;  // skip to the next track
- (void) previousTrack;  // skip to the previous track
- (void) playpause;  // toggle play/pause
- (void) pause;  // pause playback
- (void) play;  // resume playback
- (void) playTrack:(NSString *)x inContext:(NSString *)context;  // start playback of a track in the given context

@end


@interface SpotifyTrack : SBObject

@property (copy, readonly) NSString *artist;  // the artist of the track
@property (copy, readonly) NSString *album;  // the album of the track
@property (readonly) NSInteger discNumber;  // the disc number of the track
@property (readonly) NSInteger duration;  // the length of the track in milliseconds
@property (readonly) NSInteger playedCount;  // the number of times this track has been played
@property (readonly) NSInteger trackNumber;  // the index of the track in its album
@property (readonly) BOOL starred;  // is the track starred?
@property (readonly) NSInteger popularity;  // the popularity of this track, 0-100
@property (copy, readonly) NSString *id;  // the ID of the item
@property (copy, readonly) NSString *name;  // the name of the track
@property (copy, readonly) NSString *artworkUrl;  // the URL of the track's album cover
@property (copy, readonly) NSString *albumArtist;  // the album artist of the track
@property (copy) NSString *spotifyUrl;  // the URL of the track

@end
