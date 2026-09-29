#import "MelonDSCoreBridge.h"

/// "eNDSThreadedRendering" — Settings › Performance. Default ON: every device
/// eNDS supports (iOS 17+) has at least 6 cores, and the single-threaded
/// rasteriser was leaving all but one idle. Same "read the literal key, no
/// shared Swift/C++ constant" pattern this file already uses for
/// "eNDSAudioVolume" and "eNDSMicEnabled". Read once per ROM load, so flipping
/// it applies to the next game — like every other Settings toggle here.
static bool INDSThreadedRenderingEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:@"eNDSThreadedRendering"];
    return stored == nil ? true : [defaults boolForKey:@"eNDSThreadedRendering"];
}

#include "INDSMPTransport.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h> // CACurrentMediaTime, for -ensureAudioIsRunning

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <optional>
#include <pthread.h>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

#include "ARCodeFile.h"
#include "Args.h"
#include "NDS.h"
#include "NDSCart.h"
#include "Platform.h"
#include "SPI_Firmware.h"
#include "Savestate.h"
#include "types.h"

static NSString *const MelonDSCoreBridgeErrorDomain = @"com.mls.inds.melonds";

namespace {

using namespace melonDS;

constexpr int kFramebufferWidth = 256;
constexpr int kFramebufferHeight = 192;
constexpr int kFramebufferPixels = kFramebufferWidth * kFramebufferHeight;

// The DS refreshes at ~59.8260 Hz (2^25 Hz / 560190 cycles-per-frame), not an
// even 60. Pacing the emulation thread at the real rate keeps audio and game
// logic speed accurate instead of drifting against real time.
constexpr double kNDSFrameSeconds = 1.0 / 59.8260;

// Generous ceiling for a single CoreAudio render callback at 48kHz; real
// buffer sizes are typically in the low thousands at most. Fixed-size so the
// audio render block never allocates.
constexpr int kAudioScratchFrames = 4096;

// melonDS's own Mic module (Vendor/melonDS/src/Mic.cpp, Mic::Advance) pumps
// its internal mic ring "every 704 cycles ... this matches the highest
// sample rate on DSi" per that file's comment. The reference Qt/SDL frontend
// (Vendor/melonDS/src/frontend/qt_sdl/EmuInstanceAudio.cpp,
// EmuInstance::micGetNumSamplesIn) resamples whatever it captures to this
// exact constant before ever handing samples to Platform::Mic_ReadInput, so
// this is the rate melonDS's mic pipeline is actually tuned for — unrelated
// to the 48kHz used for SPU *output* above (args.OutputSampleRate).
constexpr double kMicTargetSampleRate = 47743.4659091;

// The rate melonDS renders its SPU output at (NDSArgs::OutputSampleRate) and,
// necessarily, the rate the AVAudioSourceNode feeding the engine is declared
// at — RenderAudio hands the core's samples straight over, so the two must
// agree. Unrelated to the *hardware* rate, which the mixer converts to and
// which can change under us at any time (see
// -handleAudioEngineConfigurationChange:).
constexpr double kAudioOutputSampleRate = 48000.0;

// Same ceiling as ROMStorageManager.maxROMSize. The importer enforces it,
// but Documents/ROMs is Files-app-browsable, so a multi-GB file renamed
// `.nds` can land here without going through the importer — and a
// `std::vector::resize` that size would throw straight through to Swift.
constexpr std::streamsize kMaxReadFileSize = 512LL * 1024 * 1024;

bool ReadFile(const std::string& path, std::vector<u8>& out) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) return false;
    std::streamsize size = file.tellg();
    if (size <= 0 || size > kMaxReadFileSize) return false;
    file.seekg(0, std::ios::beg);
    out.resize(static_cast<size_t>(size));
    return file.read(reinterpret_cast<char*>(out.data()), size).good();
}

template <size_t N>
bool ReadFixedFile(const std::string& path, std::array<u8, N>& out) {
    std::vector<u8> data;
    if (!ReadFile(path, data) || data.size() != N) return false;
    memcpy(out.data(), data.data(), N);
    return true;
}

// Same as ReadFile, but into a buffer the caller can hand straight to
// NDSCart::ParseROM's owning overload. The pointer overload copies the whole
// image (CopyToUnique), so going through a std::vector kept two copies of
// the cart alive for the rest of the load. `new` rather than make_unique: no
// point zero-filling up to 512 MB that is overwritten on the next line.
std::unique_ptr<u8[]> ReadFileOwned(const std::string& path, u32& outLength) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) return nullptr;
    std::streamsize size = file.tellg();
    if (size <= 0 || size > kMaxReadFileSize) return nullptr;
    file.seekg(0, std::ios::beg);
    std::unique_ptr<u8[]> out(new u8[static_cast<size_t>(size)]);
    if (!file.read(reinterpret_cast<char*>(out.get()), size).good()) return nullptr;
    outLength = static_cast<u32>(size);
    return out;
}

// Initial capacity for a serialized state. Savestate's own DEFAULT_SIZE
// mallocs 32 MB up front; a DS state is ~6 MB and the buffer doubles itself
// when a write would overflow (Savestate::VarArray -> Resize), so starting
// smaller costs at most one realloc for an unusually large state.
constexpr u32 kSavestateInitialSize = 8 * 1024 * 1024;

// Rewind, same shape as the GBA app's RewindManager: a ring of in-memory
// states, one every 3.5 s of game time, 10 of them ≈ 35 s of history, and
// each rewind jumps 3 captures (~10 s) back — three jumps in a row, which is
// what the GBA testers asked for. A DS state is ~6 MB against ~0.6 MB on
// GBA, so the captures are spaced wider instead of kept as many: ~60 MB,
// allocated on the first capture and dropped on every clear. That RAM is
// why it can be switched off in Settings.
constexpr int kRewindCaptureFrames = 210;
constexpr int kRewindMaxSlots = 10;
constexpr int kRewindJumpSlots = 3;

// How long the mic capture pipeline outlives the game's mic window. The DS
// mic has no explicit open/close: the core closes it two frames after the
// last TSC AUX sample and reopens it on the next one (Mic.cpp Advance /
// SPI.cpp), so a game that polls the mic in bursts produces a
// Mic_Stop/Mic_Start pair every few frames. Each edge acted on immediately
// means a full engine stop, session category swap and restart.
constexpr int64_t kMicCloseDebounceNanoseconds = 2 * NSEC_PER_SEC;

// Latest battery-save snapshot waiting to be written, shared between the
// thread that produced it (the emulation thread, inside RunFrame, or the
// main thread flushing SRAM on a state load) and the serial save queue that
// writes it. Only ever one snapshot: a newer one replaces a pending one
// outright, so a burst of page writes (one Platform::WriteNDSSave per SPI
// transaction, per 0x800-byte block on NAND carts) collapses into a single
// file write of the final contents. Owned by a shared_ptr so a queued write
// block never needs the bridge or its Runtime to still exist.
struct SaveWriter {
    std::mutex mutex;
    std::string path;        // destination, captured with the snapshot
    std::vector<u8> pending; // empty once the queue has taken it
    bool queued = false;     // a drain block is already queued for `pending`
};

// Runs on the serial save queue. Takes the pending snapshot (clearing
// `queued` under the lock, so a write arriving during the file I/O queues a
// fresh drain that runs after this one) and writes it atomically.
void DrainPendingSave(const std::shared_ptr<SaveWriter>& writer) {
    std::vector<u8> bytes;
    std::string path;
    {
        std::lock_guard<std::mutex> lock(writer->mutex);
        bytes.swap(writer->pending);
        path = writer->path;
        writer->queued = false;
    }
    if (bytes.empty() || path.empty()) return;

    NSData *data = [NSData dataWithBytesNoCopy:bytes.data() length:bytes.size() freeWhenDone:NO];
    NSString *nsPath = [NSString stringWithUTF8String:path.c_str()];
    NSError *error = nil;
    if (![data writeToFile:nsPath options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[melonDS] Failed to write NDS save: %@", error.localizedDescription); // no path in Release logs
    }
}

/// `message` doubles as the catalog key: every call site's literal has an
/// entry in Localizable.xcstrings, since these surface verbatim in HUD
/// toasts ("Couldn't load state: %@") and the ROM-load error screen.
NSError *MakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:MelonDSCoreBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(message, nil)}];
}

struct FramebufferSlot {
    std::array<u32, kFramebufferPixels> top{};
    std::array<u32, kFramebufferPixels> bottom{};
};

// All shared state between the UI thread, the dedicated emulation thread and
// the CoreAudio render thread lives here. Field-by-field synchronization
// notes are next to each group below.
struct Runtime {
    std::unique_ptr<NDS> nds;
    std::string status = "melonDS core ready";
    std::string savePath;     // battery .sav path
    std::string romFileName;  // ROM filename incl. extension, for direct boot
    std::string romBaseName;  // ROM filename without extension, for save states

    // Battery-save write coalescing (see SaveWriter above). Shared with every
    // queued write block, so those outlive neither the Runtime nor the bridge
    // by accident.
    std::shared_ptr<SaveWriter> saveWriter = std::make_shared<SaveWriter>();

    // Input: written from whichever thread handles UI events, read once per
    // frame by the emulation thread. Buttons are independent bits so a plain
    // atomic bitmask is lock-free; touch is a small struct guarded by a mutex
    // since x/y/pressed must stay consistent with each other.
    std::atomic<u32> keyMask{0xFFF};
    std::mutex touchMutex;
    bool touchPressed = false;
    u16 touchX = 0;
    u16 touchY = 0;

    // Audio: read from the real-time CoreAudio render thread every callback,
    // written from the main thread on user changes. Plain atomics are
    // sufficient (single scalar, no cross-field consistency needed).
    std::atomic<double> volume{1.0};
    // Transient mute over `volume` (see -outputDucked). Never persisted.
    std::atomic<bool> outputDucked{false};
    std::array<s16, kAudioScratchFrames * 2> audioScratch{};

    // Fast-forward multiplier, read once per paced tick.
    std::atomic<double> speed{1.0};

    // Rewind ring (see kRewindCaptureFrames). Written on the emulation
    // thread right after RunFrame, read/cleared from the main thread; the
    // mutex only ever guards a memcpy or a vector swap.
    std::atomic<bool> rewindEnabled{true};
    std::mutex rewindMutex;
    std::vector<std::vector<u8>> rewindSlots;
    int rewindHead = -1;  // newest capture
    int rewindCount = 0;
    int rewindFrames = 0; // frames since the last capture

    // Presentation double-buffer: the emulation thread copies melonDS's raw
    // framebuffer pointers into fbSlots[fbWriteNext] *without* holding
    // fbMutex (nobody else can see fbWriteNext until published), then takes
    // the lock only to flip fbLatest. The UI thread takes the same lock only
    // to memcpy out of fbSlots[fbLatest]. This keeps the emulation thread
    // from ever blocking on the UI thread's copy.
    std::mutex fbMutex;
    FramebufferSlot fbSlots[2];
    int fbLatest = -1;
    int fbWriteNext = 0;
    // Bumped per publish (under fbMutex). The display link ticks 60x/s
    // regardless of whether the core produced a frame — at 0.5x speed
    // exactly half the ticks would otherwise re-copy and re-wrap 2x192 KB
    // into fresh CGImages that are bit-identical to what's on screen.
    uint64_t fbGeneration = 0;
    uint64_t fbPresented = 0;

    // Microphone input: written from a real-time-ish AVAudioEngine
    // input-tap block (see -beginMicrophoneEngineCapture) every time a
    // converted chunk of captured audio is ready, read from the emulation
    // thread inside Mic_ReadInput — called synchronously by melonDS's own
    // mic pump (Mic.cpp FeedBuffer/Advance, driven by SPU.cpp's
    // `NDS.Mic.Advance(...)`). Short mutex-guarded ring, symmetric to the
    // fbMutex pattern above: both critical sections are a fixed-size
    // in-memory loop, never blocking on I/O or allocation. Capacity is a
    // few multiples of one input-tap callback's worth of converted samples
    // (~100ms per callback at kMicTargetSampleRate, see
    // -beginMicrophoneEngineCapture) so writer/reader cadence jitter never
    // starves Mic_ReadInput.
    static constexpr int kMicRingCapacity = 24576; // ~515ms at ~47.7kHz mono
    std::mutex micMutex;
    std::array<s16, kMicRingCapacity> micRing{};
    int micRingReadPos = 0;
    int micRingWritePos = 0;
    int micRingLevel = 0;

