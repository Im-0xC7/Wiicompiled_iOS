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
// Well past the visual ring - covers "roughly the bottom-left corner" rather than just the ring
// itself, so a tap that lands to the side of it (thumb not lined up exactly, held one-handed,
// etc.) still claims the stick instead of silently missing. Once claimed, the stick's origin
// snaps to wherever the finger actually landed (see the finger-down handler below), so this only
// widens the catch area - it never changes where the stick visually appears.
constexpr float kStickActivationRadiusFrac = 0.32f;
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
    // Safe-area insets (points, same space as width/height) - the margin on each edge obscured or
    // non-interactive due to a notch, Dynamic Island, rounded corners, or the home indicator.
    // Every edge-anchored control below adds these on top of its own visual margin so it never
    // sits under one of those obstructions.
    float safeLeft = 0.0f;
    float safeTop = 0.0f;
    float safeRight = 0.0f;
    float safeBottom = 0.0f;
};

// Must match the coordinate space Draw() actually renders in - ImGui's foreground draw list is
// sized off io.DisplaySize (the logical *point* size the engine feeds ImGui, see
// aurora-main/lib/imgui.cpp's new_frame()), not the native pixel framebuffer size
// AuroraGetSurfaceSize() reports. On a Retina display those differ by the 2x/3x device scale, so
// using the pixel size here silently drew every control 2-3x past the visible canvas.
ScreenMetrics CurrentMetrics() {
    const ImVec2 size = ImGui::GetIO().DisplaySize;
    ScreenMetrics m;
    m.width = size.x;
    m.height = size.y;
    m.shortSide = std::max(1.0f, std::min(m.width, m.height));
    AuroraGetSafeAreaInsets(&m.safeLeft, &m.safeTop, &m.safeRight, &m.safeBottom);
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
    return ImVec2(m.safeLeft + margin + r, m.height - m.safeBottom - margin - r);
}

