// Input devices fed by the Swift UI (virtual pad, MFi/Xbox/PS controllers, CoreMotion).
// Modelled on Azahar's Android InputManager. Licensed under GPLv2 or any later version.

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <list>
#include <mutex>
#include <numbers>

#include "az_internal.h"
#include "common/param_package.h"
#include "common/settings.h"
#include "common/vector_math.h"
#include "core/frontend/input.h"

namespace AzIOS::Pad {

namespace {

constexpr const char* kEngine = "azios";

// ---- buttons ----------------------------------------------------------------------------------
class ButtonList;

class Button final : public ::Input::ButtonDevice {
public:
    explicit Button(std::shared_ptr<ButtonList> list_) : list{std::move(list_)} {}
    ~Button() override;
    bool GetStatus() const override {
        return status.load(std::memory_order_relaxed);
    }
    std::atomic_bool status{false};

private:
    std::shared_ptr<ButtonList> list;
};

class ButtonList {
public:
    void Add(int code, Button* b) {
        std::scoped_lock lock{mutex};
        entries.push_back({code, b});
        b->status = state[Index(code)].load();
    }
    void Remove(const Button* b) {
        std::scoped_lock lock{mutex};
        entries.remove_if([b](const Entry& e) { return e.button == b; });
    }
    void Set(int code, bool pressed) {
        std::scoped_lock lock{mutex};
        state[Index(code)] = pressed;
        for (auto& e : entries) {
            if (e.code == code) {
                e.button->status = pressed;
            }
        }
    }
    void ReleaseAll() {
        std::scoped_lock lock{mutex};
        for (auto& s : state) {
            s = false;
        }
        for (auto& e : entries) {
            e.button->status = false;
        }
    }

private:
    static std::size_t Index(int code) {
        return static_cast<std::size_t>(std::clamp(code, 0, AZ_BUTTON_COUNT - 1));
    }
    struct Entry {
        int code;
        Button* button;
    };
    std::mutex mutex;
    std::list<Entry> entries;
    std::array<std::atomic_bool, AZ_BUTTON_COUNT> state{};
};

Button::~Button() {
    list->Remove(this);
}

class ButtonFactory final : public ::Input::Factory<::Input::ButtonDevice> {
public:
    std::unique_ptr<::Input::ButtonDevice> Create(const Common::ParamPackage& params) override {
        const int code = params.Get("code", 0);
        auto b = std::make_unique<Button>(list);
        list->Add(code, b.get());
        return b;
    }
    std::shared_ptr<ButtonList> list = std::make_shared<ButtonList>();
};

// ---- sticks -----------------------------------------------------------------------------------
class StickList;

class Stick final : public ::Input::AnalogDevice {
public:
    explicit Stick(std::shared_ptr<StickList> list_) : list{std::move(list_)} {}
    ~Stick() override;
    std::tuple<float, float> GetStatus() const override {
        return {x.load(std::memory_order_relaxed), y.load(std::memory_order_relaxed)};
    }
    std::atomic<float> x{0.0f};
    std::atomic<float> y{0.0f};

private:
    std::shared_ptr<StickList> list;
};

class StickList {
public:
    void Add(int code, Stick* s) {
        std::scoped_lock lock{mutex};
        entries.push_back({code, s});
    }
    void Remove(const Stick* s) {
        std::scoped_lock lock{mutex};
        entries.remove_if([s](const Entry& e) { return e.stick == s; });
    }
    void Set(int code, float x, float y) {
        // Clamp to the unit circle like a real circle pad.
        const float len = std::sqrt(x * x + y * y);
        if (len > 1.0f) {
            x /= len;
            y /= len;
        }
        std::scoped_lock lock{mutex};
        for (auto& e : entries) {
            if (e.code == code) {
                e.stick->x = x;
                e.stick->y = y;
            }
        }
    }
    void ReleaseAll() {
        std::scoped_lock lock{mutex};
        for (auto& e : entries) {
            e.stick->x = 0.0f;
            e.stick->y = 0.0f;
        }
    }

private:
    struct Entry {
        int code;
        Stick* stick;
    };
    std::mutex mutex;
    std::list<Entry> entries;
};

Stick::~Stick() {
    list->Remove(this);
}

class StickFactory final : public ::Input::Factory<::Input::AnalogDevice> {
public:
    std::unique_ptr<::Input::AnalogDevice> Create(const Common::ParamPackage& params) override {
        const int code = params.Get("code", 0);
        auto s = std::make_unique<Stick>(list);
        list->Add(code, s.get());
        return s;
    }
    std::shared_ptr<StickList> list = std::make_shared<StickList>();
};

// ---- motion -----------------------------------------------------------------------------------
struct MotionSample {
    Common::Vec3<float> accel{0.0f, -1.0f, 0.0f}; // resting flat on a table
    Common::Vec3<float> gyro{};
};

std::mutex motion_mutex;
MotionSample motion_sample;

class Motion final : public ::Input::MotionDevice {
public:
    std::tuple<Common::Vec3<float>, Common::Vec3<float>> GetStatus() const override {
        std::scoped_lock lock{motion_mutex};
        return {motion_sample.accel, motion_sample.gyro};
    }
};

class MotionFactory final : public ::Input::Factory<::Input::MotionDevice> {
public:
    std::unique_ptr<::Input::MotionDevice> Create(const Common::ParamPackage&) override {
        return std::make_unique<Motion>();
    }
};

std::shared_ptr<ButtonFactory> button_factory;
std::shared_ptr<StickFactory> stick_factory;
std::shared_ptr<MotionFactory> motion_factory;
std::atomic_int motion_rotation{0};

/// Same axis transform Azahar uses on Android. iOS CoreMotion and Android share the device
/// frame (x right, y up, z out of the screen); see az_motion() in AzaharCore.h for units.
Common::Vec3<float> TransformAxes(Common::Vec3<float> in, int rotation) {
    Common::Vec3<float> out;
    out.y = in.z;
    switch (rotation & 3) {
    case 0:
        out.x = -in.x;
        out.z = in.y;
        break;
    case 1:
        out.x = in.y;
        out.z = in.x;
        break;
    case 2:
        out.x = in.x;
        out.z = -in.y;
        break;
    default:
        out.x = -in.y;
        out.z = -in.x;
        break;
    }
    return out;
}

} // namespace

void Init() {
    if (button_factory) {
        return;
    }
    button_factory = std::make_shared<ButtonFactory>();
    stick_factory = std::make_shared<StickFactory>();
    motion_factory = std::make_shared<MotionFactory>();
    ::Input::RegisterFactory<::Input::ButtonDevice>(kEngine, button_factory);
    ::Input::RegisterFactory<::Input::AnalogDevice>(kEngine, stick_factory);
    ::Input::RegisterFactory<::Input::MotionDevice>(kEngine, motion_factory);
}

void Shutdown() {
    if (!button_factory) {
        return;
    }
    ::Input::UnregisterFactory<::Input::ButtonDevice>(kEngine);
    ::Input::UnregisterFactory<::Input::AnalogDevice>(kEngine);
    ::Input::UnregisterFactory<::Input::MotionDevice>(kEngine);
    button_factory.reset();
    stick_factory.reset();
    motion_factory.reset();
}

std::string ButtonParam(int az_button) {
    return Common::ParamPackage{{"engine", kEngine}, {"code", std::to_string(az_button)}}
        .Serialize();
}

std::string StickParam(int az_stick) {
    return Common::ParamPackage{{"engine", kEngine}, {"code", std::to_string(az_stick)}}
        .Serialize();
}

std::string MotionParam() {
    return Common::ParamPackage{{"engine", kEngine}}.Serialize();
}

void SetButton(int az_button, bool pressed) {
    if (button_factory) {
        button_factory->list->Set(az_button, pressed);
    }
}

void SetStick(int az_stick, float x, float y) {
    if (stick_factory) {
        stick_factory->list->Set(az_stick, x, y);
    }
}

void SetMotionRotation(int rotation) {
    motion_rotation = rotation;
}

void SetMotion(float ax, float ay, float az, float gx, float gy, float gz) {
    constexpr float rad_to_deg = 180.0f / std::numbers::pi_v<float>;
    const int rot = motion_rotation.load();
    MotionSample s;
    s.accel = TransformAxes({ax, ay, az}, rot);
    s.gyro = TransformAxes({gx, gy, gz}, rot) * rad_to_deg;
    std::scoped_lock lock{motion_mutex};
    motion_sample = s;
}

void ReleaseAll() {
    if (button_factory) {
        button_factory->list->ReleaseAll();
    }
    if (stick_factory) {
        stick_factory->list->ReleaseAll();
    }
}

} // namespace AzIOS::Pad
