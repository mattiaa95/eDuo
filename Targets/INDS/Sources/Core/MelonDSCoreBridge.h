#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, INDSButton) {
    INDSButtonA = 0,
    INDSButtonB = 1,
    INDSButtonSelect = 2,
    INDSButtonStart = 3,
    INDSButtonRight = 4,
    INDSButtonLeft = 5,
    INDSButtonUp = 6,
    INDSButtonDown = 7,
    INDSButtonR = 8,
    INDSButtonL = 9,
    INDSButtonX = 10,
    INDSButtonY = 11
};

NS_ASSUME_NONNULL_BEGIN

@interface MelonDSCoreBridge : NSObject

/// YES once a ROM has been parsed and a cart is inserted into the emulated console.
@property (nonatomic, readonly) BOOL loaded;

/// YES while the dedicated emulation thread is actively stepping frames
/// (started/resumed and not paused or stopped).
@property (nonatomic, readonly) BOOL running;

@property (nonatomic, readonly) NSString *statusText;

/// YES if an auto-save state already exists on disk for the loaded ROM.
@property (nonatomic, readonly) BOOL hasAutoSaveState;

/// Output volume in 0...1. Applied live in the audio render callback and
/// persisted to UserDefaults under the "eNDSAudioVolume" key.
@property (nonatomic) double audioVolume;

/// Transient output mute layered over `audioVolume` (Settings > Audio's
/// "Mute While Other Audio Plays"). Applied in the audio render callback as a
/// zero gain; never persisted, so a session that ends mid-duck cannot come
/// back silent. Defaults to NO on every new instance.
@property (nonatomic) BOOL outputDucked;

/// Emulation speed multiplier. 1.0 is normal speed, 2.0 runs two console
/// frames per paced tick, etc.; 0.5 is slow motion (one console frame every
/// other paced tick — see EmuThreadMain's frame accumulator). Clamped to
/// 0.5...2.0 internally.
@property (nonatomic) double speedMultiplier;

/// YES while the DS microphone is actually being captured right now: the
/// loaded game currently has its mic window open (between its internal
/// Mic_Start/Mic_Stop), the "Microphone" Settings toggle is on, mic
/// permission was granted, and emulation isn't paused. Reflects the real
/// AVAudioEngine capture state, not just whether the game asked for it, so
/// it never reports YES when permission was denied or the toggle is off.
/// Read from the main thread (e.g. a display-link tick driving a HUD badge).
@property (nonatomic, readonly) BOOL microphoneActive;

#pragma mark - Console profile (firmware user settings)

/// The console owner's name, as stored in the DS firmware's user settings —
/// the name games pre-fill when they ask for one and the one that shows up in PictoChat-style
/// screens. melonDS's generated firmware ships the literal string "melonDS"
/// here; leave this nil to keep it.
///
/// The firmware holds at most 10 UTF-16 characters, and anything longer is
/// truncated. Baked in at `loadROMAtPath:`, so a change only reaches a game
/// the next time one is opened.
///
/// Ignored when a real firmware.bin dump is present in the BIOS directory:
/// that image carries its owner's own profile, which is theirs to keep.
@property (nonatomic, copy, nullable) NSString *firmwareNickname;

/// The console's system language, as stored in the same firmware user
/// settings: 0 Japanese, 1 English, 2 French, 3 German, 4 Italian,
/// 5 Spanish. Most multi-language DS carts pick which of their built-in
/// translations to show from this rather than asking, so leaving melonDS's
/// default of English means every player worldwide gets an English game.
/// Negative keeps whatever the firmware already had. Same
/// next-load/generated-firmware-only rules as `firmwareNickname`.
@property (nonatomic) NSInteger firmwareLanguage;

/// Loads a ROM and prepares the core to run, but does not start stepping
/// frames (call `startEmulation`/`resumeEmulation` for that).
///
/// BIOS/firmware dumps found in `biosDirectory` (bios7.bin, bios9.bin,
/// firmware.bin) are used when present and valid. Any that are missing are
/// simply skipped: melonDS's built-in FreeBIOS + generated firmware are used
/// instead and the ROM is direct-booted regardless, so a ROM will always
/// boot even with an empty BIOS directory.
- (BOOL)loadROMAtPath:(NSString *)romPath
        biosDirectory:(NSString *)biosDirectory
                error:(NSError **)error;

#pragma mark - Emulation lifecycle (main thread only)

/// Starts the dedicated emulation thread (if not already running) and the
/// audio engine. Safe to call repeatedly.
- (void)startEmulation;

/// Pauses frame stepping and audio. The emulation thread stays alive but
/// idle, so `resumeEmulation` is cheap and instantaneous.
- (void)pauseEmulation;

/// Resumes frame stepping after a pause. Equivalent to `startEmulation` if
/// the core has never been started.
- (void)resumeEmulation;

