object Form1: TForm1
  Left = 0
  Top = 0
  Margins.Left = 10
  Caption = 'Form1'
  ClientHeight = 502
  ClientWidth = 1025
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  DesignSize = (
    1025
    502)
  TextHeight = 15
  object LabelFps: TLabel
    Left = 640
    Top = 432
    Width = 46
    Height = 15
    Anchors = [akRight, akBottom]
    Caption = 'LabelFps'
  end
  object Memo1: TMemo
    AlignWithMargins = True
    Left = 638
    Top = 10
    Width = 377
    Height = 412
    Margins.Left = 10
    Margins.Top = 10
    Margins.Right = 10
    Margins.Bottom = 80
    Align = alRight
    ScrollBars = ssBoth
    TabOrder = 0
    ExplicitLeft = 632
    ExplicitHeight = 403
  end
  object Button3D: TButton
    Left = 726
    Top = 469
    Width = 75
    Height = 25
    Anchors = [akRight, akBottom]
    Caption = '3D'
    TabOrder = 1
    OnClick = Button3DClick
    ExplicitLeft = 720
    ExplicitTop = 460
  end
  object Button2D: TButton
    Left = 835
    Top = 469
    Width = 75
    Height = 25
    Anchors = [akRight, akBottom]
    Caption = '2D'
    TabOrder = 2
    OnClick = Button2DClick
    ExplicitLeft = 829
    ExplicitTop = 460
  end
  object ButtonUI: TButton
    Left = 940
    Top = 469
    Width = 75
    Height = 25
    Anchors = [akRight, akBottom]
    Caption = 'UI'
    TabOrder = 3
    OnClick = ButtonUIClick
    ExplicitLeft = 934
    ExplicitTop = 460
  end
  object CastleControl: TCastleControl
    AlignWithMargins = True
    Left = 10
    Top = 10
    Width = 608
    Height = 482
    Margins.Left = 10
    Margins.Top = 10
    Margins.Right = 10
    Margins.Bottom = 10
    Align = alClient
    ExplicitLeft = 64
    ExplicitTop = 56
    ExplicitWidth = 425
    ExplicitHeight = 409
  end
  object Timer1: TTimer
    OnTimer = Timer1Timer
    Left = 920
    Top = 336
  end
end
