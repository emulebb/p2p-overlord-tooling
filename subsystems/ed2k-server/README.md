# ED2K Server Subsystem

Notes for local Overlord ED2K server lifecycle and scenario-specific config
materialization.

Primary responsibilities:

- build and launch local Overlord ED2K server runtimes
- write isolated scenario config and source catalog files
- stop local Overlord ED2K server sessions and surface session metadata

Main orchestration consumers:

- private ED2K server download scenarios
- focused ED2K server triplet validation
