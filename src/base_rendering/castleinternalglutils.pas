{
  Copyright 2021-2023 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Various internal OpenGL(ES) features, to help OpenGL(ES) rendering. }
unit CastleInternalGLUtils;

{$I castleconf.inc}
{$I openglmac.inc}

interface

uses
  // needed by castleinternalglutils_delphi_wgl.inc
  {$ifndef FPC} {$ifdef MSWINDOWS} Windows, {$endif} {$endif}
  SysUtils, Math, Generics.Collections,
  {$ifdef FPC} CastleGL, {$else} OpenGL, OpenGLext, {$endif}
  CastleImages, CastleUtils, CastleVectors, CastleRectangles,
  CastleColors, CastleProjection, CastleRenderOptions,
  CastleGLUtils;

{$define read_interface}

{$I castleinternalglutils_errors.inc}
{$I castleinternalglutils_helpers.inc}
{$I castleinternalglutils_mipmaps.inc}
{$I castleinternalglutils_ext_framebuffer_blit.inc}
{$I castleinternalglutils_delphi_wgl.inc}
{$I castleinternalglutils_render_unlit_mesh.inc}

{$undef read_interface}

implementation

{$define read_implementation}

uses
  CastleFilesUtils, CastleStringUtils, CastleGLVersion, CastleGLShaders,
  CastleLog, CastleApplicationProperties, CastleRenderContext;

{$I castleinternalglutils_errors.inc}
{$I castleinternalglutils_helpers.inc}
{$I castleinternalglutils_mipmaps.inc}
{$I castleinternalglutils_ext_framebuffer_blit.inc}
{$I castleinternalglutils_delphi_wgl.inc}
{$I castleinternalglutils_render_unlit_mesh.inc}

end.
