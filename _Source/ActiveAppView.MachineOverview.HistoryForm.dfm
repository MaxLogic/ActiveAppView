object MachineOverviewHistoryFrm: TMachineOverviewHistoryFrm
  Left = 0
  Top = 0
  Caption = 'Machine Overview Incident History'
  ClientHeight = 680
  ClientWidth = 900
  Color = clBtnFace
  Constraints.MinHeight = 480
  Constraints.MinWidth = 680
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -13
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poOwnerFormCenter
  OnDestroy = FormDestroy
  OnShow = FormShow
  TextHeight = 21
  object pnlFilter: TPanel
    Left = 0
    Top = 0
    Width = 900
    Height = 52
    Align = alTop
    BevelOuter = bvNone
    Caption = 'Incident history filters'
    ParentBackground = True
    ShowCaption = False
    TabOrder = 0
    object cbFilter: TComboBox
      Left = 126
      Top = 10
      Width = 180
      Height = 29
      Style = csDropDownList
      ItemIndex = 0
      TabOrder = 0
      Text = 'Last 24 hours'
      OnChange = cbFilterChange
      Items.Strings = (
        'Last 24 hours'
        'Last 7 days'
        'All')
    end
    object btnRefresh: TButton
      Left = 316
      Top = 7
      Width = 110
      Height = 37
      Caption = '&Refresh'
      TabOrder = 1
      OnClick = btnRefreshClick
    end
    object labFilter: TStaticText
      Left = 12
      Top = 14
      Width = 104
      Height = 21
      Caption = 'Show incidents:'
      TabOrder = 2
      TabStop = False
    end
  end
  object lvIncidents: TListView
    AlignWithMargins = True
    Left = 3
    Top = 55
    Width = 894
    Height = 260
    Align = alTop
    Columns = <
      item
        Caption = 'Time'
        Width = 170
      end
      item
        Caption = 'Severity'
        Width = 110
      end
      item
        Caption = 'Summary'
        Width = 580
      end>
    ColumnClick = False
    HideSelection = False
    ReadOnly = True
    RowSelect = True
    TabOrder = 1
    ViewStyle = vsReport
    OnSelectItem = lvIncidentsSelectItem
  end
  object splDetails: TSplitter
    Left = 0
    Top = 318
    Width = 900
    Height = 5
    Cursor = crVSplit
    Align = alTop
    AutoSnap = False
    MinSize = 120
  end
  object memDetails: TMemo
    AlignWithMargins = True
    Left = 3
    Top = 326
    Width = 894
    Height = 299
    Align = alClient
    Color = clWindow
    ParentFont = True
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 2
    WantReturns = False
    WordWrap = True
  end
  object pnlButtons: TPanel
    Left = 0
    Top = 628
    Width = 900
    Height = 52
    Align = alBottom
    BevelOuter = bvNone
    Caption = 'Incident history status and commands'
    ParentBackground = True
    ShowCaption = False
    TabOrder = 3
    object btnClose: TButton
      AlignWithMargins = True
      Left = 797
      Top = 3
      Width = 100
      Height = 46
      Align = alRight
      Cancel = True
      Caption = 'Close'
      ModalResult = 2
      TabOrder = 0
    end
    object labStatus: TStaticText
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 788
      Height = 46
      Align = alClient
      AutoSize = False
      Caption = 'Incident history has not been loaded.'
      TabOrder = 1
      TabStop = False
    end
  end
end
