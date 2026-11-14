// E3DS.h — eDuo's C interface to the Azahar 3DS core (Vendor/azahar).
// Plain C so Swift sees it through the bridging header; no C++ crosses over.
// GPLv2-or-later, like the core it wraps.

#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Same codes as Azahar's InputManager::ButtonType.
typedef enum {
    E3DSButtonA = 700, E3DSButtonB = 701, E3DSButtonX = 702, E3DSButtonY = 703,
    E3DSButtonStart = 704, E3DSButtonSelect = 705, E3DSButtonHome = 706,
    E3DSButtonZL = 707, E3DSButtonZR = 708,
    E3DSButtonUp = 709, E3DSButtonDown = 710, E3DSButtonLeft = 711, E3DSButtonRight = 712,
    E3DSButtonL = 773, E3DSButtonR = 774,
} E3DSButton;

typedef enum { E3DSStickCircle = 713, E3DSStickC = 718 } E3DSStick;

/// Azahar's Core::System::ResultStatus, the ones the app words differently.
typedef enum {
    E3DSResultSuccess = 0,
    E3DSResultErrorGetLoader = 2,
    E3DSResultErrorLoader = 4,
    E3DSResultErrorEncrypted = 5,
    E3DSResultErrorInvalidFormat = 6,
    E3DSResultErrorSystemFiles = 10,
    E3DSResultShutdownRequested = 16, ///< the game itself asked to exit (APT/HOME exit, homebrew "START to exit")
    E3DSResultErrorUnknown = 17,
} E3DSResult;
// The values above are checked against Core::System::ResultStatus in E3DS.mm (static_assert).

/// The two CAMetalLayers (top, bottom) and their drawable size in pixels.
/// Call before E3DSRun and again whenever a layer resizes.
void E3DSSetLayers(void *topLayer, double topWidth, double topHeight,
                   void *bottomLayer, double bottomWidth, double bottomHeight);

/// Loads and runs `path` on the calling thread until E3DSStop or the game
/// ends. Returns an E3DSResult (other values: see Azahar core.h).
int E3DSRun(const char *path);
void E3DSStop(void);
/// Internal render scale (1 = the console's 400x240). Read at E3DSRun.
void E3DSSetResolution(int factor);
/// "Dump Textures" (3DS only): the core writes every texture the game uploads that the folder
/// does not hold yet as a PNG into Documents/System/load/textures/<program ID as 16 hex digits>/,
/// the same folder packs are loaded from (one folder per game, like PPSSPP). Dumps accumulate
/// across sessions; PNGs the player edits or adds there load at the next E3DSRun, untouched
/// dumps are not loaded. A template pack.json (new hash) is written first if the folder holds no
/// pack. Read at E3DSRun: the core copies the setting while it loads, so it cannot change while a
/// game is running. Costs speed and storage while on; off (the default) changes nothing.
void E3DSSetDumpTextures(bool on);
/// Moves a 1.2.0 (68) dump (Documents/System/dump/textures/<ID>/) into the pack folder, never
/// over a file already there and never into a legacy pack. E3DSRun does it too. Returns the
/// number of files moved.
int E3DSMigrateTextureDump(unsigned long long programID);
void E3DSSetPaused(bool paused);
bool E3DSIsRunning(void);
/// After E3DSSetPaused(true): waits (1 ms steps) until the core thread is
/// parked, i.e. no emulation/GPU work in flight, or the game ended. Returns
/// true if parked/ended, false on timeout.
bool E3DSWaitParked(int timeoutMs);
/// Battery saver: native resolution (resolution_factor 1), vsync off (non-blocking present,
/// so a 30 Hz display cap does not slow the core) and speed capped at 100 %. Transient: the
/// chosen resolution is restored exactly when turned off. Applies live (the rasterizer polls
/// resolution_factor, the presenter polls vsync, each frame) and persists across E3DSRun.
void E3DSSetBatterySaver(bool on);
/// Save states (slots 0...11). Blocking (up to ~7 s, works while paused):
/// call from a background thread, never the core thread. 0 = ok; Load returns
/// -5 no such state, -6 made by another build (nothing is sent to the core,
/// the game keeps running); other negatives = failure.
int E3DSSaveState(int slot);
int E3DSLoadState(int slot);
/// True and `unixTime` (seconds) if the slot holds a state.
bool E3DSStateInfo(int slot, long long *unixTime);

