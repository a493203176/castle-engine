unit AddVelocityBehavior;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, CastleTransform, CastleBehaviors, CastleVectors,
  CastleComponentSerialize, CastleClassUtils, AbstractTimeDurationBehavior,
  SerializedVectors;

type
  TAddVelocityBehavior = class (TAbstractTimeDurationBehavior)
  private
    {FDeltaVelocity: TVector3;
    FDeltaVelocityPersistent: TCastleVector3Persistent;}
    FDVelocity: TSerializedVector3;
    {function GetDeltaVelocityForPersistent: TVector3;
    procedure SetDeltaVelocity(const AValue: TVector3);
    procedure SetDeltaVelocityForPersistent(const AValue: TVector3);}
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    function PropertySections(const PropertyName: String): TPropertySections; override;

    procedure Update(const SecondsPassed: Single; var RemoveMe: TRemoveType); override;
    {property DeltaVelocity: TVector3 read FDeltaVelocity write SetDeltaVelocity;}
  published
    {property DeltaVelocityPersistent: TCastleVector3Persistent read FDeltaVelocityPersistent;}
    property DVelocity: TSerializedVector3 read FDVelocity;
  end;

implementation

{ TAddVelocityBehavior ------------------------------------------------------- }

{
procedure TAddVelocityBehavior.SetDeltaVelocity(const AValue: TVector3);
begin
  FDeltaVelocity := AValue;
end;

function TAddVelocityBehavior.GetDeltaVelocityForPersistent: TVector3;
begin
  Result := DeltaVelocity;
end;

procedure TAddVelocityBehavior.SetDeltaVelocityForPersistent(
  const AValue: TVector3);
begin
  DeltaVelocity := AValue;
end; }

constructor TAddVelocityBehavior.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  {
  FDeltaVelocityPersistent := TCastleVector3Persistent.Create;
  FDeltaVelocityPersistent.InternalGetValue := {$ifdef FPC}@{$endif}GetDeltaVelocityForPersistent;
  FDeltaVelocityPersistent.InternalSetValue := {$ifdef FPC}@{$endif}SetDeltaVelocityForPersistent;
  FDeltaVelocityPersistent.InternalDefaultValue := DeltaVelocity; // current value is default
  }

  FDVelocity := TSerializedVector3.Create;

  StartTime := 0;
  DurationTime := 0;
end;

destructor TAddVelocityBehavior.Destroy;
begin
  FreeAndNil(FDVelocity);
  {FreeAndNil(FDeltaVelocityPersistent);}
  inherited Destroy;
end;

function TAddVelocityBehavior.PropertySections(const PropertyName: String
  ): TPropertySections;
begin
  if (PropertyName = 'DVelocity') then
    Result := [psBasic]
  else
    Result := inherited PropertySections(PropertyName);
end;

procedure TAddVelocityBehavior.Update(const SecondsPassed: Single;
  var RemoveMe: TRemoveType);
var
  RigidBody: TCastleRigidBody;
begin
  inherited Update(SecondsPassed, RemoveMe);

  if not ShouldUpdate then
    Exit;

  RigidBody := Parent.FindBehavior(TCastleRigidBody) as TCastleRigidBody;
  if (RigidBody <> nil) and (RigidBody.ExistsInRoot) then
  begin
    { RigidBody.LinearVelocity := RigidBody.LinearVelocity + DeltaVelocity; }
    RigidBody.LinearVelocity := RigidBody.LinearVelocity + DVelocity.GetPVector3^;
  end;
end;

initialization

  RegisterSerializableComponent(TAddVelocityBehavior, 'Add Velocity Behavior');

end.

