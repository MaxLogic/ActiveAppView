program AgentStateHook;

{ Harness hook: records Codex/Claude session state for ActiveAppView. See ActiveAppView.AgentState. }

{$APPTYPE CONSOLE}

{$R *.res}

uses
  MaxLogic.Windows.Identity in '..\..\MaxLogic\MaxLogicFoundation\MaxLogic.Windows.Identity.pas',
  ActiveAppView.AgentState in 'ActiveAppView.AgentState.pas';

begin
  ExitCode := RunAgentStateHook;
end.
