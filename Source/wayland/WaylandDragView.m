/* WaylandDragView - Drag and Drop for Wayland backend

   Copyright (C) 2024 Free Software Foundation, Inc.

   This file is part of the GNUstep Backend.

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

#include <unistd.h>
#include <string.h>

#include <Foundation/NSDebug.h>
#include <Foundation/NSDate.h>

#include <AppKit/NSApplication.h>
#include <AppKit/NSCell.h>
#include <AppKit/NSCursor.h>
#include <AppKit/NSGraphics.h>
#include <AppKit/NSImage.h>
#include <AppKit/NSPasteboard.h>
#include <AppKit/NSView.h>
#include <AppKit/NSWindow.h>
#include <AppKit/NSEvent.h>

#include "wayland/WaylandServer.h"
#include "wayland/WaylandDragView.h"

/* Expose GSDragView's private _setCursor so we can override it. */
@interface GSDragView (WaylandPrivate)
- (void) _setCursor;
@end

/* Private category to expose wlconfig from WaylandServer */
@interface WaylandServer (DragViewAccess)
- (WaylandConfig *) wlconfig;
@end

@implementation WaylandServer (DragViewAccess)
- (WaylandConfig *) wlconfig
{
  return wlconfig;
}
@end


/* Lightweight NSWindow subclass used to hold the GSDragView content.
   We never actually show this window - the drag icon is rendered on the
   Wayland cursor surface instead, so it follows the pointer automatically.
   The window must still exist for GSDragView's internal event handling. */
@interface WaylandRawWindow : NSWindow
@end

@implementation WaylandRawWindow

- (BOOL) canBecomeMainWindow
{
  return NO;
}

- (BOOL) canBecomeKeyWindow
{
  return NO;
}

- (void) _initDefaults
{
  [super _initDefaults];
  [self setReleasedWhenClosed: NO];
  [self setExcludedFromWindowsMenu: YES];
}

- (void) orderWindow: (NSWindowOrderingMode)place relativeTo: (NSInteger)otherWin
{
  [super orderWindow: place relativeTo: otherWin];
  [self setLevel: NSPopUpMenuWindowLevel];
}

@end


/* -------------------------------------------------------------------------
 * wl_data_offer listener
 * Accumulates the MIME types offered by a drag source into wlconfig->dnd_recv
 * ------------------------------------------------------------------------- */

static void
dnd_offer_handle_offer(void *data, struct wl_data_offer *offer,
                        const char *mime_type)
{
  WaylandConfig *wlconfig = (WaylandConfig *)data;
  if (!wlconfig->dnd_recv.mime_types)
    return;
  NSMutableArray *types = (NSMutableArray *)wlconfig->dnd_recv.mime_types;
  NSString *s = [NSString stringWithUTF8String: mime_type];
  if (![types containsObject: s])
    [types addObject: s];
}

static void
dnd_offer_handle_source_actions(void *data, struct wl_data_offer *offer,
                                  uint32_t source_actions)
{ /* ignored — we accept copy+move regardless */ }

static void
dnd_offer_handle_action(void *data, struct wl_data_offer *offer,
                          uint32_t dnd_action)
{ /* ignored */ }

static const struct wl_data_offer_listener dnd_offer_listener = {
  dnd_offer_handle_offer,
  dnd_offer_handle_source_actions,
  dnd_offer_handle_action,
};


/* -------------------------------------------------------------------------
 * wl_data_source listener  (source process side)
 * ------------------------------------------------------------------------- */

/* Forward declaration so the callbacks can use WaylandDragView methods. */
@interface WaylandDragView (DnDSource)
- (const char *) _mimeTypeForPboardType: (NSString *)pboardType;
- (NSString *) _pboardTypeForMimeType: (NSString *)mimeType;
- (void) _cleanupWlDataSource;
- (void) _cancelExternalDrag;
- (void) _dropPerformedForExternalDrag;
- (void) _finishExternalDrag;
@end

static void
data_source_handle_target(void *data, struct wl_data_source *source,
                            const char *mime_type)
{ /* compositor reports which MIME type the target prefers — informational */ }