    // Mirrors melonDS's own internal Mic::OpenMask exactly: true between the
    // core's Mic_Start and Mic_Stop calls (Platform:: has no getter for
    // OpenMask itself, so this is our own copy of that edge). Written from
    // whichever thread calls Mic_Start/Mic_Stop (always the emulation
    // thread in practice — see Mic.cpp/SPU.cpp/SPI.cpp/DSi_I2S.cpp call
    // sites), read from the main thread by -refreshMicrophoneCaptureState,
    // which decides from it (plus the Settings toggle, permission, and
    // pause state) whether AVAudioEngine capture should actually be
    // running — that *actual* capture state is what the bridge's public
    // `microphoneActive` property reports, not this raw core-side flag.
    std::atomic<bool> micCoreOpen{false};

    // Emulation thread lifecycle.
    std::thread emuThread;
    std::atomic<bool> threadAlive{false};
    std::atomic<bool> wantActive{false};
    std::atomic<bool> isStepping{false};
    std::atomic<bool> shouldStop{false};
    std::mutex syncMutex;
    std::condition_variable syncCV;
};

// Applies the latest UI-thread input state to the NDS core. Must only be
// called from the emulation thread, right before RunFrame(), so the core's
// own (non-thread-safe) input handling is only ever touched from one thread.
void ApplyPendingInput(Runtime *r) {
    if (!r->nds) return;

    r->nds->SetKeyMask(r->keyMask.load());

    bool pressed;
    u16 x, y;
    {
        std::lock_guard<std::mutex> lock(r->touchMutex);
        pressed = r->touchPressed;
        x = r->touchX;
        y = r->touchY;
    }
    if (pressed) {
        r->nds->TouchScreen(x, y);
    } else {
        r->nds->ReleaseScreen();
    }
}

// Copies melonDS's current front framebuffers into the presentation
// double-buffer and publishes them. Must only be called from the emulation
// thread, right after RunFrame().
void PublishFramebuffer(Runtime *r) {
    if (!r->nds) return;

    void *top = nullptr;
    void *bottom = nullptr;
    if (!r->nds->GPU.GetFramebuffers(&top, &bottom)) return;

    FramebufferSlot &slot = r->fbSlots[r->fbWriteNext];
    constexpr size_t byteCount = kFramebufferPixels * sizeof(u32);
    if (top) memcpy(slot.top.data(), top, byteCount);
    if (bottom) memcpy(slot.bottom.data(), bottom, byteCount);

    {
        std::lock_guard<std::mutex> lock(r->fbMutex);
        r->fbLatest = r->fbWriteNext;
        r->fbGeneration++;
    }
    r->fbWriteNext ^= 1;
}

void ClearRewind(Runtime *r) {
    std::lock_guard<std::mutex> lock(r->rewindMutex);
    std::vector<std::vector<u8>>().swap(r->rewindSlots);
    r->rewindHead = -1;
    r->rewindCount = 0;
    r->rewindFrames = 0;
}

// Emulation thread, between frames — the core is not mid-RunFrame, so
// serializing here needs no pause.
void CaptureRewindIfDue(Runtime *r, int frames) {
    if (!r->rewindEnabled.load()) return;
    {
        std::lock_guard<std::mutex> lock(r->rewindMutex);
        r->rewindFrames += frames;
        if (r->rewindFrames < kRewindCaptureFrames) return;
        r->rewindFrames = 0;
    }
    melonDS::Savestate state(kSavestateInitialSize);
    if (state.Error || !r->nds->DoSavestate(&state) || state.Error) return;
    const u8 *bytes = static_cast<const u8 *>(state.Buffer());

    std::lock_guard<std::mutex> lock(r->rewindMutex);
    if (r->rewindSlots.empty()) r->rewindSlots.resize(kRewindMaxSlots);
    const int next = (r->rewindHead + 1) % kRewindMaxSlots;
    r->rewindSlots[next].assign(bytes, bytes + state.Length());
    r->rewindHead = next;
    if (r->rewindCount < kRewindMaxSlots) r->rewindCount++;
}

void EmuThreadMain(Runtime *r) {
    // Best-effort: run the emulation loop at a high, interactive QoS so it
    // isn't starved by background work. Not fatal if unsupported.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    using Clock = std::chrono::steady_clock; // mach_absolute_time-backed on Darwin
    const auto frameDuration = std::chrono::duration_cast<Clock::duration>(
        std::chrono::duration<double>(kNDSFrameSeconds));
    auto nextTick = Clock::now();

    // Carries the fractional remainder of `speed` between ticks so speeds
    // below 1.0 (0.5x slow motion) can run a real frame every *other* tick
    // instead of being floored to "0 frames forever" — see the frame-count
    // computation below.
    double frameAccumulator = 0.0;

    while (true) {
        // The "should we step this tick" decision and the isStepping=true
        // transition happen together under syncMutex, the same lock
        // PauseAndWaitIdle uses around its wantActive-then-isStepping check.
        // Without sharing the lock across both halves, a pauser could read
        // isStepping as still-false in the narrow window after this thread
        // has already committed to stepping but before it flips the flag,
        // and wrongly conclude it's safe to mutate the NDS core concurrently
        // with RunFrame().
        {
            std::unique_lock<std::mutex> lock(r->syncMutex);
            if (r->shouldStop.load()) break;
            if (!r->wantActive.load()) {
                r->syncCV.wait_for(lock, std::chrono::milliseconds(50), [&] {
                    return r->wantActive.load() || r->shouldStop.load();
                });
                nextTick = Clock::now();
                frameAccumulator = 0.0;
                continue;
            }
            r->isStepping.store(true);
        }

        if (r->nds) {
            // Frame accumulator, not a plain per-tick frame count: this is
            // what makes speeds below 1.0 (0.5x slow motion) possible under
            // this fixed-tick-rate loop, where a single RunFrame() is the
            // smallest unit of progress — below 1x, some ticks legitimately
            // run zero frames instead of a fractional one. At speed >= 1.0
            // this computes exactly what the old std::lround-based version
            // did (no remainder ever survives a whole-number speed).
            // std::min(8, ...) keeps the same runaway cap as before.
            frameAccumulator += r->speed.load();
            const int framesThisTick = std::min(8, static_cast<int>(frameAccumulator));
            frameAccumulator -= framesThisTick;

            for (int i = 0; i < framesThisTick; i++) {
                ApplyPendingInput(r);
                r->nds->RunFrame();
                if (i + 1 < framesThisTick) {
                    // This frame only exists to advance emulation faster than
                    // real time; drop the audio it produced instead of
                    // forwarding it, so playback speed/pitch on the "real"
                    // cadence frame stays correct instead of the SPU ring
                    // buffer overflowing.
                    r->nds->SPU.TrimOutput();
                }
            }
            if (framesThisTick > 0) {
                PublishFramebuffer(r);
                CaptureRewindIfDue(r, framesThisTick);
            }
        }

        {
            std::lock_guard<std::mutex> lock(r->syncMutex);
            r->isStepping.store(false);
        }
        r->syncCV.notify_all();

        // Fixed-timestep pacing: advance the target by exactly one frame
        // duration and sleep until then. If we fell behind (device too slow
        // to keep up, e.g. at 2x speed), resync to now instead of spiraling
        // into an ever-growing catch-up loop.
        nextTick += frameDuration;
        const auto now = Clock::now();
        if (nextTick < now) {
            nextTick = now;
        } else {
            std::this_thread::sleep_until(nextTick);
        }
    }
}

// Pauses frame stepping and blocks the calling thread until the emulation
// thread has confirmed it is idle (i.e. not mid-RunFrame). Returns whether
// stepping was active beforehand, to be passed to ResumeIfNeeded. Used to
// safely touch the NDS core (reset/save state/load state) from outside the
// emulation thread without racing it. If the thread was never started this
// resolves immediately (isStepping is never true).
//
// Holds syncMutex across both the wantActive exchange and the isStepping
// wait so this can never interleave with the matching critical section in
// EmuThreadMain above (see the comment there for why that matters).
bool PauseAndWaitIdle(Runtime *r) {
    std::unique_lock<std::mutex> lock(r->syncMutex);
    const bool wasActive = r->wantActive.exchange(false);
    r->syncCV.notify_all();
    r->syncCV.wait(lock, [&] { return !r->isStepping.load(); });
    return wasActive;
}

void ResumeIfNeeded(Runtime *r, bool wasActive) {
    if (!wasActive) return;
    r->wantActive.store(true);
    r->syncCV.notify_all();
}

// Real-time audio render callback body. Pulls interleaved S16 stereo samples
// straight out of melonDS's own SPU output ring (already internally
// mutex-guarded by melonDS, see SPU::ReadOutput/BufferAudio in SPU.cpp),
// converts to the engine's planar Float32 format, and applies volume. Never
// allocates: `outputData` buffers are engine-owned and `audioScratch` is a
// fixed-size member of Runtime.
OSStatus RenderAudio(Runtime *r, AVAudioFrameCount frameCount, AudioBufferList *outputData) {
    float *left = outputData->mNumberBuffers > 0 ? static_cast<float *>(outputData->mBuffers[0].mData) : nullptr;
    float *right = outputData->mNumberBuffers > 1 ? static_cast<float *>(outputData->mBuffers[1].mData) : nullptr;

    const AVAudioFrameCount framesToRequest = std::min<AVAudioFrameCount>(frameCount, kAudioScratchFrames);
    int framesRead = 0;
    if (NDS *nds = r->nds.get()) {
        framesRead = nds->SPU.ReadOutput(r->audioScratch.data(), static_cast<int>(framesToRequest));
    }

    const float volume = r->outputDucked.load() ? 0.0f : static_cast<float>(r->volume.load());
    for (AVAudioFrameCount i = 0; i < frameCount; i++) {
        float l = 0.0f, rr = 0.0f;
        if (static_cast<int>(i) < framesRead) {
            l = (r->audioScratch[i * 2 + 0] / 32768.0f) * volume;
            rr = (r->audioScratch[i * 2 + 1] / 32768.0f) * volume;
        }
        if (left) left[i] = l;
        if (right) right[i] = rr;
    }

    return noErr;
}

// Pushes `count` freshly captured/converted mono S16 samples into the mic
// ring, called from the AVAudioEngine input-tap block (see
// -beginMicrophoneEngineCapture) — a real-time-ish audio thread, per Apple's
// own AVAudioNodeTapBlock docs ("may be invoked on a thread other than the
// main thread"). If the ring is already full, evicts the oldest samples
// first: a live mic should stay live (freshest audio kept) rather than
// stalling capture and falling further and further behind.
void PushMicSamples(Runtime *r, const s16 *samples, int count) {
    if (!r || !samples || count <= 0) return;
    std::lock_guard<std::mutex> lock(r->micMutex);

    if (count > Runtime::kMicRingCapacity) {
        // Pathological: a single callback delivered more than the ring can
        // ever hold. Keep only the most recent kMicRingCapacity samples.
        samples += (count - Runtime::kMicRingCapacity);
        count = Runtime::kMicRingCapacity;
    }

    const int freeSpace = Runtime::kMicRingCapacity - r->micRingLevel;
    if (count > freeSpace) {
        const int evict = count - freeSpace;
        r->micRingReadPos = (r->micRingReadPos + evict) % Runtime::kMicRingCapacity;
        r->micRingLevel -= evict;
    }

    for (int i = 0; i < count; i++) {
        r->micRing[r->micRingWritePos] = samples[i];
        r->micRingWritePos = (r->micRingWritePos + 1) % Runtime::kMicRingCapacity;
    }
    r->micRingLevel += count;
}

