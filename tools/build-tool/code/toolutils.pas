{
  Copyright 2014-2019 Michalis Kamburelis.

  This file is part of "Castle Game Engine".
  Parts of this file are based on FPC packages/fcl-process/src/process.pp ,
  which conveniently uses *exactly* the same license as Castle Game Engine.

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Utilities. }
unit ToolUtils;

interface

uses DOM,
  CastleImages, CastleStringUtils;

{ Copy file, making sure the destination directory exists
  (eventually creating it), and checking result. }
procedure SmartCopyFile(const Source, Dest: string);

function FileSize(const FileName: string): Int64;

var
  { Output path base directory. Empty to use working project directory. }
  OutputPathBase: string = '';

{ Calculate the final location of temporary output files
  (including the castle-engine-output subdir part),
  as an absolute path ending with path delimiter.
  Makes sure the dir exists, if CreateIfNecessary. }
function TempOutputPath(const WorkingDirectory: string;
  const CreateIfNecessary: boolean = true): string;

type
  TReplaceMacros = function (const Source: string): string of object;

type
  TImageFileNames = class(TCastleStringList)
  private
    FBaseUrl: string;
  public
    property BaseUrl: string read FBaseUrl write FBaseUrl;
    { Find image with given extension, or '' if not found. }
    function FindExtension(const Extensions: array of string): string;
    { Find and read an image format that we can process with our CastleImages.
      Try to read it to a class that supports nice-quality resizing (TResizeInterpolationFpImage).
      @nil if not found. }
    function FindReadable: TCastleImage;
  end;

const
  MaxAndroidTagLength = 23;

const
  { Interpolation to scale images with highest quality.

    Latest FPC breaks alpha channel at resizing using riLanczos.
    TODO: Submit a patch to FPC to restore previous behaviour.

    Index: packages/fcl-image/src/fpinterpolation.inc
    ===================================================================
    --- packages/fcl-image/src/fpinterpolation.inc	(wersja 40746)
    +++ packages/fcl-image/src/fpinterpolation.inc	(kopia robocza)
    @@ -223,7 +223,8 @@
               NewCol.blue:=Min(NewCol.blue+round(Col.blue*f),$ffff);
               NewCol.alpha:=Min(NewCol.alpha+round(Col.alpha*f),$ffff);
             end;
    -        Canvas.Colors[x+dx,y+dy]:=AlphaBlend(Canvas.Colors[x+dx,y+dy], NewCol);
    +        //Canvas.Colors[x+dx,y+dy]:=AlphaBlend(Canvas.Colors[x+dx,y+dy], NewCol);
    +        Canvas.Colors[x+dx,y+dy]:=NewCol;
           end;
         end;
       finally
  }
  BestInterpolation = {$ifdef VER3_0} riLanczos {$else} riBilinear {$endif};

{ Find in Element all children called <parameter>,
  read them and add to Parameters list,
  expecting this format:

  <parameter key="my_key" value="my_value" />
  or
  <parameter key="my_key">my_value</parameter>

  Note that keys are converted to lowercase.
  Parameter keys, just like macro names, are not case-sensitive.
}
procedure ReadParameters(const Element: TDOMElement; const Parameters: TStringStringMap;
  const RequiredKeys: array of String);

{ Add all parameters in Parameters to Macros.
  Each parameter key is prefixed by ParameterMacroPrefix
  when it is added to the Macros list. }
procedure ParametersAddMacros(const Macros, Parameters: TStringStringMap;
  const ParameterMacroPrefix: String);

implementation

uses Classes, Process, SysUtils,
  CastleFilesUtils, CastleUtils, CastleURIUtils, CastleLog, CastleXMLUtils,
  ToolCommonUtils;

procedure SmartCopyFile(const Source, Dest: string);
begin
  CheckForceDirectories(ExtractFileDir(Dest));
  CheckCopyFile(Source, Dest);
end;

function FileSize(const FileName: string): Int64;
var
  SourceFile: TFileStream;
begin
  SourceFile := TFileStream.Create(FileName, fmOpenRead);
  try
    Result := SourceFile.Size;
  finally FreeAndNil(SourceFile) end;
end;

var
  FOutputPath: string;

function TempOutputPath(const WorkingDirectory: string; const CreateIfNecessary: boolean): string;
const
  OutputNoteContents = {$I ../embedded_templates/template-castle-engine-output-warning.txt.inc};
var
  OutputNote: string;
begin
  if FOutputPath = '' then
  begin
    if OutputPathBase = '' then
      FOutputPath := InclPathDelim(WorkingDirectory)
    else
      FOutputPath := InclPathDelim(OutputPathBase);
    FOutputPath += 'castle-engine-output' + PathDelim;

    if CreateIfNecessary then
    begin
      CheckForceDirectories(FOutputPath);

      OutputNote := FOutputPath + 'DO-NOT-COMMIT-THIS-DIRECTORY.txt';
      if not FileExists(OutputNote) then
        StringToFile(OutputNote, OutputNoteContents);
    end;
  end;

  Result := FOutputPath;
end;

{ TImageFileNames ------------------------------------------------------------- }

function TImageFileNames.FindExtension(const Extensions: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Count - 1 do
    if AnsiSameText(ExtractFileExt(Strings[I]), '.ico') then
      Exit(Strings[I]);
end;

function TImageFileNames.FindReadable: TCastleImage;
var
  I: Integer;
  MimeType, URL: string;
begin
  for I := 0 to Count - 1 do
  begin
    URL := CombineURI(BaseUrl, Strings[I]);
    MimeType := URIMimeType(URL);
    if (MimeType <> '') and IsImageMimeType(MimeType, true, false) then
      Exit(LoadImage(URL, [TRGBImage, TRGBAlphaImage]));
  end;
  Result := nil;
end;

function GetCData(const Element: TDOMElement): String;
var
  I: TXMLCDataIterator;
begin
  Result := '';
  I := TXMLCDataIterator.Create(Element);
  try
    while I.GetNext do
      Result := Result + I.Current;
  finally FreeAndNil(I) end;
end;

procedure ReadParameters(const Element: TDOMElement; const Parameters: TStringStringMap;
  const RequiredKeys: array of String);
var
  ChildElements: TXMLElementIterator;
  ChildElement: TDOMElement;
  Key, Value, KeyLower: string;
begin
  ChildElements := Element.ChildrenIterator('parameter');
  try
    while ChildElements.GetNext do
    begin
      ChildElement := ChildElements.Current;

      Key := LowerCase(ChildElement.AttributeString('key'));
      if Key = '' then
        raise Exception.Create('Key for <parameter> is empty in CastleEngineManifest.xml');

      if ChildElement.HasAttribute('value') then
        Value := ChildElement.AttributeString('value')
      else
      begin
        Value := ChildElement.TextData;
        if Value = '' then
          Value := GetCData(ChildElement);
        { value cannot be empty in this case }
        if Value = '' then
          raise Exception.CreateFmt('No value for key "%s" specified in CastleEngineManifest.xml', [Key]);
      end;

      Parameters.Add(Key, Value);
    end;
  finally FreeAndNil(ChildElements) end;

  for Key in RequiredKeys do
  begin
    KeyLower := LowerCase(Key);
    if not Parameters.ContainsKey(KeyLower) then
      Parameters.Add(KeyLower, '');
  end;
end;

procedure ParametersAddMacros(const Macros, Parameters: TStringStringMap;
  const ParameterMacroPrefix: String);
var
  Pair: TStringStringMap.TDictionaryPair;
begin
  for Pair in Parameters do
    Macros.Add(UpperCase(ParameterMacroPrefix + Pair.Key), Pair.Value);
end;

end.