static void
data_source_handle_send(void *data, struct wl_data_source *source,
                          const char *mime_type, int32_t fd)
{
  /* A non-GNUstep destination is requesting data; serve it from NSDragPboard. */
  WaylandDragView *view = (WaylandDragView *)data;
  NSString *mimeStr = [NSString stringWithUTF8String: mime_type];
  NSString *pboardType = [view _pboardTypeForMimeType: mimeStr];
  NSPasteboard *pb = [NSPasteboard pasteboardWithName: NSDragPboard];

  NSData *bytes = nil;
  if (pboardType)
    {
      bytes = [pb dataForType: pboardType];
      if (!bytes)
        {
          NSString *str = [pb stringForType: pboardType];
          if (str)
            bytes = [str dataUsingEncoding: NSUTF8StringEncoding];
        }
    }

  if (bytes)
    {
      const uint8_t *buf = (const uint8_t *)[bytes bytes];
      NSUInteger    len  = [bytes length];
      NSUInteger    written = 0;
      while (written < len)
        {
          ssize_t n = write(fd, buf + written, len - written);
          if (n <= 0)
            break;
          written += (NSUInteger)n;
        }
    }
  close(fd);
}

static void
data_source_handle_cancelled(void *data, struct wl_data_source *source)
{
  /* Drag was cancelled (pointer released over a non-droppable area). */
  WaylandDragView *view = (WaylandDragView *)data;
  [view _cancelExternalDrag];
}

static void
data_source_handle_dnd_drop_performed(void *data, struct wl_data_source *source)
{
  /* Button released on a droppable target; the destination will handle the
     actual drop.  Wake up GSDragView's event loop so it can finish.        */
  WaylandDragView *view = (WaylandDragView *)data;
  [view _dropPerformedForExternalDrag];
}

static void
data_source_handle_dnd_finished(void *data, struct wl_data_source *source)
{
  /* Destination confirmed the drop is complete — clean up. */
  WaylandDragView *view = (WaylandDragView *)data;
  [view _finishExternalDrag];
}

static void
data_source_handle_action(void *data, struct wl_data_source *source,
                            uint32_t dnd_action)
{ /* compositor selected action — could update cursor here */ }

static const struct wl_data_source_listener data_source_listener = {
  data_source_handle_target,
  data_source_handle_send,
  data_source_handle_cancelled,
  data_source_handle_dnd_drop_performed,
  data_source_handle_dnd_finished,
  data_source_handle_action,
};


/* -------------------------------------------------------------------------
 * wl_data_device listener  (destination process side)
 * Callbacks fire in the destination process's Wayland event loop (main thread).
 * ------------------------------------------------------------------------- */

@interface WaylandServer (DnDHandlers)
- (void) _dndEnterSurface: (struct wl_surface *)surface
                        x: (float)wl_x
                        y: (float)wl_y
                   serial: (uint32_t)serial;
- (void) _dndMotionSurface: (struct wl_surface *)surface
                         x: (float)wl_x
                         y: (float)wl_y;
- (void) _dndLeaveSurface: (struct wl_surface *)surface;
- (void) _dndDropSurface: (struct wl_surface *)surface;
@end

static void
data_device_handle_data_offer(void *data, struct wl_data_device *device,
                               struct wl_data_offer *offer)
{
  WaylandConfig *wlconfig = (WaylandConfig *)data;

  /* Release any previously pending MIME-type list */
  if (wlconfig->dnd_recv.mime_types)
    {
      [(NSMutableArray *)(wlconfig->dnd_recv.mime_types) release];
      wlconfig->dnd_recv.mime_types = NULL;
    }

  NSMutableArray *types = [[NSMutableArray alloc] init];
  wlconfig->dnd_recv.mime_types = (void *)types;   /* retained by alloc */
  wlconfig->dnd_recv.offer = offer;
  wl_data_offer_add_listener(offer, &dnd_offer_listener, wlconfig);
}

static void
data_device_handle_enter(void *data, struct wl_data_device *device,
                          uint32_t serial, struct wl_surface *surface,
                          wl_fixed_t x, wl_fixed_t y,
                          struct wl_data_offer *offer)
{
  WaylandConfig *wlconfig = (WaylandConfig *)data;
  wlconfig->dnd_recv.enter_serial = serial;
  wlconfig->dnd_recv.surface = surface;
  wlconfig->dnd_recv.x = (float)wl_fixed_to_double(x);
  wlconfig->dnd_recv.y = (float)wl_fixed_to_double(y);
  wlconfig->dnd_recv.active = YES;

