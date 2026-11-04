// Blend audio server plug-in.
//
// One hidden, output-only "bus" device that only the Blend engine writes to, and one
// visible, input-only device per mix that other apps record from. Every device runs on
// one shared clock, so a mix reads exactly the frames the engine wrote for the same
// sample time, with no drift and no resampling inside the driver.
//
// The app manages mixes by writing the whole list to a custom property on the plug-in
// object. The list is persisted in the host's storage, so mixes exist at boot with the
// same UIDs and apps keep their selection even when Blend is not running.

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/log.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr UInt32 kSampleRate = 48000;
constexpr UInt32 kMixChannels = 2;
constexpr UInt32 kMaxMixes = 16;
constexpr UInt32 kBusChannels = kMixChannels * kMaxMixes;

// Power of two so ring positions are a mask. 16384 frames is 341 ms at 48 kHz, far more
// than the gap between the engine writing a frame and an app reading it.
constexpr UInt32 kRingFrames = 16384;
constexpr UInt32 kZeroTimeStampPeriod = kRingFrames;

// Frames at the old end of the ring that a reader never trusts, because the writer may
// be overwriting them while the reader copies.
constexpr SInt64 kRingGuardFrames = 2048;

constexpr UInt32 kClockDomain = 'Blnd';
constexpr double kMinApplyIntervalMs = 250;
constexpr AudioObjectPropertySelector kMixListProperty = 'bmxs';
// Mixed case, so it can never clash with Apple's selectors, which are all lower case.
constexpr AudioObjectPropertySelector kClientsProperty = 'BLus';
constexpr char kBusUID[] = "app.blend.bus";
constexpr char kMixUIDPrefix[] = "app.blend.mix.";
constexpr char kStorageKey[] = "mixes";

AudioStreamBasicDescription FloatFormat(UInt32 channels)
{
    AudioStreamBasicDescription format = {};
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = UInt32(kAudioFormatFlagIsFloat) |
                          UInt32(kAudioFormatFlagsNativeEndian) |
                          UInt32(kAudioFormatFlagIsPacked);
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = channels;
    format.mBytesPerFrame = 4 * channels;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = 4 * channels;
    return format;
}

// Host-time clock shared by every device. Sample time zero is the moment the plug-in
// loaded; each device reports the same timeline regardless of when its IO started.
class SharedClock
{
public:
    SharedClock()
        : anchor_(mach_absolute_time())
    {
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        const double ticksPerSecond = 1e9 * double(timebase.denom) / double(timebase.numer);
        ticksPerPeriod_ = ticksPerSecond / kSampleRate * kZeroTimeStampPeriod;
    }

    void ZeroTimeStamp(Float64* sampleTime, UInt64* hostTime) const
    {
        const UInt64 elapsed = mach_absolute_time() - anchor_;
        const UInt64 period = UInt64(double(elapsed) / ticksPerPeriod_);
        *sampleTime = Float64(period) * kZeroTimeStampPeriod;
        *hostTime = anchor_ + UInt64(double(period) * ticksPerPeriod_);
    }

private:
    const UInt64 anchor_;
    double ticksPerPeriod_ = 0;
};

// The bus ring: kBusChannels interleaved floats per frame, indexed by sample time.
// One writer (the bus device's IO thread), any number of readers (mix devices).
// Frames outside the last contiguous run the engine wrote read as silence, so a stopped
// or crashed engine gives silence within one buffer instead of looping stale audio.
class Bus
{
public:
    Bus()
        : ring_(size_t(kRingFrames) * kBusChannels, 0.0f)
    {
    }

    void Write(Float64 sampleTime, const float* frames, UInt32 frameCount)
    {
        const SInt64 start = SInt64(sampleTime);
        if (start != end_.load(std::memory_order_relaxed)) {
            runStart_.store(start, std::memory_order_release);
        }
        for (UInt32 i = 0; i < frameCount; i++) {
            const size_t pos = size_t((start + i) & (kRingFrames - 1)) * kBusChannels;
            std::memcpy(&ring_[pos], frames + size_t(i) * kBusChannels,
                sizeof(float) * kBusChannels);
        }
        end_.store(start + frameCount, std::memory_order_release);
    }

