{
  Copyright 2022-2022 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Control with OpenGL context on a Delphi VCL form. }
unit Vcl.CastleControl;

{$I castleconf.inc}

interface

uses SysUtils, Classes, Vcl.Controls, Vcl.ExtCtrls,
  CastleGLVersion, CastleGLUtils, CastleInternalContextWgl, CastleInternalContainer,
  CastleVectors, CastleKeysMouse;

type
  { Control rendering OpenGL on VCL form. }
  TCastleControl = class(TCustomControl)
  strict private
    type
      { Non-abstract implementation of TCastleContainer that cooperates with
        TCastleControl. }
      TContainer = class(TCastleContainerEasy)
      private
        Parent: TCastleControl;
        class var
          UpdatingTimer: TTimer;
        class procedure UpdatingTimerEvent(Sender: TObject);
      protected
        function GetMousePosition: TVector2; override;
        procedure SetMousePosition(const Value: TVector2); override;
        procedure AdjustContext(const AContext: TGLContextWGL); override;
        class procedure UpdatingEnable; override;
        class procedure UpdatingDisable; override;
      public
        constructor Create(AParent: TCastleControl); reintroduce;
        procedure Invalidate; override;
        function Width: Integer; override;
        function Height: Integer; override;
        procedure SetInternalCursor(const Value: TMouseCursor); override;
        function Dpi: Single; override;
      end;

    var
      FContainer: TContainer;
      FMousePosition: TVector2;

    { Call whenever you have new knowledge about new shift state.

      Sometimes, releasing shift / alt / ctrl keys will not be reported
      properly to KeyDown / KeyUp. Example: opening a menu
      through Alt+F for "_File" will make keydown for Alt,
      but not keyup for it, and DoExit will not be called,
      so ReleaseAllKeysAndMouse will not be called.

      To counteract this, call this method when Shift state is known,
      to update Pressed when needed. }
    procedure UpdateShiftState(const Shift: TShiftState);
  protected
    procedure CreateHandle; override;
    procedure DestroyHandle; override;
    { // TODO
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyUp(var Key: Word; Shift: TShiftState); override;
    procedure KeyPress(var Key: Char); override;
    }
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; NewX, NewY: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Paint; override;
  published
    { Access Castle Game Engine container properties and events,
      not specific for FMX. }
    property Container: TContainer read FContainer;
  end;

procedure Register;

implementation

uses Windows,
  CastleRenderOptions, CastleApplicationProperties, CastleRenderContext,
  CastleRectangles, CastleUIControls;

procedure Register;
begin
  RegisterComponents('Castle', [
    TCastleControl
  ]);
end;

{ TCastleControl.TContainer ---------------------------------------------------}

constructor TCastleControl.TContainer.Create(AParent: TCastleControl);
begin
  inherited Create(AParent); // AParent must be a component Owner to show published properties of container in LFM
  Parent := AParent;
end;

procedure TCastleControl.TContainer.AdjustContext(const AContext: TGLContextWGL);
begin
  inherited;
  AContext.WndPtr := Parent.Handle;
  AContext.h_Dc := GetWindowDC(AContext.WndPtr);
end;

function TCastleControl.TContainer.Dpi: Single;
begin
  Result := DefaultDpi;
end;

function TCastleControl.TContainer.GetMousePosition: TVector2;
begin
  Result := Parent.FMousePosition;
end;

procedure TCastleControl.TContainer.SetMousePosition(const Value: TVector2);
begin
  // TODO
end;

class procedure TCastleControl.TContainer.UpdatingEnable;
begin
  inherited;
  UpdatingTimer := TTimer.Create(nil);
  UpdatingTimer.Interval := 1;
  UpdatingTimer.OnTimer := {$ifdef FPC}@{$endif} UpdatingTimerEvent;
end;

class procedure TCastleControl.TContainer.UpdatingDisable;
begin
  FreeAndNil(UpdatingTimer);
  inherited;
end;

class procedure TCastleControl.TContainer.UpdatingTimerEvent(Sender: TObject);
begin
  DoUpdateEverything;
end;

function TCastleControl.TContainer.Width: Integer;
begin
  Result := Parent.Width;
end;

function TCastleControl.TContainer.Height: Integer;
begin
  Result := Parent.Height;
end;

procedure TCastleControl.TContainer.Invalidate;
begin
  Parent.Invalidate;
end;

procedure TCastleControl.TContainer.SetInternalCursor(const Value: TMouseCursor);
begin
  // TODO
end;

{ TCastleControl ---------------------------------------------------- }

constructor TCastleControl.Create(AOwner: TComponent);
begin
  inherited;
  FContainer := TContainer.Create(Self);
  FContainer.SetSubComponent(true);
  FContainer.Name := 'Container';
end;

destructor TCastleControl.Destroy;
begin
  inherited;
end;

procedure TCastleControl.CreateHandle;
begin
  inherited;
  { Handle is only available now, in CreateHandle.
    So only now call FContainer.CreateContext that does FContainer.AdjustContext. }
  FContainer.CreateContext;
end;

procedure TCastleControl.DestroyHandle;
begin
  FContainer.DestroyContext;
  inherited;
end;

procedure TCastleControl.MouseDown(Button: TMouseButton; Shift: TShiftState; X,
  Y: Integer);
var
  MyButton: TCastleMouseButton;
begin
  inherited; { VCL OnMouseDown before our callbacks }

  FMousePosition := Vector2(X, Height - 1 - Y);

  if MouseButtonToCastle(Button, MyButton) then
    Container.MousePressed := Container.MousePressed + [MyButton];

  UpdateShiftState(Shift); { do this after Pressed update above, and before *Event }

  if MouseButtonToCastle(Button, MyButton) then
    Container.EventPress(InputMouseButton(FMousePosition, MyButton, 0,
      ModifiersDown(Container.Pressed)));
end;

procedure TCastleControl.MouseMove(Shift: TShiftState; NewX, NewY: Integer);
begin
  inherited;

  Container.EventMotion(InputMotion(FMousePosition,
    Vector2(NewX, Height - 1 - NewY), Container.MousePressed, 0));

  // change FMousePosition *after* EventMotion, callbacks may depend on it
  FMousePosition := Vector2(NewX, Height - 1 - NewY);

  UpdateShiftState(Shift);
end;

procedure TCastleControl.MouseUp(Button: TMouseButton; Shift: TShiftState; X,
  Y: Integer);
var
  MyButton: TCastleMouseButton;
begin
  inherited; { VCL OnMouseUp before our callbacks }

  FMousePosition := Vector2(X, Height - 1 - Y);

  if MouseButtonToCastle(Button, MyButton) then
    Container.MousePressed := Container.MousePressed - [MyButton];

  UpdateShiftState(Shift); { do this after Pressed update above, and before *Event }

  if MouseButtonToCastle(Button, MyButton) then
    Container.EventRelease(InputMouseButton(FMousePosition, MyButton, 0));
end;

procedure TCastleControl.Paint;
begin
  //inherited; // inherited not needed, and possibly causes something unnecessary
  FContainer.DoRender;
end;

procedure TCastleControl.UpdateShiftState(const Shift: TShiftState);
begin
  Container.Pressed.Keys[keyShift] := ssShift in Shift;
  Container.Pressed.Keys[keyAlt  ] := ssAlt   in Shift;
  Container.Pressed.Keys[keyCtrl ] := ssCtrl  in Shift;
end;

end.
