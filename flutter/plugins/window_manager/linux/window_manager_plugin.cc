#include "include/window_manager/window_manager_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#define WINDOW_MANAGER_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), window_manager_plugin_get_type(), \
                              WindowManagerPlugin))

WindowManagerPlugin* plugin_instance;
bool main_window_initialized = false;

struct _WindowManagerPlugin {
  GObject parent_instance;
  FlPluginRegistrar* registrar;
  FlMethodChannel* channel;
  GdkGeometry window_geometry;
  GdkWindowHints window_hints;
  GtkWidget* _event_box;
  bool _is_prevent_close;
  bool _is_frameless;
  bool _is_always_on_top;
  bool _is_always_on_bottom;
  gulong button_press_hook_id;
  bool _is_dragging;
  bool _is_resizing;
  gchar* title_bar_style_;
  GdkEventButton _event_button;
  GdkDevice* grab_pointer;
  GtkCssProvider* css_provider;
};

G_DEFINE_TYPE(WindowManagerPlugin, window_manager_plugin, g_object_get_type())

// Gets the window being controlled, or nullptr if the view is gone or is not
// parented to a toplevel window.
GtkWindow* get_window(WindowManagerPlugin* self) {
  if (self == nullptr || self->registrar == nullptr)
    return nullptr;

  FlView* view = fl_plugin_registrar_get_view(self->registrar);
  if (view == nullptr)
    return nullptr;

  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  if (toplevel == nullptr || !GTK_IS_WINDOW(toplevel))
    return nullptr;

  return GTK_WINDOW(toplevel);
}

// Gets the GdkWindow backing the toplevel. Also nullptr while the toplevel is
// merely unrealized, so a non-null get_window() is not enough to assume this.
GdkWindow* get_gdk_window(WindowManagerPlugin* self) {
  GtkWindow* window = get_window(self);
  if (window == nullptr)
    return nullptr;

  return gtk_widget_get_window(GTK_WIDGET(window));
}

// Argument extraction helpers with strict type verification.
static bool get_bool_arg(FlValue* map, const char* key, bool* out) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return false;
  FlValue* val = fl_value_lookup_string(map, key);
  if (val == nullptr || fl_value_get_type(val) != FL_VALUE_TYPE_BOOL) return false;
  if (out != nullptr) *out = fl_value_get_bool(val);
  return true;
}

static bool get_float_arg(FlValue* map, const char* key, double* out) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return false;
  FlValue* val = fl_value_lookup_string(map, key);
  if (val == nullptr) return false;
  if (fl_value_get_type(val) == FL_VALUE_TYPE_FLOAT) {
    if (out != nullptr) *out = fl_value_get_float(val);
    return true;
  }
  if (fl_value_get_type(val) == FL_VALUE_TYPE_INT) {
    if (out != nullptr) *out = static_cast<double>(fl_value_get_int(val));
    return true;
  }
  return false;
}

static bool get_int_arg(FlValue* map, const char* key, int64_t* out) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return false;
  FlValue* val = fl_value_lookup_string(map, key);
  if (val == nullptr || fl_value_get_type(val) != FL_VALUE_TYPE_INT) return false;
  if (out != nullptr) *out = fl_value_get_int(val);
  return true;
}

static const char* get_string_arg(FlValue* map, const char* key) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return nullptr;
  FlValue* val = fl_value_lookup_string(map, key);
  if (val == nullptr || fl_value_get_type(val) != FL_VALUE_TYPE_STRING) return nullptr;
  return fl_value_get_string(val);
}