/// Restarts the audio engine if a running game somehow lost it. Cheap,
/// self-throttling and idempotent — meant to be called from the frame
/// presentation loop, since "the game plays on in silence until you quit it"
/// is the one audio failure a player cannot work around, and it can be caused
/// by things this class has no notification for.
- (void)ensureAudioIsRunning;

/// Stops and joins the emulation thread, stops audio, and releases the
/// loaded core. Safe to call even if nothing is loaded/running.
- (void)stopEmulation;

/// Soft-resets the console while keeping the inserted cart, then re-runs the
/// same direct-boot sequence used when the ROM was first loaded.
- (void)resetEmulation;

#pragma mark - Input (thread-safe, callable from any thread)

- (void)setButton:(INDSButton)button pressed:(BOOL)pressed;
- (void)setTouchX:(NSInteger)x y:(NSInteger)y pressed:(BOOL)pressed;

#pragma mark - Presentation

/// Copies the most recently completed top/bottom frames into caller-owned
/// buffers (256*192 uint32_t BGRA8888 pixels each, matching the previous
/// NSData layout). Returns NO if no frame has been produced yet. Does not
/// allocate.
- (BOOL)copyFramebuffersTop:(uint32_t *)top bottom:(uint32_t *)bottom;

#pragma mark - Save states

/// Path for numbered save-state slot 0...3 for the loaded ROM, or nil if no
/// ROM is loaded.
- (nullable NSString *)pathForSaveStateSlot:(NSInteger)slot;

/// Path for the dedicated auto-save slot for the loaded ROM, or nil if no
/// ROM is loaded.
- (nullable NSString *)autoSaveStatePathForROM;

- (BOOL)saveStateToPath:(NSString *)path error:(NSError **)error;
- (BOOL)loadStateFromPath:(NSString *)path error:(NSError **)error;

/// In-memory rewind history (~35 s, one capture every 3.5 s). Off frees it.
@property (nonatomic) BOOL rewindEnabled;
/// At least one capture exists for the running game.
@property (nonatomic, readonly) BOOL canRewind;
/// Jumps ~10 s back; call again to keep going. NO if nothing was restored.
- (BOOL)rewindTenSeconds;
- (void)clearRewindHistory;

/// Autosave variant: serializes synchronously (unavoidable — it must not race
/// RunFrame) but writes the file on a background queue, so a periodic autosave
/// doesn't hitch the game. Returns whether the snapshot was taken, not whether
/// it reached disk. Use `saveStateToPath:error:` wherever the user is waiting
/// on the result.
- (BOOL)autosaveStateToPath:(NSString *)path;

#pragma mark - Cheats (Action Replay)

/// Parses `path` as a melonDS Action Replay code file (`ARCodeFile`'s own
/// ".mch" text format — a flat or categorized list of CODE blocks, each a
/// name plus 8+8 hex-digit pairs) and applies its codes to the loaded core's
/// cheat engine (`NDS::AREngine.Cheats`), replacing whatever was active
/// before. Pass `enabled = NO` to clear the core's active cheat list
/// without touching the file on disk — a coarser "cheats subsystem on at
/// all" switch, mirroring melonDS's own Qt frontend
/// (`EmuInstance::enableCheats`); each code's own enabled bit, read straight
/// from the file, still gates whether *that* code actually runs whenever
/// this is YES.
///
/// A missing file parses as zero codes, not an error (matches
/// `ARCodeFile::Load`'s own behavior for a game that has never had cheats),
/// so this is always safe to call right after a ROM loads. No-op if no ROM
/// is loaded.
///
/// Safe to call from the main thread at any time: internally pauses and
/// waits for the emulation thread to be idle before touching the cheat
/// list, exactly like `resetEmulation`/`saveStateToPath:error:`, since
/// `AREngine.Cheats` is iterated by that thread every emulated VBlank.
- (void)reloadCheatsFromFile:(NSString *)path enabled:(BOOL)enabled;

/// Sets the console's own real-time clock.
///
/// melonDS starts every boot at 2000-01-01 00:00:00 unless the frontend says
/// otherwise — upstream's Qt frontend seeds it from the host clock, and eNDS
/// did not, so anything driven by the DS date/time (day-night cycles, berry
/// growth, daily events) was living in the year
/// 2000. `NDSRomViewController` applies this right after a ROM loads and
/// again whenever the app comes back to the foreground, from
/// `INDSRTCPreferences`.
///
/// Safe to call from the main thread at any time: pauses and waits for the
/// emulation thread to be idle first, like `resetEmulation`. No-op if no ROM
/// is loaded.
- (void)setConsoleDateTime:(NSDateComponents *)components;

/// The console's current date/time, or nil when no ROM is loaded — the RTC
/// advances with emulation, so this is what the game itself believes it is.
- (nullable NSDateComponents *)consoleDateTime;

@end

NS_ASSUME_NONNULL_END
