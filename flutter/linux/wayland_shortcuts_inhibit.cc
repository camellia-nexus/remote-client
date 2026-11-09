// Wayland keyboard shortcuts inhibit implementation
// Uses the zwp_keyboard_shortcuts_inhibit_manager_v1 protocol to request
// the compositor to disable system shortcuts for specific windows.

#include "wayland_shortcuts_inhibit.h"

#if defined(GDK_WINDOWING_WAYLAND) && defined(HAS_KEYBOARD_SHORTCUTS_INHIBIT)

#include <cstring>
#include <gdk/gdkwayland.h>
#include <wayland-client.h>
#include "keyboard-shortcuts-inhibit-unstable-v1-client-protocol.h"

typedef struct {
  struct wl_registry* registry;
  struct zwp_keyboard_shortcuts_inhibit_manager_v1* manager;
  bool registry_bound;
} DisplayWaylandManager;

static void display_wayland_manager_free(gpointer data) {
  DisplayWaylandManager* dm = static_cast<DisplayWaylandManager*>(data);
  if (dm == nullptr) return;
  if (dm->manager != nullptr) {
    zwp_keyboard_shortcuts_inhibit_manager_v1_destroy(dm->manager);
    dm->manager = nullptr;
  }
  if (dm->registry != nullptr) {
    wl_registry_destroy(dm->registry);
    dm->registry = nullptr;
  }
  g_free(dm);
}

static void registry_handle_global(void* data, struct wl_registry* registry,
                                   uint32_t name, const char* interface,
                                   uint32_t /*version*/) {
  DisplayWaylandManager* dm = static_cast<DisplayWaylandManager*>(data);
  if (strcmp(interface,
             zwp_keyboard_shortcuts_inhibit_manager_v1_interface.name) == 0) {
    dm->manager =
        static_cast<zwp_keyboard_shortcuts_inhibit_manager_v1*>(wl_registry_bind(
            registry, name, &zwp_keyboard_shortcuts_inhibit_manager_v1_interface,
            1));
  }
}

static void registry_handle_global_remove(void* /*data*/, struct wl_registry* /*registry*/,
                                          uint32_t /*name*/) {
}

static const struct wl_registry_listener registry_listener = {
    registry_handle_global,
    registry_handle_global_remove,
};

static DisplayWaylandManager* get_cached_display_manager(GdkDisplay* display) {
  if (display == nullptr || !GDK_IS_WAYLAND_DISPLAY(display)) {
    return nullptr;
  }
  DisplayWaylandManager* dm = static_cast<DisplayWaylandManager*>(
      g_object_get_data(G_OBJECT(display), "wayland-shortcuts-display-manager"));
  if (dm != nullptr) {
    return dm;
  }

  struct wl_display* wl_display = gdk_wayland_display_get_wl_display(display);
  if (wl_display == nullptr) {
    return nullptr;
  }

  struct wl_registry* registry = wl_display_get_registry(wl_display);
  if (registry == nullptr) {
    return nullptr;
  }

  dm = g_new0(DisplayWaylandManager, 1);
  dm->registry = registry;
  wl_registry_add_listener(registry, &registry_listener, dm);

  // Non-blocking flush: requests are queued and processed asynchronously by the main loop
  wl_display_flush(wl_display);

  g_object_set_data_full(G_OBJECT(display), "wayland-shortcuts-display-manager",
                         dm, display_wayland_manager_free);
  return dm;
}

enum InhibitState {
  INHIBIT_STATE_DISABLED = 0,
  INHIBIT_STATE_PENDING,
  INHIBIT_STATE_ACTIVE,
  INHIBIT_STATE_INACTIVE,
  INHIBIT_STATE_UNSUPPORTED,
  INHIBIT_STATE_FAILED
};

struct WindowShortcutsInhibitData {
  GtkWindow* window;
  bool enabled;
  InhibitState state;
  struct zwp_keyboard_shortcuts_inhibitor_v1* inhibitor;
};

static void window_shortcuts_inhibit_data_free(gpointer data) {
  WindowShortcutsInhibitData* wid = static_cast<WindowShortcutsInhibitData*>(data);
  if (wid == nullptr) return;
  if (wid->inhibitor != nullptr) {
    zwp_keyboard_shortcuts_inhibitor_v1_destroy(wid->inhibitor);
    wid->inhibitor = nullptr;
  }
  g_free(wid);
}

static WindowShortcutsInhibitData* get_or_create_window_data(GtkWindow* window) {
  if (window == nullptr) return nullptr;
  WindowShortcutsInhibitData* wid = static_cast<WindowShortcutsInhibitData*>(
      g_object_get_data(G_OBJECT(window), "shortcuts-inhibit-window-data"));
  if (wid != nullptr) return wid;

  wid = g_new0(WindowShortcutsInhibitData, 1);
  wid->window = window;
  wid->enabled = false;  // Disabled by default for all windows!
  wid->state = INHIBIT_STATE_DISABLED;
  wid->inhibitor = nullptr;

  g_object_set_data_full(G_OBJECT(window), "shortcuts-inhibit-window-data",
                         wid, window_shortcuts_inhibit_data_free);
  return wid;
}