  /* Accept the best type we can offer and request copy+move actions */
  NSMutableArray *types = (NSMutableArray *)wlconfig->dnd_recv.mime_types;
  if ([types count] > 0)
    wl_data_offer_accept(offer, serial, [[types objectAtIndex: 0] UTF8String]);

  wl_data_offer_set_actions(offer,
    WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY | WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE,
    WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);

  WaylandServer *srv = (WaylandServer *)GSCurrentServer();
  [srv _dndEnterSurface: surface
                      x: (float)wl_fixed_to_double(x)
                      y: (float)wl_fixed_to_double(y)
                 serial: serial];
}

static void
data_device_handle_motion(void *data, struct wl_data_device *device,
                            uint32_t time, wl_fixed_t x, wl_fixed_t y)
{
  WaylandConfig *wlconfig = (WaylandConfig *)data;
  wlconfig->dnd_recv.x = (float)wl_fixed_to_double(x);
  wlconfig->dnd_recv.y = (float)wl_fixed_to_double(y);

  if (!wlconfig->dnd_recv.active || !wlconfig->dnd_recv.surface)
    return;

  WaylandServer *srv = (WaylandServer *)GSCurrentServer();
  [srv _dndMotionSurface: wlconfig->dnd_recv.surface
                       x: (float)wl_fixed_to_double(x)
                       y: (float)wl_fixed_to_double(y)];
}

static void
data_device_handle_leave(void *data, struct wl_data_device *device)
{
  WaylandConfig *wlconfig = (WaylandConfig *)data;
  struct wl_surface *surface = wlconfig->dnd_recv.surface;
  BOOL was_active = wlconfig->dnd_recv.active;

  wlconfig->dnd_recv.active = NO;
  wlconfig->dnd_recv.surface = NULL;

  /* Destroy the offer; it is no longer valid after leave */
  if (wlconfig->dnd_recv.offer)
    {
      wl_data_offer_destroy(wlconfig->dnd_recv.offer);
      wlconfig->dnd_recv.offer = NULL;
    }
  if (wlconfig->dnd_recv.mime_types)
    {
      [(NSMutableArray *)(wlconfig->dnd_recv.mime_types) release];
      wlconfig->dnd_recv.mime_types = NULL;
    }

  if (was_active && surface)
    {
      WaylandServer *srv = (WaylandServer *)GSCurrentServer();
      [srv _dndLeaveSurface: surface];
    }
}

static void
data_device_handle_drop(void *data, struct wl_data_device *device)
{
  WaylandConfig *wlconfig = (WaylandConfig *)data;
  struct wl_surface *surface = wlconfig->dnd_recv.surface;
  wlconfig->dnd_recv.active = NO;

  if (surface)
    {
      WaylandServer *srv = (WaylandServer *)GSCurrentServer();
      [srv _dndDropSurface: surface];
    }

  /* Finish and destroy the offer now that the drop is complete */
  if (wlconfig->dnd_recv.offer)
    {
      wl_data_offer_finish(wlconfig->dnd_recv.offer);
      wl_data_offer_destroy(wlconfig->dnd_recv.offer);
      wlconfig->dnd_recv.offer = NULL;
    }
  if (wlconfig->dnd_recv.mime_types)
    {
      [(NSMutableArray *)(wlconfig->dnd_recv.mime_types) release];
      wlconfig->dnd_recv.mime_types = NULL;
    }
  wlconfig->dnd_recv.surface = NULL;
}

static void
data_device_handle_selection(void *data, struct wl_data_device *device,
                              struct wl_data_offer *offer)
{
  /* Clipboard selection change — not handled here; clean up pending offer. */
  WaylandConfig *wlconfig = (WaylandConfig *)data;
  if (offer && offer == wlconfig->dnd_recv.offer)
    {
      /* The compositor is re-using this offer for clipboard; discard our ref */
      wlconfig->dnd_recv.offer = NULL;
    }
  if (offer)
    wl_data_offer_destroy(offer);
}

const struct wl_data_device_listener gnustep_data_device_listener = {
  data_device_handle_data_offer,
  data_device_handle_enter,
  data_device_handle_leave,
  data_device_handle_motion,
  data_device_handle_drop,
  data_device_handle_selection,
};


/* -------------------------------------------------------------------------
 * WaylandDragView private extension
 * ------------------------------------------------------------------------- */