// Pops up to `maxCount` samples into `out`, called from the emulation thread
// inside Mic_ReadInput. Returns the number of real samples actually
// available (0...maxCount); the caller is responsible for silence-padding
// any shortfall, matching the pre-existing stub's "always fully satisfy the
// request" contract.
int PopMicSamples(Runtime *r, s16 *out, int maxCount) {
    if (!r || !out || maxCount <= 0) return 0;
    std::lock_guard<std::mutex> lock(r->micMutex);

    const int n = std::min(maxCount, r->micRingLevel);
    for (int i = 0; i < n; i++) {
        out[i] = r->micRing[r->micRingReadPos];
        r->micRingReadPos = (r->micRingReadPos + 1) % Runtime::kMicRingCapacity;
    }
    r->micRingLevel -= n;
    return n;
}

} // namespace

@interface MelonDSCoreBridge ()
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) AVAudioSourceNode *audioSourceNode;
// Retained for as long as the input tap is installed. The tap block also
// captures it directly (blocks retain what they capture), so this property
// mainly exists to give -removeMicrophoneTapAndRevertToPlayback a clean,
// single place to release it instead of relying on tap teardown timing.
@property (nonatomic, strong, nullable) AVAudioConverter *microphoneConverter;
- (void)writeNDSSaveBytes:(const void *)bytes length:(uint32_t)length;
// Mirror the WriteNDSSave forwarding pattern just above/below this
// extension: melonDS's Platform:: free functions below only ever receive
// this bridge instance as `userdata`, so Mic_Start/Mic_Stop/Mic_ReadInput
// forward straight into these three methods, which then touch `_runtime`
// and AVFoundation directly as regular instance methods.
- (void)micCoreDidOpen;
- (void)micCoreDidClose;
- (void)micFillInput:(int16_t *)data maxLength:(int)maxLength;
@end

namespace melonDS::Platform {

struct FileHandle { FILE *file; };
struct Thread { std::thread thread; explicit Thread(std::function<void()> func) : thread(std::move(func)) {} };
struct Mutex { std::mutex mutex; };
struct Semaphore { std::mutex mutex; std::condition_variable cv; int count = 0; };
struct AACDecoder {};
struct DynamicLibrary {};

std::string GetLocalFilePath(const std::string& filename) { return filename; }
bool FileExists(const std::string& name) { return access(name.c_str(), F_OK) == 0; }
bool LocalFileExists(const std::string& name) { return FileExists(name); }

static const char *ModeString(FileMode mode) {
    const bool read = (mode & FileMode::Read) != 0;
    const bool write = (mode & FileMode::Write) != 0;
    const bool preserve = (mode & FileMode::Preserve) != 0;
    const bool append = (mode & FileMode::Append) != 0;
    if (read && write) return preserve ? "r+b" : "w+b";
    if (write) return append ? "ab" : "wb";
    return "rb";
}

FileHandle* OpenFile(const std::string& path, FileMode mode) {
    FILE *file = fopen(path.c_str(), ModeString(mode));
    if (!file && (mode & FileMode::Write) && (mode & FileMode::Preserve)) {
        file = fopen(path.c_str(), "w+b");
    }
    return file ? new FileHandle{file} : nullptr;
}

FileHandle* OpenLocalFile(const std::string& path, FileMode mode) { return OpenFile(path, mode); }

bool CheckFileWritable(const std::string& filepath) {
    if (FILE *file = fopen(filepath.c_str(), "ab")) {
        fclose(file);
        return true;
    }
    return false;
}

bool CheckLocalFileWritable(const std::string& filepath) { return CheckFileWritable(filepath); }
bool CloseFile(FileHandle* file) { if (!file) return false; int result = fclose(file->file); delete file; return result == 0; }
bool IsEndOfFile(FileHandle* file) { return !file || feof(file->file); }
bool FileReadLine(char* str, int count, FileHandle* file) { return file && fgets(str, count, file->file); }
u64 FilePosition(FileHandle* file) { return file ? static_cast<u64>(ftell(file->file)) : 0; }
bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin) {
    if (!file) return false;
    int whence = SEEK_SET;
    if (origin == FileSeekOrigin::Current) whence = SEEK_CUR;
    if (origin == FileSeekOrigin::End) whence = SEEK_END;
    return fseek(file->file, static_cast<long>(offset), whence) == 0;
}
void FileRewind(FileHandle* file) { if (file) rewind(file->file); }
u64 FileRead(void* data, u64 size, u64 count, FileHandle* file) { return file ? fread(data, static_cast<size_t>(size), static_cast<size_t>(count), file->file) : 0; }
bool FileFlush(FileHandle* file) { return file && fflush(file->file) == 0; }
u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file) { return file ? fwrite(data, static_cast<size_t>(size), static_cast<size_t>(count), file->file) : 0; }
u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...) {
    if (!file) return 0;
    va_list args;
    va_start(args, fmt);
    int written = vfprintf(file->file, fmt, args);
    va_end(args);
    return written > 0 ? static_cast<u64>(written) : 0;
}
u64 FileLength(FileHandle* file) {
    if (!file) return 0;
    long pos = ftell(file->file);
    fseek(file->file, 0, SEEK_END);
    long len = ftell(file->file);
    fseek(file->file, pos, SEEK_SET);
    return len > 0 ? static_cast<u64>(len) : 0;
}

// Core chatter (ROM path, game title, cart type) stays out of the Release
// console — same rule as Swift's `debugLog`.
void Log(LogLevel level, const char* fmt, ...) {
#if DEBUG
    va_list args;
    va_start(args, fmt);
    NSString *format = [[NSString alloc] initWithUTF8String:fmt ?: ""];
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[melonDS:%d] %@", level, message);
#else
    (void)level; (void)fmt;
#endif
}

Thread* Thread_Create(std::function<void()> func) { return new Thread(std::move(func)); }
void Thread_Free(Thread* thread) { delete thread; }
void Thread_Wait(Thread* thread) { if (thread && thread->thread.joinable()) thread->thread.join(); }

Semaphore* Semaphore_Create() { return new Semaphore(); }
void Semaphore_Free(Semaphore* sema) { delete sema; }
void Semaphore_Reset(Semaphore* sema) { if (sema) { std::lock_guard<std::mutex> lock(sema->mutex); sema->count = 0; } }
void Semaphore_Wait(Semaphore* sema) { if (!sema) return; std::unique_lock<std::mutex> lock(sema->mutex); sema->cv.wait(lock, [&]{ return sema->count > 0; }); --sema->count; }
bool Semaphore_TryWait(Semaphore* sema, int timeout_ms) {
    if (!sema) return false;
    std::unique_lock<std::mutex> lock(sema->mutex);
    bool ok = timeout_ms <= 0
        ? sema->count > 0
        : sema->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&]{ return sema->count > 0; });
    if (ok) --sema->count;
    return ok;
}
void Semaphore_Post(Semaphore* sema, int count) { if (sema) { std::lock_guard<std::mutex> lock(sema->mutex); sema->count += count; sema->cv.notify_all(); } }

Mutex* Mutex_Create() { return new Mutex(); }
void Mutex_Free(Mutex* mutex) { delete mutex; }
void Mutex_Lock(Mutex* mutex) { if (mutex) mutex->mutex.lock(); }
void Mutex_Unlock(Mutex* mutex) { if (mutex) mutex->mutex.unlock(); }
bool Mutex_TryLock(Mutex* mutex) { return mutex && mutex->mutex.try_lock(); }

void Sleep(u64 usecs) { std::this_thread::sleep_for(std::chrono::microseconds(usecs)); }
u64 GetMSCount() { return static_cast<u64>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()); }
u64 GetUSCount() { return static_cast<u64>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()); }

void SignalStop(StopReason, void*) {}
void WriteNDSSave(const u8* savedata, u32 savelen, u32, u32, void* userdata) {
    if (!userdata || !savedata || savelen == 0) return;
    MelonDSCoreBridge *bridge = (__bridge MelonDSCoreBridge *)userdata;
    [bridge writeNDSSaveBytes:savedata length:savelen];
}
void WriteGBASave(const u8*, u32, u32, u32, void*) {}
void WriteFirmware(const Firmware&, u32, u32, void*) {}
void WriteDateTime(int, int, int, int, int, int, void*) {}

// Local multiplayer. These nine are called from the emulation thread
// (Wifi.cpp) and are the only hook melonDS offers: `net/` is not compiled and
// `MPInterface` belongs to the Qt frontend. With no transport installed they
// return exactly what they returned as stubs, so an ordinary game pays
// nothing and the binary gains no networking API.
//
// `mpInstance` returns -1 when this core is not in a multiplayer game, which
// is the usual case.
static inline int mpInstance(void *userdata, eNDS::MPTransport **transport) {
    *transport = eNDS::currentTransport();
    if (!*transport || !userdata) return -1;
    return eNDS::instanceForUserdata(userdata);
}

void MP_Begin(void* userdata) {
    eNDS::MPTransport *mp; int inst = mpInstance(userdata, &mp);
    if (inst >= 0) mp->begin(inst);
}
void MP_End(void* userdata) {
    eNDS::MPTransport *mp; int inst = mpInstance(userdata, &mp);
    if (inst >= 0) mp->end(inst);
}
int MP_SendPacket(u8* data, int len, u64 ts, void* userdata) {
    eNDS::MPTransport *mp; int inst = mpInstance(userdata, &mp);
    return inst < 0 ? 0 : mp->sendPacket(inst, data, len, ts);
}
int MP_RecvPacket(u8* data, u64* ts, void* userdata) {
    eNDS::MPTransport *mp; int inst = mpInstance(userdata, &mp);
    return inst < 0 ? 0 : mp->recvPacket(inst, data, ts);
}
int MP_SendCmd(u8* data, int len, u64 ts, void* userdata) {
    eNDS::MPTransport *mp; int inst = mpInstance(userdata, &mp);
    return inst < 0 ? 0 : mp->sendCmd(inst, data, len, ts);
}
int MP_SendReply(u8* data, int len, u64 ts, u16 aid, void* userdata) {
    eNDS::MPTransport *mp; int inst = mpInstance(userdata, &mp);
    return inst < 0 ? 0 : mp->sendReply(inst, data, len, ts, aid);
}
int MP_SendAck(u8* data, int len, u64 ts, void* userdata) {
    eNDS::MPTransport *mp; int inst = mpInstance(userdata, &mp);
    return inst < 0 ? 0 : mp->sendAck(inst, data, len, ts);
}
int MP_RecvHostPacket(u8* data, u64* ts, void* userdata) {
    eNDS::MPTransport *mp; int inst = mpInstance(userdata, &mp);
    return inst < 0 ? 0 : mp->recvHostPacket(inst, data, ts);
}
u16 MP_RecvReplies(u8* data, u64 ts, u16 aidmask, void* userdata) {
    eNDS::MPTransport *mp; int inst = mpInstance(userdata, &mp);
    return inst < 0 ? 0 : mp->recvReplies(inst, data, ts, aidmask);
}
int Net_SendPacket(u8*, int, void*) { return 0; }
int Net_RecvPacket(u8*, void*) { return 0; }
void Camera_Start(int, void*) {}
void Camera_Stop(int, void*) {}
void Camera_CaptureFrame(int, u32* frame, int width, int height, bool, void*) { if (frame) memset(frame, 0, width * height * sizeof(u32)); }
// Called synchronously from the emulation thread — always from inside a
// melonDS RunFrame() call chain (Mic.cpp Start/Stop, driven by SPI.cpp's DS
// TSC-mic reads, DSi_I2S.cpp/DSi_DSP.cpp's DSi mic hardware paths, or
// Mic::DoSavestate on a state load). Both methods must return immediately —
// never block the emu thread on a permission dialog or AVAudioSession/
// AVAudioEngine reconfiguration — so they only flip an atomic and hop the
// real work to the main thread. See MelonDSCoreBridge's "Microphone"
// section for -micCoreDidOpen/-micCoreDidClose.
void Mic_Start(void* userdata) {
    if (!userdata) return;
    [(__bridge MelonDSCoreBridge *)userdata micCoreDidOpen];
}

void Mic_Stop(void* userdata) {
    if (!userdata) return;
    [(__bridge MelonDSCoreBridge *)userdata micCoreDidClose];
}