    void Read(UInt32 slot, Float64 sampleTime, float* out, UInt32 frameCount) const
    {
        const SInt64 start = SInt64(sampleTime);
        const SInt64 end = end_.load(std::memory_order_acquire);
        const SInt64 valid = std::max(runStart_.load(std::memory_order_acquire),
            end - SInt64(kRingFrames) + kRingGuardFrames);
        for (UInt32 i = 0; i < frameCount; i++) {
            const SInt64 t = start + i;
            float* dst = out + size_t(i) * kMixChannels;
            if (t >= valid && t < end) {
                const size_t pos = size_t(t & (kRingFrames - 1)) * kBusChannels +
                                   size_t(slot) * kMixChannels;
                std::memcpy(dst, &ring_[pos], sizeof(float) * kMixChannels);
            } else {
                std::memset(dst, 0, sizeof(float) * kMixChannels);
            }
        }
    }

private:
    std::vector<float> ring_;
    std::atomic<SInt64> runStart_{0};
    std::atomic<SInt64> end_{0};
};

class BlendDevice : public aspl::Device
{
public:
    BlendDevice(std::shared_ptr<const aspl::Context> context,
        const aspl::DeviceParameters& params,
        std::shared_ptr<const SharedClock> clock)
        : aspl::Device(std::move(context), params)
        , clock_(std::move(clock))
        , name_(params.Name)
    {
        RegisterCustomProperty(kClientsProperty, [this] { return Clients(); });
    }

    std::string GetName() const override
    {
        std::lock_guard lock(nameMutex_);
        return name_;
    }

    void Rename(const std::string& name)
    {
        {
            std::lock_guard lock(nameMutex_);
            if (name == name_) {
                return;
            }
            name_ = name;
        }
        NotifyPropertyChanged(kAudioObjectPropertyName);
    }

    // The apps reading this device right now, as [{pid, bundleID}], so Blend can say who
    // uses a mix. Clients that went away without stopping are left out.
    CFPropertyListRef Clients() const
    {
        std::vector<std::shared_ptr<aspl::Client>> clients;
        {
            std::lock_guard lock(clientsMutex_);
            for (const auto& [id, count] : running_) {
                if (auto client = GetClientByID(id)) {
                    clients.push_back(client);
                }
            }
        }
        auto array = CFArrayCreateMutable(nullptr, 0, &kCFTypeArrayCallBacks);
        for (const auto& client : clients) {
            auto dict = CFDictionaryCreateMutable(
                nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            SInt32 pid = client->GetProcessID();
            auto pidValue = CFNumberCreate(nullptr, kCFNumberSInt32Type, &pid);
            auto bundle = CFStringCreateWithCString(
                nullptr, client->GetBundleID().c_str(), kCFStringEncodingUTF8);
            CFDictionarySetValue(dict, CFSTR("pid"), pidValue);
            if (bundle) {
                CFDictionarySetValue(dict, CFSTR("bundleID"), bundle);
                CFRelease(bundle);
            }
            CFArrayAppendValue(array, dict);
            CFRelease(pidValue);
            CFRelease(dict);
        }
        return array;
    }

protected:
    OSStatus StartIOImpl(UInt32 clientID, UInt32 startCount) override
    {
        const OSStatus status = aspl::Device::StartIOImpl(clientID, startCount);
        if (status == kAudioHardwareNoError) {
            {
                std::lock_guard lock(clientsMutex_);
                running_[clientID]++;
            }
            NotifyPropertyChanged(kClientsProperty);
        }
        return status;
    }

    OSStatus StopIOImpl(UInt32 clientID, UInt32 startCount) override
    {
        {
            std::lock_guard lock(clientsMutex_);
            if (auto it = running_.find(clientID); it != running_.end() && --it->second == 0) {
                running_.erase(it);
            }
        }
        NotifyPropertyChanged(kClientsProperty);
        return aspl::Device::StopIOImpl(clientID, startCount);
    }

    OSStatus GetZeroTimeStampImpl(UInt32 clientID,
        Float64* outSampleTime,
        UInt64* outHostTime,
        UInt64* outSeed) override
    {
        clock_->ZeroTimeStamp(outSampleTime, outHostTime);
        *outSeed = 1;
        return kAudioHardwareNoError;
    }

private:
    const std::shared_ptr<const SharedClock> clock_;
    mutable std::mutex nameMutex_;
    std::string name_;
    mutable std::mutex clientsMutex_;
    std::map<UInt32, UInt32> running_; // client ID to its count of started IO
};

class BusWriter : public aspl::IORequestHandler
{
public:
    explicit BusWriter(std::shared_ptr<Bus> bus)
        : bus_(std::move(bus))
    {
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        bus_->Write(timestamp, static_cast<const float*>(bytes),
            bytesCount / (sizeof(float) * kBusChannels));
    }

private:
    const std::shared_ptr<Bus> bus_;
};

class MixReader : public aspl::IORequestHandler
{
public:
    MixReader(std::shared_ptr<const Bus> bus, UInt32 slot)
        : bus_(std::move(bus))
        , slot_(slot)
    {
    }

