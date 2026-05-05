/* 
   WaylandServer - XdgShell Protocol Handling

   Copyright (C) 2020 Free Software Foundation, Inc.

   Author: Riccardo Canalicchio <riccardo.canalicchio(at)gmail.com>
   Date: November 2021

   This file is part of the GNU Objective C Backend Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; see the file COPYING.LIB.
   If not, see <http://www.gnu.org/licenses/> or write to the
   Free Software Foundation, 51 Franklin Street, Fifth Floor,
   Boston, MA 02110-1301, USA.
*/

#include "wayland/WaylandServer.h"
#include <AppKit/NSEvent.h>
#include <AppKit/NSApplication.h>
#include <AppKit/NSGraphics.h>
#include <Foundation/NSDebug.h>

static void
xdg_surface_on_configure(void *data, struct xdg_surface *xdg_surface,
                         uint32_t serial)
{
  struct window *window = data;

  NSDebugLog(@"xdg_surface_on_configure: win=%d", window->window_id);

  if (window->terminated == YES)
    {
      NSDebugLog(@"deleting window win=%d", window->window_id);
      free(window);
      return;
    }

  // NSDebugLog(@"Acknowledging surface configure %p %d (window_id=%d)",
  // xdg_surface, serial, window->window_id);

  xdg_surface_ack_configure(xdg_surface, serial);
  window->configured = YES;

  if (window->buffer_needs_attach)
    {
      [window->instance flushwindowrect:NSMakeRect(window->pos_x, window->pos_y,
                                                   window->width, window->height)
                                      :window->window_id];
    }
  /* Keyboard focus is now handled exclusively by keyboard_handle_enter/leave,
     which correctly tracks what the compositor has granted.  Sending
     GSAppKitWindowFocusIn here based on pointer position was wrong: it could
     steal key-window status from a modal dialog simply because the mouse
     cursor happened to be over the reconfigured window. */
}

static void
xdg_toplevel_configure(void *data, struct xdg_toplevel *xdg_toplevel,
                       int32_t width, int32_t height, struct wl_array *states)
{
  struct window *window = data;

  NSDebugLog(@"[%d] xdg_toplevel_configure %dx%d", window->window_id, width,
             height);

  // The compositor can send 0x0
  if (width == 0 || height == 0)
    {
      return;
    }
  if (window->width != width || window->height != height)
    {
      window->width = width;
      window->height = height;

      xdg_surface_set_window_geometry(window->xdg_surface, 0, 0, window->width,
                                      window->height);

      NSEvent *ev = [NSEvent otherEventWithType:NSAppKitDefined
                                       location:NSMakePoint(0.0, 0.0)
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:window->window_id
                                        context:GSCurrentContext()
                                        subtype:GSAppKitWindowResized
                                          data1:window->width
                                          data2:window->height];
      [(GSWindowWithNumber(window->window_id)) sendEvent:ev];
    }
  NSDebugLog(@"[%d] notify resize from backend=%dx%d", window->window_id,
             width, height);
}

static void
xdg_toplevel_close_handler(void *data, struct xdg_toplevel *xdg_toplevel)
{
  NSDebugLog(@"xdg_toplevel_close_handler");
}

static void
xdg_popup_configure(void *data, struct xdg_popup *xdg_popup, int32_t x,
                    int32_t y, int32_t width, int32_t height)
{
  struct window *window = data;

  NSDebugLog(@"[%d] xdg_popup_configure [%d,%d %dx%d]", window->window_id, x, y,
             width, height);
}

static void
xdg_popup_done(void *data, struct xdg_popup *xdg_popup)
{
  struct window *window = data;

  /* Notify AppKit that the popup was dismissed by the compositor so menus
     and other popup clients can close cleanly through the normal path. */
  NSWindow *nswindow = GSWindowWithNumber(window->window_id);
  if (nswindow)
    {
      NSEvent *ev = [NSEvent otherEventWithType:NSAppKitDefined
                                       location:NSZeroPoint
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:window->window_id
                                        context:GSCurrentContext()
                                        subtype:GSAppKitWindowClose
                                          data1:0
                                          data2:0];
      [nswindow sendEvent:ev];
    }

  /* Clean up the Wayland protocol objects.  Null all pointers so that the
     subsequent termwindow:/destroySurfaceRole: path is a safe no-op.       */
  xdg_popup_destroy(xdg_popup);
  window->popup = NULL;
  if (window->xdg_surface)
    {
      xdg_surface_destroy(window->xdg_surface);
      window->xdg_surface = NULL;
    }
  if (window->surface)
    {
      wl_surface_destroy(window->surface);
      window->surface = NULL;
    }
  window->terminated = YES;
}

static void
wm_base_handle_ping(void *data, struct xdg_wm_base *xdg_wm_base,
                    uint32_t serial)
{
  NSDebugLog(@"wm_base_handle_ping");
  xdg_wm_base_pong(xdg_wm_base, serial);
}

const struct xdg_surface_listener xdg_surface_listener = {
  xdg_surface_on_configure,
};

const struct xdg_wm_base_listener wm_base_listener = {
  .ping = wm_base_handle_ping,
};

const struct xdg_popup_listener xdg_popup_listener = {
  .configure = xdg_popup_configure,
  .popup_done = xdg_popup_done,
};

const struct xdg_toplevel_listener xdg_toplevel_listener = {
  .configure = xdg_toplevel_configure,
  .close = xdg_toplevel_close_handler,
};

static void
toplevel_decoration_on_configure(void *data,
                                  struct zxdg_toplevel_decoration_v1 *decoration,
                                  uint32_t mode)
{
  struct window *window = data;
  NSDebugLog(@"[%d] decoration configure: %s", window->window_id,
             mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
               ? "server-side" : "client-side");
}

const struct zxdg_toplevel_decoration_v1_listener toplevel_decoration_listener = {
  .configure = toplevel_decoration_on_configure,
};