// Called synchronously from the emulation thread (Mic::FeedBuffer, up to a
// few times per RunFrame — see Mic.cpp). `data`/`maxlength` are always
// fully satisfied: real captured samples first, silence-padded for any
// shortfall (no mic yet started, permission pending/denied, toggle off, or
// the input-tap thread simply hasn't delivered enough yet) — matching the
// original stub's contract exactly, so an idle/disabled mic behaves exactly
// as before this feature existed.
int Mic_ReadInput(s16* data, int maxlength, void* userdata) {
    if (!data || maxlength <= 0) return maxlength;
    if (userdata) {
        [(__bridge MelonDSCoreBridge *)userdata micFillInput:data maxLength:maxlength];
    } else {
        memset(data, 0, static_cast<size_t>(maxlength) * sizeof(s16));
    }
    return maxlength;
}
AACDecoder* AAC_Init() { return nullptr; }
void AAC_DeInit(AACDecoder*) {}
bool AAC_Configure(AACDecoder*, int, int) { return false; }
bool AAC_DecodeFrame(AACDecoder*, const void*, int, void*, int) { return false; }
bool Addon_KeyDown(KeyType, void*) { return false; }
void Addon_RumbleStart(u32, void*) {}
void Addon_RumbleStop(void*) {}
float Addon_MotionQuery(MotionQueryType, void*) { return 0.0f; }
DynamicLibrary* DynamicLibrary_Load(const char*) { return nullptr; }
void DynamicLibrary_Unload(DynamicLibrary*) {}
void* DynamicLibrary_LoadFunction(DynamicLibrary*, const char*) { return nullptr; }

} // namespace melonDS::Platform

@implementation MelonDSCoreBridge {
    Runtime *_runtime;
    // Main-thread-confined (every method that touches it is reached only
    // from main-thread call sites — see the "Microphone" section below), so
    // unlike the Runtime fields above this needs no lock/atomic of its own.
    BOOL _microphoneCaptureActive;
    // Last -ensureAudioIsRunning check, so that watchdog can be called from
    // the frame loop without doing per-frame work. Main-thread-confined like
    // the flag below it.
    CFTimeInterval _lastAudioWatchdogTime;
    // Set at the top of -dealloc. melonDS re-enters this object while the
    // core shuts down, and a __weak self formed then is a fatal error — see
    // -micCoreDidClose. Written on the deallocating thread, read wherever
    // the core calls back in (the emulation thread for Mic_Start/Mic_Stop,
    // whichever thread AVFoundation posts its notifications on), hence
    // atomic rather than a plain BOOL.
    std::atomic<bool> _tearingDown;
    // Serial, utility QoS: every battery-save and autosave write goes
    // through here, in order, off the emulation thread. Draining it
    // (-flushPendingSaveWrites) is what "the file is on disk" means.
    dispatch_queue_t _saveQueue;
    // The armed "stop capture" half of -refreshMicrophoneCaptureState,
    // while the game's mic window is closed but the debounce hasn't run out
    // (see kMicCloseDebounceNanoseconds). Main-thread-confined; nil when
    // nothing is pending.
    dispatch_block_t _pendingMicrophoneTeardown;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _runtime = new Runtime();
        dispatch_queue_attr_t saveQueueAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _saveQueue = dispatch_queue_create("com.mls.inds.melonds.save", saveQueueAttr);
        // -1, not 0: 0 is a real Firmware::Language (Japanese), so the
        // "caller never set one" default has to sit outside the enum.
        _firmwareLanguage = -1;
        NSNumber *storedVolume = [[NSUserDefaults standardUserDefaults] objectForKey:@"eNDSAudioVolume"];
        double initialVolume = storedVolume ? storedVolume.doubleValue : 1.0;
        _runtime->volume.store(std::clamp(initialVolume, 0.0, 1.0));
    }
    return self;
}

- (void)dealloc {
    // Must be set BEFORE -stopEmulation: tearing the core down re-enters this
    // object from melonDS (see -micCoreDidClose), and anything that forms a
    // __weak self from there would abort the process.
    _tearingDown.store(true);
    [NSNotificationCenter.defaultCenter removeObserver:self];
    // -stopEmulation drains the save queue after the core is gone, so no
    // queued write can outlive the Runtime deleted right after.
    [self stopEmulation];
    delete _runtime;
}

#pragma mark - State

- (BOOL)loaded {
    return _runtime->nds != nullptr && _runtime->nds->CartInserted();
}

- (BOOL)running {
    return _runtime->nds != nullptr && _runtime->wantActive.load();
}

- (NSString *)statusText {
    return [NSString stringWithUTF8String:_runtime->status.c_str()];
}

- (BOOL)hasAutoSaveState {
    NSString *path = [self autoSaveStatePathForROM];
    return path != nil && [NSFileManager.defaultManager fileExistsAtPath:path];
}

- (double)audioVolume {
    return _runtime->volume.load();
}

- (void)setAudioVolume:(double)audioVolume {
    double clamped = std::clamp(audioVolume, 0.0, 1.0);
    _runtime->volume.store(clamped);
    [[NSUserDefaults standardUserDefaults] setDouble:clamped forKey:@"eNDSAudioVolume"];
}

- (BOOL)outputDucked {
    return _runtime->outputDucked.load();
}

- (void)setOutputDucked:(BOOL)outputDucked {
    // Deliberately not written to UserDefaults: this is a live-session mute,
    // unlike `audioVolume`, which is the user's own setting.
    _runtime->outputDucked.store(outputDucked);
}

- (double)speedMultiplier {
    return _runtime->speed.load();
}

- (void)setSpeedMultiplier:(double)speedMultiplier {
    // Ceiling is 4x, the fastest rate the Fast Forward button offers. It is
    // a target, not a promise: the interpreter does not reach 4x on a phone
    // in a heavy game, and the frame loop simply runs as many frames as the
    // tick allows. That is the difference from the old PRO-gated 4x this
    // replaces — that one was sold, this one is "as fast as this device
    // goes". The 8-frames-per-tick cap in EmuThreadMain is the real fence.
    _runtime->speed.store(std::clamp(speedMultiplier, 0.5, 4.0));
}

- (BOOL)microphoneActive {
    return _microphoneCaptureActive;
}

#pragma mark - Loading

/// Writes the console profile into a generated firmware image's user
/// settings. Direct boot copies these 0x70 bytes verbatim into main RAM at
/// 0x027FFC80 (see SPI.cpp's FirmwareMem::SetupDirectBoot), which is where
/// every DS game reads the owner's name and system language from — so this
/// is the whole mechanism behind a game offering "melonDS" as your name.
///
/// Both copies of the user data are written, not just the effective one:
/// which of the two counts depends on their update counters and checksums,
/// and a generated image has them identical, so writing both keeps it that
/// way instead of leaving a stale second copy that could win later.
static void ApplyConsoleProfile(melonDS::Firmware &firmware, NSString *nickname, NSInteger language) {
    for (melonDS::Firmware::UserData &user : firmware.GetUserData()) {
        if (nickname.length > 0) {
            unichar buffer[10] = {0};
            NSUInteger count = MIN((NSUInteger)10, nickname.length);
            [nickname getCharacters:buffer range:NSMakeRange(0, count)];
            // Never cut a surrogate pair in half — half an emoji is not a
            // character the DS (or anything else) can render.
            if (count > 0 && CFStringIsSurrogateHighCharacter(buffer[count - 1])) count--;

            memset(user.Nickname, 0, sizeof(user.Nickname));
            memcpy(user.Nickname, buffer, count * sizeof(char16_t));
            user.NameLength = (melonDS::u16)count;
        }
        if (language >= melonDS::Firmware::Language::Japanese &&
            language <= melonDS::Firmware::Language::Spanish) {
            // Language is the low 3 bits of Settings; the rest of that field
            // is backlight level, GBA screen and so on, and must survive.
            user.Settings = (user.Settings & ~0x7) | (melonDS::u16)language;
            if (user.ExtendedSettings.Unknown0 == 0x01) { // DSi-style extended block
                user.ExtendedSettings.ExtendedLanguage = (melonDS::Firmware::Language)language;
            }
        }
        user.UpdateChecksum();
    }

#if DEBUG
    // The write only counts if melonDS agrees it is intact: a stale checksum
    // makes GetEffectiveUserData fall back to the other copy (SPI_Firmware.cpp),
    // which would hand the game the old profile with no sign anything failed.
    const melonDS::Firmware::UserData &effective = firmware.GetEffectiveUserData();
    NSCAssert(effective.ChecksumValid(), @"Console profile left the firmware user data corrupt");
    if (nickname.length > 0) {
        NSString *readBack = [NSString stringWithCharacters:(const unichar *)effective.Nickname
                                                     length:effective.NameLength];
        NSCAssert(readBack.length > 0 && [nickname hasPrefix:readBack],
                  @"Console nickname did not survive the firmware write: %@ -> %@", nickname, readBack);
    }
#endif
}

- (BOOL)loadROMAtPath:(NSString *)romPath biosDirectory:(NSString *)biosDirectory error:(NSError **)error {
    // Nothing in the core is `noexcept`: `std::bad_alloc` from the ROM/NDS
    // buffers under memory pressure would otherwise cross into Swift as
    // std::terminate. Failed halfway = torn down, reported, not crashed.
    try {
        return [self loadROMAtPathUnchecked:romPath biosDirectory:biosDirectory error:error];
    } catch (const std::exception& e) {
        [self stopEmulation];
        if (error) *error = MakeError(1, @"Unable to read ROM data.");
        return NO;
    }
}

- (BOOL)loadROMAtPathUnchecked:(NSString *)romPath biosDirectory:(NSString *)biosDirectory error:(NSError **)error {
    // Tear down any previously loaded session first so a reload on an
    // already-active bridge can never leak the emulation thread or race the
    // NDS instance it's about to replace.
    [self stopEmulation];

    u32 romLength = 0;
    std::unique_ptr<u8[]> romData = ReadFileOwned(romPath.fileSystemRepresentation, romLength);
    if (!romData) {
        if (error) *error = MakeError(1, @"Unable to read ROM data.");
        return NO;
    }

    NSError *directoryError = nil;
    NSURL *documentsURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *savesURL = [documentsURL URLByAppendingPathComponent:@"Saves" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:savesURL withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        if (error) *error = directoryError ?: MakeError(2, @"Unable to create Saves directory.");
        return NO;
    }
    NSString *fileName = romPath.lastPathComponent;
    NSString *baseName = fileName.stringByDeletingPathExtension;
    NSURL *saveURL = [savesURL URLByAppendingPathComponent:[baseName stringByAppendingPathExtension:@"sav"]];
    std::string savePath = saveURL.path.fileSystemRepresentation;

    // BIOS + firmware are optional. melonDS's NDSArgs already defaults to
    // FreeBIOS and a generated firmware image (see Args.h), both of which
    // support direct-booting a ROM with no user-supplied dumps at all. When
    // real dumps are present in biosDirectory, swap them in for better
    // compatibility; anything missing/invalid just falls back to the default.
    std::string biosDir = biosDirectory.fileSystemRepresentation;
    melonDS::NDSArgs args;
    args.JIT = std::nullopt;
    args.OutputSampleRate = kAudioOutputSampleRate;

    std::array<u8, melonDS::ARM9BIOSSize> arm9{};
    if (ReadFixedFile(biosDir + "/bios9.bin", arm9)) {
        args.ARM9BIOS = std::make_unique<melonDS::ARM9BIOSImage>(arm9);
    }
    std::array<u8, melonDS::ARM7BIOSSize> arm7{};
    if (ReadFixedFile(biosDir + "/bios7.bin", arm7)) {
        args.ARM7BIOS = std::make_unique<melonDS::ARM7BIOSImage>(arm7);
    }
    std::vector<u8> firmwareData;
    // BIOSManager only admits 256/512 KB dumps, but Documents/BIOS is
    // Files-app-browsable too; keep the core's assumptions honest.
    if (ReadFile(biosDir + "/firmware.bin", firmwareData)
        && (firmwareData.size() == 256 * 1024 || firmwareData.size() == 512 * 1024)) {
        args.Firmware = melonDS::Firmware(firmwareData.data(), static_cast<u32>(firmwareData.size()));
    } else {
        // Generated firmware: melonDS names its owner "melonDS" and speaks
        // English (SPI_Firmware.cpp's DEFAULT_USERNAME / UserData ctor).
        // Both are visible to the player — see ApplyConsoleProfile.
        ApplyConsoleProfile(args.Firmware, self.firmwareNickname, self.firmwareLanguage);
    }

    auto nds = std::make_unique<melonDS::NDS>(std::move(args), (__bridge void *)self);
    melonDS::NDSCart::NDSCartArgs cartArgs {};
    std::vector<u8> saveData;
    if (ReadFile(savePath, saveData) && !saveData.empty()) {
        cartArgs.SRAMLength = static_cast<u32>(saveData.size());
        cartArgs.SRAM = std::make_unique<u8[]>(saveData.size());
        memcpy(cartArgs.SRAM.get(), saveData.data(), saveData.size());
    }
    // The owning overload: the cart takes this buffer as-is instead of
    // copying it, so the image exists exactly once from here on.
    auto cart = melonDS::NDSCart::ParseROM(
        std::move(romData),
        romLength,
        (__bridge void *)self,
        std::make_optional(std::move(cartArgs))
    );
    if (!cart) {
        if (error) *error = MakeError(3, @"melonDS rejected this ROM header.");
        return NO;
    }

    std::string romFileNameStd = fileName.UTF8String;

    nds->SetNDSCart(std::move(cart));

    // melonDS builds its software renderer with the 3D rasteriser pinned to a
    // single thread (GPU3D_Soft.h: `bool Threaded = false`) and only ever
    // changes that through SetRenderSettings — which nothing here was calling.
    // Every iPhone was rasterising 3D on one core with the rest idle. This is
    // the one real performance knob melonDS exposes on iOS: the JIT is off the
    // table (no W^X on the App Store) and frame skip trades away picture
    // instead of using hardware we already have.
    {
        melonDS::RendererSettings settings {};
        settings.ScaleFactor = 1;         // the software renderer never upscales
        settings.Threaded = INDSThreadedRenderingEnabled();
        settings.HiresCoordinates = false;
        settings.BetterPolygons = false;  // OpenGL-only knob
        nds->GPU.GetRenderer().SetRenderSettings(settings);
    }

    nds->Reset();
    nds->SetupDirectBoot(romFileNameStd);
    nds->Start();

    _runtime->nds = std::move(nds);
    ClearRewind(_runtime); // another game's states must never load into this one
    _runtime->savePath = savePath;
    _runtime->romFileName = romFileNameStd;
    _runtime->romBaseName = baseName.UTF8String;
    _runtime->status = "melonDS core loaded";
    _runtime->fbLatest = -1;
    _runtime->fbWriteNext = 0;
    return YES;
}

