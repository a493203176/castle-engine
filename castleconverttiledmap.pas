{
  Copyright 2020-2021 Matthias J. Molski.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Convert Tiled map (see https://www.mapeditor.org/) loaded by
  CastleTiledMap unit into X3D representation.

  This unit is on purpose not fully integrated with the engine yet. This makes
  debugging easier. If unit is fully functional, it should be integrated with
  the Scene.Load mechanism. Until then it works as follows:

  1. Create Tiled map (TTiledMap).
  2. Prepare X3D scene.
  3. Convert Tiled map by this unit (CastleConvertTiledMap).
  4. Load X3D scene directly by X3D representation (use Scene.Load).

  TODO:
  1. Integrate unit with Castle Game Engine (e.g. add to pack., use castle conf.
     inc., ...)
  2. Turn off debug mode.
  3. Check SetDebugMode: RemoveChildren free's instance of node?

  REMARKS:
  1. Coordinate systems: The Tiled editor uses a classical coordinate system
     with origin (0,0) at top-left position. The CGE uses the OpenGL coordinate
     system with origin (0,0) at bottom-left. The conversion of coordinates
     works as follows: The top-left position of the Tiled map is placed at the
     origin of the CGE coordinate system. A simple translation of the Map node
     by height, it can be switched to CGE convention.

}
unit CastleConvertTiledMap;

//{$I castleconf.inc}

interface

uses
  Classes, Math,
  X3DNodes, CastleTiledMap, CastleVectors, CastleTransform, CastleColors,
  CastleRenderOptions, X3DLoadInternalImage;

{ Converts a Tiled map into a X3D representation for the Castle Game Engine.
  The result can be returned to Scene.Load method. }
function ConvertTiledMap(ATiledMap: TTiledMap): TX3DRootNode;

implementation

uses
  SysUtils;

type
  { Converter class to convert Tiled map into X3D representations. }

  { TTiledMapConverter }

  TTiledMapConverter = class
  strict private
    FDebugMode: Boolean;
    FDebugNode: TX3DRootNode;

    FMap: TTiledMap;
    FMapNode: TX3DRootNode;

    { Tries to construct X3D nodes for each layer. }
    procedure ConvertLayers;
    { Builds Object Group layer node from TTiledMap data. }
    function BuildObjectGroupLayerNode(const ALayer: TTiledMap.TLayer): TTransformNode;
    { Builds Tile layer node from TTiledMap data. }
    function BuildTileLayerNode(const ALayer: TTiledMap.TLayer): TTransformNode;

    { Helper functions }
    { Map width in pixels. }
    function MapWidth: Cardinal;
    { Map height in pixels. }
    function MapHeight: Cardinal;

    { Build a reference 3d coordinate system with description of axis and
      origin. It is slightly moved along Z-axis to be infront of everything. }
    procedure BuildDebugCoordinateSystem;
    { Build a rectangluar debug object at pos. X,Y with dim. W,H. }
    procedure BuildDebugObject(const X, Y, W, H: Cardinal; const AName: String);
    { Makes sure that a Debug node is added/removed from Map node list and
      is constructed/destroyed accordingly. }
    procedure SetDebugMode(AValue: Boolean);
    { This node holds all debug nodes and is added to MapNode if debug mode is
      on. This is important for automatic free'ing of all debug objects. }
    property DebugNode: TX3DRootNode read FDebugNode write FDebugNode;
  public
    constructor Create;
    destructor Destroy; override;

    { Tries to construct X3D representation from TTiledMap data. }
    procedure ConvertMap;

    property Map: TTiledMap read FMap write FMap;
    { Holds the X3D representation of the Tiled map. Is not free'd
      automatically.

      TODO : What if MapNode is never returned and manually free'd?
      Improve by getter func.! }
    property MapNode: TX3DRootNode read FMapNode;

    { If true, all objects are represented in debug mode. }
    property DebugMode: Boolean read FDebugMode write SetDebugMode;
  end;

procedure TTiledMapConverter.ConvertMap;
begin
  ConvertLayers;
  if DebugMode then
    BuildDebugCoordinateSystem;
  ;
end;

procedure TTiledMapConverter.ConvertLayers;
var
  Layer: TTiledMap.TLayer;            // A (tile, object, image) layer
  LayerTransformNode: TTransformNode; // Node of a (tile, object, image) layer.
begin

  for Layer in Map.Layers do
  begin
    if DebugMode then
      BuildDebugObject(Round(Layer.OffsetX), Round(Layer.OffsetY), MapWidth,
        MapHeight, Layer.Name);

    if not Layer.Visible then
      Continue;

    { Every Layer has an individual layer node. }
    LayerTransformNode := nil;

    if (Layer is TTiledMap.TObjectGroupLayer) then
    begin
      LayerTransformNode := BuildObjectGroupLayerNode(Layer);
    end else
    if (Layer is TTiledMap.TImageLayer) then
    begin
      { TODO : Implement!
        LayerTransformNode := BuildImageLayer(Layer); }
    end else
    begin
      LayerTransformNode := BuildTileLayerNode(Layer);
    end;

    if Assigned(LayerTransformNode) then
      MapNode.AddChildren(LayerTransformNode);
  end;

  //RootTransformNode.Rotation := Vector4(1, 0, 0, Pi);  // rotate scene by 180 deg around x-axis

  //Result := TX3DRootNode.Create;
  //Result.AddChildren(RootTransformNode);
end;

function TTiledMapConverter.BuildObjectGroupLayerNode(
  const ALayer: TTiledMap.TLayer): TTransformNode;
var
  TiledObjectMaterial: TMaterialNode = nil;    // Material node of a Tiled obj.
  TiledObjectInstance: TTiledMap.TTiledObject; // A Tiled object instance (as
                                               // saved in TTiledMap).
  TiledObject: TTransformNode = nil;           // Transform node of a Tiled object.
  TiledObjectGeometry: TPolyline2DNode = nil;  // Geometry node of a TiledObject primitive.
  TiledObjectShape: TShapeNode = nil;          // Shape node of a TiledObject.
  //ObjVector2List: TVector2List = nil;     // Helper list.

begin
  Result := nil;

  for TiledObjectInstance in (ALayer as TTiledMap.TObjectGroupLayer).Objects do
  begin

    if not TiledObjectInstance.Visible then
      Continue;

    { At this point it is clear that at least one visible Tiled object is
      present on the Object group layer. Hence the layer node and the material
      node is created. }
    if not Assigned(Result) then
      Result := TTransformNode.Create;   // Tiled object group layer node.

    { All Tiled objects of this layer share the same material node. The color
      depends on the layer color in accordance with handling of Tiled editor. }
    if not Assigned(TiledObjectMaterial) then
    begin
      TiledObjectMaterial := TMaterialNode.Create;
      TiledObjectMaterial.EmissiveColor := ALayer.Color;
    end;

    { Every Tiled object is based on a transform node. }
    TiledObject := TTransformNode.Create;
    TiledObject.Translation := Vector3(ALayer.Offset.X +
      TiledObjectInstance.Position.X, ALayer.Offset.Y +
      TiledObjectInstance.Position.Y, 0);

    { Every primitive is implemented as polyline node. Hint: For better
      performance rectangle and point could be implemented as rect. node?}
    TiledObjectGeometry := TPolyline2DNode.CreateWithShape(TiledObjectShape);
    case TiledObjectInstance.Primitive of
      topPolyline:
        begin
          //ObjVector2List.Clear;
          //ObjVector2List.Assign(TiledObj.Points);
          //ObjPolyNode.SetLineSegments(ObjVector2List);
        end;
      topPolygon:
        begin
          //ObjVector2List.Clear;
          //ObjVector2List.Assign(TiledObj.Points);
          //{ add point with index 0 to points list to get a closed polygon }
          //ObjVector2List.Add(ObjVector2List.Items[0]);
          //ObjPolyNode.SetLineSegments(ObjVector2List);
        end;
      topRectangle:
        begin
          //ObjVector2List.Clear;
          //CalcVectorListFromRect(ObjVector2List, TiledObj.Width,
          //  TiledObj.Height);
          TiledObjectGeometry.SetLineSegments([Vector2(0.0, 0.0), Vector2(
            TiledObjectInstance.Width , 0.0), Vector2(TiledObjectInstance.Width,
            TiledObjectInstance.Height), Vector2(0.0,
            TiledObjectInstance.Height), Vector2(0.0, 0.0)]);
        end;
      topPoint:
        begin
          //ObjVector2List.Clear;
          //CalcVectorListFromRect(ObjVector2List, 1, 1);
          //{ A point is a rectangle with width and height of 1 unit. }
          //ObjPolyNode.SetLineSegments(ObjVector2List);
        end;
      // TODO: handle ellipse
    end;
    TiledObjectShape.Material := TiledObjectMaterial;
    TiledObject.AddChildren(TiledObjectShape);
    Result.AddChildren(TiledObject);
  end;
    //FreeAndNil(ObjVector2List);
end;

function TTiledMapConverter.BuildTileLayerNode(const ALayer: TTiledMap.TLayer
  ): TTransformNode;
begin
  Result := TTransformNode.Create;
end;

constructor TTiledMapConverter.Create;
begin
  inherited Create;

  FMapNode := TX3DRootNode.Create;

  DebugMode := True;  // DebugMode := False; // Default
end;

destructor TTiledMapConverter.Destroy;
begin

  inherited Destroy;
end;

function TTiledMapConverter.MapWidth: Cardinal;
begin
  Result := Map.TileWidth * Map.Width;
end;

function TTiledMapConverter.MapHeight: Cardinal;
begin
  Result := Map.TileHeight * Map.Height;
end;

procedure TTiledMapConverter.BuildDebugCoordinateSystem;
var
  { Axis objects. }
  DebugAxisGeom: array[0..2] of TLineSetNode;
  DebugAxisCoord: array[0..2] of TCoordinateNode;
  DebugAxisShape: array[0..2] of TShapeNode;

  { Naming objects. }
  DebugAxisName: array[0..3] of TTransformNode;
  DebugAxisNameGeom: array[0..3] of TTextNode;
  DebugAxisNameShape: array[0..3] of TShapeNode;

  { General objects (and vars.) }
  DebugAxisMaterial: TMaterialNode;
  DebugAxisLineProperties: TLinePropertiesNode;
  I: Byte;
  OriginVector: TVector3;
const
  AxisLength = 50.0;
  AxisNameGap = 10.0; // Gap between end of axis and name
begin
  OriginVector := Vector3(0.0, 0.0, 0.1);

  DebugAxisMaterial := TMaterialNode.Create;
  DebugAxisMaterial.EmissiveColor := RedRGB;

  DebugAxisLineProperties := TLinePropertiesNode.Create;
  DebugAxisLineProperties.LinewidthScaleFactor := 2.0;

  for I := 0 to 2 do
  begin
    { Construct three axis at origin along X, Y and Z. }
    DebugAxisGeom[I] := TLineSetNode.CreateWithShape(DebugAxisShape[I]);
    DebugAxisShape[I].Appearance := TAppearanceNode.Create;
    DebugAxisShape[I].Appearance.Material := DebugAxisMaterial;
    DebugAxisShape[I].Appearance.LineProperties := DebugAxisLineProperties;
    DebugAxisCoord[I] := TCoordinateNode.Create;
    case I of
      0: DebugAxisCoord[I].SetPoint([OriginVector, Vector3(AxisLength, 0.0, 0.1)
           ]); // X-Axis
      1: DebugAxisCoord[I].SetPoint([OriginVector, Vector3(0.0, AxisLength, 0.1)
           ]); // Y-Axis
      2: DebugAxisCoord[I].SetPoint([OriginVector, Vector3(0.0, 0.0,
           0.1 + AxisLength)]); // Z-Axis
    end;
    DebugAxisGeom[I].SetVertexCount([DebugAxisCoord[I].CoordCount]);
    DebugAxisGeom[I].Coord := DebugAxisCoord[I];
    DebugNode.AddChildren(DebugAxisShape[I]);
  end;

  for I := 0 to 3 do
  begin
    { Construct axis description for X-, Y- and Z-axis and origin. }
    DebugAxisNameGeom[I] := TTextNode.CreateWithShape(DebugAxisNameShape[I]);
    DebugAxisNameShape[I].Appearance := TAppearanceNode.Create;
    DebugAxisNameShape[I].Appearance.Material := DebugAxisMaterial;
    case I of
      0: DebugAxisNameGeom[I].SetString(['X']);
      1: DebugAxisNameGeom[I].SetString(['Y']);
      2: DebugAxisNameGeom[I].SetString(['Z']);
      3: DebugAxisNameGeom[I].SetString(['O']);
    end;
    DebugAxisNameGeom[I].FontStyle := TFontStyleNode.Create;
    DebugAxisNameGeom[I].FontStyle.Size := 10.0;
    DebugAxisName[I] := TTransformNode.Create;
    case I of
      0: DebugAxisName[I].Translation := Vector3(AxisLength + AxisNameGap, 0.0,
           0.1);
      1: DebugAxisName[I].Translation := Vector3(0.0, AxisLength + AxisNameGap,
           0.1);
      2: DebugAxisName[I].Translation := Vector3(0.0, 0.0, AxisLength +
           AxisNameGap);
      3: DebugAxisName[I].Translation := Vector3(-AxisNameGap, -AxisNameGap,
           0.1);
    end;
    DebugAxisName[I].AddChildren(DebugAxisNameShape[I]);
    DebugNode.AddChildren(DebugAxisName[I]);
  end;
end;

procedure TTiledMapConverter.BuildDebugObject(const X, Y, W, H: Cardinal;
  const AName: String);
var
  { All Debug objects are based on a Transform node. }
  DebugObject: TTransformNode = nil;
  { Outline-Debug object. }
  { Hint: TRectangle2DNode is always filled, even if TFillPropertiesNode has
    property filled set to false. }
  DebugGeometryOutline: TPolyline2DNode = nil;
  DebugShapeOutline: TShapeNode = nil;
  { Name-Debug object. }
  DebugGeometryName: TTextNode = nil;
  DebugShapeName: TShapeNode = nil;

  DebugMaterial: TMaterialNode = nil;
  DebugLineProperties: TLinePropertiesNode = nil;
begin
  { Build Outline-Debug object. }
  DebugGeometryOutline := TPolyline2DNode.CreateWithShape(DebugShapeOutline);
  { Create anti-clockwise rectangle. }
  DebugGeometryOutline.SetLineSegments([Vector2(0.0, 0.0),
  Vector2(Single(W), 0.0), Vector2(Single(W), Single(H)),
  Vector2(0.0, Single(H)), Vector2(0.0, 0.0)]);

  { Build Name-Debug object. }
  DebugGeometryName := TTextNode.CreateWithShape(DebugShapeName);
  DebugGeometryName.SetString(AName);
  DebugGeometryName.FontStyle := TFontStyleNode.Create;
  DebugGeometryName.FontStyle.Size := 20.0;

  { Use the same material and line property node for Outline- and
    Name-Debug object. }
  DebugMaterial := TMaterialNode.Create;
  DebugMaterial.EmissiveColor := YellowRGB;

  DebugLineProperties := TLinePropertiesNode.Create;
  DebugLineProperties.LinewidthScaleFactor := 2.0;

  DebugShapeOutline.Appearance := TAppearanceNode.Create;
  DebugShapeOutline.Appearance.Material := DebugMaterial;
  DebugShapeOutline.Appearance.LineProperties := DebugLineProperties;

  DebugShapeName.Appearance := TAppearanceNode.Create;
  DebugShapeName.Appearance.Material := DebugMaterial;
  DebugShapeName.Appearance.LineProperties := DebugLineProperties;

  { Create Debug transform node for Outline- and NameDebug nodes. Add them to
    the Debug node. }
  DebugObject := TTransformNode.Create;
  DebugObject.Translation := Vector3(Single(X), Single(Y), 0.0);
  DebugObject.AddChildren(DebugShapeOutline);
  DebugNode.AddChildren(DebugObject);

  DebugObject := TTransformNode.Create;
  DebugObject.Translation := Vector3(Single(X+10), Single(Y+10), 0.0);
  DebugObject.AddChildren(DebugShapeName);
  DebugNode.AddChildren(DebugObject);
end;

procedure TTiledMapConverter.SetDebugMode(AValue: Boolean);
begin
  if FDebugMode = AValue then
    Exit;
  FDebugMode:=AValue;
  case FDebugMode of
    True:
      begin
        if Assigned(DebugNode) then
          FreeAndNil(FDebugNode);
        DebugNode := TX3DRootNode.Create;
        MapNode.AddChildren(DebugNode);
      end;
    False:
      begin
        MapNode.RemoveChildren(DebugNode);
        { TODO: Check if RemoveChildren also free's instance of the node.
          Would make manual free'ing here obsolete. }
        if Assigned(DebugNode) then
          FreeAndNil(FDebugNode);
      end;
  end;
end;

function ConvertTiledMap(ATiledMap: TTiledMap): TX3DRootNode;
var
  ATiledMapConverter: TTiledMapConverter;
begin
  Result := nil;

  if not Assigned(ATiledMap) then
    Exit;

  try
    ATiledMapConverter := TTiledMapConverter.Create;
    ATiledMapConverter.Map := ATiledMap;
    ATiledMapConverter.ConvertMap;
    Result := ATiledMapConverter.MapNode;
  finally
    FreeAndNil(ATiledMapConverter);
  end;

end;

end.

