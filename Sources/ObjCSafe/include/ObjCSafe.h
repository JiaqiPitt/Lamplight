#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and hands back any Objective-C exception it raised instead of letting it end the app.
///
/// AVFoundation reports some failures by raising (starting a player on an engine that the system
/// has just stopped, for one). Swift cannot catch those, so the audio code calls through here.
NSException * _Nullable LLTry(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
