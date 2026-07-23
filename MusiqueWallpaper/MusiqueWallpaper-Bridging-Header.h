//
//  MusiqueWallpaper-Bridging-Header.h
//
//  Objective-C surface the wallpaper extension needs but which has no public
//  Swift module. Two groups:
//
//  1. Private CoreAnimation / CoreGraphics-Services API used to hand a CALayer
//     to the WindowServer's wallpaper compositor (a "remote" CAContext).
//  2. The two NSXPC protocols WallpaperAgent expects on either end of the
//     connection. The concrete argument classes (WallpaperCreationRequestXPC,
//     WallpaperRemoteContextXPC, …) are defined in the private framework
//     WallpaperExtensionKit and resolved at runtime via dlopen + objc_getClass,
//     so they appear here only as `id`. These selector names are dictated by
//     Apple's host side — they are an interface contract, not our design.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - Private remote CAContext

@interface CAContext : NSObject
@property (readonly) unsigned int contextId;
@property (retain) CALayer *layer;
+ (id)remoteContext;
+ (id)remoteContextWithOptions:(id)options;
@end

extern unsigned int CGSMainConnectionID(void);

#pragma mark - Extension → WallpaperAgent (callbacks we can make on the host)

@protocol WallpaperProxyXPC <NSObject>
- (void)pingWithId:(id _Nullable)anId;
- (void)invalidateSnapshotsWithReply:(void (^ _Nonnull)(NSError * _Nullable))reply;
@end

#pragma mark - WallpaperAgent → Extension (methods the host calls on us)

@protocol WallpaperHostedXPC <NSObject>

// Lifecycle
- (void)acquireWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)updateWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invalidateWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)snapshotWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;

// Settings
- (void)provideSettingsViewModelsWithContentTypes:(id _Nullable)types reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;

// Choices
- (void)addChoiceRequestWithChoiceRequest:(id _Nullable)request onBehalfOfProcess:(id _Nullable)process reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)removeChoiceRequestWithChoiceRequest:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)selectedChoicesDidChangeFor:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invokeContextMenuActionWithMenuItemID:(id _Nullable)menuItemID groupItemID:(id _Nullable)groupItemID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Downloads (we ship nothing to download — all no-ops)
- (void)isChoiceDownloadedWith:(id _Nullable)choiceID reply:(void (^ _Nonnull)(BOOL, NSError * _Nullable))reply;
- (void)pauseDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)cancelDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)resumeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)removeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Migration
- (void)migrateSelectedChoiceFor:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)migrateFrom:(id _Nullable)from to:(id _Nullable)to reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Shuffle
- (void)skipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)canSkipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(BOOL, NSError * _Nullable))reply;

// Debug & notifications
- (void)handleDebugRequestFor:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)handleNotificationWithNamed:(id _Nullable)name reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

@end
