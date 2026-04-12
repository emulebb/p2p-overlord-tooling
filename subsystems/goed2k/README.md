# goed2k Subsystem

Owns local goed2k-server lifecycle and scenario-specific config materialization.

Primary responsibilities:

- build and launch local goed2k-server runtimes
- write isolated scenario config and source catalog files
- stop local goed2k-server sessions and surface session metadata

Main orchestration consumers:

- private ED2K server download scenarios
- focused ED2K server triplet validation
