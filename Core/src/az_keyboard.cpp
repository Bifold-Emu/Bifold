// Software keyboard applet routed to a Swift callback. Licensed under GPLv2 or later.

#include <algorithm>
#include <cstdlib>
#include <mutex>

#include "az_internal.h"
#include "common/logging/log.h"
#include "core/core.h"
#include "core/frontend/applets/default_applets.h"
#include "core/frontend/applets/swkbd.h"

namespace AzIOS {

namespace {

std::mutex keyboard_mutex;
AZKeyboardCallback keyboard_cb = nullptr;
void* keyboard_ctx = nullptr;

class IOSKeyboard final : public Frontend::SoftwareKeyboard {
public:
    void Execute(const Frontend::KeyboardConfig& config) override {
        SoftwareKeyboard::Execute(config);

        AZKeyboardCallback cb;
        void* ctx;
        {
            std::scoped_lock lock{keyboard_mutex};
            cb = keyboard_cb;
            ctx = keyboard_ctx;
        }

        int button_count = 1;
        switch (config.button_config) {
        case Frontend::ButtonConfig::None:
        case Frontend::ButtonConfig::Single:
            button_count = 1;
            break;
        case Frontend::ButtonConfig::Dual:
            button_count = 2;
            break;
        case Frontend::ButtonConfig::Triple:
            button_count = 3;
            break;
        }

        std::string text;
        int button = button_count - 1; // rightmost button is "OK"
        if (cb) {
            char* result = cb(config.hint_text.c_str(), config.max_text_length,
                              config.multiline_mode, button_count, &button, ctx);
            if (result) {
                text = result;
                std::free(result);
            }
        } else {
            text = "Azahar";
        }
        button = std::clamp(button, 0, std::max(button_count - 1, 0));

        if (Finalize(text, static_cast<u8>(button)) != Frontend::ValidationError::None) {
            // Fall back to something the game will accept rather than hanging the applet.
            LOG_WARNING(Frontend, "Keyboard input rejected by validation, sending default");
            Finalize("Azahar", static_cast<u8>(button));
        }
    }

    void ShowError(const std::string& error) override {
        LOG_ERROR(Frontend, "Software keyboard error: {}", error);
    }
};

} // namespace

void SetKeyboardCallback(AZKeyboardCallback cb, void* ctx) {
    std::scoped_lock lock{keyboard_mutex};
    keyboard_cb = cb;
    keyboard_ctx = ctx;
}

void RegisterApplets() {
    auto& system = Core::System::GetInstance();
    Frontend::RegisterDefaultApplets(system);
    system.RegisterSoftwareKeyboard(std::make_shared<IOSKeyboard>());
}

} // namespace AzIOS

extern "C" void az_set_keyboard_callback(AZKeyboardCallback cb, void* ctx) {
    AzIOS::SetKeyboardCallback(cb, ctx);
}
