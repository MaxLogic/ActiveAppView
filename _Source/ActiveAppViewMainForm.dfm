object AppsViewMainFrm: TAppsViewMainFrm
  Left = 0
  Top = 0
  ActiveControl = lbApps
  Caption = 'Apps View'
  ClientHeight = 853
  ClientWidth = 2500
  Color = clWindow
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -13
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
    AlignWithMargins = True
    Left = 509
    Top = 3
    Height = 847
    Align = alRight
  end
  object Splitter3: TSplitter
    AlignWithMargins = True
    Left = 1018
    Top = 3
    Height = 847
    Align = alRight
  end
  object Splitter4: TSplitter
    AlignWithMargins = True
    Left = 1424
    Top = 3
    Height = 847
    Align = alRight
  end
  object Splitter5: TSplitter
    AlignWithMargins = True
    Left = 1780
    Top = 3
    Height = 847
    Align = alRight
  end
  object Splitter6: TSplitter
    AlignWithMargins = True
    Left = 2136
    Top = 3
    Height = 847
    Align = alRight
  end
  object pnlApps: TPanel
    Left = 0
    Top = 0
    Width = 506
    Height = 853
    Align = alClient
    BevelOuter = bvNone
    Caption = 'pnlApps'
    Color = clWindow
    ParentBackground = False
    ShowCaption = False
    TabOrder = 0
    object Splitter2: TSplitter
      AlignWithMargins = True
      Left = 3
      Top = 483
      Width = 500
      Height = 3
      Cursor = crVSplit
      Align = alBottom
    end
    object labAppTitle: TStaticText
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 500
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
    object chkChatNotificationSound: TCheckBox
      AlignWithMargins = True
      Left = 33
      Top = 43
      Width = 440
      Height = 29
      Margins.Top = 3
      Margins.Bottom = 0
      Align = alTop
      Caption = 'Play chat notification sounds'
      Checked = True
      State = cbChecked
      TabOrder = 1
      OnClick = chkChatNotificationSoundClick
    end
    object lbApps: TListBox
      AlignWithMargins = True
      Left = 33
      Top = 75
      Width = 440
      Height = 402
      Align = alClient
      ItemHeight = 21
      Sorted = True
      TabOrder = 2
      OnClick = lbAppsClick
      OnDblClick = lbAppsDblClick
      OnKeyUp = lbAppsKeyUp
    end
    object pnlAppFocusLeft: TPanel
      AlignWithMargins = True
      Left = 3
      Top = 75
      Width = 24
      Height = 402
      Align = alLeft
      Caption = 'Panel1'
      Color = clBlack
      ParentBackground = False
      ShowCaption = False
      TabOrder = 3
    end
    object pnlAppsFocusRight: TPanel
      AlignWithMargins = True
      Left = 479
      Top = 75
      Width = 24
      Height = 402
      Align = alRight
      Caption = 'Panel1'
      Color = clBlack
      ParentBackground = False
      ShowCaption = False
      TabOrder = 4
    end
    object pnlAppDetails: TPanel
      AlignWithMargins = True
      Left = 3
      Top = 492
      Width = 500
      Height = 358
      Align = alBottom
      BevelOuter = bvNone
      Color = clWindow
      ParentBackground = False
      ShowCaption = False
      TabOrder = 5
      object imgAppScreenshot: TImage
        AlignWithMargins = True
        Left = 4
        Top = 4
        Width = 179
        Height = 350
        Align = alLeft
        AutoSize = True
        Proportional = True
      end
      object pnlAppDetailInfo: TPanel
        Left = 186
        Top = 1
        Width = 313
        Height = 356
        Align = alClient
        BevelOuter = bvNone
        Color = clWindow
        ParentBackground = False
        ShowCaption = False
        TabOrder = 0
        object edAppFileName: TEdit
          AlignWithMargins = True
          Left = 3
          Top = 88
          Width = 307
          Height = 29
          Margins.Top = 0
          Align = alTop
          TabOrder = 1
        end
        object labAppFileName: TStaticText
          AlignWithMargins = True
          Left = 3
          Top = 63
          Width = 307
          Height = 25
          Margins.Bottom = 0
          Align = alTop
          AutoSize = False
          Caption = 'Filename'
          TabStop = False
          TabOrder = 3
        end
        object edAppCaption: TEdit
          AlignWithMargins = True
          Left = 3
          Top = 28
          Width = 307
          Height = 29
          Margins.Top = 0
          Align = alTop
          TabOrder = 0
        end
        object lapAppCaption: TStaticText
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 307
          Height = 25
          Margins.Bottom = 0
          Align = alTop
          AutoSize = False
          Caption = 'Application Title'
          TabStop = False
          TabOrder = 2
        end
        object edCommandLineParams: TEdit
          AlignWithMargins = True
          Left = 3
          Top = 148
          Width = 307
          Height = 29
          Margins.Top = 0
          Align = alTop
          TabOrder = 4
        end
        object labCommandLineParams: TStaticText
          AlignWithMargins = True
          Left = 3
          Top = 123
          Width = 307
          Height = 25
          Margins.Bottom = 0
          Align = alTop
          AutoSize = False
          Caption = 'CommandLine params (not reliable for PWAs)'
          TabStop = False
          TabOrder = 5
        end
        object edPID: TEdit
          AlignWithMargins = True
          Left = 3
          Top = 208
          Width = 307
          Height = 29
          Margins.Top = 0
          Align = alTop
          TabOrder = 6
        end
        object labPid: TStaticText
          AlignWithMargins = True
          Left = 3
          Top = 183
          Width = 307
          Height = 25
          Margins.Bottom = 0
          Align = alTop
          AutoSize = False
          Caption = 'PID'
          TabStop = False
          TabOrder = 7
        end
        object edAppUserModelID: TEdit
          AlignWithMargins = True
          Left = 3
          Top = 268
          Width = 307
          Height = 29
          Margins.Top = 0
          Align = alTop
          TabOrder = 8
        end
        object labAppUserModelID: TStaticText
          AlignWithMargins = True
          Left = 3
          Top = 243
          Width = 307
          Height = 25
          Margins.Bottom = 0
          Align = alTop
          AutoSize = False
          Caption = 'AppUserModelID'
          TabStop = False
          TabOrder = 9
        end
        object edRelaunchCommand: TEdit
          AlignWithMargins = True
          Left = 3
          Top = 328
          Width = 307
          Height = 29
          Margins.Top = 0
          Align = alTop
          TabOrder = 10
        end
        object labRelaunchCommand: TStaticText
          AlignWithMargins = True
          Left = 3
          Top = 303
          Width = 307
          Height = 25
          Margins.Bottom = 0
          Align = alTop
          AutoSize = False
          Caption = 'RelaunchCommand (Edge PWA)'
          TabStop = False
          TabOrder = 11
        end
      end
    end
    object Panel1: TPanel
      Left = 264
      Top = 120
      Width = 185
      Height = 89
      BevelOuter = bvNone
      Caption = ''
      Color = clWindow
      ParentBackground = False
      ShowCaption = False
      TabOrder = 5
      Visible = False
      object labTemplateActiv: TStaticText
        AlignWithMargins = True
        Left = 4
        Top = 4
        Width = 177
        Height = 44
        Align = alTop
        Caption = #9654' template for Active title'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -15
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
        TabOrder = 0
        Visible = False
      end
      object labTemplateInActiv: TStaticText
        AlignWithMargins = True
        Left = 4
        Top = 54
        Width = 177
        Height = 25
        Align = alTop
        Caption = 'template for inactive title'
        TabStop = False
        TabOrder = 1
        Visible = False
      end
    end
  end
  object pnlExplorer: TPanel
    Left = 515
    Top = 0
    Width = 500
    Height = 853
    Align = alRight
    BevelOuter = bvNone
    Caption = 'pnlExplorer'
    Color = clWindow
    ParentBackground = False
    ShowCaption = False
    TabOrder = 1
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
      ShowCaption = False
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
      ShowCaption = False
      TabOrder = 3
    end
  end
  object pnlScripts: TPanel
    Left = 1024
    Top = 0
    Width = 403
    Height = 853
    Align = alRight
    BevelOuter = bvNone
    Caption = 'pnlScripts'
    Color = clWindow
    ParentBackground = False
    ShowCaption = False
    TabOrder = 2
    object labScriptsTitle: TStaticText
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 397
      Height = 34
      Align = alTop
      AutoSize = False
      Caption = 'Scripts (F3)'
      TabOrder = 0
    end
    object lbScripts: TListBox
      AlignWithMargins = True
      Left = 33
      Top = 43
      Width = 337
      Height = 807
      Align = alClient
      ItemHeight = 21
      Sorted = True
      TabOrder = 1
      OnDblClick = lbScriptsDblClick
      OnKeyUp = lbScriptsKeyUp
    end
    object pnlScriptsFocusLeft: TPanel
      AlignWithMargins = True
      Left = 3
      Top = 43
      Width = 24
      Height = 807
      Align = alLeft
      Color = clBlack
      ParentBackground = False
      ShowCaption = False
      TabOrder = 2
    end
    object pnlScriptsFocusRight: TPanel
      AlignWithMargins = True
      Left = 376
      Top = 43
      Width = 24
      Height = 807
      Align = alRight
      Color = clBlack
      ParentBackground = False
      ShowCaption = False
      TabOrder = 3
    end
  end
  object pnlConsole: TPanel
    Left = 1433
    Top = 0
    Width = 350
    Height = 853
    Align = alRight
    BevelOuter = bvNone
    Caption = 'pnlConsole'
    Color = clWindow
    ParentBackground = False
    ShowCaption = False
    TabOrder = 3
    object labConsoleTitle: TStaticText
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 344
      Height = 34
      Align = alTop
      AutoSize = False
      Caption = 'Console instances (F4)'
      TabOrder = 0
    end
    object lbConsole: TListBox
      AlignWithMargins = True
      Left = 33
      Top = 43
      Width = 284
      Height = 807
      Align = alClient
      ItemHeight = 21
      Sorted = True
      TabOrder = 1
      OnDblClick = lbAppsDblClick
      OnKeyUp = lbAppsKeyUp
    end
    object pnlConsoleFocusLeft: TPanel
      AlignWithMargins = True
      Left = 3
      Top = 43
      Width = 24
      Height = 807
      Align = alLeft
      Color = clBlack
      ParentBackground = False
      ShowCaption = False
      TabOrder = 2
    end
    object pnlConsoleFocusRight: TPanel
      AlignWithMargins = True
      Left = 323
      Top = 43
      Width = 24
      Height = 807
      Align = alRight
      Color = clBlack
      ParentBackground = False
      ShowCaption = False
      TabOrder = 3
    end
  end
  object pnlDesktop: TPanel
    Left = 1789
    Top = 0
    Width = 350
    Height = 853
    Align = alRight
    BevelOuter = bvNone
    Caption = 'pnlDesktop'
    Color = clWindow
    ParentBackground = False
    ShowCaption = False
    TabOrder = 4
    object labDesktopTitle: TStaticText
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 344
      Height = 34
      Align = alTop
      AutoSize = False
      Caption = 'Desktop (F6)'
      TabOrder = 0
    end
    object lbDesktop: TListBox
      AlignWithMargins = True
      Left = 33
      Top = 43
      Width = 284
      Height = 807
      Align = alClient
      ItemHeight = 21
      Sorted = True
      TabOrder = 1
      OnDblClick = lbDesktopDblClick
      OnKeyUp = lbDesktopKeyUp
    end
    object pnlDesktopFocusLeft: TPanel
      AlignWithMargins = True
      Left = 3
      Top = 43
      Width = 24
      Height = 807
      Align = alLeft
      Color = clBlack
      ParentBackground = False
      ShowCaption = False
      TabOrder = 2
    end
    object pnlDesktopFocusRight: TPanel
      AlignWithMargins = True
      Left = 323
      Top = 43
      Width = 24
      Height = 807
      Align = alRight
      Color = clBlack
      ParentBackground = False
      ShowCaption = False
      TabOrder = 3
    end
  end
  object pnlShortCuts: TPanel
    Left = 2145
    Top = 0
    Width = 350
    Height = 853
    Align = alRight
    BevelOuter = bvNone
    Caption = 'pnlShortCuts'
    Color = clWindow
    ParentBackground = False
    ShowCaption = False
    TabOrder = 5
    object labShortCutsTitle: TStaticText
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 344
      Height = 34
      Align = alTop
      AutoSize = False
      Caption = 'ShortCuts (F7)'
      TabOrder = 0
    end
    object lbShortCuts: TListBox
      AlignWithMargins = True
      Left = 33
      Top = 43
      Width = 284
      Height = 807
      Align = alClient
      ItemHeight = 21
      Sorted = True
      TabOrder = 1
      OnDblClick = lbShortCutsDblClick
      OnKeyUp = lbShortCutsKeyUp
    end
    object pnlShortCutsFocusLeft: TPanel
      AlignWithMargins = True
      Left = 3
      Top = 43
      Width = 24
      Height = 807
      Align = alLeft
      Color = clBlack
      ParentBackground = False
      ShowCaption = False
      TabOrder = 2
    end
    object pnlShortCutsFocusRight: TPanel
      AlignWithMargins = True
      Left = 323
      Top = 43
      Width = 24
      Height = 807
      Align = alRight
      Color = clBlack
      ParentBackground = False
      ShowCaption = False
      TabOrder = 3
    end
  end
  object tmrChatMonitor: TTimer
    OnTimer = tmrChatMonitorTimer
    Left = 704
    Top = 432
  end
end
