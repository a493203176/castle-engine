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

{ Load tiled map created by Tiled. (See https://www.mapeditor.org/) }
unit X3DLoadInternalTiledMap;

{$I castleconf.inc}

interface

uses
  Classes, SysUtils,
  X3DNodes, CastleTiledMap, CastleVectors, CastleTransform, CastleColors;

function LoadTiledMap2d(const URL: String): TX3DRootNode;

implementation

function BuildSceneFromTiledMap(Map: TTiledMap): TX3DRootNode;
var
  { All general variables to built the scene. }
  RootTransformNode: TTransformNode;  // The root node of the scene.
  Layer: TTiledMap.TLayer;            // A (tile, object, image) layer
  LayerTransformNode: TTransformNode; // Node of a (tile, object, image) layer.

  function CalcObjLayerHeight: Cardinal;
  begin
    Result := Map.Height * Map.TileHeight;
  end;

  { This function creates and builds a transform node from the Object Group
    Layer data. }
  function BuildObjectGroupLayer(const ALayer: TTiledMap.TLayer): TTransformNode;
  var
    ObjMaterial: TMaterialNode = nil;       // Material node of a TiledObject.
    TiledObj: TTiledMap.TTiledObject;       // A TiledObject.
    ObjTransformNode: TTransformNode = nil; // Transform node of a TiledObject.
    ObjPolyNode: TPolyline2DNode = nil;     // Geometry node of a TiledObject primitive.
    ObjShapeNode: TShapeNode = nil;         // Shape node of a TiledObject.
    ObjVector2List: TVector2List = nil;     // Helper list.

    procedure CalcVectorListFromRect(const AVector2List: TVector2List;
    const w, h: Single);
    begin
      AVector2List.Add(Vector2(0, 0));
      AVector2List.Add(Vector2(w, 0));
      AVector2List.Add(Vector2(w, h));
      AVector2List.Add(Vector2(0, h));
      AVector2List.Add(AVector2List.Items[0]);
    end;

  begin
    { All TiledObjects of this layer share the same material node. }
    ObjMaterial := TMaterialNode.Create;
    ObjMaterial.EmissiveColor := ALayer.Color;

    ObjVector2List := TVector2List.Create;  // Helper list.
    Result := TTransformNode.Create;        // The resulting layer node.

    for TiledObj in (ALayer as TTiledMap.TObjectGroupLayer).Objects do
    begin
      if not TiledObj.Visible then
        Continue;

      { Every TiledObject has its own root transform node. }
      ObjTransformNode := TTransformNode.Create;
      ObjTransformNode.Translation := Vector3(ALayer.Offset.X + TiledObj.Position.X,
      ALayer.Offset.Y + TiledObj.Position.Y, 0);
      { Every primitive is implemented as polyline node. Hint: For better
        performance rectangle and point could be implemented as rect. node?}
      ObjPolyNode := TPolyline2DNode.CreateWithShape(ObjShapeNode);
      case TiledObj.Primitive of
        topPolyline:
          begin
            ObjVector2List.Clear;
            ObjVector2List.Assign(TiledObj.Points);
            ObjPolyNode.SetLineSegments(ObjVector2List);
          end;
        topPolygon:
          begin
            ObjVector2List.Clear;
            ObjVector2List.Assign(TiledObj.Points);
            { add point with index 0 to points list to get a closed polygon }
            ObjVector2List.Add(ObjVector2List.Items[0]);
            ObjPolyNode.SetLineSegments(ObjVector2List);
          end;
        topRectangle:
          begin
            ObjVector2List.Clear;
            CalcVectorListFromRect(ObjVector2List, TiledObj.Width,
              TiledObj.Height);
            ObjPolyNode.SetLineSegments(ObjVector2List);
          end;
        topPoint:
          begin
            ObjVector2List.Clear;
            CalcVectorListFromRect(ObjVector2List, 1, 1);
            { A point is a rectangle with width and height of 1 unit. }
            ObjPolyNode.SetLineSegments(ObjVector2List);
          end;
        // TODO: handle ellipse
      end;
      ObjShapeNode.Material := ObjMaterial;
      ObjTransformNode.AddChildren(ObjShapeNode);
      Result.AddChildren(ObjTransformNode);
    end;
    FreeAndNil(ObjVector2List);
  end;

  { This function creates and builds a transform node from the Tile Layer data. }
  function BuildTileLayer(const ALayer: TTiledMap.TLayer): TTransformNode;
  var
    Tile: TTiledMap.TTile;                  // A Tile.
    Tileset: TTiledMap.TTileset;            // A Tileset.
    I: Cardinal;

    { The X3D tile node are constructred from these nodes. }
    TileShapeNode: TShapeNode;
    TileMaterialNode: TMaterialNode;
    TileImageTexNode: TImageTextureNode;
    TileTexPropertiesNode: TTexturePropertiesNode;
    CoordNode: TCoordinateNode;
    TexCoordNode: TTextureCoordinateNode;
    TriSetNode: TTriangleSetNode;



    { Get the associated tileset of a specific tile by the tileset's FirstGID.

      TODO : Handle flipped tiles. The tileset alloction may be wrong otherwise!
      }
    function GetTilesetOfTile(const ATileGID: Cardinal): TTiledMap.TTileset;
    var
      J: Cardinal;
    begin
      Result := Map.Tilesets.Items[0];
      if Map.Tilesets.Count = 1 then
        Exit
      else
      begin
        { "In order to find out from which tileset the tile is you need to find
          the tileset with the highest firstgid that is still lower or equal
          than the gid.The tilesets are always stored with increasing
          firstgids."
          (https://doc.mapeditor.org/en/stable/reference/tmx-map-format/#tmx-data) }
        for J := 1 to Map.Tilesets.Count - 1 do
        begin
          if ATileGID >= (Map.Tilesets.Items[J] as TTiledMap.TTileset).FirstGID then
            Result := Map.Tilesets.Items[J];
        end;

        { "The highest three bits of the gid store the flipped states. Bit 32 is
          used for storing whether the tile is horizontally flipped, bit 31 is used
          for the vertically flipped tiles and bit 30 indicates whether the tile is
          flipped (anti) diagonally, enabling tile rotation. These bits have to be
          read and cleared before you can find out which tileset a tile belongs to."
          https://doc.mapeditor.org/en/stable/reference/tmx-map-format/#data }

        { TODO : Handle flipped tiles! }
      end;
    end;

    { Get a specific tile by its GID from a specific tileset. }
    function GetTileFromTileset(ATileGID: Cardinal; ATileset: TTiledMap.TTileset): TTiledMap.TTile;
    var
      J: Cardinal;
      TilesetTileGID: Cardinal; // TTile.Id are local with resp. to tileset
    begin
      Result := nil;
      for J := 0 to ATileset.Tiles.Count - 1 do
      begin
        { Convert local tile id to GID. }
        TilesetTileGID := ATileset.FirstGID +
          (ATileset.Tiles.Items[J] as TTiledMap.TTile).Id;

        if TilesetTileGID = ATileGID then
        begin
          Result := ATileset.Tiles.Items[J];
          Exit;
        end;
      end;
    end;

  begin
    Result := TTransformNode.Create;        // The resulting layer node.

    { Run through tile GIDs of this tile layer found in ALayer.Data.Data. }
    for I := 0 to High(ALayer.Data.Data) do
    begin
      { Get tileset and tile ready to prepare "x3d tile node". }
      //Writeln(I, ' --> GID: ', ALayer.Data.Data[I]);
      Tileset := GetTilesetOfTile(ALayer.Data.Data[I]);
      Tile := GetTileFromTileset(ALayer.Data.Data[I], Tileset);
      //writeln('Local Tile ID: ', Tile.Id, ' --> Tileset: ',
      //  Tileset.Name, ' (FGID: ', Tileset.FirstGID, ')');

      { Create "x3d tile node" for each tile. }
      // For testing only the first tile should be handled! Delete later!
      if I > 0 then
        Continue;

      TileShapeNode := TShapeNode.Create;
      TileShapeNode.Appearance := TAppearanceNode.Create;

      { Define material of X3D tile. }
      TileMaterialNode := TMaterialNode.Create;
      TileMaterialNode.DiffuseColor := Vector3(0, 0, 0);
      TileMaterialNode.SpecularColor := Vector3(0, 0, 0);
      TileMaterialNode.AmbientIntensity := 0;
      TileMaterialNode.EmissiveColor := Vector3(1, 1, 1);
      TileShapeNode.Material := TileMaterialNode;

      TileImageTexNode := TImageTextureNode.Create;
      TileImageTexNode.RepeatS := false;
      TileImageTexNode.RepeatT := false;
      TileImageTexNode.SetUrl(['castle-data:/tmw_desert_spacing.png']);
      TileTexPropertiesNode:= TTexturePropertiesNode.Create;
      TileTexPropertiesNode.FdMagnificationFilter.Send('NEAREST_PIXEL');
      TileTexPropertiesNode.FdMinificationFilter.Send('NEAREST_PIXEL');
      TileImageTexNode.FdTextureProperties.Value := TileTexPropertiesNode;

      TileShapeNode.Texture := TileImageTexNode;

      TriSetNode := TTriangleSetNode.Create;
      TriSetNode.Solid := false;
      TileShapeNode.FdGeometry.Value := TriSetNode;

      CoordNode := TCoordinateNode.Create;
      TexCoordNode := TTextureCoordinateNode.Create;

      CoordNode.FdPoint.Items.AddRange([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)]);
      TexCoordNode.FdPoint.Items.AddRange([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)]);

      TriSetNode.FdCoord.Value := CoordNode;
      TriSetNode.FdTexCoord.Value := TexCoordNode;

      //CoordNode.FdPoint.Items.Capacity := VERTEX_BUFFER;
      //TexCoordNode.FdPoint.Items.Capacity := VERTEX_BUFFER;

      Result.AddChildren(TileShapeNode);
    end;
  end;

begin
  { Root node for scene. }
  RootTransformNode := TTransformNode.Create;

  for Layer in Map.Layers do
  begin
    if not Layer.Visible then
      Continue;

    { Every Layer has an individual layer node. }
    LayerTransformNode := nil;

    if (Layer is TTiledMap.TObjectGroupLayer) then
    begin
      LayerTransformNode := BuildObjectGroupLayer(Layer);
    end else
    if (Layer is TTiledMap.TImageLayer) then
    begin
      { TODO : Implement!
        LayerTransformNode := BuildImageLayer(Layer); }
    end else
    begin
      LayerTransformNode := BuildTileLayer(Layer);
    end;

    if Assigned(LayerTransformNode) then
      RootTransformNode.AddChildren(LayerTransformNode);
  end;

  RootTransformNode.Rotation := Vector4(1, 0, 0, Pi);  // rotate scene by 180 deg around x-axis

  Result := TX3DRootNode.Create;
  Result.AddChildren(RootTransformNode);
end;

function LoadTiledMap2d(const URL: String): TX3DRootNode;
var
  ATiledMap: TTiledMap;
begin
  Result := nil;
  ATiledMap := TTiledMap.Create(URL);
  try
    Result := BuildSceneFromTiledMap(ATiledMap);
  finally
    FreeAndNil(ATiledMap);
  end;
end;

end.