#pragma mark - Emulation lifecycle

// .playback + .mixWithOthers, the same pair iGBA uses (EmuCore.mm): plays
// regardless of the silent switch, and still lets the player's own music keep
// going (which is also what keeps Settings > Audio's "Mute While Other Audio
// Plays" working — that hint notification is only delivered to a mixable
// session).
//
// This used to be .ambient, which is silenced by the silent switch. That was
// defensible on its own, but not next to the microphone window below:
// .playAndRecord ignores the switch no matter what, so with the phone on
// silent a game that touches the DS mic had sound and a game that didn't was
// mute — reported as "the games needing the microphone are the ones I can
// hear". Both categories now behave the same way for the player.
//
// This is the session's resting state, and the one place that sets it, so
// output setup and mic teardown can never disagree about what "resting" means.
- (void)activatePlaybackCategory {
    [self setSessionCategory:AVAudioSessionCategoryPlayback
                     options:AVAudioSessionCategoryOptionMixWithOthers];
    NSError *sessionError = nil;
    if (![AVAudioSession.sharedInstance setActive:YES error:&sessionError]) {
        NSLog(@"[melonDS] Failed to activate audio session: %@", sessionError);
    }
}

// The single funnel for category changes, because a category change is the
// only thing in this file that can move the audio *hardware* underneath the
// engine — and therefore the only thing that can re-enter
// -handleAudioEngineConfigurationChange:. Asking for the category we are
// already in is skipped outright rather than handed to CoreAudio to
// short-circuit: that is what makes the rebuild path provably settle (it
// re-derives the same category, finds it already set, and stops) instead of
// risking a change/notification/rebuild/change loop.
- (BOOL)setSessionCategory:(AVAudioSessionCategory)category options:(AVAudioSessionCategoryOptions)options {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if ([session.category isEqualToString:category] && session.categoryOptions == options) return YES;

    NSError *sessionError = nil;
    if ([session setCategory:category withOptions:options error:&sessionError]) return YES;
    NSLog(@"[melonDS] Failed to set audio session category %@: %@", category, sessionError);
    return NO;
}

- (void)setUpAudioEngineIfNeeded {
    if (self.audioEngine) return;

    [self activatePlaybackCategory];

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioFormat *format = [self outputFormat];

    Runtime *runtime = _runtime;
    AVAudioSourceNodeRenderBlock renderBlock = ^OSStatus(BOOL *isSilence,
                                                          const AudioTimeStamp *timestamp,
                                                          AVAudioFrameCount frameCount,
                                                          AudioBufferList *outputData) {
        if (isSilence) *isSilence = NO;
        return RenderAudio(runtime, frameCount, outputData);
    };

    AVAudioSourceNode *node = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:renderBlock];
    [engine attachNode:node];
    [engine connect:node to:engine.mainMixerNode format:format];

    self.audioEngine = engine;
    self.audioSourceNode = node;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(handleAudioEngineConfigurationChange:)
                   name:AVAudioEngineConfigurationChangeNotification
                 object:engine];
    [center addObserver:self
               selector:@selector(handleAudioSessionInterruption:)
                   name:AVAudioSessionInterruptionNotification
                 object:AVAudioSession.sharedInstance];
    [center addObserver:self
               selector:@selector(handleMediaServicesWereReset:)
                   name:AVAudioSessionMediaServicesWereResetNotification
                 object:AVAudioSession.sharedInstance];
}

- (AVAudioFormat *)outputFormat {
    return [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kAudioOutputSampleRate channels:2];
}

#pragma mark - Audio session resilience
//
// Two ways a running game can lose its sound for good, both invisible to the
// code that starts the engine and neither of which fires reliably enough to
// notice on one device:
//
//  * A hardware configuration change. Every mic window swaps the session
//    category (.playback <-> .playAndRecord, see the Microphone section), and
//    that can change the hardware's sample rate or channel count — iPhones
//    tend to sit at 48kHz either way, iPads frequently do not. When it does
//    change, "the engine stops, uninitializes itself, and issues this
//    notification" (AVAudioEngine.h), on some other thread, which means it
//    can land *after* -beginMicrophoneEngineCapture already restarted the
//    engine: a stopped engine nobody would ever start again, i.e. a game that
//    plays on in silence until you quit it. This was eNDS 1.0(15)'s "no sound
//    on iPad in some games" — the games in question being the ones that touch
//    the DS mic at all (which on a DS is any game that samples the TSC's AUX
//    channel, no explicit open needed — Vendor/melonDS/src/Mic.cpp).
//  * An interruption: a call, an alarm, Siri. The system stops the engine for
//    us and, again, nothing restarts it.
//
// Both recover the same way, and both are cheap and safe to over-apply, so
// the handlers just re-derive a working graph rather than trying to reason
// about what exactly changed.

- (void)handleAudioEngineConfigurationChange:(NSNotification *)notification {
    if (_tearingDown.load()) return;
    // Posted "on a thread other than the thread on which the engine was
    // stopped" (AVAudioEngine.h); everything it leads to is main-thread-only.
    __weak MelonDSCoreBridge *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf rebuildAudioGraphAfterHardwareChange];
    });
}

// The third way sound dies for good, and the nastiest: iOS's media server
// (mediaserverd) crashed and restarted. Every audio object this process holds
// — session, engine, nodes, the mic tap — is now a handle to something that no
// longer exists, and nothing throws to say so. The game plays on in silence
// until it is quit, and -ensureAudioIsRunning cannot help because the engine it
// asks still cheerfully reports itself as running.
//
// Rare, but not hypothetical, and the recovery is the same full graph rebuild
// the hardware-change path already does — so this costs five lines and closes
// the last of the three.
- (void)handleMediaServicesWereReset:(NSNotification *)notification {
    if (_tearingDown.load()) return;
    __weak MelonDSCoreBridge *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf rebuildAudioGraphAfterHardwareChange];
    });
}

- (void)handleAudioSessionInterruption:(NSNotification *)notification {
    if (_tearingDown.load()) return;
    NSNumber *rawType = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    if (rawType.unsignedIntegerValue != AVAudioSessionInterruptionTypeEnded) return;
    // ShouldResume is the system's permission to take the session back; it is
    // absent when whatever interrupted us still holds it, and reactivating
    // anyway just fails.
    NSNumber *rawOptions = notification.userInfo[AVAudioSessionInterruptionOptionKey];
    if ((rawOptions.unsignedIntegerValue & AVAudioSessionInterruptionOptionShouldResume) == 0) return;

    __weak MelonDSCoreBridge *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        MelonDSCoreBridge *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSError *sessionError = nil;
        if (![AVAudioSession.sharedInstance setActive:YES error:&sessionError]) {
            NSLog(@"[melonDS] Failed to reactivate the audio session after an interruption: %@", sessionError);
            return;
        }
        [strongSelf restartAudioEngineIfGameIsRunning];
    });
}

// Main-thread only. Also safe when nothing is actually broken.
- (void)rebuildAudioGraphAfterHardwareChange {
    AVAudioEngine *engine = self.audioEngine;
    AVAudioSourceNode *node = self.audioSourceNode;
    if (!engine || !node) return;

    // The tap and its AVAudioConverter were built against the *old* input
    // format, so they cannot survive the change. Drop them without touching
    // the session category: reverting to .playback here could flip the
    // hardware format straight back and bounce us into this handler forever.
    // -refreshMicrophoneCaptureState at the bottom rebuilds them against
    // whatever the input node reports now, or leaves capture off if the
    // game's mic window closed in the meantime.
    BOOL hadCapture = _microphoneCaptureActive;
    if (hadCapture) [self tearDownMicrophoneTap];

    // The source node's format is ours and unaffected; what the change tore
    // down is the mixer's connection to the I/O node, which this rebuilds
    // from the new hardware format.
    [engine connect:node to:engine.mainMixerNode format:[self outputFormat]];
    [self restartAudioEngineIfGameIsRunning];

    if (hadCapture) [self refreshMicrophoneCaptureState];
}

// Called once per presented frame. The notifications above cover the failures
// AVFoundation tells us about; this covers the rest — a restart that failed
// because the session wasn't ready yet, a route change that stopped the engine
// without a configuration change, an interruption that ended without the
// resume option. A stopped engine while a game is running is never correct,
// and one comparison a second is cheap enough to just keep asking.
- (void)ensureAudioIsRunning {
    if (!_runtime->wantActive.load()) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastAudioWatchdogTime < 1.0) return;
    _lastAudioWatchdogTime = now;

    AVAudioEngine *engine = self.audioEngine;
    if (!engine || engine.isRunning) return;
    NSLog(@"[melonDS] Audio engine found stopped mid-game; restarting it.");
    [self restartAudioEngineIfGameIsRunning];
}

// Main-thread only. Deliberately does nothing while paused or stopped:
// -startEmulation is what starts the engine in that case, and starting it
// here would leave a paused game holding a live audio unit.
- (void)restartAudioEngineIfGameIsRunning {
    AVAudioEngine *engine = self.audioEngine;
    if (!engine || engine.isRunning) return;
    if (!_runtime->wantActive.load()) return;

    [engine prepare];
    NSError *startError = nil;
    if (![engine startAndReturnError:&startError]) {
        NSLog(@"[melonDS] Failed to restart the audio engine: %@", startError);
    }
}