static FlMethodResponse* set_as_frameless(WindowManagerPlugin* self,
                                          FlValue* args) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  gtk_window_set_decorated(window, false);
  self->_is_frameless = true;

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* destroy(WindowManagerPlugin* self) {
  self->_is_prevent_close = false;
  auto w = get_window(self);
  if (w != nullptr) {
    gtk_window_close(w);
  }
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* close(WindowManagerPlugin* self) {
  auto w = get_window(self);
  if (w != nullptr) {
    gtk_window_close(w);
  }
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_prevent_close(WindowManagerPlugin* self) {
  g_autoptr(FlValue) result = fl_value_new_bool(self->_is_prevent_close);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_prevent_close(WindowManagerPlugin* self,
                                           FlValue* args) {
  bool is_prevent_close = false;
  if (!get_bool_arg(args, "isPreventClose", &is_prevent_close)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected boolean isPreventClose", nullptr));
  }
  self->_is_prevent_close = is_prevent_close;
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* focus(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  gtk_window_present(window);
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* blur(WindowManagerPlugin* self) {
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_focused(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  bool is_focused = gtk_window_is_active(window);
  g_autoptr(FlValue) result = fl_value_new_bool(is_focused);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* show(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  gtk_widget_show(GTK_WIDGET(window));
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* hide(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  gint x = 0, y = 0, width = 0, height = 0;
  // store the bound of window before hide
  gtk_window_get_position(window, &x, &y);
  gtk_window_get_size(window, &width, &height);
  gtk_widget_hide(GTK_WIDGET(window));
  // restore the bound of window after hide
  gtk_window_move(window, x, y);
  gtk_window_resize(window, width, height);
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_visible(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  bool is_visible = gtk_widget_is_visible(GTK_WIDGET(window));
  g_autoptr(FlValue) result = fl_value_new_bool(is_visible);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_maximized(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  bool is_maximized = gtk_window_is_maximized(window);
  g_autoptr(FlValue) result = fl_value_new_bool(is_maximized);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* maximize(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  gtk_window_maximize(window);
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* unmaximize(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  gtk_window_unmaximize(window);
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_minimized(WindowManagerPlugin* self) {
  auto gdk_win = get_gdk_window(self);
  if (gdk_win == nullptr) {
    g_autoptr(FlValue) result = fl_value_new_bool(false);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }
  GdkWindowState state = gdk_window_get_state(gdk_win);
  g_autoptr(FlValue) result =
      fl_value_new_bool(state & GDK_WINDOW_STATE_ICONIFIED);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* minimize(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  gtk_window_iconify(window);
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_dockable(WindowManagerPlugin* self) {
  bool is_docked = false;
  g_autoptr(FlValue) result = fl_value_new_bool(is_docked);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_docked(WindowManagerPlugin* self) {
  g_autoptr(FlValue) result = fl_value_new_null();
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* dock(WindowManagerPlugin* self) {
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* undock(WindowManagerPlugin* self) {
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* restore(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  gtk_window_deiconify(window);
  gtk_window_present(window);
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_full_screen(WindowManagerPlugin* self) {
  auto gdk_win = get_gdk_window(self);
  if (gdk_win == nullptr) {
    g_autoptr(FlValue) result = fl_value_new_bool(false);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }
  GdkWindowState state = gdk_window_get_state(gdk_win);
  g_autoptr(FlValue) result =
      fl_value_new_bool(state & GDK_WINDOW_STATE_FULLSCREEN);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_full_screen(WindowManagerPlugin* self,
                                         FlValue* args) {
  bool is_full_screen = false;
  if (!get_bool_arg(args, "isFullScreen", &is_full_screen)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected boolean isFullScreen", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  if (is_full_screen)
    gtk_window_fullscreen(window);
  else
    gtk_window_unfullscreen(window);

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_aspect_ratio(WindowManagerPlugin* self,
                                          FlValue* args) {
  double aspect_ratio = 0.0;
  if (!get_float_arg(args, "aspectRatio", &aspect_ratio)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected float aspectRatio", nullptr));
  }

  auto gdk_win = get_gdk_window(self);
  if (gdk_win == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "GdkWindow is unavailable", nullptr));
  }

  self->window_geometry.min_aspect = aspect_ratio;
  self->window_geometry.max_aspect = aspect_ratio;

  if (aspect_ratio >= 0) {
    self->window_hints =
        static_cast<GdkWindowHints>(self->window_hints | GDK_HINT_ASPECT);
  } else {
    self->window_hints =
        static_cast<GdkWindowHints>(self->window_hints & ~GDK_HINT_ASPECT);
  }

  gdk_window_set_geometry_hints(gdk_win, &self->window_geometry,
                                self->window_hints);
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_background_color(WindowManagerPlugin* self,
                                              FlValue* args) {
  int64_t r = 0, g = 0, b = 0, a = 255;
  if (!get_int_arg(args, "backgroundColorR", &r) ||
      !get_int_arg(args, "backgroundColorG", &g) ||
      !get_int_arg(args, "backgroundColorB", &b) ||
      !get_int_arg(args, "backgroundColorA", &a)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected RGBA integer components", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  GdkRGBA rgba;
  rgba.red = CLAMP(r, 0, 255) / 255.0;
  rgba.green = CLAMP(g, 0, 255) / 255.0;
  rgba.blue = CLAMP(b, 0, 255) / 255.0;
  rgba.alpha = CLAMP(a, 0, 255) / 255.0;

  g_autofree gchar* color = gdk_rgba_to_string(&rgba);
  g_autofree gchar* css =
      g_strdup_printf("window { background-color: %s; }", color);

  if (self->css_provider == nullptr) {
    self->css_provider = gtk_css_provider_new();
    gtk_style_context_add_provider(
        gtk_widget_get_style_context(GTK_WIDGET(window)),
        GTK_STYLE_PROVIDER(self->css_provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  }

  g_autoptr(GError) error = nullptr;
  gtk_css_provider_load_from_data(self->css_provider, css, -1, &error);

  if (error != nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "setBackgroundColor", error->message, nullptr));
  }

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* get_bounds(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  gint x = 0, y = 0, width = 0, height = 0;
  gtk_window_get_position(window, &x, &y);
  gtk_window_get_size(window, &width, &height);

  g_autoptr(FlValue) result_data = fl_value_new_map();
  fl_value_set_string_take(result_data, "x", fl_value_new_float(x));
  fl_value_set_string_take(result_data, "y", fl_value_new_float(y));
  fl_value_set_string_take(result_data, "width", fl_value_new_float(width));
  fl_value_set_string_take(result_data, "height", fl_value_new_float(height));

  return FL_METHOD_RESPONSE(fl_method_success_response_new(result_data));
}

static FlMethodResponse* set_bounds(WindowManagerPlugin* self, FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected map arguments for setBounds", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  double x = 0.0, y = 0.0, width = 0.0, height = 0.0;
  if (get_float_arg(args, "x", &x) && get_float_arg(args, "y", &y)) {
    gtk_window_move(window, static_cast<gint>(x), static_cast<gint>(y));
  }

  if (get_float_arg(args, "width", &width) && get_float_arg(args, "height", &height)) {
    gtk_window_resize(window, static_cast<gint>(width), static_cast<gint>(height));
  }

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_minimum_size(WindowManagerPlugin* self,
                                          FlValue* args) {
  double width = 0.0, height = 0.0;
  if (!get_float_arg(args, "width", &width) || !get_float_arg(args, "height", &height)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected width and height numbers", nullptr));
  }

  auto gdk_win = get_gdk_window(self);
  if (gdk_win == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "GdkWindow is unavailable", nullptr));
  }

  if (width >= 0 && height >= 0) {
    self->window_geometry.min_width = static_cast<gint>(width);
    self->window_geometry.min_height = static_cast<gint>(height);
    self->window_hints =
        static_cast<GdkWindowHints>(self->window_hints | GDK_HINT_MIN_SIZE);
  } else {
    self->window_hints =
        static_cast<GdkWindowHints>(self->window_hints & ~GDK_HINT_MIN_SIZE);
  }

  gdk_window_set_geometry_hints(gdk_win, &self->window_geometry,
                                self->window_hints);

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_maximum_size(WindowManagerPlugin* self,
                                          FlValue* args) {
  double width = 0.0, height = 0.0;
  if (!get_float_arg(args, "width", &width) || !get_float_arg(args, "height", &height)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected width and height numbers", nullptr));
  }

  auto gdk_win = get_gdk_window(self);
  if (gdk_win == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "GdkWindow is unavailable", nullptr));
  }

  self->window_geometry.max_width = static_cast<gint>(width);
  self->window_geometry.max_height = static_cast<gint>(height);

  if (width >= 0 && height >= 0) {
    self->window_hints =
        static_cast<GdkWindowHints>(self->window_hints | GDK_HINT_MAX_SIZE);
  } else {
    self->window_hints =
        static_cast<GdkWindowHints>(self->window_hints & ~GDK_HINT_MAX_SIZE);
  }

  if (self->window_geometry.max_width < 0)
    self->window_geometry.max_width = G_MAXINT;
  if (self->window_geometry.max_height < 0)
    self->window_geometry.max_height = G_MAXINT;

  gdk_window_set_geometry_hints(gdk_win, &self->window_geometry,
                                self->window_hints);

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_resizable(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  bool is_resizable = gtk_window_get_resizable(window);
  g_autoptr(FlValue) result = fl_value_new_bool(is_resizable);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_resizable(WindowManagerPlugin* self,
                                       FlValue* args) {
  bool is_resizable = false;
  if (!get_bool_arg(args, "isResizable", &is_resizable)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected boolean isResizable", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  gtk_window_set_resizable(window, is_resizable);
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_minimizable(WindowManagerPlugin* self) {
  auto window = get_window(self);
  auto gdk_win = get_gdk_window(self);
  if (window == nullptr || gdk_win == nullptr) {
    g_autoptr(FlValue) result = fl_value_new_bool(false);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }

  GdkWindowState state = gdk_window_get_state(gdk_win);
  GdkWindowTypeHint type_hint = gtk_window_get_type_hint(window);
  g_autoptr(FlValue) result =
      fl_value_new_bool(!(state & GDK_WINDOW_STATE_ICONIFIED) &&
                        type_hint == GDK_WINDOW_TYPE_HINT_NORMAL);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_minimizable(WindowManagerPlugin* self,
                                         FlValue* args) {
  bool minimizable = false;
  if (!get_bool_arg(args, "isMinimizable", &minimizable)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected boolean isMinimizable", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  GdkWindowTypeHint type_hint =
      minimizable ? GDK_WINDOW_TYPE_HINT_NORMAL : GDK_WINDOW_TYPE_HINT_DIALOG;
  gtk_window_set_type_hint(window, type_hint);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* is_maximizable(WindowManagerPlugin* self) {
  auto window = get_window(self);
  auto gdk_win = get_gdk_window(self);
  if (window == nullptr || gdk_win == nullptr) {
    g_autoptr(FlValue) result = fl_value_new_bool(false);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }

  gboolean resizable = gtk_window_get_resizable(window);
  GdkWindowState state = gdk_window_get_state(gdk_win);
  GdkWindowTypeHint type_hint = gtk_window_get_type_hint(window);
  g_autoptr(FlValue) result =
      fl_value_new_bool(resizable && !(state & GDK_WINDOW_STATE_MAXIMIZED) &&
                        type_hint == GDK_WINDOW_TYPE_HINT_NORMAL);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_maximizable(WindowManagerPlugin* self,
                                         FlValue* args) {
  bool maximizable = false;
  if (!get_bool_arg(args, "isMaximizable", &maximizable)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected boolean isMaximizable", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  GdkWindowTypeHint type_hint =
      maximizable ? GDK_WINDOW_TYPE_HINT_NORMAL : GDK_WINDOW_TYPE_HINT_DIALOG;
  gtk_window_set_type_hint(window, type_hint);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* is_closable(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  bool is_closable = gtk_window_get_deletable(window);
  g_autoptr(FlValue) result = fl_value_new_bool(is_closable);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_closable(WindowManagerPlugin* self,
                                      FlValue* args) {
  bool is_closable = false;
  if (!get_bool_arg(args, "isClosable", &is_closable)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected boolean isClosable", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  gtk_window_set_deletable(window, is_closable);
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_always_on_top(WindowManagerPlugin* self) {
  g_autoptr(FlValue) result = fl_value_new_bool(self->_is_always_on_top);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_always_on_top(WindowManagerPlugin* self,
                                           FlValue* args) {
  bool isAlwaysOnTop = false;
  if (!get_bool_arg(args, "isAlwaysOnTop", &isAlwaysOnTop)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected boolean isAlwaysOnTop", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  gtk_window_set_keep_above(window, isAlwaysOnTop);
  self->_is_always_on_top = isAlwaysOnTop;

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_always_on_bottom(WindowManagerPlugin* self) {
  g_autoptr(FlValue) result = fl_value_new_bool(self->_is_always_on_bottom);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_always_on_bottom(WindowManagerPlugin* self,
                                              FlValue* args) {
  bool isAlwaysOnBottom = false;
  if (!get_bool_arg(args, "isAlwaysOnBottom", &isAlwaysOnBottom)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected boolean isAlwaysOnBottom", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  gtk_window_set_keep_below(window, isAlwaysOnBottom);
  self->_is_always_on_bottom = isAlwaysOnBottom;

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* get_title(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  const gchar* title = gtk_window_get_title(window);
  g_autoptr(FlValue) result =
      fl_value_new_string(title != nullptr ? title : "");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_title(WindowManagerPlugin* self, FlValue* args) {
  const gchar* title = get_string_arg(args, "title");
  if (title == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected string title", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  gtk_window_set_title(window, title);

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

// Returns true if the widget is GtkHeaderBar or HdyHeaderBar from libhandy.
static gboolean is_header_bar(GtkWidget* widget) {
  return widget != nullptr &&
         (GTK_IS_HEADER_BAR(widget) ||
          g_str_has_suffix(G_OBJECT_TYPE_NAME(widget), "HeaderBar"));
}

// Recursively searches for a Gtk/HdyHeaderBar in the widget tree.
static GtkWidget* find_header_bar(GtkWidget* widget) {
  if (is_header_bar(widget)) {
    return widget;
  }

  if (GTK_IS_CONTAINER(widget)) {
    g_autoptr(GList) children =
        gtk_container_get_children(GTK_CONTAINER(widget));
    for (GList* l = children; l != nullptr; l = l->next) {
      GtkWidget* header_bar = find_header_bar(GTK_WIDGET(l->data));
      if (header_bar != nullptr) {
        return header_bar;
      }
    }
  }

  return nullptr;
}

// Returns the window's header bar which is typically a GtkHeaderBar used as
// GtkWindow::titlebar, or a HdyHeaderBar as HdyWindow granchild.
static GtkWidget* get_header_bar(GtkWindow* window) {
  if (window == nullptr) return nullptr;
  GtkWidget* titlebar = gtk_window_get_titlebar(window);
  if (is_header_bar(titlebar)) {
    return titlebar;
  }
  return find_header_bar(GTK_WIDGET(window));
}

static FlMethodResponse* set_title_bar_style(WindowManagerPlugin* self,
                                             FlValue* args) {
  const gchar* title_bar_style = get_string_arg(args, "titleBarStyle");
  if (title_bar_style == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected string titleBarStyle", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  gboolean normal = g_strcmp0(title_bar_style, "hidden") != 0;

  GtkWidget* header_bar = get_header_bar(window);
  if (header_bar != nullptr) {
    gtk_widget_set_visible(header_bar, normal);
  } else {
    const gchar* title = gtk_window_get_title(window);
    if (title != nullptr) {
      gtk_window_set_decorated(window, normal);
    }
  }

  if (normal) {
    // Undo set_as_frameless, so that when the title bar is shown
    // again the window frame is also restored.
    gtk_window_set_decorated(window, true);
  }

  g_free(self->title_bar_style_);
  self->title_bar_style_ = g_strdup(title_bar_style);

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* get_title_bar_height(WindowManagerPlugin* self,
                                              FlValue* args) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  GtkWidget* widget = gtk_window_get_titlebar(window);

  int title_bar_height = 0;

  if (widget != nullptr && g_strcmp0(self->title_bar_style_, "hidden") != 0) {
    title_bar_height = gtk_widget_get_allocated_height(widget);
  }

  g_autoptr(FlValue) result = fl_value_new_int(title_bar_height);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* is_skip_taskbar(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  const gboolean skipping = gtk_window_get_skip_taskbar_hint(window);
  g_autoptr(FlValue) result = fl_value_new_bool(skipping);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_skip_taskbar(WindowManagerPlugin* self,
                                          FlValue* args) {
  bool isSkipTaskbar = false;
  if (!get_bool_arg(args, "isSkipTaskbar", &isSkipTaskbar)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected boolean isSkipTaskbar", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  gtk_window_set_skip_taskbar_hint(window, isSkipTaskbar);
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_icon(WindowManagerPlugin* self, FlValue* args) {
  const gchar* file_name = get_string_arg(args, "iconPath");
  if (file_name == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected string iconPath", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  const gboolean gtk_result =
      gtk_window_set_icon_from_file(window, file_name, NULL);
  g_autoptr(FlValue) result = fl_value_new_bool(gtk_result);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* get_opacity(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  gdouble opacity = gtk_widget_get_opacity(GTK_WIDGET(window));
  g_autoptr(FlValue) result = fl_value_new_float(opacity);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_opacity(WindowManagerPlugin* self, FlValue* args) {
  double opacity = 1.0;
  if (!get_float_arg(args, "opacity", &opacity)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected float opacity", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }

  gtk_widget_set_opacity(GTK_WIDGET(window), CLAMP(opacity, 0.0, 1.0));
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* pop_up_window_menu(WindowManagerPlugin* self) {
  GdkWindow* window = get_gdk_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "GdkWindow unavailable", nullptr));
  }
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Default display unavailable", nullptr));
  }
  GdkSeat* seat = gdk_display_get_default_seat(display);
  if (seat == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Default seat unavailable", nullptr));
  }
  GdkDevice* pointer = gdk_seat_get_pointer(seat);
  if (pointer == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Pointer device unavailable", nullptr));
  }

  int x = 0, y = 0;
  gdk_device_get_position(pointer, NULL, &x, &y);

  int origin_x = 0, origin_y = 0;
  gdk_window_get_origin(window, &origin_x, &origin_y);

  GdkEvent* event = gdk_event_new(GDK_BUTTON_PRESS);
  event->button.window = window;
  event->button.device = pointer;
  event->button.x_root = x;
  event->button.y_root = y;
  event->button.x = x - origin_x;
  event->button.y = y - origin_y;
  gdk_window_show_window_menu(window, event);

  g_autoptr(FlValue) result = fl_value_new_float(1);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* start_dragging(WindowManagerPlugin* self) {
  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  auto screen = gtk_window_get_screen(window);
  if (screen == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Screen is unavailable", nullptr));
  }
  auto display = gdk_screen_get_display(screen);
  if (display == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Display is unavailable", nullptr));
  }
  auto seat = gdk_display_get_default_seat(display);
  if (seat == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Seat is unavailable", nullptr));
  }
  auto device = gdk_seat_get_pointer(seat);
  if (device == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Pointer device is unavailable", nullptr));
  }

  gint root_x = 0, root_y = 0;
  gdk_device_get_position(device, nullptr, &root_x, &root_y);
  guint32 timestamp = (guint32)g_get_monotonic_time();

  gtk_window_begin_move_drag(window, 1, root_x, root_y, timestamp);
  self->_is_dragging = true;

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void gtk_container_children_callback(GtkWidget* widget,
                                            gpointer client_data) {
  GList** children;
  children = (GList**)client_data;
  *children = g_list_prepend(*children, widget);
}

static void find_event_box(WindowManagerPlugin* plugin, GtkWidget* widget) {
  if (widget == nullptr || !GTK_IS_CONTAINER(widget)) return;
  GList* children = NULL;
  gtk_container_forall(GTK_CONTAINER(widget), gtk_container_children_callback,
                       &children);
  for (GList* iter = children; iter != NULL; iter = g_list_next(iter)) {
    GtkWidget* current_child = (GtkWidget*)iter->data;
    if (GTK_IS_EVENT_BOX(current_child)) {
      plugin->_event_box = current_child;
      break;
    }
  }
  if (children != NULL) {
    g_list_free(children);
  }
}

static FlMethodResponse* start_resizing(WindowManagerPlugin* self,
                                        FlValue* args) {
  const gchar* resize_edge = get_string_arg(args, "resizeEdge");
  if (resize_edge == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected string resizeEdge", nullptr));
  }

  auto window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Window is unavailable", nullptr));
  }
  auto screen = gtk_window_get_screen(window);
  if (screen == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Screen is unavailable", nullptr));
  }
  auto display = gdk_screen_get_display(screen);
  if (display == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Display is unavailable", nullptr));
  }
  auto seat = gdk_display_get_default_seat(display);
  if (seat == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Seat is unavailable", nullptr));
  }
  auto device = gdk_seat_get_pointer(seat);
  if (device == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "Pointer device is unavailable", nullptr));
  }

  gint root_x = 0, root_y = 0;
  gdk_device_get_position(device, nullptr, &root_x, &root_y);
  guint32 timestamp = (guint32)g_get_monotonic_time();

  GdkWindowEdge gdk_window_edge = GDK_WINDOW_EDGE_NORTH_WEST;

  if (g_strcmp0(resize_edge, "topLeft") == 0) {
    gdk_window_edge = GDK_WINDOW_EDGE_NORTH_WEST;
  } else if (g_strcmp0(resize_edge, "top") == 0) {
    gdk_window_edge = GDK_WINDOW_EDGE_NORTH;
  } else if (g_strcmp0(resize_edge, "topRight") == 0) {
    gdk_window_edge = GDK_WINDOW_EDGE_NORTH_EAST;
  } else if (g_strcmp0(resize_edge, "left") == 0) {
    gdk_window_edge = GDK_WINDOW_EDGE_WEST;
  } else if (g_strcmp0(resize_edge, "right") == 0) {
    gdk_window_edge = GDK_WINDOW_EDGE_EAST;
  } else if (g_strcmp0(resize_edge, "bottomLeft") == 0) {
    gdk_window_edge = GDK_WINDOW_EDGE_SOUTH_WEST;
  } else if (g_strcmp0(resize_edge, "bottom") == 0) {
    gdk_window_edge = GDK_WINDOW_EDGE_SOUTH;
  } else if (g_strcmp0(resize_edge, "bottomRight") == 0) {
    gdk_window_edge = GDK_WINDOW_EDGE_SOUTH_EAST;
  }

  gtk_window_begin_resize_drag(window, gdk_window_edge,
                               self->_event_button.button, root_x, root_y,
                               timestamp);
  self->_is_resizing = true;

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static const gchar* gdk_grab_status_code(GdkGrabStatus status) {
  switch (status) {
    case GDK_GRAB_SUCCESS:
      return "GDK_GRAB_SUCCESS";
    case GDK_GRAB_ALREADY_GRABBED:
      return "GDK_GRAB_ALREADY_GRABBED";
    case GDK_GRAB_INVALID_TIME:
      return "GDK_GRAB_INVALID_TIME";
    case GDK_GRAB_NOT_VIEWABLE:
      return "GDK_GRAB_NOT_VIEWABLE";
    case GDK_GRAB_FROZEN:
      return "GDK_GRAB_FROZEN";
    case GDK_GRAB_FAILED:
      return "GDK_GRAB_FAILED";
    default:
      return "GDK_GRAB_???";
  }
}

static const gchar* gdk_grab_status_message(GdkGrabStatus status) {
  switch (status) {
    case GDK_GRAB_SUCCESS:
      return "The resource was successfully grabbed.";
    case GDK_GRAB_ALREADY_GRABBED:
      return "The resource is actively grabbed by another client.";
    case GDK_GRAB_INVALID_TIME:
      return "The resource was grabbed more recently than the specified time.";
    case GDK_GRAB_NOT_VIEWABLE:
      return "The grab window or the confine_to window are not viewable.";
    case GDK_GRAB_FROZEN:
      return "The resource is frozen by an active grab of another client.";
    case GDK_GRAB_FAILED:
      return "The grab failed for some other reason.";
    default:
      return "The grab status is unknown.";
  }
}

static GdkGrabStatus gdk_grab_keyboard(WindowManagerPlugin* self) {
  g_return_val_if_fail(self->grab_pointer == nullptr, GDK_GRAB_FAILED);

  auto window = get_window(self);
  if (window == nullptr) return GDK_GRAB_FAILED;
  auto screen = gtk_window_get_screen(window);
  if (screen == nullptr) return GDK_GRAB_FAILED;
  auto display = gdk_screen_get_display(screen);
  if (display == nullptr) return GDK_GRAB_FAILED;
  auto seat = gdk_display_get_default_seat(display);
  if (seat == nullptr) return GDK_GRAB_FAILED;
  auto gdk_window = get_gdk_window(self);
  if (gdk_window == nullptr) return GDK_GRAB_FAILED;

  GdkGrabStatus status = gdk_seat_grab(
      seat, gdk_window, GDK_SEAT_CAPABILITY_KEYBOARD, false /* owner_events */,
      nullptr /* cursor */, nullptr /* event */, nullptr /*prepare_func */,
      nullptr /* prepare_func_data */);

  self->grab_pointer = gdk_seat_get_keyboard(seat);
  if (!self->grab_pointer) {
    self->grab_pointer = gdk_seat_get_pointer(seat);
  }

  return status;
}

static FlMethodResponse* grab_keyboard(WindowManagerPlugin* self) {
  GdkGrabStatus status = gdk_grab_keyboard(self);

  if (status != GDK_GRAB_SUCCESS) {
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new(gdk_grab_status_code(status),
                                     gdk_grab_status_message(status), nullptr));
  }

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* ungrab_keyboard(WindowManagerPlugin* self) {
  if (self->grab_pointer != nullptr) {
    GdkSeat* seat = gdk_device_get_seat(self->grab_pointer);
    if (seat != nullptr) {
      gdk_seat_ungrab(seat);
    }
    self->grab_pointer = nullptr;
  }

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* set_brightness(WindowManagerPlugin* self,
                                        FlValue* args) {
  const gchar* brightness = get_string_arg(args, "brightness");
  if (brightness == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "Expected string brightness", nullptr));
  }

  gboolean dark = g_strcmp0(brightness, "dark") == 0;

  GtkSettings* settings = gtk_settings_get_default();
  if (settings != nullptr) {
    g_object_set(settings, "gtk-application-prefer-dark-theme", dark, nullptr);

    if (!dark) {
      g_autofree gchar* theme_name = nullptr;
      g_object_get(settings, "gtk-theme-name", &theme_name, nullptr);
      if (theme_name != nullptr && g_str_has_suffix(theme_name, "-dark")) {
        g_autofree gchar* light_theme_name =
            g_strndup(theme_name, strlen(theme_name) - 5);
        g_object_set(settings, "gtk-theme-name", light_theme_name, nullptr);
      }
    }
  }

  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

// Methods that stay allowed once the toplevel window is gone.
static bool method_survives_window_destruction(const gchar* method) {
  static const gchar* const kWindowlessMethods[] = {
      "ensureInitialized", "close",
      "destroy",           "isPreventClose",
      "setPreventClose",   "ungrabKeyboard",
      "setBrightness",
  };
  for (size_t i = 0; i < G_N_ELEMENTS(kWindowlessMethods); i++) {
    if (g_strcmp0(method, kWindowlessMethods[i]) == 0)
      return true;
  }
  return false;
}

// Called when a method call is received from Flutter.
static void window_manager_plugin_handle_method_call(
    WindowManagerPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);
  if (method == nullptr) {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_method", "Method name is null", nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  FlValue* args = fl_method_call_get_args(method_call);

  if (!method_survives_window_destruction(method) &&
      get_window(self) == nullptr) {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new(
        "window_destroyed", "The window has been destroyed", nullptr));
  } else if (g_strcmp0(method, "ensureInitialized") == 0) {
    g_autoptr(FlValue) result = fl_value_new_bool(true);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "waitUntilReadyToShow") == 0) {
    g_autoptr(FlValue) result = fl_value_new_bool(true);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "setAsFrameless") == 0) {
    response = set_as_frameless(self, args);
  } else if (g_strcmp0(method, "destroy") == 0) {
    response = destroy(self);
  } else if (g_strcmp0(method, "close") == 0) {
    response = close(self);
  } else if (g_strcmp0(method, "setPreventClose") == 0) {
    response = set_prevent_close(self, args);
  } else if (g_strcmp0(method, "isPreventClose") == 0) {
    response = is_prevent_close(self);
  } else if (g_strcmp0(method, "focus") == 0) {
    response = focus(self);
  } else if (g_strcmp0(method, "blur") == 0) {
    response = blur(self);
  } else if (g_strcmp0(method, "isFocused") == 0) {
    response = is_focused(self);
  } else if (g_strcmp0(method, "show") == 0) {
    response = show(self);
  } else if (g_strcmp0(method, "hide") == 0) {
    response = hide(self);
  } else if (g_strcmp0(method, "isVisible") == 0) {
    response = is_visible(self);
  } else if (g_strcmp0(method, "isMaximized") == 0) {
    response = is_maximized(self);
  } else if (g_strcmp0(method, "maximize") == 0) {
    response = maximize(self);
  } else if (g_strcmp0(method, "unmaximize") == 0) {
    response = unmaximize(self);
  } else if (g_strcmp0(method, "isMinimized") == 0) {
    response = is_minimized(self);
  } else if (g_strcmp0(method, "minimize") == 0) {
    response = minimize(self);
  } else if (g_strcmp0(method, "restore") == 0) {
    response = restore(self);
  } else if (g_strcmp0(method, "isDockable") == 0) {
    response = is_dockable(self);
  } else if (g_strcmp0(method, "isDocked") == 0) {
    response = is_docked(self);
  } else if (g_strcmp0(method, "dock") == 0) {
    response = dock(self);
  } else if (g_strcmp0(method, "undock") == 0) {
    response = undock(self);
  } else if (g_strcmp0(method, "isFullScreen") == 0) {
    response = is_full_screen(self);
  } else if (g_strcmp0(method, "setFullScreen") == 0) {
    response = set_full_screen(self, args);
  } else if (g_strcmp0(method, "setAspectRatio") == 0) {
    response = set_aspect_ratio(self, args);
  } else if (g_strcmp0(method, "setBackgroundColor") == 0) {
    response = set_background_color(self, args);
  } else if (g_strcmp0(method, "getBounds") == 0) {
    response = get_bounds(self);
  } else if (g_strcmp0(method, "setBounds") == 0) {
    response = set_bounds(self, args);
  } else if (g_strcmp0(method, "setMinimumSize") == 0) {
    response = set_minimum_size(self, args);
  } else if (g_strcmp0(method, "setMaximumSize") == 0) {
    response = set_maximum_size(self, args);
  } else if (g_strcmp0(method, "isResizable") == 0) {
    response = is_resizable(self);
  } else if (g_strcmp0(method, "setResizable") == 0) {
    response = set_resizable(self, args);
  } else if (g_strcmp0(method, "isMinimizable") == 0) {
    response = is_minimizable(self);
  } else if (g_strcmp0(method, "setMinimizable") == 0) {
    response = set_minimizable(self, args);
  } else if (g_strcmp0(method, "isMaximizable") == 0) {
    response = is_maximizable(self);
  } else if (g_strcmp0(method, "setMaximizable") == 0) {
    response = set_maximizable(self, args);
  } else if (g_strcmp0(method, "isClosable") == 0) {
    response = is_closable(self);
  } else if (g_strcmp0(method, "setClosable") == 0) {
    response = set_closable(self, args);
  } else if (g_strcmp0(method, "isAlwaysOnTop") == 0) {
    response = is_always_on_top(self);
  } else if (g_strcmp0(method, "setAlwaysOnTop") == 0) {
    response = set_always_on_top(self, args);
  } else if (g_strcmp0(method, "isAlwaysOnBottom") == 0) {
    response = is_always_on_bottom(self);
  } else if (g_strcmp0(method, "setAlwaysOnBottom") == 0) {
    response = set_always_on_bottom(self, args);
  } else if (g_strcmp0(method, "getTitle") == 0) {
    response = get_title(self);
  } else if (g_strcmp0(method, "setTitle") == 0) {
    response = set_title(self, args);
  } else if (g_strcmp0(method, "setTitleBarStyle") == 0) {
    response = set_title_bar_style(self, args);
  } else if (g_strcmp0(method, "getTitleBarHeight") == 0) {
    response = get_title_bar_height(self, args);
  } else if (g_strcmp0(method, "isSkipTaskbar") == 0) {
    response = is_skip_taskbar(self);
  } else if (g_strcmp0(method, "setSkipTaskbar") == 0) {
    response = set_skip_taskbar(self, args);
  } else if (g_strcmp0(method, "setIcon") == 0) {
    response = set_icon(self, args);
  } else if (g_strcmp0(method, "getOpacity") == 0) {
    response = get_opacity(self);
  } else if (g_strcmp0(method, "setOpacity") == 0) {
    response = set_opacity(self, args);
  } else if (g_strcmp0(method, "popUpWindowMenu") == 0) {
    response = pop_up_window_menu(self);
  } else if (g_strcmp0(method, "startDragging") == 0) {
    response = start_dragging(self);
  } else if (g_strcmp0(method, "startResizing") == 0) {
    response = start_resizing(self, args);
  } else if (g_strcmp0(method, "grabKeyboard") == 0) {
    response = grab_keyboard(self);
  } else if (g_strcmp0(method, "ungrabKeyboard") == 0) {
    response = ungrab_keyboard(self);
  } else if (g_strcmp0(method, "setBrightness") == 0) {
    response = set_brightness(self, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  if (response == nullptr) {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new(
        "internal_error", "No response generated", nullptr));
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void window_manager_plugin_dispose(GObject* object) {
  WindowManagerPlugin* self = WINDOW_MANAGER_PLUGIN(object);
  if (self->button_press_hook_id > 0) {
    guint signal_id = g_signal_lookup("button-press-event", GTK_TYPE_WIDGET);
    if (signal_id > 0) {
      g_signal_remove_emission_hook(signal_id, self->button_press_hook_id);
    }
    self->button_press_hook_id = 0;
  }
  g_clear_object(&self->channel);
  g_clear_object(&self->registrar);
  g_clear_object(&self->css_provider);
  g_free(self->title_bar_style_);
  self->title_bar_style_ = nullptr;
  G_OBJECT_CLASS(window_manager_plugin_parent_class)->dispose(object);
}

static void window_manager_plugin_class_init(WindowManagerPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = window_manager_plugin_dispose;
}

static void window_manager_plugin_init(WindowManagerPlugin* self) {
  self->button_press_hook_id = 0;
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  WindowManagerPlugin* plugin = WINDOW_MANAGER_PLUGIN(user_data);
  window_manager_plugin_handle_method_call(plugin, method_call);
}

void _emit_event(WindowManagerPlugin* plugin, const char* event_name) {
  if (plugin == nullptr || plugin->channel == nullptr) return;
  g_autoptr(FlValue) result_data = fl_value_new_map();
  fl_value_set_string_take(result_data, "eventName",
                           fl_value_new_string(event_name));
  fl_method_channel_invoke_method(plugin->channel, "onEvent", result_data,
                                  nullptr, nullptr, nullptr);
}

gboolean on_window_close(GtkWidget* widget, GdkEvent* event, gpointer data) {
  WindowManagerPlugin* plugin = WINDOW_MANAGER_PLUGIN(data);
  _emit_event(plugin, "close");
  return plugin->_is_prevent_close;
}

gboolean on_window_focus(GtkWidget* widget, GdkEvent* event, gpointer data) {
  WindowManagerPlugin* plugin = WINDOW_MANAGER_PLUGIN(data);
  _emit_event(plugin, "focus");
  return false;
}

gboolean on_window_blur(GtkWidget* widget, GdkEvent* event, gpointer data) {
  WindowManagerPlugin* plugin = WINDOW_MANAGER_PLUGIN(data);
  _emit_event(plugin, "blur");
  return false;
}

gboolean on_window_show(GtkWidget* widget, gpointer data) {
  WindowManagerPlugin* plugin = WINDOW_MANAGER_PLUGIN(data);
  _emit_event(plugin, "show");
  return false;
}

gboolean on_window_hide(GtkWidget* widget, gpointer data) {
  WindowManagerPlugin* plugin = WINDOW_MANAGER_PLUGIN(data);
  _emit_event(plugin, "hide");
  return false;
}

gboolean on_window_resize(GtkWidget* widget, gpointer data) {
  WindowManagerPlugin* plugin = WINDOW_MANAGER_PLUGIN(data);
  _emit_event(plugin, "resize");
  return false;
}

gboolean on_window_move(GtkWidget* widget, GdkEvent* event, gpointer data) {
  WindowManagerPlugin* plugin = WINDOW_MANAGER_PLUGIN(data);
  _emit_event(plugin, "move");
  return false;
}

gboolean on_window_state_change(GtkWidget* widget,
                                GdkEventWindowState* event,
                                gpointer data) {
  WindowManagerPlugin* plugin = WINDOW_MANAGER_PLUGIN(data);
  if (event->changed_mask & GDK_WINDOW_STATE_MAXIMIZED) {
    if (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) {
      _emit_event(plugin, "maximize");
    } else {
      _emit_event(plugin, "unmaximize");
    }
  }
  if (event->changed_mask & GDK_WINDOW_STATE_ICONIFIED) {
    if (event->new_window_state & GDK_WINDOW_STATE_ICONIFIED) {
      _emit_event(plugin, "minimize");
    } else {
      _emit_event(plugin, "restore");
    }
  }
  if (event->changed_mask & GDK_WINDOW_STATE_FULLSCREEN) {
    if (event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) {
      _emit_event(plugin, "enter-full-screen");
    } else {
      _emit_event(plugin, "leave-full-screen");
    }
  }
  return false;
}

void emit_button_release(WindowManagerPlugin* self) {
  if (self->_event_box == nullptr) return;
  auto newEvent = (GdkEventButton*)gdk_event_new(GDK_BUTTON_RELEASE);
  newEvent->x = self->_event_button.x;
  newEvent->y = self->_event_button.y;
  newEvent->button = self->_event_button.button;
  newEvent->type = GDK_BUTTON_RELEASE;
  newEvent->time = g_get_monotonic_time();
  gboolean result;
  g_signal_emit_by_name(self->_event_box, "button-release-event", newEvent,
                        &result);
  gdk_event_free((GdkEvent*)newEvent);
}

gboolean on_event_after(GtkWidget* text_view,
                        GdkEvent* event,
                        WindowManagerPlugin* self) {
  if (event->type == GDK_ENTER_NOTIFY) {
    if (nullptr == self->_event_box) {
      return FALSE;
    }
    if (self->_is_dragging) {
      self->_is_dragging = false;
      emit_button_release(self);
    }
    if (self->_is_resizing) {
      self->_is_resizing = false;
      emit_button_release(self);
    }
  }
  return FALSE;
}

gboolean on_mouse_press(GSignalInvocationHint* ihint,
                        guint n_param_values,
                        const GValue* param_values,
                        gpointer data) {
  WindowManagerPlugin* plugin = WINDOW_MANAGER_PLUGIN(data);
  GdkEventButton* event_button =
      (GdkEventButton*)(g_value_get_boxed(param_values + 1));

  if (event_button != nullptr) {
    memset(&plugin->_event_button, 0, sizeof(plugin->_event_button));
    memcpy(&plugin->_event_button, event_button, sizeof(plugin->_event_button));
  }
  return TRUE;
}

void window_manager_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  if (main_window_initialized) {
    // multi window trick: avoid register for sub window
    return;
  }
  main_window_initialized = true;
  WindowManagerPlugin* plugin = WINDOW_MANAGER_PLUGIN(
      g_object_new(window_manager_plugin_get_type(), nullptr));

  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

  plugin->window_geometry.min_width = -1;
  plugin->window_geometry.min_height = -1;
  plugin->window_geometry.max_width = G_MAXINT;
  plugin->window_geometry.max_height = G_MAXINT;

  auto window = get_window(plugin);
  if (window != nullptr) {
    // Disconnect all delete-event handlers first in flutter 3.10.1, which causes delete_event not working.
    // Issues from flutter/engine: https://github.com/flutter/engine/pull/40033 
    guint handler_id = g_signal_handler_find(window, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, fl_plugin_registrar_get_view(plugin->registrar));
    if (handler_id > 0) {
      g_signal_handler_disconnect(window, handler_id);
    }

    g_signal_connect(window, "delete_event",
                     G_CALLBACK(on_window_close), plugin);
    g_signal_connect(window, "focus-in-event",
                     G_CALLBACK(on_window_focus), plugin);
    g_signal_connect(window, "focus-out-event",
                     G_CALLBACK(on_window_blur), plugin);
    g_signal_connect(window, "show", G_CALLBACK(on_window_show),
                     plugin);
    g_signal_connect(window, "hide", G_CALLBACK(on_window_hide),
                     plugin);
    g_signal_connect(window, "check-resize",
                     G_CALLBACK(on_window_resize), plugin);
    g_signal_connect(window, "configure-event",
                     G_CALLBACK(on_window_move), plugin);
    g_signal_connect(window, "window-state-event",
                     G_CALLBACK(on_window_state_change), plugin);
    g_signal_connect(window, "event-after",
                     G_CALLBACK(on_event_after), plugin);
  }

  FlView* view = fl_plugin_registrar_get_view(registrar);
  if (view != nullptr) {
    find_event_box(plugin, GTK_WIDGET(view));
  }

  guint button_signal = g_signal_lookup("button-press-event", GTK_TYPE_WIDGET);
  if (button_signal > 0) {
    plugin->button_press_hook_id = g_signal_add_emission_hook(
        button_signal, 0, on_mouse_press, plugin, NULL);
  }

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "window_manager", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