void E3DSSetButton(int button, bool pressed);
/// x, y in -1...1, y up.
void E3DSSetStick(int stick, float x, float y);
/// Bottom screen touch in drawable pixels of the bottom layer.
void E3DSTouch(bool down, float x, float y);

/// Title from the game's SMDH (UTF-8), or NULL. Caller frees.
char *E3DSCopyTitle(const char *path);

/// The game's SMDH icon (the large one, always 48x48) as RGBA8, 4 bytes per pixel, rows top to
/// bottom, fully opaque (the SMDH stores RGB565). Writes the size to `width`/`height` (either may be
/// NULL). NULL (sizes 0) when the file has no valid SMDH, e.g. a .3dsx without the icon
/// extension. Loader only, no core needed. Caller frees with free().
unsigned char *E3DSCopyIcon(const char *path, int *width, int *height);

/// The game's program ID, 0 if the file can't be read.
unsigned long long E3DSProgramID(const char *path);
/// Where the core keeps a title's save instead of its SD layout. `folder` (absolute; created
/// on demand by the game's first Format) holds `00000001/` (the save files) and
/// `00000001.metadata`: exactly what the stock layout keeps in
/// sdmc/Nintendo 3DS/<id0>/<id1>/title/<high>/<low>/data/. NULL or "" removes the override.
/// Call before E3DSRun (the core reads it on every save access); it stays until changed.
/// Save states keep recording the stock path, mapped to `folder` when loaded, so states
/// made before or after an override load either way.
void E3DSSetSaveDataFolder(unsigned long long programID, const char *folder);
/// The stock save folder (`.../title/<high>/<low>/data/00000001/`), ignoring any override:
/// where builds up to 1.2.0 (64) kept every save. Caller frees.
char *E3DSCopyLegacySaveFolder(unsigned long long programID);
/// Debug self-test (no ROM, no running core): points a fake title at `folder`, then runs the
/// core's own save path (ArchiveSource_SDSaveData Format + Open, create, write, close) and
/// checks the file and the metadata landed in `folder`, plus the save-state path mapping.
/// Writes a line per check into `report` (NUL-terminated). 0 = all passed. Leaves the files.
int E3DSSaveSelfTest(const char *folder, char *report, int reportLength);
/// Debug self-test (no ROM, no running core) for texture dumping: one folder for packs and dumps,
/// the template pack.json (new hash) only into a folder without a pack and never over the
/// player's, untouched dumps kept but not loaded while edited ones load, the migration from
/// dump/textures (never overwriting, never into a legacy pack), and the core's PNG encoder
/// writing into the pack folder. Same report contract as E3DSSaveSelfTest.
int E3DSTextureDumpSelfTest(char *report, int reportLength);
/// The game's cheat file (Gateway text, `*citra_enabled` marks enabled
/// cheats). Caller frees.
char *E3DSCopyCheatFile(unsigned long long programID);
/// Re-reads the running game's cheat file into the core.
void E3DSReloadCheats(void);

/// Diagnostics (pre-release/Debug builds only; the defaults change nothing).
/// vsync: -1 core default, 0 off, 1 on. unlimitedSpeed: frame limit 0 instead of 100 %.
/// Read at E3DSRun.
void E3DSSetDiagnostics(int vsync, bool unlimitedSpeed);
/// Vertex shaders: -1 auto (hardware, software for games known to lose models), 0 software, 1 hardware.
/// Read at E3DSRun.
void E3DSSetHardwareShaders(int mode);
/// Starts/stops collecting stats; while off nothing is counted or hooked.
void E3DSSetStatsEnabled(bool enabled);

typedef struct {
    double emulationSpeed;  ///< % of real time (100 = full speed)
    double gameFPS;         ///< frames the game submits per second
    double systemFPS;       ///< emulated vblanks per second
    double presentFPS;      ///< drawables acquired for the top screen per second
    double coreCPU;         ///< % of one core used by the eDuo.3DS thread
    double processCPU;      ///< % of one core used by all threads of the app
    double hotCPU;          ///< busiest thread other than the core thread
    char hotThread[32];     ///< its name
} E3DSStats;

/// Samples since the previous call (call about once a second, from any one
/// thread). False when stats are off or the game is not running.
bool E3DSSampleStats(E3DSStats *out);

#ifdef __cplusplus
}
#endif