    // A deleted mix that an app still reads goes silent at once, so it never carries
    // audio from a newer mix that reuses its slot.
    void Silence()
    {
        silenced_.store(true, std::memory_order_relaxed);
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        const UInt32 frames = bytesCount / (sizeof(float) * kMixChannels);
        if (silenced_.load(std::memory_order_relaxed)) {
            std::memset(bytes, 0, bytesCount);
            return;
        }
        bus_->Read(slot_, timestamp, static_cast<float*>(bytes), frames);
    }

private:
    const std::shared_ptr<const Bus> bus_;
    const UInt32 slot_;
    std::atomic<bool> silenced_{false};
};

// Refuses new IO on a deleted mix, so no client can start reading it between the check
// that it is idle and its removal from the device list.
class MixControl : public aspl::ControlRequestHandler
{
public:
    void Kill()
    {
        dead_.store(true, std::memory_order_release);
    }

    OSStatus OnStartIO() override
    {
        return dead_.load(std::memory_order_acquire) ? kAudioHardwareIllegalOperationError
                                                     : kAudioHardwareNoError;
    }

private:
    std::atomic<bool> dead_{false};
};

struct MixSpec
{
    std::string id;
    std::string name;
    UInt32 slot = 0;
};

std::string ToString(CFStringRef value)
{
    if (!value) {
        return {};
    }
    char buffer[512];
    if (CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        return buffer;
    }
    return {};
}

// Parses [{id, name, slot}, ...]. Entries with a bad slot, a duplicate id or a
// duplicate slot are dropped rather than failing the whole list.
std::vector<MixSpec> ParseMixList(CFPropertyListRef list)
{
    std::vector<MixSpec> specs;
    if (!list || CFGetTypeID(list) != CFArrayGetTypeID()) {
        return specs;
    }
    auto array = static_cast<CFArrayRef>(list);
    std::vector<bool> slotUsed(kMaxMixes, false);
    for (CFIndex i = 0; i < CFArrayGetCount(array); i++) {
        auto item = CFArrayGetValueAtIndex(array, i);
        if (CFGetTypeID(item) != CFDictionaryGetTypeID()) {
            continue;
        }
        auto dict = static_cast<CFDictionaryRef>(item);
        auto id = CFDictionaryGetValue(dict, CFSTR("id"));
        auto name = CFDictionaryGetValue(dict, CFSTR("name"));
        auto slot = CFDictionaryGetValue(dict, CFSTR("slot"));
        if (!id || CFGetTypeID(id) != CFStringGetTypeID() || !name ||
            CFGetTypeID(name) != CFStringGetTypeID() || !slot ||
            CFGetTypeID(slot) != CFNumberGetTypeID()) {
            continue;
        }
        SInt32 slotValue = -1;
        CFNumberGetValue(static_cast<CFNumberRef>(slot), kCFNumberSInt32Type, &slotValue);
        MixSpec spec{ToString(static_cast<CFStringRef>(id)),
            ToString(static_cast<CFStringRef>(name)), UInt32(slotValue)};
        if (spec.id.empty() || slotValue < 0 || UInt32(slotValue) >= kMaxMixes ||
            slotUsed[spec.slot] ||
            std::any_of(specs.begin(), specs.end(),
                [&](const MixSpec& s) { return s.id == spec.id; })) {
            continue;
        }
        slotUsed[spec.slot] = true;
        specs.push_back(spec);
    }
    return specs;
}

CFPropertyListRef MakeMixList(const std::vector<MixSpec>& specs)
{
    auto array = CFArrayCreateMutable(nullptr, 0, &kCFTypeArrayCallBacks);
    for (const auto& spec : specs) {
        auto dict = CFDictionaryCreateMutable(
            nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        auto id = CFStringCreateWithCString(nullptr, spec.id.c_str(), kCFStringEncodingUTF8);
        auto name =
            CFStringCreateWithCString(nullptr, spec.name.c_str(), kCFStringEncodingUTF8);
        SInt32 slotValue = SInt32(spec.slot);
        auto slot = CFNumberCreate(nullptr, kCFNumberSInt32Type, &slotValue);
        CFDictionarySetValue(dict, CFSTR("id"), id);
        CFDictionarySetValue(dict, CFSTR("name"), name);
        CFDictionarySetValue(dict, CFSTR("slot"), slot);
        CFArrayAppendValue(array, dict);
        CFRelease(id);
        CFRelease(name);
        CFRelease(slot);
        CFRelease(dict);
    }
    return array;
}

// Owns the mix devices. Changes arrive on the HAL's property thread and are applied on
// a private serial queue, so adding or removing devices never re-enters the HAL from
// inside its own SetPropertyData call.
class MixRegistry
{
public:
    MixRegistry(std::shared_ptr<const aspl::Context> context,
        std::shared_ptr<aspl::Plugin> plugin,
        std::shared_ptr<const Bus> bus,
        std::shared_ptr<const SharedClock> clock)
        : context_(std::move(context))
        , plugin_(std::move(plugin))
        , bus_(std::move(bus))
        , clock_(std::move(clock))
        , queue_(dispatch_queue_create("app.blend.driver.mixes", DISPATCH_QUEUE_SERIAL))
        , persistQueue_(dispatch_queue_create("app.blend.driver.persist", DISPATCH_QUEUE_SERIAL))
    {
    }

    // The stored list is applied on the queue, after Initialize returns, so no device
    // notifications reach the HAL while it is still initialising the plug-in.
    void AttachStorage(std::shared_ptr<aspl::Storage> storage)
    {
        storage_ = std::move(storage);
        auto [stored, ok] = storage_->ReadCustom(kStorageKey);
        if (ok && stored) {
            Enqueue(ParseMixList(stored), false);
            lastPersisted_ = stored; // keeps the reference; saves compare against it
        }
    }

    // Returns the list most recently asked for, even if the devices still lag behind it.
    CFPropertyListRef Get() const
    {
        std::lock_guard lock(pendingMutex_);
        return MakeMixList(desired_);
    }

    void Set(CFPropertyListRef list)
    {
        auto specs = ParseMixList(list);
        os_log(Log(), "set: %zu mixes", specs.size());
        Enqueue(std::move(specs), true);
    }

private:
    struct Entry
    {
        MixSpec spec;
        std::shared_ptr<BlendDevice> device;
        std::shared_ptr<MixReader> reader;
        std::shared_ptr<MixControl> control;
    };

    struct Job
    {
        MixRegistry* registry;
        std::vector<MixSpec> specs;
        bool persist;
    };

    // Bursts of device changes wedge coreaudiod (about 50 adds and removes within a
    // second hung it on macOS 26.6), so changes are coalesced: the latest list wins, and
    // the HAL sees at most one device list change per kMinApplyInterval.
    void Enqueue(std::vector<MixSpec> specs, bool persist)
    {
        std::lock_guard lock(pendingMutex_);
        desired_ = specs;
        pending_ = std::move(specs);
        hasPending_ = true;
        persistPending_ = persistPending_ || persist;
        if (scheduled_) {
            return;
        }
        scheduled_ = true;
        const UInt64 now = mach_absolute_time();
        const UInt64 earliest = lastApply_ + MsToTicks(kMinApplyIntervalMs);
        const int64_t delayNs =
            earliest > now ? int64_t(Ms(now, earliest) * 1e6) : int64_t(0);
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, delayNs), queue_, this,
            [](void* ctx) { static_cast<MixRegistry*>(ctx)->Drain(); });
    }

