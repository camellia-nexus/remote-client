#include "include/flutter_custom_cursor/flutter_custom_cursor_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <gdk/gdk.h>
#include <sys/utsname.h>
#include <vector>
#include <string>
#include <unordered_map>
#include <cstring>

#define FLUTTER_CUSTOM_CURSOR_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_custom_cursor_plugin_get_type(), \
                              FlutterCustomCursorPlugin))

struct _FlutterCustomCursorPlugin
{
  GObject parent_instance;
  FlPluginRegistrar *registrar;
  std::unordered_map<std::string, GdkCursor*>* cache;
};

G_DEFINE_TYPE(FlutterCustomCursorPlugin, flutter_custom_cursor_plugin, g_object_get_type())

// Gets the window being controlled.
static GtkWindow *get_window(FlutterCustomCursorPlugin *self)
{
  if (self == nullptr || self->registrar == nullptr)
    return nullptr;

  FlView *view = fl_plugin_registrar_get_view(self->registrar);
  if (view == nullptr)
    return nullptr;

  GtkWidget *toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  if (toplevel == nullptr || !GTK_IS_WINDOW(toplevel))
    return nullptr;

  return GTK_WINDOW(toplevel);
}

static GdkWindow *get_gdk_window(FlutterCustomCursorPlugin *self)
{
  GtkWindow *window = get_window(self);
  if (window == nullptr)
    return nullptr;

  return gtk_widget_get_window(GTK_WIDGET(window));
}

static FlMethodResponse* create_custom_cursor(FlutterCustomCursorPlugin *self, FlValue *args)
{
  if (self == nullptr || self->cache == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INTERNAL_ERROR", "Plugin cache not initialized", nullptr));
  }
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_ARGUMENT", "Arguments must be a map", nullptr));
  }
  FlValue *name_val = fl_value_lookup_string(args, "name");
  if (name_val == nullptr || fl_value_get_type(name_val) != FL_VALUE_TYPE_STRING) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_ARGUMENT", "name must be a string", nullptr));
  }
  std::string name = fl_value_get_string(name_val);
  if (name.empty()) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_ARGUMENT", "name cannot be empty", nullptr));
  }

  FlValue *hot_x_val = fl_value_lookup_string(args, "hotX");
  FlValue *hot_y_val = fl_value_lookup_string(args, "hotY");
  double hot_x = 0.0;
  double hot_y = 0.0;
  if (hot_x_val != nullptr) {
    if (fl_value_get_type(hot_x_val) == FL_VALUE_TYPE_FLOAT) {
      hot_x = fl_value_get_float(hot_x_val);
    } else if (fl_value_get_type(hot_x_val) == FL_VALUE_TYPE_INT) {
      hot_x = static_cast<double>(fl_value_get_int(hot_x_val));
    }
  }
  if (hot_y_val != nullptr) {
    if (fl_value_get_type(hot_y_val) == FL_VALUE_TYPE_FLOAT) {
      hot_y = fl_value_get_float(hot_y_val);
    } else if (fl_value_get_type(hot_y_val) == FL_VALUE_TYPE_INT) {
      hot_y = static_cast<double>(fl_value_get_int(hot_y_val));
    }
  }

  FlValue *buffer = fl_value_lookup_string(args, "buffer");
  if (buffer == nullptr || fl_value_get_type(buffer) != FL_VALUE_TYPE_UINT8_LIST) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_ARGUMENT", "buffer must be a uint8 list", nullptr));
  }
  const uint8_t *cursor_buff = fl_value_get_uint8_list(buffer);
  size_t length = fl_value_get_length(buffer);
  if (cursor_buff == nullptr || length == 0) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_ARGUMENT", "buffer cannot be empty", nullptr));
  }

  g_autoptr(GError) loader_err = nullptr;
  g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
  if (!gdk_pixbuf_loader_write(loader, cursor_buff, length, &loader_err)) {
    const char *err_msg = loader_err ? loader_err->message : "Failed to decode cursor image";
    return FL_METHOD_RESPONSE(fl_method_error_response_new("DECODE_ERROR", err_msg, nullptr));
  }
  if (!gdk_pixbuf_loader_close(loader, &loader_err)) {
    const char *err_msg = loader_err ? loader_err->message : "Failed to finalize cursor image";
    return FL_METHOD_RESPONSE(fl_method_error_response_new("DECODE_ERROR", err_msg, nullptr));
  }

  GdkPixbuf *raw_pixbuf = gdk_pixbuf_loader_get_pixbuf(loader);
  if (raw_pixbuf == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("DECODE_ERROR", "Pixbuf loader returned null image", nullptr));
  }
  g_autoptr(GdkPixbuf) pixbuf = gdk_pixbuf_copy(raw_pixbuf);
  if (pixbuf == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("DECODE_ERROR", "Failed to copy pixbuf", nullptr));
  }

  int width = gdk_pixbuf_get_width(pixbuf);
  int height = gdk_pixbuf_get_height(pixbuf);
  if (width <= 0 || height <= 0) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_IMAGE", "Invalid image dimensions", nullptr));
  }

  // Validate and clamp hotspot
  if (hot_x < 0.0) hot_x = 0.0;
  if (hot_x >= width) hot_x = width - 1.0;
  if (hot_y < 0.0) hot_y = 0.0;
  if (hot_y >= height) hot_y = height - 1.0;

  GdkDisplay *display = gdk_display_get_default();
  if (display == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("PLATFORM_ERROR", "Default GDK display not available", nullptr));
  }

  GdkCursor *cursor = gdk_cursor_new_from_pixbuf(display, pixbuf, hot_x, hot_y);
  if (cursor == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("PLATFORM_ERROR", "Failed to create GdkCursor", nullptr));
  }

  // If already exists in cache, unref previous cursor first to prevent leak
  auto it = self->cache->find(name);
  if (it != self->cache->end()) {
    if (it->second != nullptr) {
      g_object_unref(it->second);
    }
    it->second = cursor;
  } else {
    self->cache->emplace(name, cursor);
  }

  return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_string(name.c_str())));
}

