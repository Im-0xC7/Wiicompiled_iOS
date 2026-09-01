#pragma once

#include <aurora/aurora.h>
#include <aurora/event.h>

namespace settings_overlay {
// Apply persistent controller settings once Aurora has discovered host devices.
void InitializeRuntimeSettings() noexcept;
// Draw the F10 settings bar before each Aurora present.
void HandleEvents(const AuroraEvent* events) noexcept;
void Draw() noexcept;
bool StartupScreenVisible() noexcept;
void NotifyStrapInputAccepted() noexcept;
void AdvancePresentedFrame() noexcept;

// Touch-button entry points for touch_controls.cpp's resolution-scale button - forward into the
// same SetResolutionScale the desktop top-bar's Resolution menu uses (defined in the anonymous
// namespace inside settings_overlay.cpp, so not directly callable from another translation unit),
// keeping both paths in sync through one VISetFrameBufferScale/Config.toml write.
void CycleResolutionScale() noexcept;
float CurrentResolutionScale() noexcept;
} // namespace settings_overlay