static void inhibitor_active(void* data,
                             struct zwp_keyboard_shortcuts_inhibitor_v1* /*inhibitor*/) {
  WindowShortcutsInhibitData* wid = static_cast<WindowShortcutsInhibitData*>(data);
  if (wid != nullptr) {
    wid->state = INHIBIT_STATE_ACTIVE;
  }
}

static void inhibitor_inactive(void* data,
                               struct zwp_keyboard_shortcuts_inhibitor_v1* /*inhibitor*/) {
  WindowShortcutsInhibitData* wid = static_cast<WindowShortcutsInhibitData*>(data);
  if (wid != nullptr) {
    wid->state = INHIBIT_STATE_INACTIVE;
  }
}

static const struct zwp_keyboard_shortcuts_inhibitor_v1_listener inhibitor_listener = {
    inhibitor_active,
    inhibitor_inactive,
};

static void release_inhibitor_nonblocking(WindowShortcutsInhibitData* wid) {
  if (wid == nullptr || wid->inhibitor == nullptr) return;
  zwp_keyboard_shortcuts_inhibitor_v1_destroy(wid->inhibitor);
  wid->inhibitor = nullptr;
  wid->state = wid->enabled ? INHIBIT_STATE_INACTIVE : INHIBIT_STATE_DISABLED;

  if (wid->window != nullptr) {
    GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(wid->window));
    if (display != nullptr && GDK_IS_WAYLAND_DISPLAY(display)) {
      struct wl_display* wl_display = gdk_wayland_display_get_wl_display(display);
      if (wl_display != nullptr) {
        wl_display_flush(wl_display);
      }
    }
  }
}

static void apply_inhibitor_nonblocking(WindowShortcutsInhibitData* wid) {
  if (wid == nullptr || !wid->enabled || wid->inhibitor != nullptr) return;
  if (wid->window == nullptr) return;

  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(wid->window));
  if (display == nullptr || !GDK_IS_WAYLAND_DISPLAY(display)) {
    wid->state = INHIBIT_STATE_UNSUPPORTED;
    return;
  }

  DisplayWaylandManager* dm = get_cached_display_manager(display);
  if (dm == nullptr || dm->manager == nullptr) {
    wid->state = INHIBIT_STATE_UNSUPPORTED;
    return;
  }

  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(wid->window));
  if (gdk_window == nullptr) return;

  struct wl_surface* surface = gdk_wayland_window_get_wl_surface(gdk_window);
  if (surface == nullptr) return;

  GdkSeat* gdk_seat = gdk_display_get_default_seat(display);
  if (gdk_seat == nullptr) return;

  struct wl_seat* seat = gdk_wayland_seat_get_wl_seat(gdk_seat);
  if (seat == nullptr) return;

  wid->inhibitor = zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts(
      dm->manager, surface, seat);
  if (wid->inhibitor == nullptr) {
    wid->state = INHIBIT_STATE_FAILED;
    return;
  }

  wid->state = INHIBIT_STATE_PENDING;
  zwp_keyboard_shortcuts_inhibitor_v1_add_listener(
      wid->inhibitor, &inhibitor_listener, wid);

  struct wl_display* wl_display = gdk_wayland_display_get_wl_display(display);
  if (wl_display != nullptr) {
    // Non-blocking flush: never roundtrip inside focus handler!
    wl_display_flush(wl_display);
  }
}

static gboolean on_window_focus_in(GtkWidget* widget, GdkEventFocus* /*event*/, gpointer /*user_data*/) {
  if (GTK_IS_WINDOW(widget)) {
    WindowShortcutsInhibitData* wid = get_or_create_window_data(GTK_WINDOW(widget));
    if (wid != nullptr && wid->enabled) {
      apply_inhibitor_nonblocking(wid);
    }
  }
  return FALSE;
}

static gboolean on_window_focus_out(GtkWidget* widget, GdkEventFocus* /*event*/, gpointer /*user_data*/) {
  if (GTK_IS_WINDOW(widget)) {
    WindowShortcutsInhibitData* wid = get_or_create_window_data(GTK_WINDOW(widget));
    if (wid != nullptr && wid->inhibitor != nullptr) {
      release_inhibitor_nonblocking(wid);
    }
  }
  return FALSE;
}

static void on_window_realize(GtkWidget* widget, gpointer /*user_data*/) {
  if (GTK_IS_WINDOW(widget)) {
    if (g_object_get_data(G_OBJECT(widget), "shortcuts-inhibit-focus-handlers-connected") != nullptr) {
      return;
    }
    g_signal_connect(widget, "focus-in-event", G_CALLBACK(on_window_focus_in), nullptr);
    g_signal_connect(widget, "focus-out-event", G_CALLBACK(on_window_focus_out), nullptr);
    g_object_set_data(G_OBJECT(widget), "shortcuts-inhibit-focus-handlers-connected", GINT_TO_POINTER(1));

    WindowShortcutsInhibitData* wid = get_or_create_window_data(GTK_WINDOW(widget));
    if (wid != nullptr && wid->enabled && gtk_window_has_toplevel_focus(GTK_WINDOW(widget))) {
      apply_inhibitor_nonblocking(wid);
    }
  }
}

