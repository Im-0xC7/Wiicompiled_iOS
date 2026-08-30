#pragma once

#include <SDL3/SDL_events.h>

#include <cstdint>

struct PADStatus;

// Virtual on-screen controller for touch-only play (no physical/paired controller), plus an
// optional gyro-steering mode that maps device tilt to the steering axis - a touch-input
// counterpart to controller_mapping_wizard, not a replacement for it. Multi-touch (steer with one
// finger while holding a button with another) needs its own finger tracking - ImGui's IO is
// single-pointer - so HandleSdlEvent reads raw SDL_EVENT_FINGER_*/SDL_EVENT_SENSOR_UPDATE events
// directly rather than going through ImGui's input state; Draw() only renders.
namespace touch_controls {

void HandleSdlEvent(const SDL_Event& event) noexcept;
// Draws the on-screen HUD (and the gyro-steering checkbox's own state feedback); call once per
// overlay frame, alongside controller_mapping_wizard::Draw().
void Draw() noexcept;
// Merges the current touch/gyro state into port 0 of a PADRead()-filled status array - called
// from PAD__Read_HLE (runtime/src/hle/input/pad.cpp), after the real PADRead().
void ApplyOverlay(PADStatus* statuses, uint32_t count) noexcept;

// Exposed for the "Controller settings" menu (settings_overlay.cpp) to draw touch-controls/
// gyro-steering checkboxes next to the existing button-mapping UI, rather than touch_controls
// owning its own menu. IsEnabled() reflects the effective state (an explicit user choice from
// Config.toml, or - if none recorded yet - the same touch-device/no-real-controller default
// Draw()/ApplyOverlay() use), so the checkbox's initial position matches actual current behavior.
bool IsEnabled() noexcept;
void SetEnabled(bool enabled) noexcept;
bool IsGyroSteeringEnabled() noexcept;
void SetGyroSteeringEnabled(bool enabled) noexcept;

} // namespace touch_controls
