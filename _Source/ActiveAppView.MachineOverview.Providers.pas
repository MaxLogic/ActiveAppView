unit ActiveAppView.MachineOverview.Providers;

interface

uses
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewMeasurement = record
    Name: string;
    EntityId: string;
    DisplayText: string;
    DetailText: string;
    StatusText: string;
    Value: Double;
    UnitText: string;
    Available: Boolean;
  end;

  TMachineOverviewProviderSample = record
    State: TMachineOverviewProviderState;
    Measurements: TArray<TMachineOverviewMeasurement>;
  end;

  IMachineOverviewProvider = interface(IInterface)
    ['{642614D1-9882-4314-848F-C12D4C6FB7A9}']
    function ProviderId: string;
    procedure Collect(out aSample: TMachineOverviewProviderSample);
  end;

implementation

end.
