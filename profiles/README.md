# Profiles

Generated runtime profiles, profile templates, and profile materialization logic
belong here.

Deterministic oracle and agent runs should treat profiles as first-class
reproducibility inputs rather than ad-hoc copied config files.

Oracle harness policy:

- seeded `preferences.ini` files must contain only the minimal settings needed
  for the harness and scenario contract
- avoid carrying unrelated UI, history, or workstation-specific noise into
  deterministic seeded profiles
- canonical `nodes.dat` and `server.met` inputs are imported through an
  untracked local seed bundle; tracked files must not embed operator-local seed
  source paths