@interface WaylandDragView ()
{
  void                *_dragCursorCid;
  struct wl_data_source *_wlDataSource;  /* active source during external drag */
  BOOL                  _incomingDrag;   /* YES in the destination process     */
  NSPoint               _incomingDragPosition; /* window-base coords          */
  NSDragOperation       _incomingDragMask;
}
- (void) _startWaylandDragFromConfig: (WaylandConfig *)cfg;
@end


/* -------------------------------------------------------------------------
 * WaylandDragView
 * ------------------------------------------------------------------------- */

@implementation WaylandDragView

static WaylandDragView *sharedDragView = nil;

+ (id) sharedDragView
{
  if (sharedDragView == nil)
    sharedDragView = [WaylandDragView new];
  return sharedDragView;
}

+ (Class) windowClass
{
  return [WaylandRawWindow class];
}

- (void) updateDragInfoFromEvent: (NSEvent *)event
{
  destWindow = [event window];
  dragPoint  = [event locationInWindow];
  dragSequence = [event timestamp];
  dragMask   = [event data2];
}

- (void) resetDragInfo
{
  DESTROY(dragPasteboard);
}

/* ------------------------------------------------------------------
 * NSDraggingInfo overrides for destination-process use
 * ------------------------------------------------------------------ */

- (NSPasteboard *) draggingPasteboard
{
  if (_incomingDrag)
    return [NSPasteboard pasteboardWithName: NSDragPboard];
  return [super draggingPasteboard];
}

- (NSPoint) draggingLocation
{
  if (_incomingDrag)
    return _incomingDragPosition;
  return [super draggingLocation];
}

- (NSDragOperation) draggingSourceOperationMask
{
  if (_incomingDrag)
    return _incomingDragMask;
  return [super draggingSourceOperationMask];
}

/* ------------------------------------------------------------------
 * Source-side helpers
 * ------------------------------------------------------------------ */

- (const char *) _mimeTypeForPboardType: (NSString *)pboardType
{
  if ([pboardType isEqualToString: NSStringPboardType])   return "text/plain;charset=utf-8";
  if ([pboardType isEqualToString: NSRTFPboardType])       return "text/rtf";
  if ([pboardType isEqualToString: NSFilenamesPboardType]) return "text/uri-list";
  if ([pboardType isEqualToString: NSTIFFPboardType])      return "image/tiff";
  if ([pboardType isEqualToString: NSPDFPboardType])       return "image/png";
  return [pboardType UTF8String];
}

- (NSString *) _pboardTypeForMimeType: (NSString *)mimeType
{
  if ([mimeType hasPrefix: @"text/plain"])          return NSStringPboardType;
  if ([mimeType isEqualToString: @"text/rtf"])      return NSRTFPboardType;
  if ([mimeType isEqualToString: @"text/uri-list"]) return NSFilenamesPboardType;
  if ([mimeType isEqualToString: @"image/tiff"])    return NSTIFFPboardType;
  if ([mimeType isEqualToString: @"image/png"])     return NSPDFPboardType;
  return mimeType;
}

- (void) _cleanupWlDataSource
{
  if (_wlDataSource)
    {
      wl_data_source_destroy(_wlDataSource);
      _wlDataSource = NULL;
    }
}

- (void) _cancelExternalDrag
{
  [self _cleanupWlDataSource];
  NSEvent *up = [NSEvent mouseEventWithType: NSLeftMouseUp
                                   location: [NSEvent mouseLocation]
                              modifierFlags: 0
                                  timestamp: [[NSDate date] timeIntervalSinceReferenceDate]
                               windowNumber: 0
                                    context: nil
                                eventNumber: 0
                                 clickCount: 1
                                   pressure: 0.0f];
  [NSApp postEvent: up atStart: YES];
}

- (void) _dropPerformedForExternalDrag
{
  /* Don't destroy the source yet — _finishExternalDrag handles that.
     Just break GSDragView's mouse-up wait so the loop can exit.     */
  NSEvent *up = [NSEvent mouseEventWithType: NSLeftMouseUp
                                   location: [NSEvent mouseLocation]
                              modifierFlags: 0
                                  timestamp: [[NSDate date] timeIntervalSinceReferenceDate]
                               windowNumber: 0
                                    context: nil
                                eventNumber: 0
                                 clickCount: 1
                                   pressure: 0.0f];
  [NSApp postEvent: up atStart: YES];
}

- (void) _finishExternalDrag
{
  [self _cleanupWlDataSource];
}