float ButtonRadius(const ScreenMetrics& m) { return m.shortSide * kButtonRadiusFrac; }
ImVec2 ButtonACenter(const ScreenMetrics& m) {
    const float margin = m.shortSide * kButtonMarginFrac;
    const float r = ButtonRadius(m);
    return ImVec2(m.width - m.safeRight - margin - r, m.height - m.safeBottom - margin - r);
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
    return ImVec2(m.width - m.safeRight - margin - r, m.safeTop + margin + r);
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
// A second row under Start - the settings menu's own Gyro checkbox (DrawControllerSettings() in
// settings_overlay.cpp) is normally how this gets toggled, but that menu only opens via the
// SDL_SCANCODE_F10 keyboard shortcut (see HandleEvents() there), which iOS has no way to press.
// Give touch a direct path to the same toggle instead of leaving it stranded behind a
// keyboard-only menu.
ImVec2 PanelGyroCenter(const ScreenMetrics& m) {
    const ImVec2 s = PanelStartCenter(m);
    return ImVec2(s.x, s.y + SmallButtonRadius(m) * 3.0f);
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
TouchZone g_panelGyro{PanelGyroCenter, SmallButtonRadius, std::nullopt};
bool g_panelExpanded = false;

// Gyro steering: this is deliberately the *accelerometer*'s gravity-vector tilt, not the
// gyroscope's angular-rate integration - integrating a raw gyro drifts over time with no
// reference to correct against, which is exactly wrong for "hold the phone at an angle = that
// steering angle" (the actual desired feel). Kept the "gyro" name since that is what players and
// other games colloquially call tilt-steering, but the sensor opened here is SDL_SENSOR_ACCEL.
//
// Axis mapping (data[0]/data[1]/data[2] -> roll) is my best guess at SDL3's device-frame
// convention for a landscape-held phone. Confirmed on a real device: the raw atan2(A, B) sign
// steered backwards (tilting right turned the stick left), so kRollSign flips it - keep this
// flip if the axis indices below ever change, since re-deriving from scratch would silently
// reintroduce the same reversal.
constexpr int kRollAxisA = 0;
constexpr int kRollAxisB = 1;
constexpr float kRollSign = -1.0f;
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

// TEMPORARY debug aid (requested to diagnose "buttons aren't showing up") - remove once touch
// controls are confirmed working end-to-end on a real device. Snapshot of the last values
// ApplyOverlay() actually injected into port 0, so the overlay can show what gameplay is really
// seeing rather than just what the HUD drew.
struct DebugOverlaySnapshot {
    bool active = false;
    uint16_t buttons = 0;
    int8_t stickX = 0;
    int8_t stickY = 0;
};
DebugOverlaySnapshot g_debugSnapshot;

float RollAngle(const float data[3]) {
    return kRollSign * std::atan2(data[kRollAxisA], data[kRollAxisB]);
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

// touch_controls has no dedicated Init() call site (unlike WantsTouchControls(), which just
// re-reads Config.toml fresh every frame, g_gyro.enabled is a cached in-memory flag) - so without
// this, a persisted gyro_steering_enabled=true from a previous session would never actually take
// effect on the next launch: the checkbox/panel button would read back as off even though
// Config.toml still says on, silently ignoring the player's saved choice. Idempotent, so it's
// safe to call from every entry point that touches g_gyro before this has run.
void EnsureGyroLoadedFromConfig() {
    static bool loaded = false;
    if (loaded) {
        return;
    }
    loaded = true;
    if (RuntimeConfigFile::GyroSteeringEnabled()) {
        g_gyro.enabled = true;
        OpenGyroSensor();
    }
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
#if defined(__APPLE__) && TARGET_OS_IOS
    // iOS has no keyboard/mouse fallback, so touch is the only guaranteed way to play - default
    // on unconditionally (still overridable in settings) even if something shows up assigned to
    // port 0. Confirmed live in the Simulator: it surfaces a phantom/pass-through controller at
    // port 0 with nothing physically connected, which made the old port-0 check hide the HUD with
    // no way to reach it.
    return true;
#else
    // No explicit user choice recorded yet: default on only when nothing is already driving
    // port 0, so desktop/controller play is untouched.
    return IsInherentlyTouchCapable() && PADGetIndexForPort(0) < 0;
#endif
}

// TEMPORARY debug aid - see DebugOverlaySnapshot above. Always visible regardless of
// WantsTouchControls()/gyro state so it stays useful precisely when those are misbehaving.
void DrawDebugOverlay() {
    const ScreenMetrics m = CurrentMetrics();
    uint32_t nativeW = 0, nativeH = 0;
    AuroraGetSurfaceSize(&nativeW, &nativeH);

    ImGui::SetNextWindowPos(ImVec2(8.0f, 8.0f), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowBgAlpha(0.75f);
    if (ImGui::Begin("Touch/Controller Debug", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
        ImGui::Text("ImGui display: %.0f x %.0f pts", m.width, m.height);
        ImGui::Text("Native fb size: %u x %u px", nativeW, nativeH);
        ImGui::Text("Safe-area insets: L=%.0f T=%.0f R=%.0f B=%.0f", m.safeLeft, m.safeTop,
                     m.safeRight, m.safeBottom);
        ImGui::Text("WantsTouchControls(): %s", WantsTouchControls() ? "true" : "false");
        ImGui::Text("IsInherentlyTouchCapable(): %s", IsInherentlyTouchCapable() ? "true" : "false");

        ImGui::Separator();
        ImGui::TextUnformatted("Active touches:");
        int deviceCount = 0;
        SDL_TouchID* devices = SDL_GetTouchDevices(&deviceCount);
        bool anyFinger = false;
        if (devices) {
            for (int d = 0; d < deviceCount; ++d) {
                int fingerCount = 0;
                SDL_Finger** fingers = SDL_GetTouchFingers(devices[d], &fingerCount);
                if (fingers) {
                    for (int f = 0; f < fingerCount; ++f) {
                        anyFinger = true;
                        ImGui::BulletText("dev %llu finger %llu: (%.2f, %.2f) pressure=%.2f",
                                          static_cast<unsigned long long>(devices[d]),
                                          static_cast<unsigned long long>(fingers[f]->id), fingers[f]->x,
                                          fingers[f]->y, fingers[f]->pressure);
                    }
                    SDL_free(fingers);
                }
            }
            SDL_free(devices);
        }
        if (!anyFinger) {
            ImGui::TextDisabled(deviceCount > 0 ? "(no fingers down)" : "(no touch devices reported yet)");
        }

        ImGui::Separator();
        ImGui::TextUnformatted("Zone claims:");
        const auto zoneLine = [](const char* name, const std::optional<SDL_FingerID>& finger) {
            if (finger) {
                ImGui::BulletText("%s: finger %llu", name, static_cast<unsigned long long>(*finger));
            } else {
                ImGui::BulletText("%s: -", name);
            }
        };
        zoneLine("stick", g_stick.finger);
        zoneLine("A", g_buttonA.finger);
        zoneLine("B", g_buttonB.finger);
        zoneLine("expand", g_expandButton.finger);
        if (g_panelExpanded) {
            zoneLine("panel up", g_panelUp.finger);
            zoneLine("panel down", g_panelDown.finger);
            zoneLine("panel left", g_panelLeft.finger);
            zoneLine("panel right", g_panelRight.finger);
            zoneLine("panel start", g_panelStart.finger);
            zoneLine("panel L", g_panelL.finger);
            zoneLine("panel R", g_panelR.finger);
            zoneLine("panel gyro", g_panelGyro.finger);
        }

        ImGui::Separator();
        ImGui::Text("Gyro: enabled=%s sensor=%s neutral=%s angle=%.3f",
                     g_gyro.enabled ? "yes" : "no", g_gyro.sensor ? "open" : "closed",
                     g_gyro.hasNeutral ? "yes" : "no", static_cast<double>(g_gyro.smoothedAngle));

        ImGui::Separator();
        ImGui::Text("Applied to PAD port 0: active=%s buttons=0x%04X stick=(%d, %d)",
                     g_debugSnapshot.active ? "yes" : "no", g_debugSnapshot.buttons,
                     g_debugSnapshot.stickX, g_debugSnapshot.stickY);

        ImGui::Separator();
        ImGui::TextUnformatted("Controller ports:");
        for (uint32_t port = 0; port < PAD_MAX_CONTROLLERS; ++port) {
            ImGui::BulletText("port %u: index=%d", port, PADGetIndexForPort(port));
        }
        ImGui::Text("Connected controllers: %u", PADCount());
    }
    ImGui::End();
}

} // namespace

void HandleSdlEvent(const SDL_Event& event) noexcept {
    EnsureGyroLoadedFromConfig();
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
        HandlePressZone(g_panelGyro, finger, m, event.type, g_panelExpanded);
        if (event.type == SDL_EVENT_FINGER_DOWN && g_panelGyro.finger == finger.fingerID) {
            SetGyroSteeringEnabled(!g_gyro.enabled);
        }
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
    DrawDebugOverlay(); // TEMPORARY - see DebugOverlaySnapshot above.
    // Keep the panel (and its Gyro toggle) reachable even if touch controls are otherwise off,
    // so enabling gyro can never strand the player with no way back to the toggle that turns it
    // back off.
    if (!WantsTouchControls() && !g_gyro.enabled) {
        return;
    }
    const ScreenMetrics m = CurrentMetrics();
    ImDrawList* draw = ImGui::GetForegroundDrawList();
    constexpr ImU32 kRing = IM_COL32(255, 255, 255, 220);
    // A dark outline stroke drawn just outside the white ring - keeps every control legible over
    // a light background (track/sky) the same way the white-only version was legible over a dark
    // one, instead of picking a single color that only works against half of the game's palette.
    constexpr ImU32 kRingOutline = IM_COL32(0, 0, 0, 190);
    constexpr ImU32 kFill = IM_COL32(255, 255, 255, 90);
    constexpr ImU32 kFillActive = IM_COL32(255, 255, 255, 175);
    constexpr ImU32 kLabel = IM_COL32(255, 255, 255, 235);
    constexpr ImU32 kLabelOutline = IM_COL32(0, 0, 0, 210);

    const auto drawOutlinedCircle = [&](ImVec2 c, float r) {
        draw->AddCircle(c, r + 1.5f, kRingOutline, 0, 4.0f);
        draw->AddCircle(c, r, kRing, 0, 2.0f);
    };
    const auto drawOutlinedText = [&](ImVec2 pos, const char* label) {
        for (const ImVec2& offset : {ImVec2(-1, -1), ImVec2(1, -1), ImVec2(-1, 1), ImVec2(1, 1)}) {
            draw->AddText(ImVec2(pos.x + offset.x, pos.y + offset.y), kLabelOutline, label);
        }
        draw->AddText(pos, kLabel, label);
    };

    const auto drawButton = [&](const TouchZone& zone, const char* label) {
        const ImVec2 c = zone.center(m);
        const float r = zone.radius(m);
        draw->AddCircleFilled(c, r, zone.finger ? kFillActive : kFill);
        drawOutlinedCircle(c, r);
        const ImVec2 textSize = ImGui::CalcTextSize(label);
        drawOutlinedText(ImVec2(c.x - textSize.x * 0.5f, c.y - textSize.y * 0.5f), label);
    };

    if (!g_gyro.enabled) {
        const ImVec2 center = g_stick.finger ? g_stick.origin : StickDefaultCenter(m);
        const float visualRadius = m.shortSide * kStickVisualRadiusFrac;
        drawOutlinedCircle(center, visualRadius);
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
        const float thumbRadius = visualRadius * 0.45f;
        draw->AddCircleFilled(thumb, thumbRadius, g_stick.finger ? kFillActive : kFill);
        drawOutlinedCircle(thumb, thumbRadius);
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

        // Reflects the persistent on/off toggle state, not "currently held" like the buttons
        // above - so unlike drawButton() this colors active off g_gyro.enabled, not zone.finger.
        const ImVec2 gyroCenter = PanelGyroCenter(m);
        const float gyroRadius = SmallButtonRadius(m);
        draw->AddCircleFilled(gyroCenter, gyroRadius, g_gyro.enabled ? kFillActive : kFill);
        drawOutlinedCircle(gyroCenter, gyroRadius);
        constexpr const char* kGyroLabel = "Gy";
        const ImVec2 gyroTextSize = ImGui::CalcTextSize(kGyroLabel);
        drawOutlinedText(ImVec2(gyroCenter.x - gyroTextSize.x * 0.5f, gyroCenter.y - gyroTextSize.y * 0.5f),
                         kGyroLabel);
    }
}

void ApplyOverlay(PADStatus* statuses, uint32_t count) noexcept {
    EnsureGyroLoadedFromConfig();
    if (count == 0 || statuses == nullptr) {
        return;
    }
    const bool gyroActive = g_gyro.enabled && g_gyro.sensor && g_gyro.hasNeutral;
    if (!WantsTouchControls() && !gyroActive) {
        g_debugSnapshot.active = false;
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

    g_debugSnapshot = {true, status.button, status.stickX, status.stickY};
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