bool wayland_shortcuts_inhibit_is_supported(GdkDisplay* display) {
  if (display == nullptr || !GDK_IS_WAYLAND_DISPLAY(display)) return false;
  DisplayWaylandManager* dm = get_cached_display_manager(display);
  return dm != nullptr && dm->manager != nullptr;
}

void wayland_shortcuts_inhibit_init_for_subwindow(void* view) {
  if (view == nullptr) return;
  GtkWidget* widget = GTK_WIDGET(view);
  GtkWidget* toplevel = gtk_widget_get_toplevel(widget);

  if (toplevel != nullptr && GTK_IS_WINDOW(toplevel)) {
    // Ensure window data exists (disabled by default)
    get_or_create_window_data(GTK_WINDOW(toplevel));

    if (g_object_get_data(G_OBJECT(toplevel), "shortcuts-inhibit-focus-handlers-connected") != nullptr ||
        g_object_get_data(G_OBJECT(toplevel), "shortcuts-inhibit-realize-handler-connected") != nullptr) {
      return;
    }

    if (gtk_widget_get_realized(toplevel)) {
      on_window_realize(toplevel, nullptr);
    } else {
      g_object_set_data(G_OBJECT(toplevel), "shortcuts-inhibit-realize-handler-connected", GINT_TO_POINTER(1));
      g_signal_connect(toplevel, "realize", G_CALLBACK(on_window_realize), nullptr);
    }
  }
}

bool wayland_shortcuts_inhibit_set_enabled(GtkWindow* window, bool enabled) {
  if (window == nullptr) return false;
  WindowShortcutsInhibitData* wid = get_or_create_window_data(window);
  if (wid == nullptr) return false;

  wid->enabled = enabled;
  if (!enabled) {
    release_inhibitor_nonblocking(wid);
    wid->state = INHIBIT_STATE_DISABLED;
    return true;
  }

  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  if (display == nullptr || !GDK_IS_WAYLAND_DISPLAY(display)) {
    wid->state = INHIBIT_STATE_UNSUPPORTED;
    return false;
  }

  DisplayWaylandManager* dm = get_cached_display_manager(display);
  if (dm == nullptr || dm->manager == nullptr) {
    wid->state = INHIBIT_STATE_UNSUPPORTED;
    return false;
  }

  if (gtk_window_has_toplevel_focus(window)) {
    apply_inhibitor_nonblocking(wid);
  } else {
    wid->state = INHIBIT_STATE_INACTIVE;
  }
  return true;
}

const char* wayland_shortcuts_inhibit_get_state(GtkWindow* window) {
  if (window == nullptr) return "destroyed";
  WindowShortcutsInhibitData* wid = static_cast<WindowShortcutsInhibitData*>(
      g_object_get_data(G_OBJECT(window), "shortcuts-inhibit-window-data"));
  if (wid == nullptr) return "disabled";

  switch (wid->state) {
    case INHIBIT_STATE_ACTIVE:
      return "active";
    case INHIBIT_STATE_INACTIVE:
      return "inactive";
    case INHIBIT_STATE_PENDING:
      return "pending";
    case INHIBIT_STATE_UNSUPPORTED:
      return "unsupported";
    case INHIBIT_STATE_FAILED:
      return "failed";
    case INHIBIT_STATE_DISABLED:
    default:
      return "disabled";
  }
}

void wayland_shortcuts_inhibit_teardown(GtkWindow* window) {
  if (window == nullptr) return;
  WindowShortcutsInhibitData* wid = static_cast<WindowShortcutsInhibitData*>(
      g_object_get_data(G_OBJECT(window), "shortcuts-inhibit-window-data"));
  if (wid != nullptr) {
    wid->enabled = false;
    release_inhibitor_nonblocking(wid);
    g_object_set_data(G_OBJECT(window), "shortcuts-inhibit-window-data", nullptr);
  }
}

#else  // !(defined(GDK_WINDOWING_WAYLAND) && defined(HAS_KEYBOARD_SHORTCUTS_INHIBIT))

bool wayland_shortcuts_inhibit_is_supported(GdkDisplay* /*display*/) {
  return false;
}

void wayland_shortcuts_inhibit_init_for_subwindow(void* /*view*/) {
}

bool wayland_shortcuts_inhibit_set_enabled(GtkWindow* /*window*/, bool /*enabled*/) {
  return false;
}

const char* wayland_shortcuts_inhibit_get_state(GtkWindow* /*window*/) {
  return "unsupported";
}

void wayland_shortcuts_inhibit_teardown(GtkWindow* /*window*/) {
}

#endif