- (void) _startWaylandDragFromConfig: (WaylandConfig *)cfg
{
  if (!cfg->data_device_manager || !cfg->data_device)
    return;

  _wlDataSource = wl_data_device_manager_create_data_source(cfg->data_device_manager);
  if (!_wlDataSource)
    return;

  wl_data_source_add_listener(_wlDataSource, &data_source_listener, (void *)self);

  /* Advertise all pasteboard types as MIME types */
  NSArray *types = [dragPasteboard types];
  NSUInteger i;
  for (i = 0; i < [types count]; i++)
    {
      const char *mime = [self _mimeTypeForPboardType: [types objectAtIndex: i]];
      if (mime)
        wl_data_source_offer(_wlDataSource, mime);
    }
  wl_data_source_set_actions(_wlDataSource,
    WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY |
    WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE);

  /* Use the window that currently has pointer focus as the drag origin */
  struct window *srcWin = cfg->pointer.focus;
  struct wl_surface *srcSurface = srcWin ? srcWin->surface : NULL;

  if (srcSurface && cfg->pointer.serial)
    {
      wl_data_device_start_drag(cfg->data_device, _wlDataSource,
                                 srcSurface, NULL, cfg->pointer.serial);
      wl_display_flush(cfg->display);
      NSDebugLog(@"WaylandDragView: started wl_data_device drag (serial=%u)",
                 cfg->pointer.serial);
    }
  else
    {
      NSDebugLog(@"WaylandDragView: no source surface/serial for start_drag");
      [self _cleanupWlDataSource];
    }
}

/* ------------------------------------------------------------------
 * Destination-side helpers
 * ------------------------------------------------------------------ */

- (void) _setupIncomingDragAtWindowPosition: (NSPoint)pos
                              allowedActions: (NSDragOperation)mask
{
  _incomingDrag = YES;
  _incomingDragPosition = pos;
  _incomingDragMask = mask;
}

- (void) _clearIncomingDrag
{
  _incomingDrag = NO;
}

/* ------------------------------------------------------------------
 * Overrides for external (inter-process) drag events
 * ------------------------------------------------------------------ */

- (void) postDragEvent: (NSEvent *)theEvent
{
  if (destExternal)
    {
      /* The destination is in another process; wl_data_device routes events.
         No action needed here — the loop stays alive via fake status events. */
      return;
    }
  [super postDragEvent: theEvent];
}

- (void) sendExternalEvent: (GSAppKitSubtype)subtype
                    action: (NSDragOperation)action
                  position: (NSPoint)eventLocation
                 timestamp: (NSTimeInterval)time
                  toWindow: (int)dWindowNumber
{
  WaylandConfig *cfg = [(WaylandServer *)GSCurrentServer() wlconfig];

  if (subtype == GSAppKitDraggingEnter)
    {
      /* First call with an external window: start the Wayland DnD drag so
         the compositor can route enter/motion/drop to the destination.      */
      if (!_wlDataSource)
        [self _startWaylandDragFromConfig: cfg];
    }

  /* Exit and Drop have no further action on our side — the compositor's
     DnD state machine (and wl_data_source callbacks) handle the rest.  */
  if (subtype == GSAppKitDraggingExit || subtype == GSAppKitDraggingDrop)
    return;

  /* For Enter and Update: post a synthetic GSAppKitDraggingStatus event
     back to this process so GSDragView's loop stays alive and knows the
     target accepts the drag.                                              */
  NSDragOperation mask = action ? action
                                : (NSDragOperationCopy | NSDragOperationMove);
  NSEvent *status =
    [NSEvent otherEventWithType: NSAppKitDefined
                       location: eventLocation
                  modifierFlags: 0
                      timestamp: time
                   windowNumber: dWindowNumber
                        context: nil
                        subtype: GSAppKitDraggingStatus
                          data1: dWindowNumber
                          data2: (NSInteger)mask];
  [NSApp postEvent: status atStart: NO];
}

/* ------------------------------------------------------------------
 * Drag image / cursor management  (unchanged from original)
 * ------------------------------------------------------------------ */

