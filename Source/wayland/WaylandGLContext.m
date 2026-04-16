/* -*- mode:ObjC -*-
   WaylandGLContext - backend implementation of NSOpenGLContext

   Copyright (C) 2026 Free Software Foundation, Inc.

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

#include "config.h"

#include <Foundation/NSDebug.h>
#include <Foundation/NSException.h>
#include <AppKit/NSView.h>

#include "wayland/WaylandOpenGL.h"

static WaylandGLContext *currentGLContext;

@implementation WaylandGLContext

+ (void)clearCurrentContext
{
  currentGLContext = nil;
}

+ (NSOpenGLContext *)currentContext
{
  return currentGLContext;
}

- (void *)CGLContextObj
{
  return NULL;
}

- (void)copyAttributesFromContext:(NSOpenGLContext *)context
          withMask:(unsigned long)mask
{
  (void)context;
  (void)mask;
}

- (id)initWithCGLContextObj:(void *)context
{
  NSDebugMLLog(@"OpenGL", @"initWithCGLContextObj is not supported on Wayland (%p)", context);
  [self release];
  return nil;
}

- (id)initWithFormat:(NSOpenGLPixelFormat *)format
        shareContext:(NSOpenGLContext *)share
{
  (void)share;

  if (format == nil || [format isKindOfClass:[WaylandGLPixelFormat class]] == NO)
    {
      NSDebugMLLog(@"OpenGL", @"Invalid pixel format %@", format);
      [self release];
      return nil;
    }

  self = [super init];
  if (self == nil)
    {
      return nil;
    }

  _pixelFormat = RETAIN(format);

  return self;
}

- (NSOpenGLPixelFormat *)pixelFormat
{
  return _pixelFormat;
}

- (void)setView:(NSView *)view
{
  ASSIGN(_view, view);
}

- (NSView *)view
{
  return _view;
}

- (void)clearDrawable
{
  ASSIGN(_view, nil);
}

- (void)makeCurrentContext
{
  currentGLContext = self;
}

- (void)flushBuffer
{
  if (currentGLContext != self)
    {
      NSDebugMLLog(@"OpenGL", @"Attempt to flush a non-current Wayland GL context %@", self);
    }
}

- (void)update
{
}

- (void)getValues:(long *)vals forParameter:(NSOpenGLContextParameter)param
{
  if (vals == NULL)
    {
      return;
    }

  switch (param)
    {
      case NSOpenGLCPSwapInterval:
      case NSOpenGLCPRasterizationEnable:
      case NSOpenGLCPStateValidation:
      case NSOpenGLCPSurfaceOpacity:
      case NSOpenGLCPSurfaceOrder:
        *vals = 0;
        break;
      default:
        *vals = 0;
        break;
    }
}

- (void)setValues:(long *)vals forParameter:(NSOpenGLContextParameter)param
{
  (void)vals;
  (void)param;
}

- (void)dealloc
{
  if (currentGLContext == self)
    {
      [WaylandGLContext clearCurrentContext];
    }

  RELEASE(_view);
  RELEASE(_pixelFormat);

  [super dealloc];
}

@end