static FlMethodResponse* set_custom_cursor(FlutterCustomCursorPlugin* self, FlValue *args) {
  if (self == nullptr || self->cache == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INTERNAL_ERROR", "Plugin cache not initialized", nullptr));
  }
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_ARGUMENT", "Arguments must be a map", nullptr));
  }
  FlValue *name_val = fl_value_lookup_string(args, "name");
  if (name_val == nullptr || fl_value_get_type(name_val) != FL_VALUE_TYPE_STRING) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_ARGUMENT", "name must be a string", nullptr));
  }
  std::string name = fl_value_get_string(name_val);
  auto it = self->cache->find(name);
  if (it == self->cache->end() || it->second == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("NOT_FOUND", "Custom cursor not found", nullptr));
  }
  GdkWindow *gdk_window = get_gdk_window(self);
  if (gdk_window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("PLATFORM_ERROR", "Window not available", nullptr));
  }
  gdk_window_set_cursor(gdk_window, it->second);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* delete_custom_cursor(FlutterCustomCursorPlugin* self, FlValue *args) {
  if (self == nullptr || self->cache == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INTERNAL_ERROR", "Plugin cache not initialized", nullptr));
  }
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_ARGUMENT", "Arguments must be a map", nullptr));
  }
  FlValue *name_val = fl_value_lookup_string(args, "name");
  if (name_val == nullptr || fl_value_get_type(name_val) != FL_VALUE_TYPE_STRING) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_ARGUMENT", "name must be a string", nullptr));
  }
  std::string name = fl_value_get_string(name_val);
  auto it = self->cache->find(name);
  if (it != self->cache->end()) {
    if (it->second != nullptr) {
      g_object_unref(it->second);
    }
    self->cache->erase(it);
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static void flutter_custom_cursor_plugin_handle_method_call(
    FlutterCustomCursorPlugin *self,
    FlMethodCall *method_call)
{
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar *method = fl_method_call_get_name(method_call);
  if (strcmp(method, "getPlatformVersion") == 0)
  {
    struct utsname uname_data = {};
    uname(&uname_data);
    g_autofree gchar *version = g_strdup_printf("Linux %s", uname_data.version);
    g_autoptr(FlValue) result = fl_value_new_string(version);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }
  else if (strcmp(method, "createCustomCursor") == 0)
  {
    FlValue *args = fl_method_call_get_args(method_call);
    response = create_custom_cursor(self, args);
  }
  else if (strcmp(method, "setCustomCursor") == 0)
  {
    FlValue *args = fl_method_call_get_args(method_call); 
    response = set_custom_cursor(self, args);
  }
  else if (strcmp(method, "deleteCustomCursor") == 0)
  {
    FlValue *args = fl_method_call_get_args(method_call);
    response = delete_custom_cursor(self, args);
  }
  else
  {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static void flutter_custom_cursor_plugin_dispose(GObject *object)
{
  FlutterCustomCursorPlugin *self = FLUTTER_CUSTOM_CURSOR_PLUGIN(object);
  if (self->cache != nullptr) {
    for (auto &pair : *self->cache) {
      if (pair.second != nullptr) {
        g_object_unref(pair.second);
      }
    }
    delete self->cache;
    self->cache = nullptr;
  }
  if (self->registrar != nullptr) {
    g_object_unref(self->registrar);
    self->registrar = nullptr;
  }
  G_OBJECT_CLASS(flutter_custom_cursor_plugin_parent_class)->dispose(object);
}

static void flutter_custom_cursor_plugin_class_init(FlutterCustomCursorPluginClass *klass)
{
  G_OBJECT_CLASS(klass)->dispose = flutter_custom_cursor_plugin_dispose;
}

static void flutter_custom_cursor_plugin_init(FlutterCustomCursorPlugin *self) {
  self->registrar = nullptr;
  self->cache = new std::unordered_map<std::string, GdkCursor*>();
}

static void method_call_cb(FlMethodChannel *channel, FlMethodCall *method_call,
                           gpointer user_data)
{
  FlutterCustomCursorPlugin *plugin = FLUTTER_CUSTOM_CURSOR_PLUGIN(user_data);
  flutter_custom_cursor_plugin_handle_method_call(plugin, method_call);
}

void flutter_custom_cursor_plugin_register_with_registrar(FlPluginRegistrar *registrar)
{
  FlutterCustomCursorPlugin *plugin = FLUTTER_CUSTOM_CURSOR_PLUGIN(
      g_object_new(flutter_custom_cursor_plugin_get_type(), nullptr));
  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "flutter_custom_cursor",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
