object AppsViewMainFrm: TAppsViewMainFrm
  Left = 0
  Top = 0
  ActiveControl = lbApps
  Caption = 'Apps View'
  ClientHeight = 853
  ClientWidth = 1427
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -16
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poMainFormCenter
  OnActivate = FormActivate
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnKeyUp = FormKeyUp
  OnShow = FormShow
  TextHeight = 21
  object Splitter1: TSplitter
    Left = 500
    Top = 0
    Height = 853
  end
  object pnlAppDetails: TPanel
    AlignWithMargins = True
    Left = 506
    Top = 3
    Width = 418
    Height = 847
    Align = alClient
    TabOrder = 0
    object imgAppScreenshot: TImage
      AlignWithMargins = True
      Left = 4
      Top = 4
      Width = 179
      Height = 839
      Align = alLeft
      AutoSize = True
      Proportional = True
    end
    object pnlAppDetailInfo: TPanel
      Left = 186
      Top = 1
      Width = 231
      Height = 845
      Align = alClient
      BevelOuter = bvNone
      ShowCaption = False
      TabOrder = 0
      object edAppFileName: TEdit
        AlignWithMargins = True
        Left = 3
        Top = 88
        Width = 225
        Height = 29
        Margins.Top = 0
        Align = alTop
        TabOrder = 1
      end
      object lapAppCaption: TStaticText
        AlignWithMargins = True
        Left = 3
        Top = 3
        Width = 225
        Height = 25
        Margins.Bottom = 0
        Align = alTop
        Caption = 'lapAppCaption'
        TabOrder = 2
      end
      object edAppCaption: TEdit
        AlignWithMargins = True
        Left = 3
        Top = 28
        Width = 225
        Height = 29
        Margins.Top = 0
        Align = alTop
        TabOrder = 0
      end
      object labAppFileName: TStaticText
        AlignWithMargins = True
        Left = 3
        Top = 63
        Width = 225
        Height = 25
        Margins.Bottom = 0
        Align = alTop
        Caption = 'labAppFileName'
        TabOrder = 3
      end
      object labTemplateActiv: TStaticText
        AlignWithMargins = True
        Left = 3
        Top = 123
        Width = 225
        Height = 44
        Align = alTop
        Caption = #9654' template for Active title'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -29
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold, fsUnderline]
        ParentFont = False
        TabOrder = 4
        Visible = False
      end
      object labTemplateInActiv: TStaticText
        AlignWithMargins = True
        Left = 3
        Top = 173
        Width = 225
        Height = 25
        Align = alTop
        Caption = 'template for inactive title'
        TabOrder = 5
        Visible = False
      end
      object btnRestartNvda: TBitBtn
        AlignWithMargins = True
        Left = 3
        Top = 789
        Width = 225
        Height = 48
        Margins.Bottom = 8
        Align = alBottom
        Caption = 'Restart NVDA'
        TabOrder = 6
        OnClick = btnRestartNvdaClick
      end
      object btnRestartExplorer: TBitBtn
        AlignWithMargins = True
        Left = 3
        Top = 671
        Width = 225
        Height = 48
        Margins.Bottom = 8
        Align = alBottom
        Caption = 'Restart Explorer'
        TabOrder = 7
        OnClick = btnRestartExplorerClick
      end
      object btnKillDelphi: TBitBtn
        AlignWithMargins = True
        Left = 3
        Top = 730
        Width = 225
        Height = 48
        Margins.Bottom = 8
        Align = alBottom
        Caption = 'Kill Delphi'
        TabOrder = 8
        OnClick = btnKillDelphiClick
      end
    end
  end
  object pnlApps: TPanel
    Left = 0
    Top = 0
    Width = 500
    Height = 853
    Align = alLeft
    BevelOuter = bvNone
    Caption = 'pnlApps'
    TabOrder = 1
    object labAppTitle: TStaticText
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 494
      Height = 34
      Align = alTop
      AutoSize = False
      Caption = 'Applications (F1)'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -21
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold, fsUnderline]
      ParentFont = False
      TabOrder = 0
    end
    object lbApps: TListBox
      AlignWithMargins = True
      Left = 33
      Top = 43
      Width = 434
      Height = 807
      Align = alClient
      ItemHeight = 21
      Sorted = True
      TabOrder = 1
      OnClick = lbAppsClick
      OnDblClick = lbAppsDblClick
      OnKeyUp = lbAppsKeyUp
    end
    object pnlAppFocusLeft: TPanel
      AlignWithMargins = True
      Left = 3
      Top = 43
      Width = 24
      Height = 807
      Align = alLeft
      Caption = 'Panel1'
      Color = clBlack
      ParentBackground = False
      TabOrder = 2
    end
    object pnlAppsFocusRight: TPanel
      AlignWithMargins = True
      Left = 473
      Top = 43
      Width = 24
      Height = 807
      Align = alRight
      Caption = 'Panel1'
      Color = clBlack
      ParentBackground = False
      TabOrder = 3
    end
  end
  object pnlExplorer: TPanel
    Left = 927
    Top = 0
    Width = 500
    Height = 853
    Align = alRight
    BevelOuter = bvNone
    Caption = 'pnlApps'
    TabOrder = 2
    object labExplorerTitle: TStaticText
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 494
      Height = 34
      Align = alTop
      AutoSize = False
      Caption = 'Explorer (F2)'
      TabOrder = 0
    end
    object lbExplorer: TListBox
      AlignWithMargins = True
      Left = 33
      Top = 43
      Width = 434
      Height = 807
      Align = alClient
      ItemHeight = 21
      Sorted = True
      TabOrder = 1
      OnClick = lbAppsClick
      OnDblClick = lbAppsDblClick
      OnKeyUp = lbAppsKeyUp
    end
    object pnlExplorerFocusLeft: TPanel
      AlignWithMargins = True
      Left = 3
      Top = 43
      Width = 24
      Height = 807
      Align = alLeft
      Caption = 'Panel1'
      Color = clBlack
      ParentBackground = False
      TabOrder = 2
    end
    object pnlExplorerFocusRight: TPanel
      AlignWithMargins = True
      Left = 473
      Top = 43
      Width = 24
      Height = 807
      Align = alRight
      Caption = 'Panel1'
      Color = clBlack
      ParentBackground = False
      TabOrder = 3
    end
  end
end
