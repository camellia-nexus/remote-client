#include "bump_mouse.h"

#include "bump_mouse_x11.h"

#include <gdk/gdkx.h>

bool bump_mouse(int dx, int dy)
{
  GdkDisplay *display = gdk_display_get_default();
  if (display != nullptr && GDK_IS_X11_DISPLAY(display)) {
    return bump_mouse_x11(dx, dy);
  }
  return false;
}
