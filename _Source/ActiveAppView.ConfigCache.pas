unit ActiveAppView.ConfigCache;

interface

uses
  System.Classes, System.IOUtils, System.StrUtils, System.SysUtils,
  MaxLogic.Cache;

type
  TStringArray = TArray<string>;

  TPrefixRule = record
    Prefix: string;
    CaptionMask: string;
    FileNameMask: string;
    AppUserModelIDMask: string;
    CmdParamsMask: string;
  end;

  TReviewRule = record
    CaptionMask: string;
    FileNameMask: string;
    AppUserModelIDMask: string;
    CmdParamsMask: string;
    ExcludeCaptionMask: string;
    ExcludeFileNameMask: string;
    ExcludeAppUserModelIDMask: string;
    ExcludeCmdParamsMask: string;
  end;

  TNamedValue = record
    Name: string;
    Value: string;
  end;

  TPrefixRuleArray = TArray<TPrefixRule>;
  TReviewRuleArray = TArray<TReviewRule>;
  TNamedValueArray = TArray<TNamedValue>;

  IStringArraySnapshot = interface(IInterface)
    ['{BD95EFE5-9235-425F-8C04-E47E4C71B4F7}']
    function GetItems: TStringArray;
    property Items: TStringArray read GetItems;
  end;

  IPrefixRuleArraySnapshot = interface(IInterface)
    ['{4D3D8909-4022-4838-8DFC-FE8F89B09666}']
    function GetItems: TPrefixRuleArray;
    property Items: TPrefixRuleArray read GetItems;
  end;

  IReviewRuleArraySnapshot = interface(IInterface)
    ['{F4CC5C7D-3D84-48D6-968D-E3F95F2B9C30}']
    function GetItems: TReviewRuleArray;
    property Items: TReviewRuleArray read GetItems;
  end;

  INamedValueArraySnapshot = interface(IInterface)
    ['{61DF8FD7-8AFE-4D8A-B4EB-11FB9AA9F159}']
    function GetItems: TNamedValueArray;
    property Items: TNamedValueArray read GetItems;
  end;

  TConfigCache = class
  private
    fCache: IMaxCache;
    fInstallDir: string;
    function ResolveFileName(const aFileName: string): string;
    class function ReadNormalizedLines(const aFileName: string): TStringArray; static;
    class function ParsePrefixRules(const aFileName: string): TPrefixRuleArray; static;
    class function ParseReviewRules(const aFileName: string): TReviewRuleArray; static;
    class function ParseShortCuts(const aFileName: string): TNamedValueArray; static;
  public
    constructor Create(const aInstallDir: string);
    function GetHideMasks(const aFileName: string): TStringArray;
    function GetPrefixRules(const aFileName: string): TPrefixRuleArray;
    function GetReviewRules(const aFileName: string): TReviewRuleArray;
    function GetShortCuts(const aFileName: string): TNamedValueArray;
    function GetTerminalPatterns(const aFileName: string): TStringArray;
  end;

implementation

type
  TStringArraySnapshot = class(TInterfacedObject, IStringArraySnapshot)
  private
    fItems: TStringArray;
  public
    constructor Create(const aItems: TStringArray);
    function GetItems: TStringArray;
  end;

  TPrefixRuleArraySnapshot = class(TInterfacedObject, IPrefixRuleArraySnapshot)
  private
    fItems: TPrefixRuleArray;
  public
    constructor Create(const aItems: TPrefixRuleArray);
    function GetItems: TPrefixRuleArray;
  end;

  TReviewRuleArraySnapshot = class(TInterfacedObject, IReviewRuleArraySnapshot)
  private
    fItems: TReviewRuleArray;
  public
    constructor Create(const aItems: TReviewRuleArray);
    function GetItems: TReviewRuleArray;
  end;

  TNamedValueArraySnapshot = class(TInterfacedObject, INamedValueArraySnapshot)
  private
    fItems: TNamedValueArray;
  public
    constructor Create(const aItems: TNamedValueArray);
    function GetItems: TNamedValueArray;
  end;

const
  cNamespaceHideMask = 'activeappview.hide-mask';
  cNamespacePrefixMask = 'activeappview.prefix-mask';
  cNamespaceReviewMask = 'activeappview.review-mask';
  cNamespaceShortCuts = 'activeappview.shortcuts';
  cNamespaceTerminalPatterns = 'activeappview.terminal-patterns';
  cConfigValidateIntervalMs = 1000;

{ TStringArraySnapshot }

constructor TStringArraySnapshot.Create(const aItems: TStringArray);
begin
  inherited Create;
  fItems := Copy(aItems);