    // scheduled_ stays set until Apply returns, so a change that arrives while the HAL is
    // slow still waits a full interval after this one finishes.
    void Drain()
    {
        std::vector<MixSpec> specs;
        bool persist = false;
        {
            std::lock_guard lock(pendingMutex_);
            specs = std::move(pending_);
            persist = persistPending_;
            hasPending_ = false;
            persistPending_ = false;
        }
        Apply(std::move(specs));
        if (persist) {
            SchedulePersist();
        }
        std::lock_guard lock(pendingMutex_);
        lastApply_ = mach_absolute_time();
        scheduled_ = false;
        if (hasPending_) {
            scheduled_ = true;
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,
                                 int64_t(kMinApplyIntervalMs * NSEC_PER_MSEC)),
                queue_, this, [](void* ctx) { static_cast<MixRegistry*>(ctx)->Drain(); });
        }
    }

    // Saving the list goes through coreaudiod; one save made right after a device swap
    // waited ten minutes and held up every audio request on the Mac. Saves now run on
    // their own queue, a second after the last change, and only when the list changed.
    void SchedulePersist()
    {
        const uint64_t generation = ++persistGeneration_;
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, int64_t(NSEC_PER_SEC)), persistQueue_,
            new std::pair<MixRegistry*, uint64_t>(this, generation), [](void* ctx) {
                auto job = static_cast<std::pair<MixRegistry*, uint64_t>*>(ctx);
                if (job->second == job->first->persistGeneration_.load()) {
                    job->first->Persist();
                }
                delete job;
            });
    }

    void Persist()
    {
        if (!storage_) {
            return;
        }
        std::vector<MixSpec> applied;
        {
            std::lock_guard lock(mutex_);
            for (const auto& [id, entry] : mixes_) {
                applied.push_back(entry.spec);
            }
        }
        auto list = MakeMixList(applied);
        if (lastPersisted_ && CFEqual(list, lastPersisted_)) {
            CFRelease(list);
            return;
        }
        const UInt64 begin = mach_absolute_time();
        storage_->WriteCustom(kStorageKey, list);
        os_log(Log(), "persist: %zu mixes in %.1fms", applied.size(),
            Ms(begin, mach_absolute_time()));
        if (lastPersisted_) {
            CFRelease(lastPersisted_);
        }
        lastPersisted_ = list;
    }

    static UInt64 MsToTicks(double ms)
    {
        return UInt64(ms / Ms(0, 1));
    }

    // Never calls into the HAL while holding mutex_: the HAL may be inside Get() on
    // another thread waiting for the same lock while it handles our notification.
    void Apply(std::vector<MixSpec> specs)
    {
        const UInt64 begin = mach_absolute_time();
        std::vector<Entry> removed;
        std::vector<std::shared_ptr<BlendDevice>> added;
        std::vector<std::pair<std::shared_ptr<BlendDevice>, std::string>> renamed;
        {
            std::lock_guard lock(mutex_);
            for (auto it = mixes_.begin(); it != mixes_.end();) {
                auto wanted = std::find_if(specs.begin(), specs.end(),
                    [&](const MixSpec& s) { return s.id == it->first; });
                if (wanted == specs.end()) {
                    removed.push_back(it->second);
                    it = mixes_.erase(it);
                } else {
                    // A mix keeps its slot for life. Replacing the device instead would put
                    // two devices with one UID in the list while the old one drains.
                    if (wanted->slot != it->second.spec.slot) {
                        os_log(Log(), "apply: ignoring a slot change for %{public}s",
                            it->first.c_str());
                    }
                    ++it;
                }
            }
            for (const auto& spec : specs) {
                if (auto it = mixes_.find(spec.id); it != mixes_.end()) {
                    if (it->second.spec.name != spec.name) {
                        it->second.spec.name = spec.name;
                        renamed.emplace_back(it->second.device, spec.name);
                    }
                    continue;
                }
                auto entry = MakeMix(spec);
                mixes_[spec.id] = entry;
                added.push_back(entry.device);
            }
        }
        const UInt64 diffed = mach_absolute_time();
        os_log(Log(), "apply: start +%zu -%zu ~%zu", added.size(), removed.size(),
            renamed.size());
        for (auto& [device, name] : renamed) {
            device->Rename(name);
        }
        const UInt64 renamedAt = mach_absolute_time();
        // Removing a device while an app runs IO on it hung coreaudiod (macOS 26.6). A
        // deleted mix is silenced, refuses new IO and is marked dead at once, and is removed
        // from the list on a later pass once no IO is running on it.
        for (auto& entry : removed) {
            entry.reader->Silence();
            entry.control->Kill();
            entry.device->SetIsAlive(false);
            os_log(Log(), "apply: retiring %u%s", entry.device->GetID(),
                entry.device->GetIsRunning() ? ", in use" : "");
            dying_.push_back(entry.device);
        }
        if (!dying_.empty()) {
            ScheduleReap();
        }
        const UInt64 removedAt = mach_absolute_time();
        for (auto& device : added) {
            os_log(Log(), "apply: adding %u", device->GetID());
            plugin_->AddDevice(device);
        }
        const UInt64 addedAt = mach_absolute_time();
        os_log(Log(), "apply: +%zu -%zu ~%zu diff=%.1fms rename=%.1fms retire=%.1fms add=%.1fms",
            added.size(), removed.size(), renamed.size(), Ms(begin, diffed),
            Ms(diffed, renamedAt), Ms(renamedAt, removedAt), Ms(removedAt, addedAt));
    }

    static os_log_t Log()
    {
        static os_log_t log = os_log_create("app.blend.driver", "mixes");
        return log;
    }

    static double Ms(UInt64 from, UInt64 to)
    {
        static const double ticksPerMs = [] {
            mach_timebase_info_data_t tb;
            mach_timebase_info(&tb);
            return 1e6 * double(tb.denom) / double(tb.numer);
        }();
        return double(to - from) / ticksPerMs;
    }

    // Runs on queue_. Polls rather than hooking StopIO, because removal must not run
    // inside the HAL's own StopIO call either.
    void ScheduleReap()
    {
        if (reapScheduled_) {
            return;
        }
        reapScheduled_ = true;
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), queue_, this,
            [](void* ctx) {
                auto self = static_cast<MixRegistry*>(ctx);
                self->reapScheduled_ = false;
                self->Reap();
            });
    }

    void Reap()
    {
        for (auto it = dying_.begin(); it != dying_.end();) {
            if ((*it)->GetIsRunning()) {
                ++it;
                continue;
            }
            os_log(Log(), "reap: removing %u, its IO stopped", (*it)->GetID());
            plugin_->RemoveDevice(*it);
            it = dying_.erase(it);
        }
        if (!dying_.empty()) {
            ScheduleReap();
        }
    }

    Entry MakeMix(const MixSpec& spec)
    {
        aspl::DeviceParameters params;
        params.Name = spec.name;
        params.Manufacturer = "Blend";
        params.DeviceUID = std::string(kMixUIDPrefix) + spec.id;
        params.ModelUID = "app.blend.mix";
        params.SampleRate = kSampleRate;
        params.ChannelCount = kMixChannels;
        params.ZeroTimeStampPeriod = kZeroTimeStampPeriod;
        params.ClockDomain = kClockDomain;
        params.CanBeDefault = true;
        params.CanBeDefaultForSystemSounds = false;

        auto device = std::make_shared<BlendDevice>(context_, params, clock_);
        aspl::StreamParameters stream;
        stream.Direction = aspl::Direction::Input;
        stream.Format = FloatFormat(kMixChannels);
        device->AddStreamAsync(stream);
        auto reader = std::make_shared<MixReader>(bus_, spec.slot);
        device->SetIOHandler(reader);
        auto control = std::make_shared<MixControl>();
        device->SetControlHandler(control);
        return Entry{spec, device, reader, control};
    }

    const std::shared_ptr<const aspl::Context> context_;
    const std::shared_ptr<aspl::Plugin> plugin_;
    const std::shared_ptr<const Bus> bus_;
    const std::shared_ptr<const SharedClock> clock_;
    const dispatch_queue_t queue_;
    std::shared_ptr<aspl::Storage> storage_;
    mutable std::mutex mutex_;
    std::map<std::string, Entry> mixes_;

    // Only touched on queue_.
    std::vector<std::shared_ptr<BlendDevice>> dying_;
    bool reapScheduled_ = false;

    // Only touched on persistQueue_, apart from the generation counter.
    const dispatch_queue_t persistQueue_;
    std::atomic<uint64_t> persistGeneration_{0};
    CFPropertyListRef lastPersisted_ = nullptr;

    mutable std::mutex pendingMutex_;
    std::vector<MixSpec> desired_;
    std::vector<MixSpec> pending_;
    bool hasPending_ = false;
    bool persistPending_ = false;
    bool scheduled_ = false;
    UInt64 lastApply_ = 0;
};

