#include "bump_mouse.h"

#include <gtk/gtk.h>

#include <gdk/gdkx.h>

#include <iostream>

bool bump_mouse_x11(int dx, int dy)
{
  GdkDisplay *display = gdk_display_get_default();
  if (display == nullptr) {
    return false;
  }

  GdkDevice *mouse_device = nullptr;

#if GTK_CHECK_VERSION(3, 20, 0)
  GdkSeat *seat = gdk_display_get_default_seat(display);
  if (seat == nullptr) {
    return false;
  }
  mouse_device = gdk_seat_get_pointer(seat);
#else
  GdkDeviceManager *devman = gdk_display_get_device_manager(display);
  if (devman == nullptr) {
    return false;
  }
  mouse_device = gdk_device_manager_get_client_pointer(devman);
#endif

  if (mouse_device == nullptr) {
    return false;
  }

  GdkScreen *screen = nullptr;
  gint x = 0, y = 0;

  gdk_device_get_position(mouse_device, &screen, &x, &y);
  if (screen == nullptr) {
    return false;
  }

  gdk_device_warp(mouse_device, screen, x + dx, y + dy);
  return true;
}