end;

function TStringArraySnapshot.GetItems: TStringArray;
begin
  Result := Copy(fItems);
end;

{ TPrefixRuleArraySnapshot }

constructor TPrefixRuleArraySnapshot.Create(const aItems: TPrefixRuleArray);
begin
  inherited Create;
  fItems := Copy(aItems);
end;

function TPrefixRuleArraySnapshot.GetItems: TPrefixRuleArray;
begin
  Result := Copy(fItems);
end;

{ TReviewRuleArraySnapshot }

constructor TReviewRuleArraySnapshot.Create(const aItems: TReviewRuleArray);
begin
  inherited Create;
  fItems := Copy(aItems);
end;

function TReviewRuleArraySnapshot.GetItems: TReviewRuleArray;
begin
  Result := Copy(fItems);
end;

{ TNamedValueArraySnapshot }

constructor TNamedValueArraySnapshot.Create(const aItems: TNamedValueArray);
begin
  inherited Create;
  fItems := Copy(aItems);
end;

function TNamedValueArraySnapshot.GetItems: TNamedValueArray;
begin
  Result := Copy(fItems);
end;

{ TConfigCache }

constructor TConfigCache.Create(const aInstallDir: string);
var
  lConfig: TMaxCacheConfig;
begin
  inherited Create;
  fInstallDir := aInstallDir;

  lConfig := TMaxCacheConfig.Default;
  lConfig.CaseSensitiveKeys := False;
  lConfig.SweepIntervalMs := 0;
  fCache := TMaxCache.New(lConfig);
end;

function TConfigCache.ResolveFileName(const aFileName: string): string;
begin
  Result := aFileName;
  if TPath.IsRelativePath(Result) then
    Result := TPath.Combine(fInstallDir, Result);
end;

class function TConfigCache.ReadNormalizedLines(const aFileName: string): TStringArray;
var
  lLines: TStringList;
  lLine: string;
  lIndex: Integer;
  lResultIndex: Integer;
begin
  SetLength(Result, 0);
  if not TFile.Exists(aFileName) then
    Exit;

  lLines := TStringList.Create;
  try
    lLines.LoadFromFile(aFileName, TEncoding.UTF8);
    SetLength(Result, lLines.Count);
    lResultIndex := 0;
    for lIndex := 0 to lLines.Count - 1 do
    begin
      lLine := Trim(lLines[lIndex]);
      if (lLine = '') or StartsText('#', lLine) or StartsText(';', lLine) then
        Continue;
      Result[lResultIndex] := lLine;
      Inc(lResultIndex);
    end;
    SetLength(Result, lResultIndex);
  finally
    lLines.Free;
  end;
end;

class function TConfigCache.ParsePrefixRules(const aFileName: string): TPrefixRuleArray;
var
  lEqPos: Integer;
  lIndex: Integer;
  lKey: string;
  lLine: string;
  lLines: TStringArray;
  lParts: TStringList;
  lPart: string;
  lResultIndex: Integer;
  lRule: TPrefixRule;
  lValue: string;
begin
  lLines := ReadNormalizedLines(aFileName);
  SetLength(Result, 0);
  if Length(lLines) = 0 then
    Exit;

  lParts := TStringList.Create;
  try
    lParts.CaseSensitive := False;
    lParts.StrictDelimiter := True;
    SetLength(Result, Length(lLines));
    lResultIndex := 0;
    for lLine in lLines do
    begin
      lParts.CommaText := lLine;
      lRule := Default(TPrefixRule);
      for lIndex := 0 to lParts.Count - 1 do
      begin
        lPart := Trim(lParts[lIndex]);
        if lPart = '' then
          Continue;

        lEqPos := Pos('=', lPart);
        if lEqPos <= 1 then
          Continue;

        lKey := Trim(Copy(lPart, 1, lEqPos - 1));
        if lKey = '' then
          Continue;

        lValue := Trim(Copy(lPart, lEqPos + 1, MaxInt));
        if SameText(lKey, 'prefix') then
          lRule.Prefix := lValue
        else if SameText(lKey, 'caption') then
          lRule.CaptionMask := lValue
        else if SameText(lKey, 'filename') then
          lRule.FileNameMask := lValue
        else if SameText(lKey, 'AppUserModelID') then
          lRule.AppUserModelIDMask := lValue
        else if SameText(lKey, 'CmdParams') then
          lRule.CmdParamsMask := lValue;
      end;

      if (lRule.Prefix = '') and (lRule.CaptionMask = '') and (lRule.FileNameMask = '')
        and (lRule.AppUserModelIDMask = '') and (lRule.CmdParamsMask = '') then
        Continue;

      Result[lResultIndex] := lRule;
      Inc(lResultIndex);
    end;
    SetLength(Result, lResultIndex);
  finally
    lParts.Free;
  end;
