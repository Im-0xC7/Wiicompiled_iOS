#include "touch_controls.h"
#include "runtime_config.h"

#include <imgui.h>
#include <SDL3/SDL_events.h>
#include <SDL3/SDL_sensor.h>
#include <SDL3/SDL_touch.h>

#include <dolphin/gx/GXAurora.h>
#include <dolphin/pad.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <optional>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

namespace touch_controls {
namespace {

// All sizes are fractions of the shorter screen dimension, so the HUD scales sensibly across
// phone/tablet sizes and either orientation, matching how e.g. DrawFpsOverlay's kMargin constants
// are fixed pixels but this HUD's touch targets need to stay a consistent *finger-relative* size.
constexpr float kStickVisualRadiusFrac = 0.10f;
constexpr float kStickActivationRadiusFrac = 0.16f; // larger than the visual ring - forgiving hit target
constexpr float kStickDragRangeFrac = 0.14f;         // drag distance for full deflection
constexpr float kStickMarginFrac = 0.07f;
constexpr float kButtonRadiusFrac = 0.06f;
constexpr float kButtonMarginFrac = 0.05f;
constexpr float kSmallButtonRadiusFrac = 0.035f;
constexpr float kExpandButtonRadiusFrac = 0.035f;
constexpr float kExpandMarginFrac = 0.035f;

struct ScreenMetrics {
    float width = 0.0f;
    float height = 0.0f;
    float shortSide = 0.0f;
};

ScreenMetrics CurrentMetrics() {
    uint32_t w = 0, h = 0;
    AuroraGetSurfaceSize(&w, &h);
    ScreenMetrics m;
    m.width = static_cast<float>(w);
    m.height = static_cast<float>(h);
    m.shortSide = std::max(1.0f, std::min(m.width, m.height));
    return m;
}

float Distance(ImVec2 a, ImVec2 b) {
    const float dx = a.x - b.x;
    const float dy = a.y - b.y;
    return std::sqrt(dx * dx + dy * dy);
}

// One touch-claimable circular control: a fixed default center/radius for hit-testing and
// drawing, plus which finger (if any) currently owns it. The stick additionally floats its
// effective center to wherever the claiming finger went down, for a forgiving "thumb doesn't
// need to start exactly on the ring" feel; press-only buttons just track pressed/not.
struct TouchZone {
    ImVec2 (*center)(const ScreenMetrics&);
    float (*radius)(const ScreenMetrics&);
    std::optional<SDL_FingerID> finger;
};

float StickActivationRadius(const ScreenMetrics& m) { return m.shortSide * kStickActivationRadiusFrac; }
ImVec2 StickDefaultCenter(const ScreenMetrics& m) {
    const float margin = m.shortSide * kStickMarginFrac;
    const float r = m.shortSide * kStickVisualRadiusFrac;
    return ImVec2(margin + r, m.height - margin - r);
}

float ButtonRadius(const ScreenMetrics& m) { return m.shortSide * kButtonRadiusFrac; }
ImVec2 ButtonACenter(const ScreenMetrics& m) {
    const float margin = m.shortSide * kButtonMarginFrac;
    const float r = ButtonRadius(m);
    return ImVec2(m.width - margin - r, m.height - margin - r);
}
ImVec2 ButtonBCenter(const ScreenMetrics& m) {
    const ImVec2 a = ButtonACenter(m);
    const float r = ButtonRadius(m);
    return ImVec2(a.x - r * 2.1f, a.y - r * 1.5f);
}

float SmallButtonRadius(const ScreenMetrics& m) { return m.shortSide * kSmallButtonRadiusFrac; }
ImVec2 ExpandButtonCenter(const ScreenMetrics& m) {
    const float margin = m.shortSide * kExpandMarginFrac;
    const float r = m.shortSide * kExpandButtonRadiusFrac;
    return ImVec2(m.width - margin - r, margin + r);
}
// Secondary panel (D-pad/Start/L/R), only meaningful while expanded - a horizontal cluster below
// the expand button so it never overlaps the primary race controls.
ImVec2 PanelDPadCenter(const ScreenMetrics& m) {
    const ImVec2 e = ExpandButtonCenter(m);
    return ImVec2(e.x - SmallButtonRadius(m) * 5.0f, e.y + SmallButtonRadius(m) * 3.0f);
}
ImVec2 PanelStartCenter(const ScreenMetrics& m) {
    const ImVec2 d = PanelDPadCenter(m);
    return ImVec2(d.x + SmallButtonRadius(m) * 3.2f, d.y);
}
ImVec2 PanelLCenter(const ScreenMetrics& m) {
    const ImVec2 s = PanelStartCenter(m);
    return ImVec2(s.x + SmallButtonRadius(m) * 2.6f, s.y);
}
ImVec2 PanelRCenter(const ScreenMetrics& m) {
    const ImVec2 l = PanelLCenter(m);
    return ImVec2(l.x + SmallButtonRadius(m) * 2.6f, l.y);
}

struct StickState {
    std::optional<SDL_FingerID> finger;
    ImVec2 origin{};
    ImVec2 current{};
};

// Directional sub-zones around PanelDPadCenter.
constexpr float kDPadSpreadFrac = 0.045f;
ImVec2 PanelUpCenter(const ScreenMetrics& m) {
    const ImVec2 c = PanelDPadCenter(m);
    return ImVec2(c.x, c.y - m.shortSide * kDPadSpreadFrac);
}
ImVec2 PanelDownCenter(const ScreenMetrics& m) {
    const ImVec2 c = PanelDPadCenter(m);
    return ImVec2(c.x, c.y + m.shortSide * kDPadSpreadFrac);
}
ImVec2 PanelLeftCenter(const ScreenMetrics& m) {
    const ImVec2 c = PanelDPadCenter(m);
    return ImVec2(c.x - m.shortSide * kDPadSpreadFrac, c.y);
}
ImVec2 PanelRightCenter(const ScreenMetrics& m) {
    const ImVec2 c = PanelDPadCenter(m);
    return ImVec2(c.x + m.shortSide * kDPadSpreadFrac, c.y);
}

StickState g_stick;
TouchZone g_buttonA{ButtonACenter, ButtonRadius, std::nullopt};
TouchZone g_buttonB{ButtonBCenter, ButtonRadius, std::nullopt};
TouchZone g_expandButton{ExpandButtonCenter, SmallButtonRadius, std::nullopt};
// Every zone needs a real center/radius function pointer - a default-constructed TouchZone would
// zero-initialize these to null and crash the first time it's hit-tested or drawn.
TouchZone g_panelUp{PanelUpCenter, SmallButtonRadius, std::nullopt};
TouchZone g_panelDown{PanelDownCenter, SmallButtonRadius, std::nullopt};
TouchZone g_panelLeft{PanelLeftCenter, SmallButtonRadius, std::nullopt};
TouchZone g_panelRight{PanelRightCenter, SmallButtonRadius, std::nullopt};
TouchZone g_panelStart{PanelStartCenter, SmallButtonRadius, std::nullopt};
TouchZone g_panelL{PanelLCenter, SmallButtonRadius, std::nullopt};
TouchZone g_panelR{PanelRCenter, SmallButtonRadius, std::nullopt};
bool g_panelExpanded = false;

// Gyro steering: this is deliberately the *accelerometer*'s gravity-vector tilt, not the
// gyroscope's angular-rate integration - integrating a raw gyro drifts over time with no
// reference to correct against, which is exactly wrong for "hold the phone at an angle = that
// steering angle" (the actual desired feel). Kept the "gyro" name since that is what players and
// other games colloquially call tilt-steering, but the sensor opened here is SDL_SENSOR_ACCEL.
//
// Axis mapping (data[0]/data[1]/data[2] -> roll) is my best guess at SDL3's device-frame
// convention for a landscape-held phone and has NOT been verified against a real device from
// this session - the calibrate-a-neutral-reading-then-take-the-delta approach means even a
// mis-assigned axis pair still yields *some* signed left/right signal, but which physical
// direction of tilt reads as "left" may need a real-device sign/axis flip. Worth confirming and
// adjusting kRollAxisA/kRollAxisB below on first real-device test.
constexpr int kRollAxisA = 0;
constexpr int kRollAxisB = 1;
constexpr float kGyroDeadzoneRadians = 0.05f;
constexpr float kGyroMaxAngleRadians = 0.6f; // ~34 degrees of tilt for full steering deflection
constexpr float kGyroSmoothing = 0.25f;      // exponential smoothing factor, higher = snappier

struct GyroState {
    bool enabled = false;
    SDL_Sensor* sensor = nullptr;
    bool hasNeutral = false;
    float neutralAngle = 0.0f;
    float smoothedAngle = 0.0f;
};

GyroState g_gyro;

float RollAngle(const float data[3]) {
    return std::atan2(data[kRollAxisA], data[kRollAxisB]);
}

void CloseGyroSensor() {
    if (g_gyro.sensor) {
        SDL_CloseSensor(g_gyro.sensor);
        g_gyro.sensor = nullptr;
    }
    g_gyro.hasNeutral = false;
}

void OpenGyroSensor() {
    int count = 0;
    SDL_SensorID* sensors = SDL_GetSensors(&count);
    if (!sensors) {
        return;
    }
    for (int i = 0; i < count; ++i) {
        if (SDL_GetSensorTypeForID(sensors[i]) == SDL_SENSOR_ACCEL) {
            g_gyro.sensor = SDL_OpenSensor(sensors[i]);
            break;
        }
    }
    SDL_free(sensors);
}

bool PointInZone(ImVec2 point, ImVec2 center, float radius) {
    return Distance(point, center) <= radius;
}

ImVec2 FingerScreenPos(const SDL_TouchFingerEvent& finger, const ScreenMetrics& m) {
    return ImVec2(finger.x * m.width, finger.y * m.height);
}

// Claims a press-only zone on finger-down, releases it on finger-up/canceled for that same
// finger. Motion is ignored - once claimed, a zone stays pressed regardless of small drift,
// which matters more for a racing game's accelerate button than pixel-perfect tracking would.
// allowNewClaims gates only finger-down (e.g. the collapsed panel's buttons can't be newly
// pressed); release always processes regardless, or a finger that claimed a panel button right
// before the panel collapsed would stay stuck "pressed" forever since nothing would ever see its
// matching finger-up.
void HandlePressZone(TouchZone& zone, const SDL_TouchFingerEvent& finger, const ScreenMetrics& m,
                     Uint32 type, bool allowNewClaims = true) {
    if (type == SDL_EVENT_FINGER_DOWN) {
        if (allowNewClaims && !zone.finger &&
            PointInZone(FingerScreenPos(finger, m), zone.center(m), zone.radius(m))) {
            zone.finger = finger.fingerID;
        }
    } else if (type == SDL_EVENT_FINGER_UP || type == SDL_EVENT_FINGER_CANCELED) {
        if (zone.finger == finger.fingerID) {
            zone.finger.reset();
        }
    }
}

// SDL3's touch-device list is populated lazily on this platform - SDL_GetTouchDevices() reports
// none at all until the first real touch event has actually occurred, which makes it useless as
// an *up-front* "should touch controls be visible" signal: nothing would ever show them for the
// player to make that first touch with. iOS (device or Simulator - TARGET_OS_IOS covers both) is
// unconditionally touch-capable, so that's the primary signal there; SDL_GetTouchDevices() stays
// as a fallback for any other platform with real, already-detected touch hardware.
bool IsInherentlyTouchCapable() {
#if defined(__APPLE__) && TARGET_OS_IOS
    return true;
#else
    int touchDeviceCount = 0;
    SDL_TouchID* devices = SDL_GetTouchDevices(&touchDeviceCount);
    if (devices) {
        SDL_free(devices);
    }
    return touchDeviceCount > 0;
#endif
}

bool WantsTouchControls() {
    if (const auto configured = RuntimeConfigFile::TouchControlsEnabled()) {
        return *configured;
    }
    // No explicit user choice recorded yet: default on only when nothing is already driving
    // port 0, so desktop/controller play is untouched.
    return IsInherentlyTouchCapable() && PADGetIndexForPort(0) < 0;
}

} // namespace

void HandleSdlEvent(const SDL_Event& event) noexcept {
    // Finger tracking below always runs regardless of WantsTouchControls()/g_panelExpanded, so a
    // zone claimed just before the setting changes (or the panel collapses) still gets its
    // matching finger-up and doesn't stay stuck pressed. Draw()/ApplyOverlay() are what actually
    // gate visibility and gameplay effect.
    switch (event.type) {
    case SDL_EVENT_FINGER_DOWN:
    case SDL_EVENT_FINGER_MOTION:
    case SDL_EVENT_FINGER_UP:
    case SDL_EVENT_FINGER_CANCELED: {
        const ScreenMetrics m = CurrentMetrics();
        const SDL_TouchFingerEvent& finger = event.tfinger;
        const ImVec2 pos = FingerScreenPos(finger, m);

        if (event.type == SDL_EVENT_FINGER_DOWN) {
            if (!g_stick.finger &&
                Distance(pos, StickDefaultCenter(m)) <= StickActivationRadius(m)) {
                g_stick.finger = finger.fingerID;
                g_stick.origin = pos;
                g_stick.current = pos;
            }
        } else if (event.type == SDL_EVENT_FINGER_MOTION) {
            if (g_stick.finger == finger.fingerID) {
                g_stick.current = pos;
            }
        } else {
            if (g_stick.finger == finger.fingerID) {
                g_stick.finger.reset();
            }
        }

        HandlePressZone(g_buttonA, finger, m, event.type);
        HandlePressZone(g_buttonB, finger, m, event.type);
        HandlePressZone(g_expandButton, finger, m, event.type);
        if (event.type == SDL_EVENT_FINGER_DOWN && g_expandButton.finger == finger.fingerID) {
            g_panelExpanded = !g_panelExpanded;
        }
        HandlePressZone(g_panelUp, finger, m, event.type, g_panelExpanded);
        HandlePressZone(g_panelDown, finger, m, event.type, g_panelExpanded);
        HandlePressZone(g_panelLeft, finger, m, event.type, g_panelExpanded);
        HandlePressZone(g_panelRight, finger, m, event.type, g_panelExpanded);
        HandlePressZone(g_panelStart, finger, m, event.type, g_panelExpanded);
        HandlePressZone(g_panelL, finger, m, event.type, g_panelExpanded);
        HandlePressZone(g_panelR, finger, m, event.type, g_panelExpanded);
        break;
    }
    case SDL_EVENT_SENSOR_UPDATE: {
        if (g_gyro.enabled && g_gyro.sensor &&
            SDL_GetSensorFromID(event.sensor.which) == g_gyro.sensor) {
            const float angle = RollAngle(event.sensor.data);
            if (!g_gyro.hasNeutral) {
                g_gyro.neutralAngle = angle;
                g_gyro.smoothedAngle = angle;
                g_gyro.hasNeutral = true;
            } else {
                g_gyro.smoothedAngle += (angle - g_gyro.smoothedAngle) * kGyroSmoothing;
            }
        }
        break;
    }
    default:
        break;
    }
}

void Draw() noexcept {
    if (!WantsTouchControls()) {
        return;
    }
    const ScreenMetrics m = CurrentMetrics();
    ImDrawList* draw = ImGui::GetForegroundDrawList();
    constexpr ImU32 kRing = IM_COL32(255, 255, 255, 90);
    constexpr ImU32 kFill = IM_COL32(255, 255, 255, 60);
    constexpr ImU32 kFillActive = IM_COL32(255, 255, 255, 130);
    constexpr ImU32 kLabel = IM_COL32(255, 255, 255, 200);

    const auto drawButton = [&](const TouchZone& zone, const char* label) {
        const ImVec2 c = zone.center(m);
        const float r = zone.radius(m);
        draw->AddCircleFilled(c, r, zone.finger ? kFillActive : kFill);
        draw->AddCircle(c, r, kRing, 0, 2.0f);
        const ImVec2 textSize = ImGui::CalcTextSize(label);
        draw->AddText(ImVec2(c.x - textSize.x * 0.5f, c.y - textSize.y * 0.5f), kLabel, label);
    };

    if (!g_gyro.enabled) {
        const ImVec2 center = g_stick.finger ? g_stick.origin : StickDefaultCenter(m);
        const float visualRadius = m.shortSide * kStickVisualRadiusFrac;
        draw->AddCircle(center, visualRadius, kRing, 0, 2.0f);
        ImVec2 thumb = center;
        if (g_stick.finger) {
            const float dragRange = m.shortSide * kStickDragRangeFrac;
            ImVec2 offset(g_stick.current.x - g_stick.origin.x, g_stick.current.y - g_stick.origin.y);
            const float len = std::sqrt(offset.x * offset.x + offset.y * offset.y);
            if (len > dragRange && len > 0.0f) {
                offset.x = offset.x / len * dragRange;
                offset.y = offset.y / len * dragRange;
            }
            thumb = ImVec2(center.x + offset.x, center.y + offset.y);
        }
        draw->AddCircleFilled(thumb, visualRadius * 0.45f, g_stick.finger ? kFillActive : kFill);
    }

    drawButton(g_buttonA, "A");
    drawButton(g_buttonB, "B");
    drawButton(g_expandButton, g_panelExpanded ? "x" : "...");

    if (g_panelExpanded) {
        drawButton(g_panelUp, "^");
        drawButton(g_panelDown, "v");
        drawButton(g_panelLeft, "<");
        drawButton(g_panelRight, ">");
        drawButton(g_panelStart, "St");
        drawButton(g_panelL, "L");
        drawButton(g_panelR, "R");
    }
}

void ApplyOverlay(PADStatus* statuses, uint32_t count) noexcept {
    if (count == 0 || statuses == nullptr) {
        return;
    }
    const bool gyroActive = g_gyro.enabled && g_gyro.sensor && g_gyro.hasNeutral;
    if (!WantsTouchControls() && !gyroActive) {
        return;
    }

    PADStatus& status = statuses[0];
    status.err = PAD_ERR_NONE;

    uint16_t buttons = status.button;
    if (g_buttonA.finger) buttons |= PAD_BUTTON_A;
    if (g_buttonB.finger) buttons |= PAD_BUTTON_B;
    if (g_panelExpanded) {
        if (g_panelUp.finger) buttons |= PAD_BUTTON_UP;
        if (g_panelDown.finger) buttons |= PAD_BUTTON_DOWN;
        if (g_panelLeft.finger) buttons |= PAD_BUTTON_LEFT;
        if (g_panelRight.finger) buttons |= PAD_BUTTON_RIGHT;
        if (g_panelStart.finger) buttons |= PAD_BUTTON_START;
        if (g_panelL.finger) buttons |= PAD_TRIGGER_L;
        if (g_panelR.finger) buttons |= PAD_TRIGGER_R;
    }
    status.button = buttons;

    if (gyroActive) {
        float delta = g_gyro.smoothedAngle - g_gyro.neutralAngle;
        const float sign = delta < 0.0f ? -1.0f : 1.0f;
        float magnitude = std::fabs(delta);
        magnitude = std::max(0.0f, magnitude - kGyroDeadzoneRadians);
        magnitude = std::min(magnitude, kGyroMaxAngleRadians - kGyroDeadzoneRadians);
        const float normalized = magnitude / (kGyroMaxAngleRadians - kGyroDeadzoneRadians);
        status.stickX = static_cast<int8_t>(std::lround(sign * normalized * 127.0f));
    } else if (g_stick.finger) {
        const ScreenMetrics m = CurrentMetrics();
        const float dragRange = m.shortSide * kStickDragRangeFrac;
        ImVec2 offset(g_stick.current.x - g_stick.origin.x, g_stick.current.y - g_stick.origin.y);
        const float len = std::sqrt(offset.x * offset.x + offset.y * offset.y);
        if (len > dragRange && len > 0.0f) {
            offset.x = offset.x / len * dragRange;
            offset.y = offset.y / len * dragRange;
        }
        status.stickX = static_cast<int8_t>(std::lround(std::clamp(offset.x / dragRange, -1.0f, 1.0f) * 127.0f));
        status.stickY = static_cast<int8_t>(std::lround(std::clamp(-offset.y / dragRange, -1.0f, 1.0f) * 127.0f));
    }
}

bool IsEnabled() noexcept { return WantsTouchControls(); }

void SetEnabled(bool enabled) noexcept { RuntimeConfigFile::SetTouchControlsEnabled(enabled); }

bool IsGyroSteeringEnabled() noexcept { return g_gyro.enabled; }

void SetGyroSteeringEnabled(bool enabled) noexcept {
    if (enabled == g_gyro.enabled) {
        return;
    }
    g_gyro.enabled = enabled;
    RuntimeConfigFile::SetGyroSteeringEnabled(enabled);
    if (enabled) {
        OpenGyroSensor();
    } else {
        CloseGyroSensor();
    }
}

} // namespace touch_controls
