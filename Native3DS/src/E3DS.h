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
    E3DSResultShutdownRequested = 17,
} E3DSResult;

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
void E3DSSetPaused(bool paused);
bool E3DSIsRunning(void);

void E3DSSetButton(int button, bool pressed);
/// x, y in -1...1, y up.
void E3DSSetStick(int stick, float x, float y);
/// Bottom screen touch in drawable pixels of the bottom layer.
void E3DSTouch(bool down, float x, float y);

/// Title from the game's SMDH (UTF-8), or NULL. Caller frees.
char *E3DSCopyTitle(const char *path);

/// The game's program ID, 0 if the file can't be read.
unsigned long long E3DSProgramID(const char *path);
/// Folder holding the game's save files (the core's SD layout). Caller frees.
char *E3DSCopySaveFolder(unsigned long long programID);
/// The game's cheat file (Gateway text, `*citra_enabled` marks enabled
/// cheats). Caller frees.
char *E3DSCopyCheatFile(unsigned long long programID);
/// Re-reads the running game's cheat file into the core.
void E3DSReloadCheats(void);

#ifdef __cplusplus
}
#endif
