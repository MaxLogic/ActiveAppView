unit ActiveAppView.MachineOverview.Types;

interface

{$SCOPEDENUMS ON}

type
  TMachineOverviewSeverity = (Normal, Notice, Warning, Critical, Unavailable);
  TMachineOverviewAction = (None, OpenIncidentHistory);
  TMachineOverviewCommand = (None, FocusPanel, ToggleFullView,
    ToggleDisplayFrozen, CopySelectedRow, CopyFullDiagnostics);
  TMachineOverviewProviderStatus = (Available, Stale, Unavailable, Failed);
  TMachineOverviewShutdownResult = (Stopped, TimedOut);
  TMachineOverviewDiskReason = (None, ThroughputContext, ActiveTime, Latency, QueueLength);

  TMachineOverviewOptionalDouble = record
    Available: Boolean;
    Value: Double;
  end;

  TMachineOverviewProviderState = record
    ProviderId: string;
    Status: TMachineOverviewProviderStatus;
    CapturedAtUtc: TDateTime;
    CapturedAtMonotonicMs: UInt64;
    DataAgeMs: UInt64;
    ErrorText: string;
  end;

  TMachineOverviewProcessIdentity = record
    ProcessId: Cardinal;
    CreationTime100ns: UInt64;
  end;

  TMachineOverviewDiskIdentity = record
    StableId: string;
    DisplayName: string;
  end;

  TMachineOverviewWindowStatistics = record
    Available: Boolean;
    Average: Double;
    Peak: Double;
    ValidSampleCount: Integer;
    ExpectedSampleCount: UInt64;
    CoveragePercent: Double;
    CoverageSufficient: Boolean;
  end;

  TMachineOverviewCpuAggregate = record
    NowValue: TMachineOverviewOptionalDouble;
    NowCapturedAtMonotonicMs: UInt64;
    Window5Seconds: TMachineOverviewWindowStatistics;
    Window15Seconds: TMachineOverviewWindowStatistics;
    Window60Seconds: TMachineOverviewWindowStatistics;
    LogicalProcessorCount: Integer;
    HotLogicalProcessorCount: Integer;
  end;

  TMachineOverviewProcessMetric = record
    Identity: TMachineOverviewProcessIdentity;
    DisplayName: string;
    MetricAvailable: Boolean;
    MetricValue: Double;
  end;

  TMachineOverviewRankedProcess = record
    Rank: Integer;
    Metric: TMachineOverviewProcessMetric;
  end;

  TMachineOverviewDiskMetric = record
    Identity: TMachineOverviewDiskIdentity;
    Available: Boolean;
    SustainedActivePercent: Double;
    ReadMBPerSecond: Double;
    WriteMBPerSecond: Double;
    SustainedLatencyMs: Double;
    SustainedQueueLength: Double;
  end;

  TMachineOverviewDiskSelection = record
    Metric: TMachineOverviewDiskMetric;
    Severity: TMachineOverviewSeverity;
    Reason: TMachineOverviewDiskReason;
  end;

  TMachineOverviewRow = record
    RowId: string;
    Category: string;
    LabelText: string;
    ValueText: string;
    Severity: TMachineOverviewSeverity;
    Action: TMachineOverviewAction;
  end;

  TMachineOverviewPresentation = record
    CapturedAtUtc: TDateTime;
    Sequence: UInt64;
    Rows: TArray<TMachineOverviewRow>;
    DiagnosticText: string;
  end;

  IMachineOverviewView = interface(IInterface)
    ['{697D3BC4-F4B5-4D8F-B5C2-9951E2547D8F}']
    procedure Render(const aPresentation: TMachineOverviewPresentation);
    procedure SetDisplayFrozen(const aValue: Boolean);
    function SelectedRowId: string;
  end;

  IMachineOverviewCpuSample = interface(IInterface)
    ['{0D47A15F-1C44-4189-B66B-574965995118}']
    function CapturedAtMonotonicMs: UInt64;
    function CapturedAtUtc: TDateTime;
    function TotalCpu: TMachineOverviewOptionalDouble;
    function LogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
  end;

implementation

end.