- (void) _setupWindowFor: (NSImage *)anImage
           mousePosition: (NSPoint)mPoint
           imagePosition: (NSPoint)iPoint
{
  if (anImage == nil)
    anImage = [NSImage imageNamed: @"common_Close"];

  NSSize imageSize = [anImage size];

  [dragCell setImage: anImage];
  dragPosition = mPoint;
  newPosition  = mPoint;
  offset.width  = mPoint.x - iPoint.x;
  offset.height = mPoint.y - iPoint.y;

  NSPoint hotspot;
  hotspot.x = offset.width;
  hotspot.y = imageSize.height - offset.height;
  if (hotspot.x < 0) hotspot.x = 0;
  if (hotspot.y < 0) hotspot.y = 0;

  NSDebugLog(@"WaylandDragView: setting drag cursor hotspot=(%g,%g)",
             hotspot.x, hotspot.y);

  WaylandServer *server = (WaylandServer *) GSCurrentServer();
  [server imagecursor: hotspot : anImage : &_dragCursorCid];
  if (_dragCursorCid != NULL)
    [server setcursor: _dragCursorCid];
}

- (void) _clearupWindow
{
  WaylandServer *server = (WaylandServer *) GSCurrentServer();

  void *arrowCid = NULL;
  [server standardcursor: GSArrowCursor : &arrowCid];
  if (arrowCid != NULL)
    {
      [server setcursor: arrowCid];
      [server freecursor: arrowCid];
    }

  if (_dragCursorCid != NULL)
    {
      [server freecursor: _dragCursorCid];
      _dragCursorCid = NULL;
    }
}

- (void) _setCursor
{
  /* Suppress: the drag image IS the cursor surface */
}

- (void) _moveDraggedImageToNewPosition
{
  /* Cursor follows the pointer automatically via the compositor */
  dragPosition = newPosition;
}

/* ------------------------------------------------------------------
 * Window-under-pointer detection for intra-process drag  (unchanged)
 * ------------------------------------------------------------------ */

- (NSWindow *) windowAcceptingDnDunder: (NSPoint)p
                             windowRef: (int *)mouseWindowRef
{
  WaylandConfig *wlconfig =
    [(WaylandServer *) GSCurrentServer() wlconfig];
  struct window *window;

  int dragWinNum = (_window != nil) ? [_window windowNumber] : -1;

  struct window *candidate = NULL;
  wl_list_for_each(window, &wlconfig->window_list, link)
  {
    if (window->window_id == dragWinNum)
      continue;
    if (window->ignoreMouse || window->terminated || !window->configured)
      continue;
    if (window->output == NULL)
      continue;

    float ns_x = window->pos_x;
    float ns_y = window->output->height - window->pos_y - window->height;

    if (p.x >= ns_x && p.x < ns_x + window->width
	&& p.y >= ns_y && p.y < ns_y + window->height)
      {
	NSWindow *nswindow = GSWindowWithNumber(window->window_id);
	if (nswindow == nil)
	  continue;
	NSCountedSet *dragTypes =
	  [GSCurrentServer() dragTypesForWindow: nswindow];
	if ([dragTypes count] > 0)
	  candidate = window;
      }
  }

  if (candidate != NULL)
    {
      if (mouseWindowRef)
	*mouseWindowRef = candidate->window_id;
      return GSWindowWithNumber(candidate->window_id);
    }

  if (mouseWindowRef)
    *mouseWindowRef = 0;
  return nil;
}

@end


/* -------------------------------------------------------------------------
 * WaylandServer (DragAndDrop)
 * ------------------------------------------------------------------------- */

@implementation WaylandServer (DragAndDrop)

- (id <NSDraggingInfo>) dragInfo
{
  return [WaylandDragView sharedDragView];
}

- (BOOL) addDragTypes: (NSArray *)types toWindow: (NSWindow *)win
{
  return [super addDragTypes: types toWindow: win];
}

- (BOOL) removeDragTypes: (NSArray *)types fromWindow: (NSWindow *)win
{
  return [super removeDragTypes: types fromWindow: win];
}

/* Called from _initWaylandContext once both seat and data_device_manager
   are available (after the initial registry roundtrip).                  */
- (void) _setupDataDevice
{
  extern const struct wl_data_device_listener gnustep_data_device_listener;

  if (!wlconfig->data_device_manager || !wlconfig->seat)
    return;
  if (wlconfig->data_device)
    return; /* already set up */

  wlconfig->data_device =
    wl_data_device_manager_get_data_device(wlconfig->data_device_manager,
                                            wlconfig->seat);
  if (wlconfig->data_device)
    {
      wl_data_device_add_listener(wlconfig->data_device,
                                   &gnustep_data_device_listener, wlconfig);
      NSDebugLog(@"wayland: wl_data_device ready for DnD");
    }
}

