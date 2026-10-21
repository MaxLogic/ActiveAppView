object MachineOverviewHistoryFrm: TMachineOverviewHistoryFrm
  Left = 0
  Top = 0
  Caption = 'Machine Overview Incident History'
  ClientHeight = 680
  ClientWidth = 900
  Color = clBtnFace
  Constraints.MinHeight = 420
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
      TabStop = False
    end
  end
  object gridDetails: TGridPanel
    Align = alClient
    BevelOuter = bvNone
    Caption = ''
    ColumnCollection = <
      item
        Value = 100.000000000000000000
      end>
    ControlCollection = <
      item
        Column = 0
        Control = lvIncidents
        Row = 0
      end
      item
        Column = 0
        Control = lvEvidence
        Row = 2
      end
      item
        Column = 0
        Control = labEvidence
        Row = 1
      end
      item
        Column = 0
        Control = memDetails
        Row = 3
      end>
    RowCollection = <
      item
        Value = 30.000000000000000000
      end
      item
        SizeStyle = ssAbsolute
        Value = 24.000000000000000000
      end
      item
        Value = 35.000000000000000000
      end
      item
        Value = 35.000000000000000000
      end>
    TabOrder = 1
    object lvIncidents: TListView
      AlignWithMargins = True
      Left = 3
      Top = 55
      Width = 894
      Height = 180
      Align = alClient
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
      TabOrder = 0
      ViewStyle = vsReport
      OnSelectItem = lvIncidentsSelectItem
    end
    object lvEvidence: TListView
      AlignWithMargins = True
      Left = 3
      Top = 268
      Width = 894
      Height = 180
      Align = alClient
      Columns = <
        item
          Caption = 'Phase / contributor'
          Width = 165
        end
        item
          Caption = 'Identity'
          Width = 245
        end
        item
          Caption = 'Average'
          Width = 125
        end
        item
          Caption = 'Peak'
          Width = 125
        end
        item
          Caption = 'Peak time'
          Width = 90
        end
        item
          Caption = 'Measured'
          Width = 108
        end>
      ColumnClick = False
      HideSelection = False
      ReadOnly = True
      RowSelect = True
      TabOrder = 1
      ViewStyle = vsReport
    end
    object labEvidence: TStaticText
      AlignWithMargins = True
      Left = 3
      Top = 244
      Width = 894
      Height = 18
      Align = alClient
      Caption = 'Measured incident evidence:'
      TabStop = False
    end
    object memDetails: TMemo
      AlignWithMargins = True
      Left = 3
      Top = 459
      Width = 894
      Height = 166
      Align = alClient
      Color = clWindow
      ParentFont = True
      ReadOnly = True
      ScrollBars = ssVertical
      TabOrder = 2
      WantReturns = False
      WordWrap = True
    end
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
    TabOrder = 2
    object btnCopyEvidence: TButton
      AlignWithMargins = True
      Left = 641
      Top = 3
      Width = 150
      Height = 46
      Align = alRight
      Caption = '&Copy evidence'
      Enabled = False
      TabOrder = 0
      OnClick = btnCopyEvidenceClick
    end
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
      TabOrder = 1
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
      TabStop = False
    end
  end
end