- (void)startEmulation {
    if (!_runtime->nds) return;

    [self setUpAudioEngineIfNeeded];

    if (!_runtime->threadAlive.load()) {
        _runtime->shouldStop.store(false);
        _runtime->threadAlive.store(true);
        _runtime->emuThread = std::thread(EmuThreadMain, _runtime);
    }
    _runtime->wantActive.store(true);
    _runtime->syncCV.notify_all();

    if (!self.audioEngine.isRunning) {
        NSError *engineError = nil;
        if (![self.audioEngine startAndReturnError:&engineError]) {
            NSLog(@"[melonDS] Failed to start audio engine: %@", engineError);
        }
    }

    // Covers resuming from a pause taken while a game's mic window was open
    // (the core never re-calls Mic_Start on resume — from its perspective
    // the mic was open the whole time, since pausing just stops time from
    // advancing for it; only *our* capture pipeline actually tore down).
    [self refreshMicrophoneCaptureState];
}

- (void)resumeEmulation {
    // Resuming from a pause and performing the very first start are the same
    // operation here: (re)start the paced thread and audio engine if needed.
    [self startEmulation];
}

- (void)pauseEmulation {
    // Wait for the in-flight tick, not just the flag: a battery write issued
    // by a RunFrame still finishing would otherwise land on the save queue
    // after the flush below, and this pause is what the background/exit path
    // relies on for "the .sav is on disk".
    PauseAndWaitIdle(_runtime);
    [self flushPendingSaveWrites];
    // Stop listening the moment the game pauses, even though melonDS's own
    // mic state (invisible to us) stays logically open — never keep the mic
    // hot behind a paused/backgrounded game. -refreshMicrophoneCaptureState
    // sees wantActive is now false and tears capture down (restarting
    // output-only playback if it was running); the plain -pause below then
    // just pauses that already-reverted, playback-category engine.
    [self refreshMicrophoneCaptureState];
    [self.audioEngine pause];
}

- (void)stopEmulation {
    _runtime->wantActive.store(false);
    _runtime->shouldStop.store(true);
    _runtime->syncCV.notify_all();
    if (_runtime->emuThread.joinable()) {
        _runtime->emuThread.join();
    }
    _runtime->threadAlive.store(false);

    _runtime->micCoreOpen.store(false);
    [self cancelDeferredMicrophoneTeardown];
    [self removeMicrophoneTapAndRevertToPlayback];

    [self.audioEngine stop];

    if (_runtime->nds) {
        _runtime->nds->Stop();
        _runtime->nds.reset();
    }
    ClearRewind(_runtime);
    // After the core is gone, so anything it wrote on the way out is
    // included: this is the exit path, and -dealloc deletes the Runtime
    // right after.
    [self flushPendingSaveWrites];
    _runtime->fbLatest = -1;
}

- (void)resetEmulation {
    if (!_runtime->nds) return;
    bool wasActive = PauseAndWaitIdle(_runtime);

    _runtime->nds->Reset();
    _runtime->nds->SetupDirectBoot(_runtime->romFileName);
    _runtime->nds->Start();
    ClearRewind(_runtime);
    {
        std::lock_guard<std::mutex> lock(_runtime->fbMutex);
        _runtime->fbLatest = -1;
    }

    ResumeIfNeeded(_runtime, wasActive);
}

#pragma mark - Microphone
//
// State model: `_runtime->micCoreOpen` mirrors melonDS's own Mic_Start...
// Mic_Stop window exactly (set from the emulation thread, instantly).
// `_microphoneCaptureActive` mirrors whether the AVAudioEngine capture
// pipeline is *actually* running right now (main-thread-only). Every path
// that can change what capture *should* be doing — a core Mic_Start/Stop
// edge, pausing, or resuming — funnels through -refreshMicrophoneCaptureState,
// which is the only place that starts or stops the pipeline. That keeps the
// AVAudioSession category switch to one call site (the same place that
// manages the output session), and
// makes every transition idempotent: re-deriving "should capture be
// running?" from scratch each time, rather than reacting to the specific
// edge that triggered the call, means bursts of Start/Stop or a permission
// prompt resolving late can never leave the pipeline in the wrong state.

// Emulation-thread → main-thread forwarding for Platform::Mic_Start. Flips
// the atomic synchronously (instant, cheap — safe to do right here), then
// hops to the main thread for everything that isn't: permission checks can
// show a system alert, and AVAudioSession/AVAudioEngine reconfiguration is
// conventionally main-thread work. __weak avoids keeping `self` alive for
// this async hop if the bridge is torn down before it runs (dealloc already
// calls -stopEmulation synchronously on the emu-thread caller's behalf, so
// this is a defensive guard, not the primary teardown path).
- (void)micCoreDidOpen {
    _runtime->micCoreOpen.store(true);
    if (_tearingDown.load()) return;
    __weak MelonDSCoreBridge *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf refreshMicrophoneCaptureState];
    });
}

// The `_tearingDown` guard is not an optimization, it is the fix for a hard
// crash (1.0(9), backgrounding a running game): -dealloc calls -stopEmulation,
// whose `nds->Stop()` makes melonDS close its mic core, which calls straight
// back in here — and forming a __weak reference to an object that is already
// deallocating is an unconditional objc_fatal ("cannot form weak reference to
// object of class ... it is in the process of being deallocated"). There is
// also nothing left to refresh at that point: -stopEmulation already called
// -removeMicrophoneTapAndRevertToPlayback synchronously.
- (void)micCoreDidClose {
    _runtime->micCoreOpen.store(false);
    if (_tearingDown.load()) return;
    __weak MelonDSCoreBridge *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf refreshMicrophoneCaptureState];
    });
}

// Emulation-thread entry point for Platform::Mic_ReadInput. Always fully
// satisfies `maxLength` — real ring samples first, silence-padded for any
// shortfall — so a not-yet-started/denied/disabled mic is bit-for-bit the
// same "silence" behavior as the original stub.
- (void)micFillInput:(int16_t *)data maxLength:(int)maxLength {
    int filled = PopMicSamples(_runtime, data, maxLength);
    if (filled < maxLength) {
        memset(data + filled, 0, static_cast<size_t>(maxLength - filled) * sizeof(int16_t));
    }
}

// Main-thread only. The single source of truth for "should the mic capture
// pipeline be running right now?" — re-derived from scratch on every call
// rather than trusting whatever edge triggered it (see the section comment
// above).
- (void)refreshMicrophoneCaptureState {
    const BOOL sessionWantsCapture = _runtime->wantActive.load() && [self isMicrophoneToggleEnabled];
    const BOOL desired = _runtime->micCoreOpen.load() && sessionWantsCapture;

    if (desired) {
        [self cancelDeferredMicrophoneTeardown];
        if (!_microphoneCaptureActive) {
            [self attemptStartMicrophoneCapture];
        }
    } else if (_microphoneCaptureActive && sessionWantsCapture) {
        // Only the game's mic window closed. Every close acted on right here
        // stops the engine, swaps the session category and starts it again —
        // an audible dropout, and on iPad usually a hardware-rate change on
        // top — and the core closes and reopens that window every few frames
        // for a game that polls the mic in bursts (see
        // kMicCloseDebounceNanoseconds). Keep the tap and .playAndRecord
        // alive briefly instead; a Mic_Start in the meantime cancels the
        // teardown and costs nothing.
        [self scheduleDeferredMicrophoneTeardown];
    } else {
        // Paused, toggle off, or nothing to keep alive: tear down right away.
        // Never keep the mic hot behind a paused/backgrounded game.
        [self cancelDeferredMicrophoneTeardown];
        [self stopMicrophoneCaptureAndRestorePlaybackSession];
    }
}

// Main-thread only. Arms the delayed "stop" half of
// -refreshMicrophoneCaptureState; one already pending keeps its deadline.
// The block re-derives the decision when it fires rather than blindly
// stopping: the emulation thread flips micCoreOpen before its own refresh
// hop reaches the main queue, so the window may already be open again.
- (void)scheduleDeferredMicrophoneTeardown {
    if (_pendingMicrophoneTeardown) return;
    __weak MelonDSCoreBridge *weakSelf = self;
    dispatch_block_t teardown = dispatch_block_create((dispatch_block_flags_t)0, ^{
        MelonDSCoreBridge *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_pendingMicrophoneTeardown = nil;
        if (strongSelf->_runtime->micCoreOpen.load()
            && strongSelf->_runtime->wantActive.load()
            && [strongSelf isMicrophoneToggleEnabled]) {
            return;
        }
        [strongSelf stopMicrophoneCaptureAndRestorePlaybackSession];
    });
    _pendingMicrophoneTeardown = teardown;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kMicCloseDebounceNanoseconds),
                   dispatch_get_main_queue(), teardown);
}

// Main-thread only. No-op when nothing is pending. Called from every path
// that decides capture's fate itself — a Mic_Start, pause, ROM unload — so a
// stale timer can never stop a window that was legitimately reopened or fire
// against a torn-down core.
- (void)cancelDeferredMicrophoneTeardown {
    if (!_pendingMicrophoneTeardown) return;
    dispatch_block_cancel(_pendingMicrophoneTeardown);
    _pendingMicrophoneTeardown = nil;
}

// "eNDSMicEnabled" — the same literal UserDefaults key Settings > Audio's
// "Microphone" toggle reads/writes (AudioSettingsView.swift), default ON
// like this app's other toggles (INDSHaptics, INDSSavingPreferences). No
// shared Swift/C++ constant on purpose: this file already duplicates
// "eNDSAudioVolume" the exact same way (see -init and -setAudioVolume:
// above) — Settings has no live core instance to push changes into, so
// both sides just agree on the string key.
- (BOOL)isMicrophoneToggleEnabled {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"eNDSMicEnabled"] == nil) return YES;
    return [defaults boolForKey:@"eNDSMicEnabled"];
}

// Lazy permission ask: only ever reached the first time a game actually
// opens its mic window with the toggle on — never at app launch (there is
// no other call site that leads here). A denial is silent by design (one
// log line, no repeated alerts): Mic_ReadInput already degrades to silence
// with no other visible effect, exactly like the mic simply not existing.
- (void)attemptStartMicrophoneCapture {
    switch (AVAudioApplication.sharedInstance.recordPermission) {
        case AVAudioApplicationRecordPermissionGranted:
            [self beginMicrophoneEngineCapture];
            break;

        case AVAudioApplicationRecordPermissionDenied:
            NSLog(@"[melonDS] Microphone permission denied; DS mic input stays silent.");
            break;

        case AVAudioApplicationRecordPermissionUndetermined:
        default: {
            __weak MelonDSCoreBridge *weakSelf = self;
            [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
                // "the block may be called in a different thread context"
                // per AVAudioApplication.h — hop back to main before
                // touching anything else here.
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf handleMicrophonePermissionResolved:granted];
                });
            }];
            break;
        }
    }
}

- (void)handleMicrophonePermissionResolved:(BOOL)granted {
    if (!granted) {
        NSLog(@"[melonDS] Microphone permission denied; DS mic input stays silent.");
        return;
    }
    // Re-derive rather than blindly starting: the mic window (or the app
    // itself) may have closed/backgrounded while the system prompt was up.
    [self refreshMicrophoneCaptureState];
}