class DriverHandler : public aspl::DriverRequestHandler
{
public:
    DriverHandler(std::weak_ptr<aspl::Driver> driver, std::shared_ptr<MixRegistry> registry)
        : driver_(std::move(driver))
        , registry_(std::move(registry))
    {
    }

    // Host storage only works once the HAL has initialised the plug-in.
    OSStatus OnInitialize() override
    {
        if (auto driver = driver_.lock()) {
            registry_->AttachStorage(driver->GetStorage());
        }
        return kAudioHardwareNoError;
    }

private:
    const std::weak_ptr<aspl::Driver> driver_;
    const std::shared_ptr<MixRegistry> registry_;
};

std::shared_ptr<aspl::Driver> CreateDriver()
{
    // libASPL's default tracer sends every operation to syslog; the driver logs its own
    // mix changes through os_log instead.
    auto context = std::make_shared<aspl::Context>(
        std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto clock = std::make_shared<const SharedClock>();
    auto bus = std::make_shared<Bus>();

    aspl::DeviceParameters busParams;
    busParams.Name = "Blend Bus";
    busParams.Manufacturer = "Blend";
    busParams.DeviceUID = kBusUID;
    busParams.ModelUID = "app.blend.bus";
    busParams.SampleRate = kSampleRate;
    busParams.ChannelCount = kBusChannels;
    busParams.ZeroTimeStampPeriod = kZeroTimeStampPeriod;
    busParams.ClockDomain = kClockDomain;
    busParams.CanBeDefault = false;
    busParams.CanBeDefaultForSystemSounds = false;

    auto busDevice = std::make_shared<BlendDevice>(context, busParams, clock);
    // The HAL ignores later changes to IsHidden, so it is set before the device exists.
    busDevice->SetIsHidden(true);
    aspl::StreamParameters busStream;
    busStream.Direction = aspl::Direction::Output;
    busStream.Format = FloatFormat(kBusChannels);
    busDevice->AddStreamAsync(busStream);
    busDevice->SetIOHandler(std::make_shared<BusWriter>(bus));

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(busDevice);

    auto registry = std::make_shared<MixRegistry>(context, plugin, bus, clock);
    plugin->RegisterCustomProperty(
        kMixListProperty,
        std::function<CFPropertyListRef()>([registry] { return registry->Get(); }),
        std::function<void(CFPropertyListRef)>(
            [registry](CFPropertyListRef list) { registry->Set(list); }));

    auto driver = std::make_shared<aspl::Driver>(context, plugin);
    driver->SetDriverHandler(std::make_shared<DriverHandler>(driver, registry));
    return driver;
}

} // namespace

extern "C" void* BlendDriverEntryPoint(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static std::shared_ptr<aspl::Driver> driver = CreateDriver();
    return driver->GetReference();
}