end;

class function TConfigCache.ParseReviewRules(const aFileName: string): TReviewRuleArray;
var
  lEqPos: Integer;
  lIndex: Integer;
  lKey: string;
  lLine: string;
  lLines: TStringArray;
  lParts: TStringList;
  lPart: string;
  lResultIndex: Integer;
  lRule: TReviewRule;
  lValue: string;
begin
  lLines := ReadNormalizedLines(aFileName);
  SetLength(Result, 0);
  if Length(lLines) = 0 then
    Exit;

  lParts := TStringList.Create;
  try
    lParts.CaseSensitive := False;
    lParts.StrictDelimiter := True;
    SetLength(Result, Length(lLines));
    lResultIndex := 0;
    for lLine in lLines do
    begin
      lParts.CommaText := lLine;
      lRule := Default(TReviewRule);
      for lIndex := 0 to lParts.Count - 1 do
      begin
        lPart := Trim(lParts[lIndex]);
        if lPart = '' then
          Continue;

        lEqPos := Pos('=', lPart);
        if lEqPos <= 1 then
          Continue;

        lKey := Trim(Copy(lPart, 1, lEqPos - 1));
        if lKey = '' then
          Continue;

        lValue := Trim(Copy(lPart, lEqPos + 1, MaxInt));
        if SameText(lKey, 'caption') then
          lRule.CaptionMask := lValue
        else if SameText(lKey, 'filename') then
          lRule.FileNameMask := lValue
        else if SameText(lKey, 'AppUserModelID') then
          lRule.AppUserModelIDMask := lValue
        else if SameText(lKey, 'CmdParams') then
          lRule.CmdParamsMask := lValue
        else if SameText(lKey, 'excludeCaption') then
          lRule.ExcludeCaptionMask := lValue
        else if SameText(lKey, 'excludeFileName') then
          lRule.ExcludeFileNameMask := lValue
        else if SameText(lKey, 'excludeAppUserModelID') then
          lRule.ExcludeAppUserModelIDMask := lValue
        else if SameText(lKey, 'excludeCmdParams') then
          lRule.ExcludeCmdParamsMask := lValue;
      end;

      if (lRule.CaptionMask = '') and (lRule.FileNameMask = '')
        and (lRule.AppUserModelIDMask = '') and (lRule.CmdParamsMask = '')
        and (lRule.ExcludeCaptionMask = '') and (lRule.ExcludeFileNameMask = '')
        and (lRule.ExcludeAppUserModelIDMask = '') and (lRule.ExcludeCmdParamsMask = '') then
        Continue;

      Result[lResultIndex] := lRule;
      Inc(lResultIndex);
    end;
    SetLength(Result, lResultIndex);
  finally
    lParts.Free;
  end;
end;

class function TConfigCache.ParseShortCuts(const aFileName: string): TNamedValueArray;
var
  lLine: string;
  lLines: TStringArray;
  lResultIndex: Integer;
  lPos: Integer;
  lItem: TNamedValue;
begin
  lLines := ReadNormalizedLines(aFileName);
  SetLength(Result, 0);
  if Length(lLines) = 0 then
    Exit;

  SetLength(Result, Length(lLines));
  lResultIndex := 0;
  for lLine in lLines do
  begin
    lPos := Pos('=', lLine);
    if lPos <= 0 then
      Continue;

    lItem.Name := Trim(Copy(lLine, 1, lPos - 1));
    lItem.Value := Trim(Copy(lLine, lPos + 1, MaxInt));
    if (lItem.Name = '') or (lItem.Value = '') then
      Continue;

    Result[lResultIndex] := lItem;
    Inc(lResultIndex);
  end;
  SetLength(Result, lResultIndex);
end;

function TConfigCache.GetHideMasks(const aFileName: string): TStringArray;
var
  lCacheEntry: IStringArraySnapshot;
  lOptions: TMaxCacheOptions;
  lResolvedFileName: string;
  lValue: IInterface;
