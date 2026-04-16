/* -*- mode:ObjC -*-
   WaylandGLPixelFormat - backend implementation of NSOpenGLPixelFormat

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
#include <Foundation/NSZone.h>
#include <string.h>

#include "wayland/WaylandOpenGL.h"

@implementation WaylandGLPixelFormat

- (id)initWithAttributes:(NSOpenGLPixelFormatAttribute *)attribs
{
  NSOpenGLPixelFormatAttribute *ptr;

  self = [super init];
  if (self == nil)
    {
      return nil;
    }

  if (attribs == NULL)
    {
      _attributeCount = 1;
      _attributes = NSZoneMalloc(NSDefaultMallocZone(),
                                 sizeof(NSOpenGLPixelFormatAttribute));
      _attributes[0] = (NSOpenGLPixelFormatAttribute)0;
      return self;
    }

  _attributeCount = 1;
  for (ptr = attribs; *ptr != 0; ptr++)
    {
      _attributeCount++;
      switch (*ptr)
        {
          case NSOpenGLPFAAuxBuffers:
          case NSOpenGLPFAColorSize:
          case NSOpenGLPFAAlphaSize:
          case NSOpenGLPFADepthSize:
          case NSOpenGLPFAStencilSize:
          case NSOpenGLPFAAccumSize:
          case NSOpenGLPFARendererID:
          case NSOpenGLPFAScreenMask:
          case NSOpenGLPFASamples:
          case NSOpenGLPFAAuxDepthStencil:
          case NSOpenGLPFASampleBuffers:
            if (*(ptr + 1) != 0)
              {
                ptr++;
                _attributeCount++;
              }
            break;
          default:
            break;
        }
    }

  _attributes = NSZoneMalloc(NSDefaultMallocZone(),
                             _attributeCount * sizeof(NSOpenGLPixelFormatAttribute));
  memcpy(_attributes, attribs,
         _attributeCount * sizeof(NSOpenGLPixelFormatAttribute));

  return self;
}

- (void)getValues:(GLint *)vals
     forAttribute:(NSOpenGLPixelFormatAttribute)attrib
 forVirtualScreen:(GLint)screen
{
  NSUInteger i;

  (void)screen;

  if (vals == NULL)
    {
      return;
    }

  *vals = 0;
  if (_attributes == NULL)
    {
      return;
    }

  for (i = 0; i + 1 < _attributeCount; i++)
    {
      if (_attributes[i] == attrib)
        {
          switch (attrib)
            {
              case NSOpenGLPFAAuxBuffers:
              case NSOpenGLPFAColorSize:
              case NSOpenGLPFAAlphaSize:
              case NSOpenGLPFADepthSize:
              case NSOpenGLPFAStencilSize:
              case NSOpenGLPFAAccumSize:
              case NSOpenGLPFARendererID:
              case NSOpenGLPFAScreenMask:
              case NSOpenGLPFASamples:
              case NSOpenGLPFAAuxDepthStencil:
              case NSOpenGLPFASampleBuffers:
                *vals = _attributes[i + 1];
                break;
              default:
                *vals = 1;
                break;
            }
          return;
        }
    }
}

- (void)dealloc
{
  if (_attributes != NULL)
    {
      NSZoneFree(NSDefaultMallocZone(), _attributes);
      _attributes = NULL;
    }

  [super dealloc];
}

@end
