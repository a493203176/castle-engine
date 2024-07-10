﻿{ Auto-generated unit with information about the project.
  The information set here reflects the CastleEngineManifest.xml properties.

  You should not modify this file manually.
  Regenerate it using CGE editor "Code -> Regenerate Project" menu item
  (or command-line: "castle-engine generate-program").

  Note: This file has UTF-8 BOM, which makes sure that string literals
  are interpreted as UTF-8. This is important, as CGE build tool will
  place here caption encoded in UTF-8.
  Without the BOM, right now both FPC and Delphi
  would interpret the file as having ANSI encoding on Windows (see
  https://blogs.embarcadero.com/the-delphi-compiler-and-utf-8-encoded-source-code-files-with-no-bom/ ,
  https://wiki.freepascal.org/FPC_Unicode_support#Source_file_codepage ) }
unit CastleAutoGenerated;

interface

implementation

uses CastleApplicationProperties, CastleWindow, CastleLog;

initialization
  ApplicationProperties.ApplicationName := 'screen_resolution_change';
  ApplicationProperties.Caption := 'Test Changing Screen Resolutions';
  ApplicationProperties.Version := '0.1';

  if not IsLibrary then
    Application.ParseStandardParameters;

  { Start logging.

    Should be done after setting ApplicationProperties.ApplicationName/Version,
    since they are recorded in the first automatic log messages.

    Should be done after basic command-line parameters are parsed
    for standalone programs (when "not IsLibrary").
    This allows to handle --version and --help command-line parameters
    without any extra output on Unix, and to set --log-file . }
  InitializeLog;

  {$ifdef DEBUG}
  { Enable debug features, like inspector and file monitor, in debug mode.
    We call it here, to depend on the DEBUG define when compiling the project
    -- and not depend on DEBUG define when compiling the engine. }
  ApplicationProperties.InitializeDebug;
  {$else}
  { Enable release features at run-time.
    This does *nothing* for now, but enables possible future extensions
    (e.g. special optimizations). }
  ApplicationProperties.InitializeRelease;
  {$endif}
end.