/* ------------------------------------------------------------------
 * Helpers called by wl_data_device callbacks (destination side)
 * ------------------------------------------------------------------ */

static struct window *
_find_window_for_surface(WaylandConfig *cfg, struct wl_surface *surface)
{
  struct window *w;
  wl_list_for_each(w, &cfg->window_list, link)
    if (w->surface == surface)
      return w;
  return NULL;
}

- (void) _dndEnterSurface: (struct wl_surface *)surface
                        x: (float)wl_x
                        y: (float)wl_y
                   serial: (uint32_t)serial
{
  struct window *win = _find_window_for_surface(wlconfig, surface);
  if (!win)
    return;

  /* Wayland coords: origin = surface top-left, Y downward
     NS window base: origin = window bottom-left, Y upward  */
  NSPoint winPos = NSMakePoint(wl_x, win->height - wl_y);
  NSDragOperation mask = NSDragOperationCopy | NSDragOperationMove;

  /* Prepare the WaylandDragView singleton as the NSDraggingInfo object */
  [[WaylandDragView sharedDragView] _setupIncomingDragAtWindowPosition: winPos
                                                         allowedActions: mask];

  NSEvent *event =
    [NSEvent otherEventWithType: NSAppKitDefined
                       location: winPos
                  modifierFlags: 0
                      timestamp: [[NSDate date] timeIntervalSinceReferenceDate]
                   windowNumber: win->window_id
                        context: nil
                        subtype: GSAppKitDraggingEnter
                          data1: win->window_id
                          data2: (NSInteger)mask];
  [NSApp postEvent: event atStart: NO];
}

- (void) _dndMotionSurface: (struct wl_surface *)surface
                         x: (float)wl_x
                         y: (float)wl_y
{
  struct window *win = _find_window_for_surface(wlconfig, surface);
  if (!win)
    return;

  NSPoint winPos = NSMakePoint(wl_x, win->height - wl_y);
  NSDragOperation mask = NSDragOperationCopy | NSDragOperationMove;

  [[WaylandDragView sharedDragView] _setupIncomingDragAtWindowPosition: winPos
                                                         allowedActions: mask];

  NSEvent *event =
    [NSEvent otherEventWithType: NSAppKitDefined
                       location: winPos
                  modifierFlags: 0
                      timestamp: [[NSDate date] timeIntervalSinceReferenceDate]
                   windowNumber: win->window_id
                        context: nil
                        subtype: GSAppKitDraggingUpdate
                          data1: win->window_id
                          data2: (NSInteger)mask];
  [NSApp postEvent: event atStart: NO];
}

- (void) _dndLeaveSurface: (struct wl_surface *)surface
{
  struct window *win = _find_window_for_surface(wlconfig, surface);
  if (!win)
    return;

  [[WaylandDragView sharedDragView] _clearIncomingDrag];

  NSEvent *event =
    [NSEvent otherEventWithType: NSAppKitDefined
                       location: NSZeroPoint
                  modifierFlags: 0
                      timestamp: [[NSDate date] timeIntervalSinceReferenceDate]
                   windowNumber: win->window_id
                        context: nil
                        subtype: GSAppKitDraggingExit
                          data1: win->window_id
                          data2: 0];
  [NSApp postEvent: event atStart: NO];
}

- (void) _dndDropSurface: (struct wl_surface *)surface
{
  struct window *win = _find_window_for_surface(wlconfig, surface);
  if (!win)
    return;

  NSPoint winPos = NSMakePoint(wlconfig->dnd_recv.x,
                               win->height - wlconfig->dnd_recv.y);
  [[WaylandDragView sharedDragView] _setupIncomingDragAtWindowPosition: winPos
                                                         allowedActions: NSDragOperationCopy];

  NSEvent *event =
    [NSEvent otherEventWithType: NSAppKitDefined
                       location: winPos
                  modifierFlags: 0
                      timestamp: [[NSDate date] timeIntervalSinceReferenceDate]
                   windowNumber: win->window_id
                        context: nil
                        subtype: GSAppKitDraggingDrop
                          data1: win->window_id
                          data2: (NSInteger)NSDragOperationCopy];
  [NSApp postEvent: event atStart: NO];

  [[WaylandDragView sharedDragView] _clearIncomingDrag];
}

@end