// Main-thread only. Leaves the pipeline either fully running
// (_microphoneCaptureActive = YES, tap installed, session .playAndRecord)
// or fully reverted on any failure — never half-configured.
- (void)beginMicrophoneEngineCapture {
    if (_microphoneCaptureActive) return;
    AVAudioEngine *engine = self.audioEngine;
    if (!engine) return; // no output session exists yet; shouldn't happen — Mic_Start only ever fires mid-RunFrame, which requires -startEmulation to have already set one up.

    BOOL wasRunning = engine.isRunning;
    if (wasRunning) [engine stop];

    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *sessionError = nil;
    // Trade-off: .playAndRecord is the only category that unlocks
    // `inputNode`, and this start/stop transition briefly interrupts audio
    // while the engine restarts around the category change (there is no
    // documented glitch-free way to swap AVAudioSession categories on a
    // running AVAudioEngine; CoreAudio has to rebuild the I/O unit). It
    // reverts the moment the window closes, via
    // -stopMicrophoneCaptureAndRestorePlaybackSession below.
    //
    // MixWithOthers to match the resting category above: whether a game
    // happens to sample the DS mic must not decide whether the player's own
    // music survives.
    //
    // A2DP and not HFP on purpose: allowing HFP lets iOS move the *whole*
    // route onto a Bluetooth headset's 16kHz mono voice channel for as long as
    // a game samples the mic, which turns a paired speaker or AirPods into a
    // sudden, obvious drop in sound quality mid-game. Without it, output stays
    // on A2DP and input quietly falls back to the built-in mic — which is
    // where the player is blowing anyway.
    if (![self setSessionCategory:AVAudioSessionCategoryPlayAndRecord
                          options:AVAudioSessionCategoryOptionDefaultToSpeaker
                                | AVAudioSessionCategoryOptionAllowBluetoothA2DP
                                | AVAudioSessionCategoryOptionMixWithOthers]) {
        [self abortMicrophoneCaptureAttemptAndRestart:wasRunning];
        return;
    }
    // iOS silences *all* haptics while an app records — the whole Taptic
    // Engine, not just system sounds — and this is the documented opt-out
    // (default NO, and it resets with the category, so it has to be re-set
    // here on every window). Without it the controller overlay goes dead-feeling
    // the moment a game samples the DS mic and stays that way for as long as
    // the window is open: eNDS 1.0(15)'s "you broke the button haptics".
    if (![session setAllowHapticsAndSystemSoundsDuringRecording:YES error:&sessionError]) {
        // Non-fatal: worst case is the pre-existing behaviour (no haptics
        // while listening), which is not worth losing mic input over.
        NSLog(@"[melonDS] Could not keep haptics alive during mic capture: %@", sessionError);
    }
    if (![session setActive:YES error:&sessionError]) {
        NSLog(@"[melonDS] Failed to activate recording session: %@", sessionError);
        [self abortMicrophoneCaptureAttemptAndRestart:wasRunning];
        return;
    }

    AVAudioInputNode *inputNode = engine.inputNode;
    // outputFormatForBus:0, not inputFormatForBus: — per AVAudioNode.h's own
    // documented example, tapping a node means reading what comes *out* of
    // it. Only valid/non-zero now that the session actually supports
    // recording.
    AVAudioFormat *inputFormat = [inputNode outputFormatForBus:0];
    if (inputFormat.sampleRate <= 0 || inputFormat.channelCount == 0) {
        NSLog(@"[melonDS] Microphone input format unavailable; DS mic input stays silent.");
        [self abortMicrophoneCaptureAttemptAndRestart:wasRunning];
        return;
    }

    AVAudioFormat *targetFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                     sampleRate:kMicTargetSampleRate
                                                                       channels:1
                                                                    interleaved:YES];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:targetFormat];
    if (!converter) {
        NSLog(@"[melonDS] Could not build microphone AVAudioConverter; DS mic input stays silent.");
        [self abortMicrophoneCaptureAttemptAndRestart:wasRunning];
        return;
    }

    Runtime *runtime = _runtime;
    const double inputSampleRate = inputFormat.sampleRate;
    const double targetSampleRate = targetFormat.sampleRate;
    // 100ms is the shortest buffer installTapOnBus:bufferSize:format:block:
    // supports (per AVAudioNode.h: "Supported range is [100, 400] ms") —
    // picked over a longer one so a "blow now" moment reaches the emulated
    // mic with as little added latency as possible.
    AVAudioFrameCount tapBufferSize = (AVAudioFrameCount)llround(inputSampleRate * 0.1);

    [inputNode installTapOnBus:0
                     bufferSize:tapBufferSize
                         format:inputFormat
                          block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
        // Real-time-ish input-tap thread (Apple's own docs: "may be invoked
        // on a thread other than the main thread"). Mirrors RenderAudio's
        // contract on the output side: the only allocation is the small
        // per-callback AVAudioPCMBuffer (unavoidable with this API — there
        // is no in-place convertToBuffer:fromBuffer: variant that handles a
        // sample-rate change), and the only synchronization is
        // micMutex's few-microsecond critical section inside
        // PushMicSamples — this never blocks on I/O.
        AVAudioFrameCount capacity = (AVAudioFrameCount)ceil(buffer.frameLength * (targetSampleRate / inputSampleRate)) + 32;
        AVAudioPCMBuffer *converted = [[AVAudioPCMBuffer alloc] initWithPCMFormat:targetFormat frameCapacity:capacity];
        if (!converted) return;

        __block BOOL supplied = NO;
        NSError *conversionError = nil;
        AVAudioConverterOutputStatus status = [converter convertToBuffer:converted
                                                                     error:&conversionError
                                                        withInputFromBlock:
            ^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus *outStatus) {
                if (supplied) {
                    *outStatus = AVAudioConverterInputStatus_NoDataNow;
                    return nil;
                }
                supplied = YES;
                *outStatus = AVAudioConverterInputStatus_HaveData;
                return buffer;
            }];

        // Keep whatever came out, not just the full-buffer case. HaveData
        // means "all of the requested data was returned"; InputRanDry means
        // "not enough input was available ... the output buffer contains as
        // much as could be converted" (AVAudioConverter.h) — real captured
        // audio either way. Since `capacity` above deliberately asks for a
        // little more than one tap buffer can yield, the converter runs dry
        // regularly, and discarding those rounds threw away ~5% of the mic
        // feed in ~86ms holes: measured over 40 tap callbacks, dry rounds hit
        // the very first callback (so the start of every mic window, when the
        // player is already blowing) and then roughly every two seconds.
        if (status != AVAudioConverterOutputStatus_Error
            && converted.frameLength > 0
            && converted.int16ChannelData) {
            PushMicSamples(runtime, converted.int16ChannelData[0], (int)converted.frameLength);
        }
    }];

    [engine prepare];
    NSError *startError = nil;
    if (![engine startAndReturnError:&startError]) {
        NSLog(@"[melonDS] Failed to restart audio engine for mic capture: %@", startError);
        [inputNode removeTapOnBus:0];
        [self abortMicrophoneCaptureAttemptAndRestart:wasRunning];
        return;
    }

    self.microphoneConverter = converter;
    _microphoneCaptureActive = YES;
}

// Best-effort cleanup shared by every -beginMicrophoneEngineCapture failure
// path: get back to a plain, playback-only output engine (restarted only if
// it was actually running before this attempt began).
- (void)abortMicrophoneCaptureAttemptAndRestart:(BOOL)wasRunning {
    [self activatePlaybackCategory];
    if (!wasRunning) return;
    [self.audioEngine prepare];
    NSError *startError = nil;
    if (![self.audioEngine startAndReturnError:&startError]) {
        NSLog(@"[melonDS] Failed to restart audio engine after aborted mic capture: %@", startError);
    }
}

// Main-thread only. The "stop" side of -refreshMicrophoneCaptureState:
// tears the tap down, reverts the session to .playback, and — since this
// path is reached while the game (and its output audio) may still very much
// be running, unlike -stopEmulation's harder teardown below — restarts
// output-only playback if the engine was running beforehand.
- (void)stopMicrophoneCaptureAndRestorePlaybackSession {
    if (!_microphoneCaptureActive) return;

    AVAudioEngine *engine = self.audioEngine;
    BOOL wasRunning = engine.isRunning;
    if (wasRunning) [engine stop];

    [self removeMicrophoneTapAndRevertToPlayback];

    if (wasRunning) {
        [engine prepare];
        NSError *startError = nil;
        if (![engine startAndReturnError:&startError]) {
            NSLog(@"[melonDS] Failed to restart audio engine after mic capture: %@", startError);
        }
    }
}

// Removes the tap/converter and reverts the session category if (and only
// if) capture is actually active; a no-op otherwise. Does not touch the
// engine's running state — callers that need output to keep playing
// afterward (-stopMicrophoneCaptureAndRestorePlaybackSession) stop/restart
// it themselves around this call; -stopEmulation doesn't need to, since it
// stops the whole engine right after calling this anyway.
- (void)removeMicrophoneTapAndRevertToPlayback {
    if (!_microphoneCaptureActive) return;
    [self tearDownMicrophoneTap];
    [self activatePlaybackCategory];
}

// The half of the teardown above that does not touch the session category —
// split out for -rebuildAudioGraphAfterHardwareChange, which must drop a tap
// built for a stale input format while leaving the category exactly where it
// is (see the comment there).
- (void)tearDownMicrophoneTap {
    if (!_microphoneCaptureActive) return;

    [self.audioEngine.inputNode removeTapOnBus:0];
    self.microphoneConverter = nil;
    _microphoneCaptureActive = NO;

    // Drop whatever was mid-flight so a future capture window starts clean
    // instead of replaying stale audio from before this one ended.
    {
        std::lock_guard<std::mutex> lock(_runtime->micMutex);
        _runtime->micRingReadPos = 0;
        _runtime->micRingWritePos = 0;
        _runtime->micRingLevel = 0;
    }
}

#pragma mark - Input

- (void)setButton:(INDSButton)button pressed:(BOOL)pressed {
    if (button < 0 || button > 11) return;
    const u32 bit = 1u << static_cast<u32>(button);
    if (pressed) {
        _runtime->keyMask.fetch_and(~bit);
    } else {
        _runtime->keyMask.fetch_or(bit);
    }
}

- (void)setTouchX:(NSInteger)x y:(NSInteger)y pressed:(BOOL)pressed {
    std::lock_guard<std::mutex> lock(_runtime->touchMutex);
    _runtime->touchPressed = pressed;
    _runtime->touchX = static_cast<u16>(std::clamp<NSInteger>(x, 0, 255));
    _runtime->touchY = static_cast<u16>(std::clamp<NSInteger>(y, 0, 191));
}

#pragma mark - Presentation

- (BOOL)copyFramebuffersTop:(uint32_t *)top bottom:(uint32_t *)bottom {
    if (!top || !bottom) return NO;
    std::lock_guard<std::mutex> lock(_runtime->fbMutex);
    if (_runtime->fbLatest < 0) return NO;
    if (_runtime->fbGeneration == _runtime->fbPresented) return NO; // nothing new since last copy
    _runtime->fbPresented = _runtime->fbGeneration;
    const FramebufferSlot &slot = _runtime->fbSlots[_runtime->fbLatest];
    constexpr size_t byteCount = kFramebufferPixels * sizeof(uint32_t);
    memcpy(top, slot.top.data(), byteCount);
    memcpy(bottom, slot.bottom.data(), byteCount);
    return YES;
}

#pragma mark - Save states

- (nullable NSString *)saveStateDirectoryPath {
    if (_runtime->romBaseName.empty()) return nil;
    NSURL *documentsURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (!documentsURL) return nil;
    NSString *baseName = [NSString stringWithUTF8String:_runtime->romBaseName.c_str()];
    NSURL *directoryURL = [[documentsURL URLByAppendingPathComponent:@"SaveStates" isDirectory:YES]
                            URLByAppendingPathComponent:baseName isDirectory:YES];
    return directoryURL.path;
}

- (nullable NSString *)pathForSaveStateSlot:(NSInteger)slot {
    NSString *directory = [self saveStateDirectoryPath];
    if (!directory) return nil;
    NSString *filename = [NSString stringWithFormat:@"slot%ld.mln", (long)slot];
    return [directory stringByAppendingPathComponent:filename];
}

- (nullable NSString *)autoSaveStatePathForROM {
    NSString *directory = [self saveStateDirectoryPath];
    if (!directory) return nil;
    return [directory stringByAppendingPathComponent:@"auto.mln"];
}

