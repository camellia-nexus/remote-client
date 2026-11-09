// Wayland keyboard shortcuts inhibit support
// This module provides functionality to inhibit system keyboard shortcuts
// on Wayland compositors, allowing remote desktop windows to capture all
// key events including Super, Alt+Tab, etc.

#ifndef WAYLAND_SHORTCUTS_INHIBIT_H_
#define WAYLAND_SHORTCUTS_INHIBIT_H_

#include <gtk/gtk.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Check if Wayland shortcuts inhibition is supported on the given GdkDisplay.
bool wayland_shortcuts_inhibit_is_supported(GdkDisplay* display);

// Initialize shortcuts inhibit hooks for a sub-window created by desktop_multi_window plugin.
// Sub-windows start with shortcuts inhibition disabled by default.
//
// @param view The FlView of the sub-window
void wayland_shortcuts_inhibit_init_for_subwindow(void* view);

// Enable or disable keyboard shortcuts inhibition for a specific GtkWindow.
// Returns true if the request was accepted or already in desired state.
bool wayland_shortcuts_inhibit_set_enabled(GtkWindow* window, bool enabled);

// Get the current shortcuts inhibitor state string for a window:
// "active", "inactive", "pending", "unsupported", "disabled", "destroyed".
const char* wayland_shortcuts_inhibit_get_state(GtkWindow* window);

// Explicitly teardown and release all inhibitor resources for a window.
void wayland_shortcuts_inhibit_teardown(GtkWindow* window);

#ifdef __cplusplus
}
#endif

#endif  // WAYLAND_SHORTCUTS_INHIBIT_H_
