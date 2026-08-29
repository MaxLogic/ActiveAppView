object MachineOverviewHelpFrm: TMachineOverviewHelpFrm
  Left = 0
  Top = 0
  Caption = 'Machine Overview Help'
  ClientHeight = 600
  ClientWidth = 760
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -13
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poOwnerFormCenter
  OnShow = FormShow
  TextHeight = 21
  object memHelp: TMemo
    AlignWithMargins = True
    Left = 3
    Top = 3
    Width = 754
    Height = 545
    Align = alClient
    Color = clWindow
    ParentFont = True
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 0
    WantReturns = False
    WordWrap = True
  end
  object pnlButtons: TPanel
    Left = 0
    Top = 551
    Width = 760
    Height = 49
    Align = alBottom
    BevelOuter = bvNone
    Caption = 'Help commands'
    ParentBackground = True
    ShowCaption = False
    TabOrder = 1
    object btnClose: TButton
      AlignWithMargins = True
      Left = 657
      Top = 3
      Width = 100
      Height = 43
      Align = alRight
      Cancel = True
      Caption = 'Close'
      ModalResult = 2
      TabOrder = 0
    end
  end
end