- (BOOL)saveStateToPath:(NSString *)path error:(NSError **)error {
    if (!_runtime->nds) {
        if (error) *error = MakeError(4, @"No ROM is currently loaded.");
        return NO;
    }

    NSString *directory = path.stringByDeletingLastPathComponent;
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        if (error) *error = directoryError ?: MakeError(5, @"Unable to create save state directory.");
        return NO;
    }

    // DoSavestate touches the entire NDS state (RAM, CPU, GPU, SPU, cart...),
    // so it must not run concurrently with the emulation thread's RunFrame.
    bool wasActive = PauseAndWaitIdle(_runtime);
    // The battery save this state was taken against must be on disk before
    // the state is; the thread is idle now, so nothing can queue behind us.
    [self flushPendingSaveWrites];

    melonDS::Savestate state(kSavestateInitialSize);
    // NDS::DoSavestate calls file->Finish() internally (both for saving and
    // loading) and always returns true unless the console-type header word
    // itself mismatches, so state.Error must be checked separately to catch
    // a failed/short write into the buffer.
    bool ok = !state.Error && _runtime->nds->DoSavestate(&state) && !state.Error;
    NSData *data = ok ? [NSData dataWithBytes:state.Buffer() length:state.Length()] : nil;

    ResumeIfNeeded(_runtime, wasActive);

    if (!data) {
        if (error) *error = MakeError(6, @"Failed to create save state.");
        return NO;
    }

    // On the save queue, synchronously: a periodic autosave of the same file
    // (-autosaveStateToPath:) may still be queued ahead of this newer
    // snapshot, and the serial queue is what keeps the older write from
    // renaming over it.
    __block NSError *writeError = nil;
    __block BOOL written = NO;
    dispatch_sync(_saveQueue, ^{
        written = [data writeToFile:path options:NSDataWritingAtomic error:&writeError];
    });
    if (!written) {
        if (error) *error = writeError ?: MakeError(7, @"Failed to write save state file.");
        return NO;
    }
    return YES;
}

- (BOOL)autosaveStateToPath:(NSString *)path {
    if (!_runtime->nds) return NO;

    NSString *directory = path.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) {
        return NO;
    }

    // Same serialize-under-pause as -saveStateToPath:error: — that part cannot
    // move off the caller's thread, since DoSavestate walks the whole console
    // and must not race RunFrame. It is also the cheap half (a few MB of
    // memcpy, one frame's worth of stall at most).
    bool wasActive = PauseAndWaitIdle(_runtime);
    [self flushPendingSaveWrites];
    melonDS::Savestate state(kSavestateInitialSize);
    bool ok = !state.Error && _runtime->nds->DoSavestate(&state) && !state.Error;
    NSData *data = ok ? [NSData dataWithBytes:state.Buffer() length:state.Length()] : nil;
    ResumeIfNeeded(_runtime, wasActive);

    if (!data) return NO;

    // The write is the expensive half and nothing is waiting on it: a periodic
    // autosave that hitched the game every couple of minutes would be worse
    // than the jetsam it protects against. Atomic, so a crash mid-write leaves
    // the previous autosave intact rather than a truncated one. On the same
    // serial queue as the synchronous -saveStateToPath:error:, so the exit
    // autosave that follows a periodic one can never be overtaken by it.
    dispatch_async(_saveQueue, ^{
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
    });
    return YES;
}

- (BOOL)loadStateFromPath:(NSString *)path error:(NSError **)error {
    if (!_runtime->nds) {
        if (error) *error = MakeError(4, @"No ROM is currently loaded.");
        return NO;
    }

    std::vector<u8> buffer;
    if (!ReadFile(path.fileSystemRepresentation, buffer) || buffer.empty()) {
        if (error) *error = MakeError(8, @"Save state file not found or unreadable.");
        return NO;
    }

    bool wasActive = PauseAndWaitIdle(_runtime);
    // CartRetail::DoSavestate flushes the loaded SRAM through WriteNDSSave;
    // let whatever the game wrote before this jump reach disk first.
    [self flushPendingSaveWrites];

    // Snapshot first (melonDS's own frontend keeps the same backup for its
    // "undo load"): the header check only catches a truncated/foreign file.
    // A state that fails half-way through — a section missing after a core
    // update, a corrupt body — would otherwise leave the console partially
    // overwritten, and CartRetail::DoSavestate flushes SRAM to the .sav on
    // load regardless, so a half-loaded state could take the battery save
    // down with it. Restoring the snapshot keeps the game exactly where the
    // user left it.
    melonDS::Savestate backup(kSavestateInitialSize);
    bool haveBackup = !backup.Error && _runtime->nds->DoSavestate(&backup) && !backup.Error;

    melonDS::Savestate state(buffer.data(), static_cast<u32>(buffer.size()), false);
    bool ok = !state.Error && _runtime->nds->DoSavestate(&state) && !state.Error;
    if (!ok && haveBackup) {
        backup.Rewind(false);
        _runtime->nds->DoSavestate(&backup);
    }
    if (ok) {
        // Discard whatever was queued from before the jump so playback
        // doesn't glitch on stale pre-load audio.
        _runtime->nds->SPU.DrainOutput();
        // Rewinding past a load would silently undo it.
        ClearRewind(_runtime);
    }
    {
        std::lock_guard<std::mutex> lock(_runtime->fbMutex);
        _runtime->fbLatest = -1;
    }
    // The SRAM the state carried was just queued for writing; callers that
    // stamp the .sav right after a load (the pre-load backup policy) need it
    // on disk before this returns.
    [self flushPendingSaveWrites];

    ResumeIfNeeded(_runtime, wasActive);

    if (!ok) {
        if (error) *error = MakeError(9, @"Save state is invalid or incompatible.");
        return NO;
    }
    return YES;
}

#pragma mark - Rewind

- (BOOL)rewindEnabled {
    return _runtime->rewindEnabled.load();
}

- (void)setRewindEnabled:(BOOL)rewindEnabled {
    _runtime->rewindEnabled.store(rewindEnabled);
    if (!rewindEnabled) ClearRewind(_runtime); // give the ~60 MB back now
}

- (BOOL)canRewind {
    std::lock_guard<std::mutex> lock(_runtime->rewindMutex);
    return _runtime->nds && _runtime->rewindCount > 0;
}

- (void)clearRewindHistory {
    ClearRewind(_runtime);
}

- (BOOL)rewindTenSeconds {
    if (!_runtime->nds) return NO;
    bool wasActive = PauseAndWaitIdle(_runtime);
    // Same reason as -loadStateFromPath:error: — the jump flushes the
    // state's SRAM, and what the game wrote before must land first.
    [self flushPendingSaveWrites];

    bool ok = false;
    {
        std::lock_guard<std::mutex> lock(_runtime->rewindMutex);
        if (_runtime->rewindCount > 0) {
            const int back = std::min(kRewindJumpSlots, _runtime->rewindCount - 1);
            const int target = ((_runtime->rewindHead - back) % kRewindMaxSlots + kRewindMaxSlots) % kRewindMaxSlots;
            std::vector<u8> &slot = _runtime->rewindSlots[target];
            melonDS::Savestate state(slot.data(), static_cast<u32>(slot.size()), false);
            ok = !state.Error && _runtime->nds->DoSavestate(&state) && !state.Error;
            if (ok) {
                // The restored capture stays as the newest, so the next
                // rewind keeps stepping further back.
                _runtime->rewindCount -= back;
                _runtime->rewindHead = target;
                _runtime->rewindFrames = 0;
                NSLog(@"[Rewind] Jumped back %d captures, %d left", back, _runtime->rewindCount);
            }
        }
    }
    if (ok) {
        _runtime->nds->SPU.DrainOutput();
        std::lock_guard<std::mutex> lock(_runtime->fbMutex);
        _runtime->fbLatest = -1;
    } else {
        // A capture that fails to load half-way leaves nothing worth keeping.
        ClearRewind(_runtime);
    }
    [self flushPendingSaveWrites];
    ResumeIfNeeded(_runtime, wasActive);
    return ok;
}

#pragma mark - Battery saves

// Platform::WriteNDSSave lands here once per SPI transaction (CartRetail::
// SPIRelease; per 0x800-byte block on NAND carts), always with the whole
// SRAM, from inside RunFrame on the emulation thread — or from the main
// thread when a state load flushes SRAM. Never blocks on I/O: copies the
// bytes into the single pending snapshot (replacing one not yet written) and
// queues one drain if none is queued. The drain writes whatever is pending
// when it runs, so a burst of writes becomes one file write of the final
// contents, and there is no delay before it: a crash right after a save
// loses no more than it did with the synchronous write.
- (void)writeNDSSaveBytes:(const void *)bytes length:(uint32_t)length {
    if (!_runtime || _runtime->savePath.empty()) return;
    std::shared_ptr<SaveWriter> writer = _runtime->saveWriter;
    {
        std::lock_guard<std::mutex> lock(writer->mutex);
        const u8 *data = static_cast<const u8 *>(bytes);
        writer->pending.assign(data, data + length);
        writer->path = _runtime->savePath;
        if (writer->queued) return; // the queued drain will pick this one up
        writer->queued = true;
    }
    dispatch_async(_saveQueue, ^{
        DrainPendingSave(writer);
    });
}

// Blocks until every save write queued so far (battery snapshots and
// autosave states alike) has reached disk. The queue is serial, so an empty
// block dispatched synchronously runs only after everything ahead of it.
// Callers pause the emulation thread first where it matters, so nothing
// new can be queued behind the flush.
- (void)flushPendingSaveWrites {
    dispatch_sync(_saveQueue, ^{});
}

#pragma mark - Cheats (Action Replay)

- (void)reloadCheatsFromFile:(NSString *)path enabled:(BOOL)enabled {
    if (!_runtime->nds) return;

    // AREngine.Cheats is a plain std::vector, iterated in full by
    // AREngine::RunCheats every emulated VBlank (ARM.cpp's ARM7 IRQ handler,
    // called from the emulation thread inside RunFrame()) — reassigning it
    // from the main thread while that iteration is in-flight would be a
    // concurrent-mutation-during-iteration race. Same pause/resume pattern
    // as resetEmulation/saveStateToPath: above.
    bool wasActive = PauseAndWaitIdle(_runtime);

    if (enabled) {
        // Constructing ARCodeFile here (rather than keeping one around like
        // melonDS's own Qt frontend does for its editor) is fine: GetCodes()
        // *copies* every ARCode out of the file's internal tree, and nothing
        // downstream (AREngine::RunCheat) ever reads an ARCode's `Parent`
        // pointer back into that tree — only `.Code`/`.Enabled` — so it's
        // safe for `file` to go out of scope immediately after, even though
        // the copied codes' `Parent` pointers technically dangle from then on.
        melonDS::ARCodeFile file(path.fileSystemRepresentation);
        std::vector<melonDS::ARCode> codes = file.Error ? std::vector<melonDS::ARCode>{} : file.GetCodes();

        // Defense in depth against a zero-length code ever reaching
        // AREngine::RunCheat: it indexes `Code[Code.size() - 1]`
        // unconditionally, which is undefined behavior for an empty Code —
        // the exact shape of iGBA's own historical P0 cheats crash. The
        // Swift-side writer (NDSCheatFileStore) never emits an enabled
        // zero-line code, but this is the last line of defense for a
        // hand-edited or foreign .mch file.
        codes.erase(std::remove_if(codes.begin(), codes.end(), [](const melonDS::ARCode& c) {
            return c.Code.empty();
        }), codes.end());

        _runtime->nds->AREngine.Cheats = std::move(codes);
    } else {
        _runtime->nds->AREngine.Cheats.clear();
    }

    ResumeIfNeeded(_runtime, wasActive);
}

#pragma mark - Console clock (RTC)

- (void)setConsoleDateTime:(NSDateComponents *)components {
    if (!_runtime->nds || components == nil) return;

    // RTC::SetDateTime writes straight into the RTC's BCD state, which the
    // emulation thread reads every time the game polls the clock — same
    // pause/resume handshake as the cheat list above.
    bool wasActive = PauseAndWaitIdle(_runtime);
    _runtime->nds->RTC.SetDateTime(static_cast<int>(components.year),
                                   static_cast<int>(components.month),
                                   static_cast<int>(components.day),
                                   static_cast<int>(components.hour),
                                   static_cast<int>(components.minute),
                                   static_cast<int>(components.second));
    ResumeIfNeeded(_runtime, wasActive);
}

- (nullable NSDateComponents *)consoleDateTime {
    if (!_runtime->nds) return nil;

    int year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0;
    bool wasActive = PauseAndWaitIdle(_runtime);
    _runtime->nds->RTC.GetDateTime(year, month, day, hour, minute, second);
    ResumeIfNeeded(_runtime, wasActive);

    NSDateComponents *components = [[NSDateComponents alloc] init];
    components.year = year;
    components.month = month;
    components.day = day;
    components.hour = hour;
    components.minute = minute;
    components.second = second;
    return components;
}

@end