begin
  lResolvedFileName := ResolveFileName(aFileName);
  lOptions := TMaxCacheOptions.Create;
  try
    lOptions.Dependency := TMaxFileDependency.Create(lResolvedFileName);
    lOptions.ValidateIntervalMs := cConfigValidateIntervalMs;
    lValue := fCache.GetOrCreate(cNamespaceHideMask, lResolvedFileName,
      function: IInterface
      begin
        Result := TStringArraySnapshot.Create(ReadNormalizedLines(lResolvedFileName));
      end,
      lOptions);
  finally
    lOptions.Free;
  end;

  if Supports(lValue, IStringArraySnapshot, lCacheEntry) then
    Result := lCacheEntry.Items
  else
    SetLength(Result, 0);
end;

function TConfigCache.GetPrefixRules(const aFileName: string): TPrefixRuleArray;
var
  lCacheEntry: IPrefixRuleArraySnapshot;
  lOptions: TMaxCacheOptions;
  lResolvedFileName: string;
  lValue: IInterface;
begin
  lResolvedFileName := ResolveFileName(aFileName);
  lOptions := TMaxCacheOptions.Create;
  try
    lOptions.Dependency := TMaxFileDependency.Create(lResolvedFileName);
    lOptions.ValidateIntervalMs := cConfigValidateIntervalMs;
    lValue := fCache.GetOrCreate(cNamespacePrefixMask, lResolvedFileName,
      function: IInterface
      begin
        Result := TPrefixRuleArraySnapshot.Create(ParsePrefixRules(lResolvedFileName));
      end,
      lOptions);
  finally
    lOptions.Free;
  end;

  if Supports(lValue, IPrefixRuleArraySnapshot, lCacheEntry) then
    Result := lCacheEntry.Items
  else
    SetLength(Result, 0);
end;

function TConfigCache.GetReviewRules(const aFileName: string): TReviewRuleArray;
var
  lCacheEntry: IReviewRuleArraySnapshot;
  lOptions: TMaxCacheOptions;
  lResolvedFileName: string;
  lValue: IInterface;
begin
  lResolvedFileName := ResolveFileName(aFileName);
  lOptions := TMaxCacheOptions.Create;
  try
    lOptions.Dependency := TMaxFileDependency.Create(lResolvedFileName);
    lOptions.ValidateIntervalMs := cConfigValidateIntervalMs;
    lValue := fCache.GetOrCreate(cNamespaceReviewMask, lResolvedFileName,
      function: IInterface
      begin
        Result := TReviewRuleArraySnapshot.Create(ParseReviewRules(lResolvedFileName));
      end,
      lOptions);
  finally
    lOptions.Free;
  end;

  if Supports(lValue, IReviewRuleArraySnapshot, lCacheEntry) then
    Result := lCacheEntry.Items
  else
    SetLength(Result, 0);
end;

function TConfigCache.GetShortCuts(const aFileName: string): TNamedValueArray;
var
  lCacheEntry: INamedValueArraySnapshot;
  lOptions: TMaxCacheOptions;
  lResolvedFileName: string;
  lValue: IInterface;
begin
  lResolvedFileName := ResolveFileName(aFileName);
  lOptions := TMaxCacheOptions.Create;
  try
    lOptions.Dependency := TMaxFileDependency.Create(lResolvedFileName);
    lOptions.ValidateIntervalMs := cConfigValidateIntervalMs;
    lValue := fCache.GetOrCreate(cNamespaceShortCuts, lResolvedFileName,
      function: IInterface
      begin
        Result := TNamedValueArraySnapshot.Create(ParseShortCuts(lResolvedFileName));
      end,
      lOptions);
  finally
    lOptions.Free;
  end;

  if Supports(lValue, INamedValueArraySnapshot, lCacheEntry) then
    Result := lCacheEntry.Items
  else
    SetLength(Result, 0);
end;

function TConfigCache.GetTerminalPatterns(const aFileName: string): TStringArray;
var
  lCacheEntry: IStringArraySnapshot;
  lOptions: TMaxCacheOptions;
  lResolvedFileName: string;
  lValue: IInterface;
begin
  lResolvedFileName := ResolveFileName(aFileName);
  lOptions := TMaxCacheOptions.Create;
  try
    lOptions.Dependency := TMaxFileDependency.Create(lResolvedFileName);
    lOptions.ValidateIntervalMs := cConfigValidateIntervalMs;
    lValue := fCache.GetOrCreate(cNamespaceTerminalPatterns, lResolvedFileName,
      function: IInterface
      begin
        Result := TStringArraySnapshot.Create(ReadNormalizedLines(lResolvedFileName));
      end,
      lOptions);
  finally
    lOptions.Free;
  end;

  if Supports(lValue, IStringArraySnapshot, lCacheEntry) then
    Result := lCacheEntry.Items
  else
    SetLength(Result, 0);
end;

end.
